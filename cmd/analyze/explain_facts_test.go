//go:build darwin

package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

func TestReadExplainDirIsBoundedAndSorted(t *testing.T) {
	dir := t.TempDir()
	for i := range explainMaxStatChildren + 100 {
		if err := os.WriteFile(filepath.Join(dir, fmt.Sprintf("file-%04d", i)), nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}

	contents, _ := readExplainDir(dir)
	if len(contents.Children) != explainMaxListedChildren || !contents.Truncated {
		t.Fatalf("children = %d, truncated = %v", len(contents.Children), contents.Truncated)
	}
	if !slices.IsSortedFunc(contents.Children, func(a, b explainChild) int { return strings.Compare(a.Name, b.Name) }) {
		t.Fatalf("listing not sorted: %+v", contents.Children)
	}
	for _, child := range contents.Children {
		if child.Size >= 0 {
			t.Fatalf("uncached listing must not claim a size: %+v", child)
		}
	}
}

func TestReadExplainDirReportsNewestChange(t *testing.T) {
	dir := t.TempDir()
	old := time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)
	recent := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	for name, mtime := range map[string]time.Time{"old": old, "recent": recent} {
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, nil, 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(path, mtime, mtime); err != nil {
			t.Fatal(err)
		}
	}

	if _, newest := readExplainDir(dir); !newest.Equal(recent) {
		t.Fatalf("newest = %s, want %s", newest, recent)
	}
}

func TestReadExplainDirReportsUnreadableDirectory(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "locked")
	if err := os.Mkdir(dir, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(dir, 0o755) })

	contents, newest := readExplainDir(dir)
	if len(contents.Children) != 0 || !newest.IsZero() || !strings.Contains(contents.Note, "permission refusée") {
		t.Fatalf("contents = %+v, newest = %s, want a permission note", contents, newest)
	}
}

func TestParseWhereFroms(t *testing.T) {
	long := "https://example.com/" + strings.Repeat("a", explainMaxURLWidth)
	tests := []struct {
		name   string
		output string
		want   []string
	}{
		{name: "download and page", output: "(\n    \"https://cdn.example.com/x.pdf\",\n    \"https://example.com/\"\n)", want: []string{"https://cdn.example.com/x.pdf", "https://example.com/"}},
		{name: "empty page entry", output: "(\n    \"https://editique.example.co/x.pdf\",\n    \"\"\n)", want: []string{"https://editique.example.co/x.pdf"}},
		{name: "not from the web", output: "(null)", want: nil},
		{name: "capped", output: `("a", "b", "c")`, want: []string{"a", "b"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := parseWhereFroms([]byte(tt.output)); !slices.Equal(got, tt.want) {
				t.Fatalf("parseWhereFroms() = %q, want %q", got, tt.want)
			}
		})
	}
	got := parseWhereFroms([]byte(`("` + long + `")`))
	if len(got) != 1 || len([]rune(got[0])) != explainMaxURLWidth || !strings.HasSuffix(got[0], "…") {
		t.Fatalf("long URL = %q, want it cut to %d characters", got, explainMaxURLWidth)
	}
}

func TestGatherExplainFactsUsesLocalSources(t *testing.T) {
	home := t.TempDir()
	library := filepath.Join(home, "Library", "Caches", "com.example.app")
	if err := os.MkdirAll(library, 0o755); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(library, "big.bin")
	if err := os.WriteFile(file, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	var lookedUp []string
	sources := explainSources{
		apps: fakeAppIndex(t, home, map[string]installedApp{"Example.app": {BundleID: "com.example.app"}}),
		whereFroms: func(_ context.Context, path string) ([]string, error) {
			lookedUp = append(lookedUp, path)
			return []string{"https://example.com/big.bin"}, nil
		},
	}

	fileFacts := gatherExplainFacts(context.Background(), explainJobItem{target: explainTarget{Path: file}}, sources)
	if !fileFacts.stamp.Exists || fileFacts.stamp.IsDir || fileFacts.newestChange.IsZero() {
		t.Fatalf("file stamp = %+v, newest = %s", fileFacts.stamp, fileFacts.newestChange)
	}
	if fileFacts.owner.kind != explainOwnerInstalled || fileFacts.owner.app.Name != "Example" {
		t.Fatalf("owner = %+v, want the installed Example app", fileFacts.owner)
	}
	if !slices.Equal(fileFacts.downloadedFrom, []string{"https://example.com/big.bin"}) {
		t.Fatalf("downloadedFrom = %q", fileFacts.downloadedFrom)
	}

	cached := explainContents{Children: []explainChild{{Name: "from-scan", Size: 42}}}
	dirFacts := gatherExplainFacts(context.Background(), explainJobItem{target: explainTarget{Path: library, IsDir: true}, cached: &cached}, sources)
	if !dirFacts.stamp.IsDir || len(dirFacts.contents.Children) != 1 || dirFacts.contents.Children[0].Name != "from-scan" {
		t.Fatalf("dir facts = %+v, want the scan cache listing", dirFacts)
	}
	if len(lookedUp) != 1 || lookedUp[0] != file {
		t.Fatalf("provenance looked up for %q, want only the file", lookedUp)
	}

	sources.whereFroms = func(context.Context, string) ([]string, error) { return nil, errors.New("spotlight off") }
	if facts := gatherExplainFacts(context.Background(), explainJobItem{target: explainTarget{Path: file}}, sources); facts.downloadedFrom != nil {
		t.Fatalf("a failed lookup must only drop the hint: %+v", facts.downloadedFrom)
	}
	if facts := gatherExplainFacts(context.Background(), explainJobItem{target: explainTarget{Path: filepath.Join(home, "gone")}}, explainSources{}); facts.stamp.Exists {
		t.Fatal("a missing target must not be stamped as existing")
	}
}
