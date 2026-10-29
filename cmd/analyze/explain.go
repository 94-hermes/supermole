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
	state      explainState
	mode       explainMode
	requestID  int64
	startedAt  time.Time
	result     explanation
	err        error
	answeredAt time.Time
	stamp      explainStamp // the target when it was answered
	fromStore  bool         // answered in an earlier analyzer run
}

// explainSession holds the panel and the per-path answers for one analyzer
// run. entries is only touched on the event loop; workers report back
// through explainResultMsg.
type explainSession struct {
	ctx       context.Context
	cancel    context.CancelFunc
	inFlight  *sync.WaitGroup
	backend   explainBackend
	sources   explainSources
	entries   map[string]explainEntry
	nextID    int64
	panelOpen bool

	store       *explainStore // nil: answers last for this run only
	storeLoaded bool          // nothing is saved before the remembered answers are in
	storeDirty  bool          // an answer arrived before loading finished
	generation  int64
	storeErr    error
}

func newExplainSession(backend explainBackend) explainSession {
	ctx, cancel := context.WithCancel(context.Background())
	return explainSession{
		ctx:      ctx,
		cancel:   cancel,
		inFlight: &sync.WaitGroup{},
		backend:  backend,
		sources:  defaultExplainSources(),
		entries:  make(map[string]explainEntry),
		store:    defaultExplainStore(),
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
	stamp  explainStamp
	err    error
}

type explainStoreLoadedMsg struct {
	answers map[string]storedExplanation
	err     error
}

type explainStoreSavedMsg struct {
	err error
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
	return m, tea.Batch(m.explain.command(job), m.startTick())
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

// command runs job on a worker. The caller has already counted it in inFlight.
func (s explainSession) command(job explainJob) tea.Cmd {
	return func() tea.Msg {
		defer s.inFlight.Done()
		return explainResultMsg{requestID: job.requestID, outcomes: runExplainJob(s.ctx, s.backend, s.sources, job)}
	}
}

// runExplainJob asks for every row of the job in one request and returns one
// outcome per row: its answer, or why it has none.
func runExplainJob(ctx context.Context, backend explainBackend, sources explainSources, job explainJob) map[string]explainOutcome {
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
		promptItems[i] = explainPromptItem{id: ids[i], target: item.target, facts: gatherExplainFacts(ctx, item, sources)}
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
		outcomes[item.target.Path] = explainOutcome{result: result, stamp: promptItems[i].facts.stamp}
	}
	return outcomes
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
	answered := false
	for path, outcome := range msg.outcomes {
		entry, ok := m.explain.entries[path]
		if !ok || entry.state != explainLoading || entry.requestID != msg.requestID {
			continue
		}
		if outcome.err != nil {
			entry.state = explainFailed
			entry.err = outcome.err
		} else {
			entry = explainEntry{
				state:      explainDone,
				mode:       entry.mode,
				requestID:  entry.requestID,
				result:     outcome.result,
				answeredAt: time.Now(),
				stamp:      outcome.stamp,
			}
			answered = true
		}
		m.explain.entries[path] = entry
	}
	if !answered {
		return m, nil
	}
	return m, m.persistExplanations()
}

// loadStoreCommand reads the remembered answers off the event loop.
func (s explainSession) loadStoreCommand() tea.Cmd {
	if s.store == nil {
		return nil
	}
	store := s.store
	return func() tea.Msg {
		answers, err := store.load(time.Now())
		return explainStoreLoadedMsg{answers: answers, err: err}
	}
}

// handleExplainStoreLoaded adds remembered answers under any given this run.
// An unreadable store is started over; one that cannot be read at all is left
// alone and this run does not save.
func (m model) handleExplainStoreLoaded(msg explainStoreLoadedMsg) (tea.Model, tea.Cmd) {
	m.explain.storeErr = msg.err
	if msg.err != nil && !errors.Is(msg.err, errExplainStoreCorrupt) {
		m.explain.store = nil
		return m, nil
	}
	for path, answer := range msg.answers {
		if _, known := m.explain.entries[path]; !known {
			m.explain.entries[path] = answer.entry()
		}
	}
	m.explain.storeLoaded = true
	m.keepSelectionVisible()
	if !m.explain.storeDirty {
		return m, nil
	}
	m.explain.storeDirty = false
	return m, m.persistExplanations()
}

func (m model) handleExplainStoreSaved(msg explainStoreSavedMsg) (tea.Model, tea.Cmd) {
	m.explain.storeErr = msg.err
	return m, nil
}

// persistExplanations saves a snapshot of every answer whose target existed
// when it was given: a target that was already gone cannot be checked on the
// next run. The write runs on a worker; the snapshot is taken here, on the
// event loop.
func (m *model) persistExplanations() tea.Cmd {
	if m.explain.store == nil {
		return nil
	}
	if !m.explain.storeLoaded {
		m.explain.storeDirty = true
		return nil
	}
	snapshot := make(map[string]storedExplanation, len(m.explain.entries))
	for path, entry := range m.explain.entries {
		if entry.state == explainDone && entry.stamp.Exists {
			snapshot[path] = storedFromEntry(entry)
		}
	}
	m.explain.generation++
	store, generation := m.explain.store, m.explain.generation
	return func() tea.Msg {
		return explainStoreSavedMsg{err: store.save(snapshot, generation)}
	}
}

// forgetExplanations drops the answers about deleted paths and everything
// inside them, so a new item at the same path is never described by them.
func (m *model) forgetExplanations(removedPaths []string) tea.Cmd {
	forgotten := false
	for path := range m.explain.entries {
		for _, removed := range removedPaths {
			if pathIsWithin(path, removed) {
				delete(m.explain.entries, path)
				forgotten = true
				break
			}
		}
	}
	if !forgotten {
		return nil
	}
	return m.persistExplanations()
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
