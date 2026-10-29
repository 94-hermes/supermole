//go:build darwin

package main

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
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
			return []byte(r.reply), r.err
		},
	}
}

func (r *recordingExplainBackend) calls() []explainCommand {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]explainCommand(nil), r.commands...)
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

func TestExplainLimitsConcurrentRequests(t *testing.T) {
	m := newExplainTestModel(t, &recordingExplainBackend{reply: claudeReplyJSON(explainVerdictSafe, false)})
	m.entries = nil
	for i := range explainMaxConcurrent + 1 {
		m.entries = append(m.entries, dirEntry{Name: fmt.Sprintf("d%d", i), Path: filepath.Join(m.path, fmt.Sprintf("d%d", i)), Size: 1, IsDir: true})
	}
	m.entriesAll = m.entries

	for i := range m.entries {
		m.selected = i
		m, _ = pressExplainKey(t, m, explainKey)
	}
	if loading := m.explain.loadingCount(); loading != explainMaxConcurrent {
		t.Fatalf("loading = %d, want %d", loading, explainMaxConcurrent)
	}
	last := m.explain.entries[m.entries[explainMaxConcurrent].Path]
	if last.state != explainFailed || !errors.Is(last.err, errExplainBusy) {
		t.Fatalf("over-limit request = %+v, want a busy failure", last)
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
