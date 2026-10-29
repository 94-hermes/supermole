//go:build darwin

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestBuildExplainPromptDescribesTargetWithoutFileContents(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	target := filepath.Join(home, "Library", "Developer", "CoreSimulator")
	devices := filepath.Join(target, "Devices")
	if err := os.MkdirAll(devices, 0o755); err != nil {
		t.Fatal(err)
	}
	const secret = "jeton-secret-ne-doit-pas-partir"
	if err := os.WriteFile(filepath.Join(target, "device_set.plist"), []byte(secret), 0o600); err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 10, 29, 12, 0, 0, 0, time.UTC)

	prompt := buildExplainPrompt([]explainPromptItem{{
		id: "1",
		target: explainTarget{
			Label:      "Xcode Simulators",
			Path:       target,
			Size:       7 << 30,
			IsDir:      true,
			LastAccess: now.Add(-120 * 24 * time.Hour),
			Cleanable:  true,
		},
		facts: explainFacts{contents: readExplainContents(target)},
	}}, explainQuick, now)

	for _, want := range []string{
		"Élément id « 1 »",
		"Nom affiché par l'outil : Xcode Simulators",
		"Chemin : ~/Library/Developer/CoreSimulator",
		"Type : dossier",
		"Taille : " + humanizeBytes(7<<30),
		"Dernier accès : il y a 120 jours",
		"caches de développement",
		"- Devices/",
		"- device_set.plist",
		"sans exécuter de commande",
	} {
		if !strings.Contains(prompt, want) {
			t.Fatalf("prompt lacks %q:\n%s", want, prompt)
		}
	}
	if strings.Contains(prompt, secret) || strings.Contains(prompt, home) {
		t.Fatalf("prompt leaked file contents or the home path:\n%s", prompt)
	}
}

func TestBuildExplainPromptDeepModeAllowsReadOnlyLook(t *testing.T) {
	prompt := buildExplainPrompt([]explainPromptItem{{id: "1", target: explainTarget{Label: "cache.db", Path: "/tmp/cache.db", Size: -1}}}, explainDeep, time.Now())
	if !strings.Contains(prompt, "lecture seule") || !strings.Contains(prompt, "ne supprime rien") {
		t.Fatalf("deep prompt must allow reading only:\n%s", prompt)
	}
	if strings.Contains(prompt, "Taille") || strings.Contains(prompt, "Nom affiché") {
		t.Fatalf("unknown size and matching label must stay out:\n%s", prompt)
	}
}

func TestBuildExplainPromptListsCachedSizes(t *testing.T) {
	contents := cachedExplainContents([]dirEntry{{Name: "Devices", Size: 3 << 30, IsDir: true}})
	prompt := buildExplainPrompt([]explainPromptItem{{id: "1", target: explainTarget{Path: "/x", IsDir: true}, facts: explainFacts{contents: contents}}}, explainQuick, time.Now())
	if !strings.Contains(prompt, "- Devices/ : "+humanizeBytes(3<<30)) {
		t.Fatalf("cached child size missing:\n%s", prompt)
	}
}

func TestBuildExplainPromptNumbersBatchItems(t *testing.T) {
	prompt := buildExplainPrompt([]explainPromptItem{
		{id: "1", target: explainTarget{Path: "/x/a", Size: -1}},
		{id: "2", target: explainTarget{Path: "/x/b", Size: -1}},
	}, explainQuick, time.Now())
	for _, want := range []string{"2 éléments à expliquer", "Élément id « 1 »", "Chemin : /x/a", "Élément id « 2 »", "Chemin : /x/b"} {
		if !strings.Contains(prompt, want) {
			t.Fatalf("batch prompt lacks %q:\n%s", want, prompt)
		}
	}
}

func TestExplainAgeLabel(t *testing.T) {
	now := time.Date(2026, 10, 29, 12, 0, 0, 0, time.UTC)
	for _, tt := range []struct {
		age  time.Duration
		want string
	}{{time.Hour, "aujourd'hui"}, {30 * time.Hour, "il y a 1 jour"}, {10 * 24 * time.Hour, "il y a 10 jours"}} {
		if got := explainAgeLabel(now.Add(-tt.age), now); got != tt.want {
			t.Fatalf("explainAgeLabel(-%s) = %q, want %q", tt.age, got, tt.want)
		}
	}
}

func TestReadExplainContentsIsBounded(t *testing.T) {
	dir := t.TempDir()
	for i := range 100 {
		if err := os.WriteFile(filepath.Join(dir, fmt.Sprintf("file-%03d", i)), nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}

	contents := readExplainContents(dir)
	if len(contents.Children) != explainMaxListedChildren || !contents.Truncated {
		t.Fatalf("children = %d, truncated = %v", len(contents.Children), contents.Truncated)
	}
	for i := 1; i < len(contents.Children); i++ {
		if contents.Children[i-1].Name > contents.Children[i].Name {
			t.Fatalf("listing not sorted: %q before %q", contents.Children[i-1].Name, contents.Children[i].Name)
		}
	}
	for _, child := range contents.Children {
		if child.Size >= 0 {
			t.Fatalf("uncached listing must not claim a size: %+v", child)
		}
	}
}

func TestReadExplainContentsReportsUnreadableDirectory(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "locked")
	if err := os.Mkdir(dir, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(dir, 0o755) })

	contents := readExplainContents(dir)
	if len(contents.Children) != 0 || !strings.Contains(contents.Note, "permission refusée") {
		t.Fatalf("contents = %+v, want a permission note", contents)
	}
}

func TestCachedExplainContentsKeepsBiggestChildren(t *testing.T) {
	entries := make([]dirEntry, 0, 30)
	for i := range 30 {
		entries = append(entries, dirEntry{Name: fmt.Sprintf("d%02d", i), Size: int64(i)})
	}

	contents := cachedExplainContents(entries)
	if len(contents.Children) != explainMaxCachedChildren || !contents.Truncated {
		t.Fatalf("children = %d, truncated = %v", len(contents.Children), contents.Truncated)
	}
	if contents.Children[0].Name != "d29" || contents.Children[len(contents.Children)-1].Name != "d10" {
		t.Fatalf("not the biggest first: %+v", contents.Children)
	}
	if entries[0].Name != "d00" {
		t.Fatal("cachedExplainContents must not reorder the model's entries")
	}
}
