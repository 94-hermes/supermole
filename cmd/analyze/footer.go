//go:build darwin

package main

import (
	"fmt"
	"slices"
	"strings"

	"github.com/charmbracelet/x/ansi"
)

// Footer hint priorities: on a narrow terminal the lowest goes first, the
// rightmost of a tie first. Navigation and the way out are never dropped;
// Bubble Tea cuts any line wider than the window, which used to take
// "Esc Back | Q Quit" off the end of the longest footers.
const (
	footerKeep     = 100
	footerExit     = 90
	footerEnter    = 80
	footerDelete   = 70
	footerExplain  = 65
	footerTriage   = 60
	footerSelect   = 55
	footerFilter   = 50
	footerTop      = 45
	footerRefresh  = 30
	footerOpen     = 25
	footerReveal   = 20
	footerPreview  = 15
	footerSep      = " | "
	footerInputSep = "  |  "
)

type footerHint struct {
	text     string
	priority int
}

func (m model) footerHints() (hints []footerHint, separator string) {
	explain := []footerHint{{"E Explain", footerExplain}, {"⇧E All", footerTriage}}
	open := []footerHint{{"O Open", footerOpen}, {"P Preview", footerPreview}, {"F File", footerReveal}}
	deleteHint := func(selected int) footerHint {
		if selected > 0 {
			return footerHint{fmt.Sprintf("⌫ Del %d", selected), footerDelete}
		}
		return footerHint{"⌫ Del", footerDelete}
	}

	switch {
	case m.inOverviewMode():
		hints = []footerHint{{"↑↓→", footerKeep}, {"Enter", footerEnter}, {"R Refresh", footerRefresh}}
		hints = append(append(hints, open...), explain...)
		if len(m.history) > 0 {
			hints[0].text = "↑↓←→"
			return append(hints, footerHint{"Esc Back", footerExit}, footerHint{"Q/Ctrl+C Quit", footerKeep}), footerSep
		}
		return append(hints, footerHint{"Esc/Q Quit", footerKeep}), footerSep
	case (m.showLargeFiles && m.largeFiltering) || (!m.showLargeFiles && m.entryFiltering):
		return []footerHint{{"Type to filter", footerKeep}, {"Enter Apply", footerKeep}, {"Esc Clear", footerKeep}, {"Ctrl+C Quit", footerKeep}}, footerInputSep
	case m.showLargeFiles && m.largeFilter != "":
		hints = []footerHint{{"↑↓←", footerKeep}, {"Space Select", footerSelect}, {"/ Edit", footerFilter}, {"Esc Clear filter", footerExit}}
		hints = append(append(hints, open...), explain...)
		return append(hints, deleteHint(0), footerHint{"Q Quit", footerKeep}), footerSep
	case m.showLargeFiles:
		hints = []footerHint{{"↑↓←", footerKeep}, {"Space Select", footerSelect}, {"/ Filter", footerFilter}, {"R Refresh", footerRefresh}}
		hints = append(append(hints, open...), explain...)
		return append(hints, deleteHint(len(m.largeMultiSelected)), footerHint{"Esc Back", footerExit}, footerHint{"Q/Ctrl+C Quit", footerKeep}), footerSep
	case m.entryFilter != "":
		hints = []footerHint{{"↑↓←→", footerKeep}, {"Enter", footerEnter}, {"Space Select", footerSelect}, {"/ Edit", footerFilter}, {"Esc Clear filter", footerExit}}
		hints = append(append(hints, open...), explain...)
		return append(hints, deleteHint(0), footerHint{"Q Quit", footerKeep}), footerSep
	default:
		hints = []footerHint{{"↑↓←→", footerKeep}, {"Space Select", footerSelect}, {"Enter", footerEnter}, {"/ Filter", footerFilter}, {"R Refresh", footerRefresh}}
		hints = append(append(hints, open...), explain...)
		hints = append(hints, deleteHint(len(m.multiSelected)))
		if count := len(m.largeFiles); count > 0 {
			hints = append(hints, footerHint{fmt.Sprintf("T Top %d", count), footerTop})
		}
		return append(hints, footerHint{"Esc Back", footerExit}, footerHint{"Q/Ctrl+C Quit", footerKeep}), footerSep
	}
}

// fitFooter joins hints, dropping the least useful until the line fits width.
// A width of 0 (not yet known) keeps them all.
func fitFooter(hints []footerHint, separator string, width int) string {
	kept := slices.Clone(hints)
	join := func() string {
		texts := make([]string, len(kept))
		for i, hint := range kept {
			texts[i] = hint.text
		}
		return strings.Join(texts, separator)
	}
	for width > 0 && ansi.StringWidth(join()) > width {
		drop := -1
		for i, hint := range kept {
			if hint.priority < footerKeep && (drop < 0 || hint.priority <= kept[drop].priority) {
				drop = i
			}
		}
		if drop < 0 {
			break
		}
		kept = slices.Delete(kept, drop, drop+1)
	}
	return join()
}

func (m model) writeFooter(b *strings.Builder) {
	hints, separator := m.footerHints()
	fmt.Fprintf(b, "%s%s%s\n", colorGray, fitFooter(hints, separator, m.width), colorReset)
}
