//go:build darwin

package main

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// footerStates covers every footer variant.
func footerStates(t *testing.T) map[string]model {
	t.Helper()
	base := func() model {
		m := newModel(t.TempDir(), false)
		m.scanning = false
		return m
	}
	states := map[string]model{}

	states["directory"] = base()

	withSelection := base()
	withSelection.multiSelected = map[string]bool{"/a": true, "/b": true}
	withSelection.largeFiles = []fileEntry{{Name: "x", Path: "/x", Size: 1}}
	states["directory with selection and top files"] = withSelection

	filtered := base()
	filtered.entryFilter = "cache"
	states["directory filter applied"] = filtered

	typing := base()
	typing.entryFiltering = true
	states["directory filter typing"] = typing

	topFiles := base()
	topFiles.showLargeFiles = true
	topFiles.largeMultiSelected = map[string]bool{"/x": true}
	states["top files"] = topFiles

	topFiltered := base()
	topFiltered.showLargeFiles = true
	topFiltered.largeFilter = "iso"
	states["top files filter applied"] = topFiltered

	overview := base()
	overview.path, overview.isOverview = "/", true
	states["overview"] = overview

	overviewBack := overview
	overviewBack.history = []historyEntry{{Path: "/x"}}
	states["overview with history"] = overviewBack
	return states
}

func footerLine(m model) string {
	var b strings.Builder
	m.writeFooter(&b)
	return strings.TrimSuffix(ansi.Strip(b.String()), "\n")
}

func TestFooterShowsEveryHintWhenItFits(t *testing.T) {
	want := map[string]string{
		"directory":                              "↑↓←→ | Space Select | Enter | / Filter | R Refresh | O Open | P Preview | F File | E Explain | ⇧E All | ⌫ Del | Esc Back | Q/Ctrl+C Quit",
		"directory with selection and top files": "↑↓←→ | Space Select | Enter | / Filter | R Refresh | O Open | P Preview | F File | E Explain | ⇧E All | ⌫ Del 2 | T Top 1 | Esc Back | Q/Ctrl+C Quit",
		"directory filter applied":               "↑↓←→ | Enter | Space Select | / Edit | Esc Clear filter | O Open | P Preview | F File | E Explain | ⇧E All | ⌫ Del | Q Quit",
		"directory filter typing":                "Type to filter  |  Enter Apply  |  Esc Clear  |  Ctrl+C Quit",
		"top files":                              "↑↓← | Space Select | / Filter | R Refresh | O Open | P Preview | F File | E Explain | ⇧E All | ⌫ Del 1 | Esc Back | Q/Ctrl+C Quit",
		"top files filter applied":               "↑↓← | Space Select | / Edit | Esc Clear filter | O Open | P Preview | F File | E Explain | ⇧E All | ⌫ Del | Q Quit",
		"overview":                               "↑↓→ | Enter | R Refresh | O Open | P Preview | F File | E Explain | ⇧E All | Esc/Q Quit",
		"overview with history":                  "↑↓←→ | Enter | R Refresh | O Open | P Preview | F File | E Explain | ⇧E All | Esc Back | Q/Ctrl+C Quit",
	}
	for name, m := range footerStates(t) {
		for _, width := range []int{0, 400} {
			m.width = width
			if got := footerLine(m); got != want[name] {
				t.Fatalf("%s at width %d:\n got %q\nwant %q", name, width, got, want[name])
			}
		}
	}
}

func TestFooterDropsTheLeastUsefulHintsFirst(t *testing.T) {
	m := footerStates(t)["directory"]
	m.width = 400
	full := footerLine(m)
	dropOrder := []string{"P Preview", "F File", "O Open", "R Refresh", "/ Filter", "Space Select", "⇧E All", "E Explain", "⌫ Del", "Enter", "Esc Back"}

	for i, dropped := range dropOrder {
		m.width = ansi.StringWidth(full) - 1
		got := footerLine(m)
		if strings.Contains(got, dropped) || ansi.StringWidth(got) > m.width {
			t.Fatalf("step %d: %q, want %q dropped first and the line within %d columns", i, got, dropped, m.width)
		}
		for _, later := range dropOrder[i+1:] {
			if !strings.Contains(got, later) {
				t.Fatalf("step %d: %q dropped %q before %q", i, got, later, dropped)
			}
		}
		full = got
	}
	if full != "↑↓←→ | Q/Ctrl+C Quit" {
		t.Fatalf("last line = %q, want navigation and the way out", full)
	}
}

func TestFooterFitsEveryWidthAndKeepsTheWayOut(t *testing.T) {
	for name, m := range footerStates(t) {
		for width := 20; width <= 200; width++ {
			m.width = width
			got := footerLine(m)
			if !strings.Contains(got, "Quit") {
				t.Fatalf("%s at %d columns lost the way out: %q", name, width, got)
			}
			hints, separator := m.footerHints()
			var essential []string
			for _, hint := range hints {
				if hint.priority >= footerKeep {
					essential = append(essential, hint.text)
				}
			}
			if ansi.StringWidth(got) > width && got != strings.Join(essential, separator) {
				t.Fatalf("%s at %d columns is %d wide with droppable hints left: %q", name, width, ansi.StringWidth(got), got)
			}
		}
	}
}
