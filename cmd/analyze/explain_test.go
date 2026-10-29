//go:build darwin

package main

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

var explainKey = tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("e")}

// recordingExplainBackend answers every Claude call with reply (or fails with
// err) and records each command it was asked to run.
type recordingExplainBackend struct {
	mu       sync.Mutex
	commands []explainCommand
	reply    string
	err      error
	// batchVerdict, when set, answers every row id the prompt lists.
	batchVerdict explainVerdict
}

func (r *recordingExplainBackend) backend() explainBackend {
	return explainBackend{
		find: func(name string) (string, error) {
			if name != "claude" {
				return "", errExplainBinaryMissing
			}
			return "/fake/claude", nil
		},
		run: func(_ context.Context, command explainCommand) ([]byte, error) {
			r.mu.Lock()
			defer r.mu.Unlock()
			r.commands = append(r.commands, command)
			if r.batchVerdict != "" {
				return []byte(claudeBatchReply(command.stdin, r.batchVerdict)), r.err
			}
			return []byte(r.reply), r.err
		},
	}
}

func (r *recordingExplainBackend) calls() []explainCommand {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]explainCommand(nil), r.commands...)
}

var promptItemIDPattern = regexp.MustCompile(`Élément id « (\d+) »`)

// claudeBatchReply answers every row id the prompt lists with verdict.
func claudeBatchReply(prompt string, verdict explainVerdict) string {
	var items []string
	for _, match := range promptItemIDPattern.FindAllStringSubmatch(prompt, -1) {
		items = append(items, fmt.Sprintf(`{"id":%q,"verdict":%q,"what":"Un dossier.","if_deleted":"x","advice":"y","needs_exploration":false}`, match[1], verdict))
	}
	return `{"is_error":false,"structured_output":{"items":[` + strings.Join(items, ",") + `]}}`
}

func claudeReplyJSON(verdict explainVerdict, needsExploration bool) string {
	return fmt.Sprintf(`{"is_error":false,"structured_output":{"items":[{"id":"1","verdict":%q,"what":"Des faux iPhone pour Xcode.",`+
		`"if_deleted":"Tu perds leurs apps.","advice":"Passe par Xcode.","needs_exploration":%t}]}}`, verdict, needsExploration)
}

func newExplainTestModel(t *testing.T, recorder *recordingExplainBackend) model {
	t.Helper()
	m := newModel(t.TempDir(), false)
	m.scanning = false
	m.width = 100
	m.height = 40
	m.entries = []dirEntry{
		{Name: "Devices", Path: filepath.Join(m.path, "Devices"), Size: 7 << 30, IsDir: true},
		{Name: "device_set.plist", Path: filepath.Join(m.path, "device_set.plist"), Size: 4 << 10},
	}
	m.entriesAll = m.entries
	m.explain = newExplainSession(recorder.backend())
	// No app inventory or Spotlight lookups: UI tests stay hermetic.
	m.explain.sources = explainSources{}
	// Never the real ~/.cache: each test remembers answers in its own store.
	m.explain.store = newExplainStore(filepath.Join(t.TempDir(), "answers.json"))
	// Cancel only: requests a test dispatches but never runs would hold
	// shutdownExplain for its whole grace period.
	t.Cleanup(m.explain.cancel)
	return m
}

func pressExplainKey(t *testing.T, m model, key tea.KeyMsg) (model, tea.Cmd) {
	t.Helper()
	next, cmd := m.Update(key)
	return next.(model), cmd
}

// collectExplainResults runs a returned command, including batched ones, and
// keeps the explain results. Tick commands just sleep one UI interval.
func collectExplainResults(t *testing.T, cmd tea.Cmd) []explainResultMsg {
	t.Helper()
	if cmd == nil {
		return nil
	}
	var results []explainResultMsg
	switch msg := cmd().(type) {
	case tea.BatchMsg:
		for _, inner := range msg {
			results = append(results, collectExplainResults(t, inner)...)
		}
	case explainResultMsg:
		results = append(results, msg)
	}
	return results
}

// deliverExplainResults runs cmd and feeds its explain results back in.
func deliverExplainResults(t *testing.T, m model, cmd tea.Cmd) model {
	t.Helper()
	results := collectExplainResults(t, cmd)
	if len(results) == 0 {
		t.Fatal("no explain request was dispatched")
	}
	for _, result := range results {
		next, _ := m.Update(result)
		m = next.(model)
	}
	return m
}

func TestExplainKeyAsksOnceAndShowsAnswer(t *testing.T) {
	recorder := &recordingExplainBackend{reply: claudeReplyJSON(explainVerdictCaution, false)}
	m := newExplainTestModel(t, recorder)
	target := m.entries[0].Path

	m, cmd := pressExplainKey(t, m, explainKey)
	if !m.explain.panelOpen || m.explain.entries[target].state != explainLoading || cmd == nil {
		t.Fatalf("first E: open=%v entry=%+v cmd=%v", m.explain.panelOpen, m.explain.entries[target], cmd != nil)
	}
	m, repeat := pressExplainKey(t, m, explainKey)
	if repeat != nil {
		t.Fatal("E while loading must not start a second request")
	}

	m = deliverExplainResults(t, m, cmd)
	if calls := recorder.calls(); len(calls) != 1 {
		t.Fatalf("agent ran %d times, want 1", len(calls))
	}
	entry := m.explain.entries[target]
	if entry.state != explainDone || entry.result.Provider != "Claude" {
		t.Fatalf("entry = %+v", entry)
	}
	view := ansi.Strip(m.View())
	for _, want := range []string{"● PRUDENCE", "C'est quoi : Des faux iPhone pour Xcode.", "Devices · " + humanizeBytes(7<<30) + " · Claude", "E/Esc : fermer"} {
		if !strings.Contains(view, want) {
			t.Fatalf("panel lacks %q:\n%s", want, view)
		}
	}
}

func TestExplainKeyExploresOnlyWhenUnsure(t *testing.T) {
	recorder := &recordingExplainBackend{reply: claudeReplyJSON(explainVerdictUnknown, true)}
	m := newExplainTestModel(t, recorder)
	target := m.entries[0].Path

	m, cmd := pressExplainKey(t, m, explainKey)
	m = deliverExplainResults(t, m, cmd)
	if !strings.Contains(ansi.Strip(m.View()), "E : regarder dedans (lecture seule)") {
		t.Fatal("an unsure answer must offer the read-only look")
	}

	recorder.reply = claudeReplyJSON(explainVerdictSafe, false)
	m, cmd = pressExplainKey(t, m, explainKey)
	if m.explain.entries[target].mode != explainDeep {
		t.Fatalf("second E on an unsure answer must explore, entry = %+v", m.explain.entries[target])
	}
	m = deliverExplainResults(t, m, cmd)
	calls := recorder.calls()
	deep := calls[len(calls)-1]
	if tools := argAfter(t, deep.args, "--tools"); tools != explainClaudeDeepTools || deep.dir != target {
		t.Fatalf("deep pass tools=%q dir=%q, want read-only tools inside %s", tools, deep.dir, target)
	}
	if result := m.explain.entries[target].result; !result.Explored || result.Verdict != explainVerdictSafe {
		t.Fatalf("deep result = %+v", result)
	}

	m, cmd = pressExplainKey(t, m, explainKey)
	if cmd != nil || m.explain.panelOpen {
		t.Fatal("E after exploration must close the panel without asking again")
	}
}

func TestExplainKeyClosesAndReopensConfidentAnswer(t *testing.T) {
	recorder := &recordingExplainBackend{reply: claudeReplyJSON(explainVerdictKeep, false)}
	m := newExplainTestModel(t, recorder)

	m, cmd := pressExplainKey(t, m, explainKey)
	m = deliverExplainResults(t, m, cmd)
	m, cmd = pressExplainKey(t, m, explainKey)
	if cmd != nil || m.explain.panelOpen {
		t.Fatal("E on a confident answer must close the panel")
	}
	m, cmd = pressExplainKey(t, m, explainKey)
	if cmd != nil || !m.explain.panelOpen {
		t.Fatal("E on a closed panel with a stored answer must reopen it without a request")
	}
	if len(recorder.calls()) != 1 {
		t.Fatalf("agent ran %d times, want 1", len(recorder.calls()))
	}
}

func TestExplainKeyRetriesFailure(t *testing.T) {
	recorder := &recordingExplainBackend{err: errors.New("Not logged in")}
	m := newExplainTestModel(t, recorder)
	target := m.entries[0].Path

	m, cmd := pressExplainKey(t, m, explainKey)
	m = deliverExplainResults(t, m, cmd)
	entry := m.explain.entries[target]
	if entry.state != explainFailed || !strings.Contains(entry.err.Error(), "Claude : Not logged in") {
		t.Fatalf("entry = %+v", entry)
	}
	view := ansi.Strip(m.View())
	if !strings.Contains(view, "Impossible d'obtenir une explication.") || !strings.Contains(view, "E : réessayer") {
		t.Fatalf("failure not shown:\n%s", view)
	}

	recorder.err = nil
	recorder.reply = claudeReplyJSON(explainVerdictSafe, false)
	m, cmd = pressExplainKey(t, m, explainKey)
	m = deliverExplainResults(t, m, cmd)
	if m.explain.entries[target].state != explainDone {
		t.Fatalf("retry did not recover: %+v", m.explain.entries[target])
	}
}

func TestExplainEscClosesPanelBeforeGoingBack(t *testing.T) {
	m := newExplainTestModel(t, &recordingExplainBackend{reply: claudeReplyJSON(explainVerdictSafe, false)})
	m.history = []historyEntry{{Path: filepath.Dir(m.path)}}
	path := m.path

	m, _ = pressExplainKey(t, m, explainKey)
	m, _ = pressExplainKey(t, m, tea.KeyMsg{Type: tea.KeyEsc})
	if m.explain.panelOpen || m.path != path {
		t.Fatalf("first Esc: open=%v path=%s, want the panel closed and the directory kept", m.explain.panelOpen, m.path)
	}
	m, _ = pressExplainKey(t, m, tea.KeyMsg{Type: tea.KeyEsc})
	if m.path == path {
		t.Fatal("second Esc must go back as before")
	}
}

func TestExplainKeyIgnoredWhileDeletingOrConfirming(t *testing.T) {
	for _, state := range []string{"deleting", "confirming"} {
		t.Run(state, func(t *testing.T) {
			recorder := &recordingExplainBackend{reply: claudeReplyJSON(explainVerdictSafe, false)}
			m := newExplainTestModel(t, recorder)
			if state == "deleting" {
				m.deleting = true
			} else {
				m.deleteConfirm = true
				m.deleteTarget = &m.entries[0]
			}
			m, cmd := pressExplainKey(t, m, explainKey)
			if cmd != nil || m.explain.panelOpen || len(m.explain.entries) != 0 {
				t.Fatalf("E must do nothing while %s", state)
			}
		})
	}
}

func TestExplainKeyTypesIntoFilter(t *testing.T) {
	m := newExplainTestModel(t, &recordingExplainBackend{})
	m.entryFiltering = true

	m, _ = pressExplainKey(t, m, explainKey)
	if m.entryFilter != "e" || m.explain.panelOpen {
		t.Fatalf("filter=%q open=%v, want E typed into the filter", m.entryFilter, m.explain.panelOpen)
	}
}

// directoryRows replaces the model's rows with n one-byte folders.
func directoryRows(m *model, n int) {
	m.entries = nil
	for i := range n {
		name := fmt.Sprintf("d%02d", i)
		m.entries = append(m.entries, dirEntry{Name: name, Path: filepath.Join(m.path, name), Size: 1, IsDir: true})
	}
	m.entriesAll = m.entries
}

func countStates(m model, state explainState) int {
	count := 0
	for _, entry := range m.explain.entries {
		if entry.state == state {
			count++
		}
	}
	return count
}

func TestExplainQueuesBeyondConcurrentRequests(t *testing.T) {
	m := newExplainTestModel(t, &recordingExplainBackend{reply: claudeReplyJSON(explainVerdictSafe, false)})
	directoryRows(&m, explainMaxConcurrent+1)

	var cmds []tea.Cmd
	for i := range m.entries {
		m.selected = i
		var cmd tea.Cmd
		m, cmd = pressExplainKey(t, m, explainKey)
		cmds = append(cmds, cmd)
	}
	if len(m.explain.active) != explainMaxConcurrent || countStates(m, explainQueued) != 1 {
		t.Fatalf("active = %d, queued = %d, want %d running and 1 waiting", len(m.explain.active), countStates(m, explainQueued), explainMaxConcurrent)
	}
	if cmds[explainMaxConcurrent] != nil {
		t.Fatal("a queued request must not start a worker")
	}

	next, follow := m.Update(collectExplainResults(t, cmds[0])[0])
	m = next.(model)
	last := m.explain.entries[m.entries[explainMaxConcurrent].Path]
	if last.state != explainLoading || len(m.explain.active) != explainMaxConcurrent || follow == nil {
		t.Fatalf("waiting row = %+v, active = %d: a finished request must start the next one", last, len(m.explain.active))
	}
}

func TestBatchExplainAsksOnlyVisibleRows(t *testing.T) {
	recorder := &recordingExplainBackend{batchVerdict: explainVerdictSafe}
	m := newExplainTestModel(t, recorder)
	directoryRows(&m, 45)
	visible := m.listViewport(false)

	m, cmd := pressExplainKey(t, m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("E")})
	if got := countStates(m, explainLoading) + countStates(m, explainQueued); got != visible {
		t.Fatalf("asked about %d rows, want the %d visible ones", got, visible)
	}
	if _, asked := m.explain.entries[m.entries[visible].Path]; asked {
		t.Fatal("a row below the screen must not be asked about")
	}
	if len(m.explain.active) != min(explainMaxConcurrent, (visible+explainBatchSize-1)/explainBatchSize) {
		t.Fatalf("active requests = %d", len(m.explain.active))
	}

	m = runAndApply(t, m, cmd)
	for _, call := range recorder.calls() {
		if n := len(promptItemIDPattern.FindAllString(call.stdin, -1)); n > explainBatchSize {
			t.Fatalf("a request carried %d rows, more than %d", n, explainBatchSize)
		}
	}
	if countStates(m, explainDone) != visible || m.explain.busy() {
		t.Fatalf("done = %d, busy = %v, want all %d visible rows answered", countStates(m, explainDone), m.explain.busy(), visible)
	}
}

func TestBatchExplainSkipsAnsweredRowsAndRetriesFailures(t *testing.T) {
	recorder := &recordingExplainBackend{batchVerdict: explainVerdictSafe}
	m := newExplainTestModel(t, recorder)
	directoryRows(&m, 3)
	answered, failed, fresh := m.entries[0].Path, m.entries[1].Path, m.entries[2].Path
	m.explain.entries[answered] = explainEntry{state: explainDone, result: explanation{Verdict: explainVerdictKeep, What: "x"}}
	m.explain.entries[failed] = explainEntry{state: explainFailed, err: errors.New("Not logged in")}

	m, cmd := pressExplainKey(t, m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("E")})
	m = runAndApply(t, m, cmd)
	prompt := recorder.calls()[0].stdin
	if strings.Contains(prompt, answered) || !strings.Contains(prompt, displayPath(failed)) || !strings.Contains(prompt, displayPath(fresh)) {
		t.Fatalf("batch prompt must skip the answered row and retry the failed one:\n%s", prompt)
	}
	if m.explain.entries[answered].result.Verdict != explainVerdictKeep {
		t.Fatal("an answered row must keep its answer")
	}
	if _, cmd := pressExplainKey(t, m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("E")}); cmd != nil {
		t.Fatal("with every row answered, E must do nothing")
	}
}

func TestSingleExplainGoesAheadOfQueuedBatches(t *testing.T) {
	m := newExplainTestModel(t, &recordingExplainBackend{batchVerdict: explainVerdictSafe})
	directoryRows(&m, 90)
	m, first := pressExplainKey(t, m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("E")})
	m.offset = m.listViewport(false)
	m, _ = pressExplainKey(t, m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("E")})
	if len(m.explain.queue) == 0 {
		t.Fatal("a second screen while three requests run must wait in the queue")
	}

	m.selected = len(m.entries) - 1
	m, _ = pressExplainKey(t, m, explainKey)
	single := m.entries[len(m.entries)-1].Path
	if m.explain.queue[0].items[0].target.Path != single {
		t.Fatalf("queue head = %s, want the row asked about with e", m.explain.queue[0].items[0].target.Path)
	}

	results := collectExplainResults(t, first)
	next, _ := m.Update(results[0])
	if got := next.(model).explain.entries[single]; got.state != explainLoading {
		t.Fatalf("single row = %+v, want it started by the first free slot", got)
	}
}

func TestExplainIgnoresStaleResult(t *testing.T) {
	m := newExplainTestModel(t, &recordingExplainBackend{reply: claudeReplyJSON(explainVerdictSafe, false)})
	target := m.entries[0].Path
	m, _ = pressExplainKey(t, m, explainKey)

	next, _ := m.Update(explainResultMsg{requestID: m.explain.entries[target].requestID + 1, outcomes: map[string]explainOutcome{target: {result: explanation{Verdict: explainVerdictSafe, What: "x"}}}})
	if got := next.(model).explain.entries[target]; got.state != explainLoading {
		t.Fatalf("stale result replaced the pending request: %+v", got)
	}
}

func TestExplainSendsCachedChildSizes(t *testing.T) {
	recorder := &recordingExplainBackend{reply: claudeReplyJSON(explainVerdictSafe, false)}
	m := newExplainTestModel(t, recorder)
	target := m.entries[0].Path
	m.cache[target] = historyEntry{Path: target, Entries: []dirEntry{{Name: "8A1B-UUID", Size: 2 << 30, IsDir: true}}}

	m, cmd := pressExplainKey(t, m, explainKey)
	deliverExplainResults(t, m, cmd)
	if prompt := recorder.calls()[0].stdin; !strings.Contains(prompt, "- 8A1B-UUID/ : "+humanizeBytes(2<<30)) {
		t.Fatalf("cached child sizes missing from prompt:\n%s", prompt)
	}
}

func TestExplainTargetFollowsActiveView(t *testing.T) {
	m := newExplainTestModel(t, &recordingExplainBackend{})
	m.showLargeFiles = true
	m.largeFiles = []fileEntry{{Name: "big.iso", Path: "/tmp/big.iso", Size: 5 << 30}}
	if target, ok := m.explainTarget(); !ok || target.Path != "/tmp/big.iso" || target.IsDir {
		t.Fatalf("top files target = %+v, %v", target, ok)
	}

	overview := model{path: "/", isOverview: true}
	overview.entries = []dirEntry{{Name: "Xcode Simulators", Path: "/Users/me/Library/Developer/CoreSimulator", Size: -1, IsDir: true}}
	if target, ok := overview.explainTarget(); !ok || target.Label != "Xcode Simulators" {
		t.Fatalf("overview target = %+v, %v", target, ok)
	}

	m.largeFiles = nil
	m, cmd := pressExplainKey(t, m, explainKey)
	if cmd != nil || m.explain.panelOpen {
		t.Fatal("E with nothing selected must not open the panel")
	}
}

func TestExplainPanelKeepsViewInsideTerminal(t *testing.T) {
	m := newExplainTestModel(t, &recordingExplainBackend{})
	m.entries = nil
	for i := range 100 {
		m.entries = append(m.entries, dirEntry{Name: fmt.Sprintf("dir-%03d", i), Path: filepath.Join(m.path, fmt.Sprintf("dir-%03d", i)), Size: int64(1000 - i), IsDir: true})
	}
	m.entriesAll = m.entries
	m.totalSize = 100_000
	closedRows := m.listViewport(false)
	m.selected = closedRows - 1

	m, _ = pressExplainKey(t, m, explainKey)
	if got := m.listViewport(false); got >= closedRows {
		t.Fatalf("viewport = %d, want fewer than %d rows once the panel is open", got, closedRows)
	}
	if m.selected < m.offset || m.selected >= m.offset+m.listViewport(false) {
		t.Fatalf("selection %d left the viewport [%d, %d)", m.selected, m.offset, m.offset+m.listViewport(false))
	}
	if lines := strings.Count(m.View(), "\n"); lines > m.height {
		t.Fatalf("view has %d lines for a %d-row terminal", lines, m.height)
	}
}

func TestExplainPanelBordersAlign(t *testing.T) {
	long := strings.Repeat("Un dossier très très long à expliquer avec des accents é à ç. ", 6)
	reply := fmt.Sprintf(`{"structured_output":{"items":[{"id":"1","verdict":"caution","what":%q,"if_deleted":%q,"advice":%q,"needs_exploration":true}]}}`, long, long, long)
	for _, width := range []int{30, 80, 200} {
		t.Run(fmt.Sprint(width), func(t *testing.T) {
			m := newExplainTestModel(t, &recordingExplainBackend{reply: reply})
			m.width = width
			m.entries[0].Name = strings.Repeat("NomTrèsLong", 20)
			m, cmd := pressExplainKey(t, m, explainKey)
			m = deliverExplainResults(t, m, cmd)

			var panel strings.Builder
			m.writeExplainPanel(&panel)
			lines := strings.Split(strings.TrimRight(panel.String(), "\n"), "\n")[1:]
			if len(lines) != m.explainPanelRows()-1 {
				t.Fatalf("panel drew %d rows, budget is %d", len(lines), m.explainPanelRows()-1)
			}
			want := ansi.StringWidth(lines[0])
			for _, line := range lines {
				if got := ansi.StringWidth(line); got != want {
					t.Fatalf("row width %d != %d:\n%s", got, want, ansi.Strip(panel.String()))
				}
			}
			if !strings.Contains(ansi.Strip(panel.String()), explainPanelEllipsis) {
				t.Fatal("overflowing answer must end with an ellipsis")
			}
		})
	}
}

func TestExplainFooterAdvertisesKey(t *testing.T) {
	m := newExplainTestModel(t, &recordingExplainBackend{})
	if !strings.Contains(ansi.Strip(m.View()), "E Explain") {
		t.Fatal("footer must list the E key")
	}
}

func TestShutdownExplainCancelsRunningAgents(t *testing.T) {
	started := make(chan struct{})
	m := newExplainTestModel(t, &recordingExplainBackend{})
	m.explain.backend.run = func(ctx context.Context, _ explainCommand) ([]byte, error) {
		close(started)
		<-ctx.Done()
		return nil, ctx.Err()
	}

	m, cmd := pressExplainKey(t, m, explainKey)
	results := make(chan []explainResultMsg, 1)
	go func() { results <- collectExplainResults(t, cmd) }()
	<-started

	begin := time.Now()
	m.shutdownExplain()
	if elapsed := time.Since(begin); elapsed >= explainShutdownGrace {
		t.Fatalf("shutdown waited the full grace (%s); the running agent was not canceled", elapsed)
	}
	if got := <-results; len(got) != 1 || !errors.Is(got[0].outcomes[m.entries[0].Path].err, context.Canceled) {
		t.Fatalf("results = %+v, want one canceled request", got)
	}
}

// runAndApply runs cmd, feeds every message it produces back into m and keeps
// going with whatever those updates return. UI ticks are skipped.
func runAndApply(t *testing.T, m model, cmd tea.Cmd) model {
	t.Helper()
	queue := []tea.Cmd{cmd}
	for len(queue) > 0 {
		next := queue[0]
		queue = queue[1:]
		if next == nil {
			continue
		}
		switch msg := next().(type) {
		case tea.BatchMsg:
			queue = append(queue, msg...)
		case tickMsg:
		default:
			updated, follow := m.Update(msg)
			m = updated.(model)
			queue = append(queue, follow)
		}
	}
	return m
}

// materializeEntries creates the test model's rows on disk, which persisted
// answers need so they can be checked on the next run.
func materializeEntries(t *testing.T, m model) {
	t.Helper()
	for _, entry := range m.entries {
		var err error
		if entry.IsDir {
			err = os.MkdirAll(entry.Path, 0o755)
		} else {
			err = os.WriteFile(entry.Path, nil, 0o600)
		}
		if err != nil {
			t.Fatal(err)
		}
	}
}

func TestExplainAnswerIsSavedOnlyAfterStoreLoads(t *testing.T) {
	m := newExplainTestModel(t, &recordingExplainBackend{reply: claudeReplyJSON(explainVerdictSafe, false)})
	materializeEntries(t, m)
	target := m.entries[0].Path

	m, cmd := pressExplainKey(t, m, explainKey)
	m = runAndApply(t, m, cmd)
	if _, err := os.Stat(m.explain.store.path); !errors.Is(err, fs.ErrNotExist) || !m.explain.storeDirty {
		t.Fatalf("stat err = %v, dirty = %v: nothing may be written before the remembered answers are in", err, m.explain.storeDirty)
	}

	m = runAndApply(t, m, m.explain.loadStoreCommand())
	saved, err := m.explain.store.load(time.Now())
	if err != nil || saved[target].Verdict != explainVerdictSafe || m.explain.storeErr != nil {
		t.Fatalf("saved = %+v, err = %v, storeErr = %v", saved, err, m.explain.storeErr)
	}
}

func TestExplainRememberedAnswersComeBackWithoutAsking(t *testing.T) {
	recorder := &recordingExplainBackend{reply: claudeReplyJSON(explainVerdictSafe, false)}
	m := newExplainTestModel(t, recorder)
	materializeEntries(t, m)
	target := m.entries[0].Path
	answer := storedAnswer(true, modTimeOf(t, target), time.Now().Add(-24*time.Hour))
	answer.Verdict = explainVerdictKeep
	if err := m.explain.store.save(map[string]storedExplanation{target: answer}, 1); err != nil {
		t.Fatal(err)
	}

	m = runAndApply(t, m, m.explain.loadStoreCommand())
	entry := m.explain.entries[target]
	if entry.state != explainDone || !entry.fromStore || entry.result.Verdict != explainVerdictKeep {
		t.Fatalf("remembered entry = %+v", entry)
	}
	m, cmd := pressExplainKey(t, m, explainKey)
	if cmd != nil || !m.explain.panelOpen || len(recorder.calls()) != 0 {
		t.Fatal("a remembered answer must open without asking the model again")
	}
}

func TestExplainAnswerFromThisRunWinsOverRemembered(t *testing.T) {
	m := newExplainTestModel(t, &recordingExplainBackend{reply: claudeReplyJSON(explainVerdictSafe, false)})
	materializeEntries(t, m)
	target := m.entries[0].Path
	if err := m.explain.store.save(map[string]storedExplanation{target: storedAnswer(true, modTimeOf(t, target), time.Now().Add(-time.Hour))}, 1); err != nil {
		t.Fatal(err)
	}

	m, cmd := pressExplainKey(t, m, explainKey)
	m = runAndApply(t, m, cmd)
	m = runAndApply(t, m, m.explain.loadStoreCommand())
	if entry := m.explain.entries[target]; entry.fromStore {
		t.Fatalf("a remembered answer replaced this run's: %+v", entry)
	}
}

func TestExplainForgetsDeletedPaths(t *testing.T) {
	m := newExplainTestModel(t, &recordingExplainBackend{})
	m.explain.storeLoaded = true
	devices := m.entries[0].Path
	done := explainEntry{state: explainDone, result: explanation{Verdict: explainVerdictSafe, What: "x"}}
	m.explain.entries = map[string]explainEntry{
		devices:                            done,
		filepath.Join(devices, "UUID"):     done,
		devices + "-sibling":               done,
		filepath.Join(m.path, "untouched"): done,
	}

	next, _ := m.Update(deleteProgressMsg{done: true, path: devices, count: 1})
	got := next.(model).explain.entries
	if _, ok := got[devices]; ok || len(got) != 2 {
		t.Fatalf("entries after delete = %v, want the folder and its contents forgotten", got)
	}
	if _, ok := got[devices+"-sibling"]; !ok {
		t.Fatal("a sibling sharing the name prefix must stay")
	}
}

func TestExplainUnreadableStoreTurnsSavingOff(t *testing.T) {
	m := newExplainTestModel(t, &recordingExplainBackend{})
	m.explain.store = newExplainStore(t.TempDir()) // a directory cannot be read as a file

	m = runAndApply(t, m, m.explain.loadStoreCommand())
	if m.explain.store != nil || m.explain.storeErr == nil {
		t.Fatalf("store = %v, storeErr = %v: an unreadable store must stop saving and say why", m.explain.store, m.explain.storeErr)
	}
}

func answeredEntry(verdict explainVerdict) explainEntry {
	return explainEntry{state: explainDone, result: explanation{Verdict: verdict, What: "x", Provider: "Claude"}}
}

// viewLine returns the stripped view line that mentions name.
func viewLine(t *testing.T, m model, name string) string {
	t.Helper()
	for line := range strings.SplitSeq(ansi.Strip(m.View()), "\n") {
		if strings.Contains(line, name) {
			return line
		}
	}
	t.Fatalf("no line mentions %q:\n%s", name, ansi.Strip(m.View()))
	return ""
}

func TestExplainRowMarksReplaceTheSeparator(t *testing.T) {
	m := newExplainTestModel(t, &recordingExplainBackend{})
	directoryRows(&m, 5)
	m.totalSize = 5
	m.explain.entries[m.entries[0].Path] = answeredEntry(explainVerdictSafe)
	m.explain.entries[m.entries[1].Path] = answeredEntry(explainVerdictKeep)
	m.explain.entries[m.entries[2].Path] = explainEntry{state: explainLoading}
	m.explain.entries[m.entries[3].Path] = explainEntry{state: explainFailed, err: errors.New("x")}

	for name, mark := range map[string]string{"d00": "●", "d01": "●", "d02": "◌", "d03": "!", "d04": "|"} {
		if line := viewLine(t, m, name); !strings.Contains(line, mark+"  📁 "+name) {
			t.Fatalf("row %s = %q, want mark %q in the separator column", name, line, mark)
		}
	}
	if !strings.Contains(m.View(), colorGreen+explainVerdictMark) || !strings.Contains(m.View(), colorRed+explainVerdictMark) {
		t.Fatal("verdict marks must carry their verdict colour")
	}

	m.liveScanningPaths = map[string]bool{m.entries[0].Path: true}
	if line := viewLine(t, m, "d00"); strings.Contains(line, "●") || !strings.ContainsAny(line, strings.Join(spinnerFrames, "")) {
		t.Fatalf("row being scanned = %q, want the scan spinner over the mark", line)
	}
}

func TestExplainRowMarksInTopFilesAndOverview(t *testing.T) {
	m := newExplainTestModel(t, &recordingExplainBackend{})
	m.showLargeFiles = true
	m.largeFiles = []fileEntry{{Name: "big.iso", Path: filepath.Join(m.path, "big.iso"), Size: 5 << 30}}
	m.explain.entries[m.largeFiles[0].Path] = answeredEntry(explainVerdictSafe)
	if line := viewLine(t, m, "big.iso"); !strings.Contains(line, "●  📄") {
		t.Fatalf("top files row = %q", line)
	}

	overview := newExplainTestModel(t, &recordingExplainBackend{})
	overview.path, overview.isOverview = "/", true
	overview.entries = []dirEntry{{Name: "Applications", Path: "/Applications", Size: 21 << 30, IsDir: true}}
	overview.totalSize = 21 << 30
	overview.explain.entries["/Applications"] = answeredEntry(explainVerdictKeep)
	if line := viewLine(t, overview, "Applications"); !strings.Contains(line, "●  Applications") {
		t.Fatalf("overview row = %q", line)
	}
}

func TestExplainSummaryCountsEachByteOnce(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	library := filepath.Join(home, "Library")
	m := newExplainTestModel(t, &recordingExplainBackend{})
	m.path, m.isOverview = "/", true
	m.entries = []dirEntry{
		{Name: "Home", Path: home, Size: 30 << 30, IsDir: true},
		{Name: "User Library", Path: library, Size: 58 << 30, IsDir: true},
		{Name: "Xcode Simulators", Path: filepath.Join(library, "Developer", "CoreSimulator"), Size: 7 << 30, IsDir: true},
		{Name: "Old Downloads", Path: filepath.Join(home, "Downloads"), Size: 2 << 30, IsDir: true},
		{Name: "Applications", Path: "/Applications", Size: 21 << 30, IsDir: true},
	}
	m.explain.entries[home] = answeredEntry(explainVerdictKeep)
	m.explain.entries[library] = answeredEntry(explainVerdictCaution)
	m.explain.entries[m.entries[2].Path] = answeredEntry(explainVerdictSafe)
	m.explain.entries[m.entries[3].Path] = answeredEntry(explainVerdictSafe)
	m.explain.entries["/Applications"] = explainEntry{state: explainQueued}

	summary := m.explainSummaryOf()
	want := map[explainVerdict]int64{
		explainVerdictSafe:    9 << 30,  // the simulators and old downloads
		explainVerdictCaution: 51 << 30, // the Library minus the simulators inside it
		explainVerdictKeep:    28 << 30, // Home holds Downloads but, as measured, not ~/Library
	}
	for verdict, size := range want {
		if summary.size[verdict] != size {
			t.Fatalf("%s = %s, want %s", verdict, humanizeBytes(summary.size[verdict]), humanizeBytes(size))
		}
	}
	line := ansi.Strip(m.explainSummaryLine())
	for _, part := range []string{"● Supprimable " + humanizeBytes(9<<30), "● Prudence " + humanizeBytes(51<<30), "● À garder " + humanizeBytes(28<<30), "◌ 1 en cours"} {
		if !strings.Contains(line, part) {
			t.Fatalf("summary %q lacks %q", line, part)
		}
	}
	if strings.Index(line, "Supprimable") > strings.Index(line, "Prudence") {
		t.Fatalf("summary %q must list the most reclaimable verdict first", line)
	}
}

func TestExplainSummaryTakesRowsOnlyWhenShown(t *testing.T) {
	m := newExplainTestModel(t, &recordingExplainBackend{})
	directoryRows(&m, 60)
	m.totalSize = 60
	m.height = 30 // below calculateViewport's 30-row cap, so every row counts
	before := m.listViewport(false)
	if m.explainSummaryLine() != "" || m.explainSummaryRows() != 0 {
		t.Fatal("no summary before anything is asked")
	}

	m.selected = before - 1
	m.explain.entries[m.entries[0].Path] = answeredEntry(explainVerdictSafe)
	m.keepSelectionVisible()
	if got := m.listViewport(false); got != before-m.explainSummaryRows() || m.explainSummaryRows() != 2 {
		t.Fatalf("viewport = %d, want %d minus the summary", got, before)
	}
	if m.selected < m.offset || m.selected >= m.offset+m.listViewport(false) {
		t.Fatal("the summary pushed the selection off screen")
	}
	if lines := strings.Count(m.View(), "\n"); lines > m.height {
		t.Fatalf("view has %d lines for %d rows", lines, m.height)
	}

	m.width = 40
	if width := ansi.StringWidth(m.explainSummaryLine()); width > m.width {
		t.Fatalf("summary is %d columns wide on a %d-column terminal", width, m.width)
	}
}

func TestExplainSummaryShowsStoreError(t *testing.T) {
	m := newExplainTestModel(t, &recordingExplainBackend{})
	m.explain.storeErr = errors.New("disque plein")
	if line := ansi.Strip(m.explainSummaryLine()); !strings.Contains(line, "mémoire : disque plein") {
		t.Fatalf("summary %q must say the answers are not being saved", line)
	}
}
