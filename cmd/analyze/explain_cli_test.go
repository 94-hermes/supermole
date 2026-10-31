//go:build darwin

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func explainCLIRequest(t *testing.T, items ...explainCLIItem) string {
	t.Helper()
	data, err := json.Marshal(items)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func TestParseExplainItemsReadsWhatEachPathIsFromTheDisk(t *testing.T) {
	dir := t.TempDir()
	folder := filepath.Join(dir, "Caches")
	file := filepath.Join(dir, "movie.mov")
	if err := os.Mkdir(folder, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(file, []byte("12345"), 0o644); err != nil {
		t.Fatal(err)
	}

	items, err := parseExplainItems(explainCLIRequest(t,
		explainCLIItem{Path: folder, Label: "User caches", Size: 4096},
		explainCLIItem{Path: file},
	), explainQuick)
	if err != nil {
		t.Fatal(err)
	}

	if got := items[0].target; !got.IsDir || got.Label != "User caches" || got.Size != 4096 {
		t.Errorf("folder target = %+v", got)
	}
	// No label falls back to the name; no size reads the file's own.
	if got := items[1].target; got.IsDir || got.Label != "movie.mov" || got.Size != 5 {
		t.Errorf("file target = %+v", got)
	}
}

func TestParseExplainItemsRefusesWhatTheTUICouldNotAsk(t *testing.T) {
	dir := t.TempDir()
	tooMany := make([]explainCLIItem, explainBatchSize+1)
	for i := range tooMany {
		tooMany[i] = explainCLIItem{Path: dir}
	}
	cases := []struct {
		name string
		raw  string
		mode explainMode
		want string
	}{
		{"not JSON", "Caches", explainQuick, "JSON array"},
		{"empty", "[]", explainQuick, "at least one"},
		{"too many", explainCLIRequest(t, tooMany...), explainQuick, "at most"},
		{"deep on two", explainCLIRequest(t, explainCLIItem{Path: dir}, explainCLIItem{Path: dir}), explainDeep, "exactly one"},
		{"relative", explainCLIRequest(t, explainCLIItem{Path: "Library"}), explainQuick, "absolute"},
		{"missing", explainCLIRequest(t, explainCLIItem{Path: filepath.Join(dir, "gone")}), explainQuick, "cannot read"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := parseExplainItems(tc.raw, tc.mode)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Errorf("err = %v, want it to mention %q", err, tc.want)
			}
		})
	}
}

func TestRunExplainCLIPrintsAndKeepsEveryAnswer(t *testing.T) {
	dir := t.TempDir()
	first, second := filepath.Join(dir, "a"), filepath.Join(dir, "b")
	for _, path := range []string{first, second} {
		if err := os.Mkdir(path, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	store := newExplainStore(filepath.Join(dir, "store", explainStoreFileName))
	now := time.Now()
	// An answer the TUI gave earlier stays in the store.
	earlier := storedExplanation{Verdict: explainVerdictKeep, What: "Tes photos.", IsDir: true, AnsweredAt: now}
	if err := store.save(map[string]storedExplanation{dir: earlier}, 1); err != nil {
		t.Fatal(err)
	}
	items, err := parseExplainItems(explainCLIRequest(t, explainCLIItem{Path: first}, explainCLIItem{Path: second}), explainQuick)
	if err != nil {
		t.Fatal(err)
	}
	recorder := &recordingExplainBackend{batchVerdict: explainVerdictSafe}
	var stdout, stderr bytes.Buffer

	err = runExplainCLI(context.Background(), items, explainQuick, recorder.backend(), defaultExplainSources(),
		newExplainStore(store.path), now, &stdout, &stderr)
	if err != nil {
		t.Fatal(err)
	}

	var report explainCLIReport
	if err := json.Unmarshal(stdout.Bytes(), &report); err != nil {
		t.Fatalf("stdout is not the report: %v\n%s", err, stdout.String())
	}
	if len(recorder.calls()) != 1 {
		t.Errorf("asked %d times, want one request for the batch", len(recorder.calls()))
	}
	for _, path := range []string{first, second} {
		if report.Answers[path].Verdict != explainVerdictSafe || report.Answers[path].Provider != "Claude" {
			t.Errorf("answer for %s = %+v", path, report.Answers[path])
		}
	}
	saved, err := newExplainStore(store.path).load(now)
	if err != nil {
		t.Fatal(err)
	}
	if len(saved) != 3 || saved[dir].What != "Tes photos." || saved[first].Verdict != explainVerdictSafe {
		t.Errorf("store after the request = %+v", saved)
	}
	if stderr.Len() != 0 {
		t.Errorf("stderr = %q", stderr.String())
	}
}

func TestRunExplainCLIReportsAFailureWithoutTouchingTheStore(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "a")
	if err := os.Mkdir(target, 0o755); err != nil {
		t.Fatal(err)
	}
	storePath := filepath.Join(dir, "store", explainStoreFileName)
	items, err := parseExplainItems(explainCLIRequest(t, explainCLIItem{Path: target}), explainQuick)
	if err != nil {
		t.Fatal(err)
	}
	recorder := &recordingExplainBackend{err: errors.New("claude is logged out")}
	var stdout, stderr bytes.Buffer

	if err := runExplainCLI(context.Background(), items, explainQuick, recorder.backend(), defaultExplainSources(),
		newExplainStore(storePath), time.Now(), &stdout, &stderr); err != nil {
		t.Fatal(err)
	}

	var report explainCLIReport
	if err := json.Unmarshal(stdout.Bytes(), &report); err != nil {
		t.Fatal(err)
	}
	if len(report.Answers) != 0 || report.Errors[target] == "" {
		t.Errorf("report = %+v, want only an error for %s", report, target)
	}
	if _, err := os.Stat(storePath); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("store written after a failed request: %v", err)
	}
}
