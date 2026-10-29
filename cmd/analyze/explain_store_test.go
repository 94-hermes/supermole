//go:build darwin

package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func storedAnswer(isDir bool, modTime, answeredAt time.Time) storedExplanation {
	return storedExplanation{
		Verdict:    explainVerdictSafe,
		What:       "Un cache.",
		Provider:   "Claude",
		IsDir:      isDir,
		ModTime:    modTime,
		AnsweredAt: answeredAt,
	}
}

func modTimeOf(t *testing.T, path string) time.Time {
	t.Helper()
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	return info.ModTime()
}

func TestExplainStoreRoundTrip(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "Caches")
	if err := os.Mkdir(target, 0o755); err != nil {
		t.Fatal(err)
	}
	store := newExplainStore(filepath.Join(dir, "explain", "answers.json"))
	now := time.Now()
	saved := map[string]storedExplanation{target: storedAnswer(true, modTimeOf(t, target), now)}

	if err := store.save(saved, 1); err != nil {
		t.Fatalf("save() error = %v", err)
	}
	loaded, err := store.load(now)
	if err != nil || len(loaded) != 1 || loaded[target].What != "Un cache." || !loaded[target].AnsweredAt.Equal(now) {
		t.Fatalf("load() = %+v, %v", loaded, err)
	}
	for path, want := range map[string]os.FileMode{store.path: explainStoreFilePerm, filepath.Dir(store.path): explainStoreDirPerm} {
		if info, err := os.Stat(path); err != nil || info.Mode().Perm() != want {
			t.Fatalf("%s mode = %v, %v; want %v", path, info.Mode().Perm(), err, want)
		}
	}
}

func TestExplainStoreDropsAnswersThatNoLongerFit(t *testing.T) {
	dir := t.TempDir()
	now := time.Now()
	folder := filepath.Join(dir, "folder")
	file := filepath.Join(dir, "file.bin")
	if err := os.Mkdir(folder, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(file, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	folderTime, fileTime := modTimeOf(t, folder), modTimeOf(t, file)
	earlier := folderTime.Add(-time.Hour)
	explored := storedAnswer(true, earlier, now)
	explored.Explored = true

	tests := []struct {
		name   string
		path   string
		answer storedExplanation
		kept   bool
	}{
		{name: "fresh folder answer", path: folder, answer: storedAnswer(true, folderTime, now), kept: true},
		{name: "folder contents changed, quick answer", path: folder, answer: storedAnswer(true, earlier, now), kept: true},
		{name: "folder contents changed, answer read the files", path: folder, answer: explored},
		{name: "file unchanged", path: file, answer: storedAnswer(false, fileTime, now), kept: true},
		{name: "file changed", path: file, answer: storedAnswer(false, fileTime.Add(-time.Hour), now)},
		{name: "folder became a file", path: file, answer: storedAnswer(true, fileTime, now)},
		{name: "target gone", path: filepath.Join(dir, "gone"), answer: storedAnswer(true, folderTime, now)},
		{name: "older than the TTL", path: folder, answer: storedAnswer(true, folderTime, now.Add(-explainStoreTTL-time.Hour))},
		{name: "invalid verdict", path: folder, answer: storedExplanation{Verdict: "maybe", What: "x", IsDir: true, AnsweredAt: now}},
	}
	for i, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			store := newExplainStore(filepath.Join(dir, fmt.Sprintf("store-%d.json", i)))
			if err := store.save(map[string]storedExplanation{tt.path: tt.answer}, 1); err != nil {
				t.Fatal(err)
			}
			loaded, err := store.load(now)
			if _, kept := loaded[tt.path]; err != nil || kept != tt.kept {
				t.Fatalf("kept = %v, err = %v; want kept = %v", kept, err, tt.kept)
			}
		})
	}
}

func TestExplainStoreIgnoresOlderSnapshot(t *testing.T) {
	dir := t.TempDir()
	store := newExplainStore(filepath.Join(dir, "answers.json"))
	now := time.Now()
	newer := map[string]storedExplanation{dir: storedAnswer(true, modTimeOf(t, dir), now)}

	if err := store.save(newer, 2); err != nil {
		t.Fatal(err)
	}
	if err := store.save(map[string]storedExplanation{}, 1); err != nil {
		t.Fatal(err)
	}
	if loaded, err := store.load(now); err != nil || len(loaded) != 1 {
		t.Fatalf("an older snapshot overwrote a newer one: %+v, %v", loaded, err)
	}
}

func TestExplainStoreKeepsNewestAnswers(t *testing.T) {
	now := time.Now()
	answers := map[string]storedExplanation{}
	for i := range 5 {
		answers[fmt.Sprintf("/p%d", i)] = storedAnswer(true, now, now.Add(time.Duration(i)*time.Minute))
	}

	kept := newestAnswers(answers, 3)
	if len(kept) != 3 {
		t.Fatalf("kept %d answers, want 3", len(kept))
	}
	for _, path := range []string{"/p2", "/p3", "/p4"} {
		if _, ok := kept[path]; !ok {
			t.Fatalf("newest answer %s dropped: %v", path, kept)
		}
	}
}

func TestExplainStoreReportsCorruptAndOutdatedFiles(t *testing.T) {
	dir := t.TempDir()
	corrupt := newExplainStore(filepath.Join(dir, "corrupt.json"))
	if err := os.WriteFile(corrupt.path, []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}
	if loaded, err := corrupt.load(time.Now()); !errors.Is(err, errExplainStoreCorrupt) || len(loaded) != 0 {
		t.Fatalf("corrupt load = %+v, %v", loaded, err)
	}

	outdated := newExplainStore(filepath.Join(dir, "outdated.json"))
	data, err := json.Marshal(explainStoreFile{SchemaVersion: explainStoreSchemaVersion + 1, Answers: map[string]storedExplanation{dir: storedAnswer(true, modTimeOf(t, dir), time.Now())}})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(outdated.path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	if loaded, err := outdated.load(time.Now()); err != nil || len(loaded) != 0 {
		t.Fatalf("another schema must start empty: %+v, %v", loaded, err)
	}

	if loaded, err := newExplainStore(filepath.Join(dir, "absent.json")).load(time.Now()); err != nil || len(loaded) != 0 {
		t.Fatalf("a missing store is empty: %+v, %v", loaded, err)
	}
}
