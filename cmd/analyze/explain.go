//go:build darwin

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
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

var errExplainItemMissing = errors.New("pas de réponse pour cet élément")

// explainOutcome is one row's share of a finished request.
type explainOutcome struct {
	result explanation
	err    error
}

type explainResultMsg struct {
	requestID int64
	outcomes  map[string]explainOutcome // by target path, one per row of the job
}

// explainJobItem is one row of a request. cached holds sizes copied from the
// scan cache on the event loop; nil lists the directory off the event loop.
type explainJobItem struct {
	target explainTarget
	cached *explainContents
}

// explainJob is the immutable input a worker receives: one row, a batch of
// rows, or a deep look at one row.
type explainJob struct {
	requestID int64
	mode      explainMode
	items     []explainJobItem
}

func (job explainJob) timeout() time.Duration {
	switch {
	case job.mode == explainDeep:
		return explainDeepTimeout
	case len(job.items) > 1:
		return explainBatchTimeout
	default:
		return explainQuickTimeout
	}
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
	job := explainJob{requestID: m.explain.nextID, mode: mode, items: []explainJobItem{m.explainJobItem(target)}}
	m.explain.entries[target.Path] = explainEntry{state: explainLoading, mode: mode, requestID: job.requestID, startedAt: time.Now()}
	m.explain.inFlight.Add(1)
	return m, tea.Batch(explainCmd(m.explain.ctx, m.explain.inFlight, m.explain.backend, job), m.startTick())
}

// explainJobItem copies what a worker needs from the scan cache, which
// belongs to the event loop.
func (m model) explainJobItem(target explainTarget) explainJobItem {
	item := explainJobItem{target: target}
	if cached, ok := m.cache[target.Path]; ok && target.IsDir && len(cached.Entries) > 0 {
		contents := cachedExplainContents(cached.Entries)
		item.cached = &contents
	}
	return item
}

func explainCmd(ctx context.Context, inFlight *sync.WaitGroup, backend explainBackend, job explainJob) tea.Cmd {
	return func() tea.Msg {
		defer inFlight.Done()
		return explainResultMsg{requestID: job.requestID, outcomes: runExplainJob(ctx, backend, job)}
	}
}

// runExplainJob asks for every row of the job in one request and returns one
// outcome per row: its answer, or why it has none.
func runExplainJob(ctx context.Context, backend explainBackend, job explainJob) map[string]explainOutcome {
	outcomes := make(map[string]explainOutcome, len(job.items))
	failAll := func(err error) map[string]explainOutcome {
		for _, item := range job.items {
			outcomes[item.target.Path] = explainOutcome{err: err}
		}
		return outcomes
	}

	scratch, err := os.MkdirTemp("", explainScratchPrefix)
	if err != nil {
		return failAll(fmt.Errorf("dossier temporaire : %w", err))
	}
	// Only schema and answer files live here; a failed removal leaves a few
	// bytes in the per-user temp directory that macOS purges.
	defer os.RemoveAll(scratch) //nolint:errcheck

	ids := make([]string, len(job.items))
	promptItems := make([]explainPromptItem, len(job.items))
	for i, item := range job.items {
		ids[i] = strconv.Itoa(i + 1)
		promptItems[i] = explainPromptItem{id: ids[i], target: item.target, facts: gatherExplainFacts(item)}
	}

	var answers map[string]explanation
	provider, err := askExplainProviders(ctx, backend, explainCall{
		prompt:  buildExplainPrompt(promptItems, job.mode, time.Now()),
		mode:    job.mode,
		timeout: job.timeout(),
		workDir: explainWorkDir(job, scratch),
		scratch: scratch,
	}, func(reply json.RawMessage) error {
		decoded, decodeErr := decodeExplainItems(reply, ids)
		answers = decoded
		return decodeErr
	})
	if err != nil {
		return failAll(err)
	}

	for i, item := range job.items {
		result, ok := answers[ids[i]]
		if !ok {
			outcomes[item.target.Path] = explainOutcome{err: errExplainItemMissing}
			continue
		}
		result.Provider = provider
		result.Explored = job.mode == explainDeep
		outcomes[item.target.Path] = explainOutcome{result: result}
	}
	return outcomes
}

// gatherExplainFacts collects what Mole knows locally about one row. It runs
// on a worker, never on the event loop.
func gatherExplainFacts(item explainJobItem) explainFacts {
	var facts explainFacts
	switch {
	case item.cached != nil:
		facts.contents = *item.cached
	case item.target.IsDir:
		facts.contents = readExplainContents(item.target.Path)
	}
	return facts
}

// explainWorkDir is the one directory an agent may read. The quick pass and a
// batch get an empty scratch directory; the deep pass, always a single row,
// gets the target itself, or the folder holding a selected file.
func explainWorkDir(job explainJob, scratch string) string {
	if job.mode != explainDeep || len(job.items) != 1 {
		return scratch
	}
	target := job.items[0].target
	if target.IsDir {
		return target.Path
	}
	return filepath.Dir(target.Path)
}

func (m model) handleExplainResult(msg explainResultMsg) (tea.Model, tea.Cmd) {
	for path, outcome := range msg.outcomes {
		entry, ok := m.explain.entries[path]
		if !ok || entry.state != explainLoading || entry.requestID != msg.requestID {
			continue
		}
		if outcome.err != nil {
			entry.state = explainFailed
			entry.err = outcome.err
		} else {
			entry.state = explainDone
			entry.result = outcome.result
			entry.err = nil
		}
		m.explain.entries[path] = entry
	}
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
