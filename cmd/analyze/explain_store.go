//go:build darwin

package main

import (
	"cmp"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"time"
)

const (
	// A subdirectory of its own: the analyzer cache caps and the legacy sweep
	// of ~/.cache/mole never reach it.
	explainStoreDirName       = "explain"
	explainStoreFileName      = "answers.json"
	explainStoreSchemaVersion = 1
	explainStoreTTL           = 30 * 24 * time.Hour
	explainStoreMaxAnswers    = 2000
	explainStoreDirPerm       = 0o700
	explainStoreFilePerm      = 0o600
)

var errExplainStoreCorrupt = errors.New("mémoire des réponses illisible")

// storedExplanation is one remembered answer and the target as it was then.
type storedExplanation struct {
	Verdict          explainVerdict `json:"verdict"`
	What             string         `json:"what"`
	IfDeleted        string         `json:"if_deleted"`
	Advice           string         `json:"advice"`
	NeedsExploration bool           `json:"needs_exploration"`
	Explored         bool           `json:"explored"`
	Provider         string         `json:"provider"`
	IsDir            bool           `json:"is_dir"`
	ModTime          time.Time      `json:"mod_time"`
	AnsweredAt       time.Time      `json:"answered_at"`
}

type explainStoreFile struct {
	SchemaVersion int                          `json:"schema_version"`
	Answers       map[string]storedExplanation `json:"answers"`
}

// explainStore persists answers across analyzer runs. Saves run on workers
// and may finish out of order; generation keeps an older snapshot from
// overwriting a newer one.
type explainStore struct {
	path            string
	mu              sync.Mutex
	savedGeneration int64
}

func newExplainStore(path string) *explainStore {
	return &explainStore{path: path}
}

// defaultExplainStore is nil when there is no home directory to keep it in;
// answers then last for the session only.
func defaultExplainStore() *explainStore {
	root, err := getMoleCacheRoot()
	if err != nil {
		return nil
	}
	return newExplainStore(filepath.Join(root, explainStoreDirName, explainStoreFileName))
}

func storedFromEntry(entry explainEntry) storedExplanation {
	result := entry.result
	return storedExplanation{
		Verdict:          result.Verdict,
		What:             result.What,
		IfDeleted:        result.IfDeleted,
		Advice:           result.Advice,
		NeedsExploration: result.NeedsExploration,
		Explored:         result.Explored,
		Provider:         result.Provider,
		IsDir:            entry.stamp.IsDir,
		ModTime:          entry.stamp.ModTime,
		AnsweredAt:       entry.answeredAt,
	}
}

func (a storedExplanation) entry() explainEntry {
	return explainEntry{
		state: explainDone,
		result: explanation{
			Verdict:          a.Verdict,
			What:             a.What,
			IfDeleted:        a.IfDeleted,
			Advice:           a.Advice,
			NeedsExploration: a.NeedsExploration,
			Explored:         a.Explored,
			Provider:         a.Provider,
		},
		answeredAt: a.AnsweredAt,
		stamp:      explainStamp{Exists: true, IsDir: a.IsDir, ModTime: a.ModTime},
		fromStore:  true,
	}
}

// stillDescribes reports whether a remembered answer still fits its target.
// What a folder is survives its contents changing (a cache stays a cache), so
// a quick answer about a folder only needs the folder to remain one. A file,
// or an answer that came from reading the files, must be unchanged.
func (a storedExplanation) stillDescribes(path string, now time.Time) bool {
	if now.Sub(a.AnsweredAt) > explainStoreTTL || !a.Verdict.valid() || a.What == "" {
		return false
	}
	info, err := os.Lstat(path)
	if err != nil || info.IsDir() != a.IsDir {
		return false
	}
	if !a.IsDir || a.Explored {
		return info.ModTime().Equal(a.ModTime)
	}
	return true
}

// load returns the answers that still describe their target. A missing store
// is empty; an unreadable one wraps errExplainStoreCorrupt so the caller can
// start over and overwrite it.
func (s *explainStore) load(now time.Time) (map[string]storedExplanation, error) {
	data, err := os.ReadFile(s.path)
	if errors.Is(err, fs.ErrNotExist) {
		return map[string]storedExplanation{}, nil
	}
	if err != nil {
		return nil, err
	}
	var file explainStoreFile
	if err := json.Unmarshal(data, &file); err != nil {
		return map[string]storedExplanation{}, fmt.Errorf("%w : %v", errExplainStoreCorrupt, err)
	}
	if file.SchemaVersion != explainStoreSchemaVersion {
		return map[string]storedExplanation{}, nil
	}
	valid := make(map[string]storedExplanation, len(file.Answers))
	for path, answer := range file.Answers {
		if answer.stillDescribes(path, now) {
			valid[path] = answer
		}
	}
	return valid, nil
}

func (s *explainStore) save(answers map[string]storedExplanation, generation int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if generation <= s.savedGeneration {
		return nil
	}
	data, err := json.Marshal(explainStoreFile{
		SchemaVersion: explainStoreSchemaVersion,
		Answers:       newestAnswers(answers, explainStoreMaxAnswers),
	})
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(s.path), explainStoreDirPerm); err != nil {
		return err
	}
	if err := writeFileAtomically(s.path, data, explainStoreFilePerm); err != nil {
		return err
	}
	s.savedGeneration = generation
	return nil
}

// newestAnswers keeps at most limit answers, dropping the oldest first.
func newestAnswers(answers map[string]storedExplanation, limit int) map[string]storedExplanation {
	if len(answers) <= limit {
		return answers
	}
	paths := slices.Collect(maps.Keys(answers))
	slices.SortFunc(paths, func(a, b string) int {
		return cmp.Or(answers[b].AnsweredAt.Compare(answers[a].AnsweredAt), cmp.Compare(a, b))
	})
	kept := make(map[string]storedExplanation, limit)
	for _, path := range paths[:limit] {
		kept[path] = answers[path]
	}
	return kept
}
