//go:build darwin

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"
)

// `mo analyze --explain '<items>' [--deep]` asks the same AI the TUI's E key
// asks, without a terminal, for Supermole.app. Items are a JSON array of
// {"path", "label", "size"}; what each path is (folder or file) is read from
// the disk, not from the request. The answers are printed as JSON and kept in
// the same store the TUI reads, so either side shows what the other asked.

// explainCLIItem is one row the caller asks about.
type explainCLIItem struct {
	Path  string `json:"path"`
	Label string `json:"label"`
	Size  int64  `json:"size"` // 0 or less when the caller has no measurement
}

// explainCLIReport is what --explain prints: the answers by path, and why the
// other paths have none.
type explainCLIReport struct {
	Answers map[string]storedExplanation `json:"answers"`
	Errors  map[string]string            `json:"errors"`
}

// parseExplainItems turns the request into job items: one batch, at most the
// TUI's batch size, and one item for a deep look.
func parseExplainItems(raw string, mode explainMode) ([]explainJobItem, error) {
	var items []explainCLIItem
	if err := json.Unmarshal([]byte(raw), &items); err != nil {
		return nil, fmt.Errorf("--explain expects a JSON array of {\"path\", \"label\", \"size\"}: %v", err)
	}
	switch {
	case len(items) == 0:
		return nil, errors.New("--explain needs at least one item")
	case len(items) > explainBatchSize:
		return nil, fmt.Errorf("--explain takes at most %d items at once", explainBatchSize)
	case mode == explainDeep && len(items) != 1:
		return nil, errors.New("--deep looks inside exactly one item")
	}

	jobItems := make([]explainJobItem, 0, len(items))
	for _, item := range items {
		if !filepath.IsAbs(item.Path) {
			return nil, fmt.Errorf("--explain needs absolute paths: %q", item.Path)
		}
		info, err := os.Lstat(item.Path)
		if err != nil {
			return nil, fmt.Errorf("cannot read %s: %v", item.Path, err)
		}
		label := item.Label
		if label == "" {
			label = filepath.Base(item.Path)
		}
		size := item.Size
		switch {
		case size <= 0 && !info.IsDir():
			size = info.Size()
		case size <= 0:
			size = -1 // unmeasured, as the TUI marks it
		}
		entry := dirEntry{Name: filepath.Base(item.Path), Path: item.Path, IsDir: info.IsDir(), Size: size}
		target := explainTargetForEntry(entry)
		target.Label = label
		jobItems = append(jobItems, explainJobItem{target: target})
	}
	return jobItems, nil
}

// runExplainCLI asks once for every item, prints the report and keeps the
// answers. A store that cannot be updated is reported on stderr; the answers
// are still printed.
func runExplainCLI(ctx context.Context, items []explainJobItem, mode explainMode, backend explainBackend,
	sources explainSources, store *explainStore, now time.Time, stdout, stderr io.Writer,
) error {
	outcomes := runExplainJob(ctx, backend, sources, explainJob{requestID: 1, mode: mode, items: items})
	report := explainCLIReport{Answers: map[string]storedExplanation{}, Errors: map[string]string{}}
	keep := map[string]storedExplanation{}
	for path, outcome := range outcomes {
		if outcome.err != nil {
			report.Errors[path] = outcome.err.Error()
			continue
		}
		answer := storedFromEntry(explainEntry{state: explainDone, result: outcome.result, stamp: outcome.stamp, answeredAt: now})
		report.Answers[path] = answer
		// A target that was already gone cannot be checked on the next run.
		if outcome.stamp.Exists {
			keep[path] = answer
		}
	}
	if store != nil && len(keep) > 0 {
		if err := mergeExplainAnswers(store, keep, now); err != nil {
			_, _ = fmt.Fprintf(stderr, "Explanations not saved: %v\n", err)
		}
	}
	return json.NewEncoder(stdout).Encode(report)
}

// mergeExplainAnswers adds answers to the store, keeping every other answer
// that still describes its target. An unreadable store is started over, as
// the TUI does; one that cannot be read at all is left alone.
func mergeExplainAnswers(store *explainStore, answers map[string]storedExplanation, now time.Time) error {
	existing, err := store.load(now)
	if err != nil && !errors.Is(err, errExplainStoreCorrupt) {
		return err
	}
	maps.Copy(existing, answers)
	return store.save(existing, 1)
}

// runExplainMain is main's --explain branch; it returns the exit code.
func runExplainMain(raw string, deep bool) int {
	mode := explainQuick
	if deep {
		mode = explainDeep
	}
	items, err := parseExplainItems(raw, mode)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	ctx, stop := explainSignalContext()
	defer stop()
	if err := runExplainCLI(ctx, items, mode, defaultExplainBackend(), defaultExplainSources(), defaultExplainStore(),
		time.Now(), os.Stdout, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	return 0
}

// explainSignalContext ends with Ctrl-C or the caller's SIGTERM (the app
// stopping a request), which stops the AI agent with it.
func explainSignalContext() (context.Context, context.CancelFunc) {
	return signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
}
