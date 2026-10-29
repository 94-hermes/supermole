//go:build darwin

package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

const (
	// Each request is a full agent process; keep a burst of E presses cheap.
	explainMaxConcurrent = 3
	explainShutdownGrace = 2 * time.Second
)

var errExplainBusy = fmt.Errorf("déjà %d explications en cours, réessaie dans un instant", explainMaxConcurrent)

type explainState int

const (
	explainLoading explainState = iota
	explainDone
	explainFailed
)

type explainEntry struct {
	state     explainState
	mode      explainMode
	requestID int64
	startedAt time.Time
	result    explanation
	err       error
}

// explainSession holds the panel and the per-path answers for one analyzer
// run. entries is only touched on the event loop; workers report back
// through explainResultMsg.
type explainSession struct {
	ctx       context.Context
	cancel    context.CancelFunc
	inFlight  *sync.WaitGroup
	backend   explainBackend
	entries   map[string]explainEntry
	nextID    int64
	panelOpen bool
}

func newExplainSession(backend explainBackend) explainSession {
	ctx, cancel := context.WithCancel(context.Background())
	return explainSession{
		ctx:      ctx,
		cancel:   cancel,
		inFlight: &sync.WaitGroup{},
		backend:  backend,
		entries:  make(map[string]explainEntry),
	}
}

func (s explainSession) loadingCount() int {
	count := 0
	for _, entry := range s.entries {
		if entry.state == explainLoading {
			count++
		}
	}
	return count
}

type explainResultMsg struct {
	path      string
	requestID int64
	result    explanation
	err       error
}

// explainJob is the immutable input a worker receives.
type explainJob struct {
	requestID int64
	target    explainTarget
	mode      explainMode
	contents  *explainContents // nil: list the directory off the event loop
}

func (m model) explainTarget() (explainTarget, bool) {
	if m.showLargeFiles {
		if m.largeSelected < 0 || m.largeSelected >= len(m.largeFiles) {
			return explainTarget{}, false
		}
		file := m.largeFiles[m.largeSelected]
		return explainTarget{Label: file.Name, Path: file.Path, Size: file.Size}, true
	}
	if m.selected < 0 || m.selected >= len(m.entries) {
		return explainTarget{}, false
	}
	entry := m.entries[m.selected]
	return explainTarget{
		Label:      entry.Name,
		Path:       entry.Path,
		Size:       entry.Size,
		SizeState:  entry.State,
		IsDir:      entry.IsDir,
		LastAccess: entry.LastAccess,
		Cleanable:  entry.IsDir && isCleanableDir(entry.Path),
		AppBundle:  isAppBundleEntry(entry),
	}, true
}

// handleExplainKey opens the panel on the selected row, then walks it
// through quick answer, optional read-only exploration and close.
func (m model) handleExplainKey() (tea.Model, tea.Cmd) {
	target, ok := m.explainTarget()
	if !ok {
		return m, nil
	}
	wasOpen := m.explain.panelOpen
	if !wasOpen {
		m.explain.panelOpen = true
		m.keepSelectionVisible()
	}

	entry, known := m.explain.entries[target.Path]
	switch {
	case !known:
		return m.startExplain(target, explainQuick)
	case !wasOpen, entry.state == explainLoading:
		return m, nil
	case entry.state == explainFailed:
		return m.startExplain(target, entry.mode)
	case entry.result.NeedsExploration && !entry.result.Explored:
		return m.startExplain(target, explainDeep)
	default:
		m.closeExplainPanel()
		return m, nil
	}
}

func (m *model) closeExplainPanel() {
	m.explain.panelOpen = false
	m.keepSelectionVisible()
}

// keepSelectionVisible re-clamps the active list after the panel changes the
// number of rows it can show.
func (m *model) keepSelectionVisible() {
	if m.showLargeFiles {
		m.clampLargeSelection()
		return
	}
	if !m.inOverviewMode() {
		m.clampEntrySelection()
	}
}

func (m model) startExplain(target explainTarget, mode explainMode) (tea.Model, tea.Cmd) {
	if m.explain.ctx == nil {
		panelOpen := m.explain.panelOpen
		m.explain = newExplainSession(defaultExplainBackend())
		m.explain.panelOpen = panelOpen
	}
	if m.explain.loadingCount() >= explainMaxConcurrent {
		m.explain.entries[target.Path] = explainEntry{state: explainFailed, mode: mode, err: errExplainBusy}
		return m, nil
	}

	m.explain.nextID++
	job := explainJob{requestID: m.explain.nextID, target: target, mode: mode}
	// The scan cache belongs to the event loop, so copy what the worker needs now.
	if cached, ok := m.cache[target.Path]; ok && target.IsDir && len(cached.Entries) > 0 {
		contents := cachedExplainContents(cached.Entries)
		job.contents = &contents
	}
	m.explain.entries[target.Path] = explainEntry{state: explainLoading, mode: mode, requestID: job.requestID, startedAt: time.Now()}
	m.explain.inFlight.Add(1)
	return m, tea.Batch(explainCmd(m.explain.ctx, m.explain.inFlight, m.explain.backend, job), m.startTick())
}

func explainCmd(ctx context.Context, inFlight *sync.WaitGroup, backend explainBackend, job explainJob) tea.Cmd {
	return func() tea.Msg {
		defer inFlight.Done()
		result, err := runExplainJob(ctx, backend, job)
		return explainResultMsg{path: job.target.Path, requestID: job.requestID, result: result, err: err}
	}
}

func runExplainJob(ctx context.Context, backend explainBackend, job explainJob) (explanation, error) {
	var contents explainContents
	switch {
	case job.contents != nil:
		contents = *job.contents
	case job.target.IsDir:
		contents = readExplainContents(job.target.Path)
	}

	scratch, err := os.MkdirTemp("", explainScratchPrefix)
	if err != nil {
		return explanation{}, fmt.Errorf("dossier temporaire : %w", err)
	}
	// Only schema and answer files live here; a failed removal leaves a few
	// bytes in the per-user temp directory that macOS purges.
	defer os.RemoveAll(scratch) //nolint:errcheck

	return askExplainProviders(ctx, backend, explainCall{
		prompt:  buildExplainPrompt(job.target, contents, job.mode, time.Now()),
		mode:    job.mode,
		workDir: explainWorkDir(job, scratch),
		scratch: scratch,
	})
}

// explainWorkDir is the one directory an agent may read. The quick pass gets
// an empty scratch directory; the deep pass gets the target itself, or the
// folder holding a selected file.
func explainWorkDir(job explainJob, scratch string) string {
	if job.mode != explainDeep {
		return scratch
	}
	if job.target.IsDir {
		return job.target.Path
	}
	return filepath.Dir(job.target.Path)
}

func (m model) handleExplainResult(msg explainResultMsg) (tea.Model, tea.Cmd) {
	entry, ok := m.explain.entries[msg.path]
	if !ok || entry.state != explainLoading || entry.requestID != msg.requestID {
		return m, nil
	}
	if msg.err != nil {
		entry.state = explainFailed
		entry.err = msg.err
	} else {
		entry.state = explainDone
		entry.result = msg.result
		entry.err = nil
	}
	m.explain.entries[msg.path] = entry
	return m, nil
}

// shutdownExplain stops running agents when the analyzer exits, waiting a
// bounded time so their process groups are gone before Mole returns.
func (m model) shutdownExplain() {
	if m.explain.cancel == nil {
		return
	}
	m.explain.cancel()
	done := make(chan struct{})
	go func() {
		m.explain.inFlight.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(explainShutdownGrace):
	}
}
