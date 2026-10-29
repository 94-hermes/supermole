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
	listing, _ := readExplainDir(target)

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
		facts: explainFacts{contents: listing},
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

func TestBuildExplainPromptDescribesLocalFacts(t *testing.T) {
	now := time.Date(2026, 10, 29, 12, 0, 0, 0, time.UTC)
	describe := func(facts explainFacts) string {
		return buildExplainPrompt([]explainPromptItem{{id: "1", target: explainTarget{Path: "/x", Size: -1}, facts: facts}}, explainQuick, now)
	}
	tests := []struct {
		name  string
		facts explainFacts
		want  string
	}{
		{name: "newest change", facts: explainFacts{newestChange: now.Add(-3 * 24 * time.Hour)}, want: "- Dernière modification : il y a 3 jours"},
		{name: "installed owner", facts: explainFacts{owner: explainOwner{kind: explainOwnerInstalled, token: "com.docker.docker", app: installedApp{Name: "Docker"}}}, want: "app installée « Docker » (com.docker.docker)"},
		{name: "missing owner id", facts: explainFacts{owner: explainOwner{kind: explainOwnerMissing, token: "com.docker.docker"}}, want: "Identifiant « com.docker.docker » : aucune app installée ne le porte"},
		{name: "apple owner", facts: explainFacts{owner: explainOwner{kind: explainOwnerApple, token: "com.apple.akd"}}, want: "Identifiant Apple « com.apple.akd » : composant de macOS"},
		{name: "download with page", facts: explainFacts{downloadedFrom: []string{"https://a/x.dmg", "https://a/"}}, want: "- Téléchargé depuis : https://a/x.dmg (page : https://a/)"},
		{name: "download alone", facts: explainFacts{downloadedFrom: []string{"https://a/x.dmg"}}, want: "- Téléchargé depuis : https://a/x.dmg\n"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if prompt := describe(tt.facts); !strings.Contains(prompt, tt.want) {
				t.Fatalf("prompt lacks %q:\n%s", tt.want, prompt)
			}
		})
	}
	if prompt := describe(explainFacts{}); strings.Contains(prompt, "app installée") || strings.Contains(prompt, "Dernière modification") {
		t.Fatalf("absent facts must stay out of the prompt:\n%s", prompt)
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
