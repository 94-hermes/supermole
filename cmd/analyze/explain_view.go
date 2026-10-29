//go:build darwin

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/charmbracelet/x/ansi"
)

const (
	explainPanelMaxBodyRows   = 8
	explainPanelMinBodyRows   = 3
	explainPanelHeightDivisor = 4 // the body takes at most a quarter of the terminal
	explainPanelChromeRows    = 3 // blank separator plus top and bottom borders
	explainPanelMaxWidth      = 104
	explainPanelMinWidth      = 40
	explainPanelDefaultWidth  = 80
	explainPanelSideWidth     = 4 // "│ " and " │"
	explainPanelLabelPadding  = 4 // "─ " before a border label, " ─" after it
	explainPanelMargin        = " "
	explainPanelEllipsis      = "…"

	// Row marks that take the place of a list row's "|" separator, so they cost
	// no column.
	explainRowSeparator  = "|"
	explainVerdictMark   = "●"
	explainPendingMark   = "◌"
	explainFailedMark    = "!"
	explainSummaryRowGap = 1 // blank line between the summary and the list
	explainSummaryJoin   = "  ·  "
)

type explainVerdictStyle struct {
	label   string // panel verdict line
	summary string // summary line
	color   string
}

var explainVerdictStyles = map[explainVerdict]explainVerdictStyle{
	explainVerdictSafe:    {label: "SUPPRIMABLE", summary: "Supprimable", color: colorGreen},
	explainVerdictCaution: {label: "PRUDENCE", summary: "Prudence", color: colorYellow},
	explainVerdictKeep:    {label: "À GARDER", summary: "À garder", color: colorRed},
	explainVerdictUnknown: {label: "INCERTAIN", summary: "Incertain", color: colorGray},
}

// explainSummaryOrder lists verdicts from most to least reclaimable.
var explainSummaryOrder = []explainVerdict{explainVerdictSafe, explainVerdictCaution, explainVerdictKeep, explainVerdictUnknown}

func explainStyleOf(verdict explainVerdict) explainVerdictStyle {
	if style, ok := explainVerdictStyles[verdict]; ok {
		return style
	}
	return explainVerdictStyles[explainVerdictUnknown]
}

type explainParagraph struct {
	label string // bold lead-in on the first line
	text  string
	color string // applied to every wrapped line
}

type explainPanelContent struct {
	title      string
	hint       string
	paragraphs []explainParagraph
}

// explainPanelRows is what the open panel takes from the list viewport. The
// height is fixed while open so rows do not jump when an answer arrives.
func (m model) explainPanelRows() int {
	if !m.explain.panelOpen {
		return 0
	}
	return explainPanelChromeRows + m.explainPanelBodyRows()
}

func (m model) explainPanelBodyRows() int {
	if m.height <= 0 {
		return explainPanelMaxBodyRows
	}
	return min(max(m.height/explainPanelHeightDivisor, explainPanelMinBodyRows), explainPanelMaxBodyRows)
}

func (m model) explainPanelWidth() int {
	width := m.width
	if width <= 0 {
		width = explainPanelDefaultWidth
	}
	return min(max(width-len(explainPanelMargin), explainPanelMinWidth), explainPanelMaxWidth)
}

func (m model) explainPanelContent() explainPanelContent {
	target, ok := m.explainTarget()
	if !ok {
		return explainPanelContent{
			title:      "Expliquer",
			paragraphs: []explainParagraph{{text: "Rien à expliquer ici.", color: colorGray}},
		}
	}
	content := explainPanelContent{title: target.Label}
	if target.Size >= 0 {
		content.title += " · " + measuredSizeLabel(target.Size, target.SizeState)
	}

	entry, known := m.explain.entries[target.Path]
	switch {
	case !known:
		content.paragraphs = []explainParagraph{{text: "Pas encore expliqué. Appuie sur E pour demander à l'IA.", color: colorGray}}
	case entry.state == explainQueued:
		content.paragraphs = []explainParagraph{{
			text:  fmt.Sprintf("%s En attente : d'autres explications passent avant.", explainPendingMark),
			color: colorCyan,
		}}
	case entry.state == explainLoading:
		action := "L'IA réfléchit"
		if entry.mode == explainDeep {
			action = "L'IA regarde dedans, en lecture seule"
		}
		elapsed := int(time.Since(entry.startedAt) / time.Second)
		content.paragraphs = []explainParagraph{{
			text:  fmt.Sprintf("%s %s… %ds", spinnerFrames[m.spinner], action, elapsed),
			color: colorCyan,
		}}
	case entry.state == explainFailed:
		content.paragraphs = []explainParagraph{
			{text: "Impossible d'obtenir une explication.", color: colorRed},
			{text: compactExplainError(entry.err), color: colorGray},
		}
		content.hint = "E : réessayer"
	default:
		result := entry.result
		content.title += " · " + result.Provider
		style := explainStyleOf(result.Verdict)
		verdict := explainParagraph{text: explainVerdictMark + " " + style.label, color: style.color}
		if result.Explored {
			verdict.text += " · après exploration"
		}
		content.paragraphs = []explainParagraph{
			verdict,
			{label: "C'est quoi : ", text: result.What},
			{label: "Si je supprime : ", text: result.IfDeleted},
			{label: "Conseil : ", text: result.Advice},
		}
		content.hint = "E/Esc : fermer"
		if result.NeedsExploration && !result.Explored {
			content.hint = "E : regarder dedans (lecture seule)"
		}
	}
	return content
}

func (p explainParagraph) wrap(width int) []string {
	lines := strings.Split(ansi.Wrap(p.label+p.text, width, ""), "\n")
	for i, line := range lines {
		styled := p.color + line
		if i == 0 && p.label != "" {
			if rest, ok := strings.CutPrefix(line, p.label); ok {
				styled = colorBold + p.label + colorReset + p.color + rest
			}
		}
		lines[i] = styled + colorReset
	}
	return lines
}

func (m model) writeExplainPanel(b *strings.Builder) {
	if !m.explain.panelOpen {
		return
	}
	content := m.explainPanelContent()
	width := m.explainPanelWidth()
	inner := width - explainPanelSideWidth
	rows := m.explainPanelBodyRows()

	var lines []string
	for _, paragraph := range content.paragraphs {
		if paragraph.text != "" {
			lines = append(lines, paragraph.wrap(inner)...)
		}
	}
	if len(lines) > rows {
		lines = lines[:rows]
		lines[rows-1] = ansi.Truncate(lines[rows-1], inner-1, "") + explainPanelEllipsis + colorReset
	}

	fmt.Fprintln(b)
	b.WriteString(explainPanelBorder("╭", "╮", content.title, colorCyan, width))
	for i := range rows {
		line := ""
		if i < len(lines) {
			line = lines[i]
		}
		padding := strings.Repeat(" ", max(inner-ansi.StringWidth(line), 0))
		fmt.Fprintf(b, "%s%s│%s %s%s %s│%s\n", explainPanelMargin, colorGray, colorReset, line, padding, colorGray, colorReset)
	}
	b.WriteString(explainPanelBorder("╰", "╯", content.hint, colorGray, width))
}

// explainPanelBorder draws a horizontal edge with an optional label set into
// it, truncated so the edge always spans exactly width columns.
func explainPanelBorder(left, right, label, labelColor string, width int) string {
	fill := width - ansi.StringWidth(left) - ansi.StringWidth(right)
	segment := ""
	if label != "" {
		label = ansi.Truncate(label, fill-explainPanelLabelPadding, explainPanelEllipsis)
		segment = fmt.Sprintf("─ %s%s%s%s ", colorReset, labelColor, label, colorGray)
		fill -= ansi.StringWidth(label) + explainPanelLabelPadding - 1
	}
	return fmt.Sprintf("%s%s%s%s%s%s%s\n", explainPanelMargin, colorGray, left, segment, strings.Repeat("─", fill), right, colorReset)
}

// rowSeparator is a row's "|" separator, or its explain mark once the row has
// been asked about.
func (m model) rowSeparator(path string) string {
	entry, ok := m.explain.entries[path]
	switch {
	case !ok:
		return explainRowSeparator
	case entry.state.pending():
		return colorCyan + explainPendingMark + colorReset
	case entry.state == explainFailed:
		return colorRed + explainFailedMark + colorReset
	default:
		return explainStyleOf(entry.result.Verdict).color + explainVerdictMark + colorReset
	}
}

type explainListingRow struct {
	path string
	size int64
}

// explainListingRows are all rows of the current listing, on screen or not.
func (m model) explainListingRows() []explainListingRow {
	var rows []explainListingRow
	if m.showLargeFiles {
		for _, file := range m.largeFiles {
			rows = append(rows, explainListingRow{path: file.Path, size: file.Size})
		}
		return rows
	}
	for _, entry := range m.entries {
		if m.inOverviewMode() && isHiddenOverviewEntry(entry) {
			continue
		}
		rows = append(rows, explainListingRow{path: entry.Path, size: entry.Size})
	}
	return rows
}

type explainSummary struct {
	count   map[explainVerdict]int
	size    map[explainVerdict]int64
	pending int
	failed  int
}

// explainSummaryOf totals the verdicts of the current listing. A byte is
// counted once, under the innermost answered row holding it: on the overview,
// an answered "Xcode Simulators" is taken out of an answered "User Library".
func (m model) explainSummaryOf() explainSummary {
	summary := explainSummary{count: map[explainVerdict]int{}, size: map[explainVerdict]int64{}}
	var answered []explainListingRow
	for _, row := range m.explainListingRows() {
		entry, ok := m.explain.entries[row.path]
		switch {
		case !ok:
		case entry.state.pending():
			summary.pending++
		case entry.state == explainFailed:
			summary.failed++
		default:
			answered = append(answered, row)
		}
	}
	// The scanner reads HOME the same way when it measures the Home row.
	home := os.Getenv("HOME")
	for i, row := range answered {
		verdict := m.explain.entries[row.path].result.Verdict
		summary.count[verdict]++
		summary.size[verdict] += exclusiveSize(answered, i, home)
	}
	return summary
}

// exclusiveSize is rows[i]'s size minus the rows whose bytes it holds directly,
// with no other answered row in between.
func exclusiveSize(rows []explainListingRow, i int, home string) int64 {
	outer := rows[i]
	size := max(outer.size, 0)
	for j, inner := range rows {
		if j == i || !rowSizeIncludes(outer.path, inner.path, home) {
			continue
		}
		direct := true
		for k, middle := range rows {
			if k != i && k != j && rowSizeIncludes(outer.path, middle.path, home) && rowSizeIncludes(middle.path, inner.path, home) {
				direct = false
				break
			}
		}
		if direct {
			size -= max(inner.size, 0)
		}
	}
	return max(size, 0)
}

// rowSizeIncludes reports whether outer's measured size counts inner's bytes.
// The overview measures Home without ~/Library (measureOverviewSize in
// scanner.go), so nothing under ~/Library is part of the Home row.
func rowSizeIncludes(outer, inner, home string) bool {
	if inner == outer || !pathIsWithin(inner, outer) {
		return false
	}
	return home == "" || outer != home || !pathIsWithin(inner, filepath.Join(home, "Library"))
}

// explainSummaryLine is the legend and running total shown above the list, or
// "" when nothing in this listing has been asked about.
func (m model) explainSummaryLine() string {
	summary := m.explainSummaryOf()
	var parts []string
	for _, verdict := range explainSummaryOrder {
		if summary.count[verdict] == 0 {
			continue
		}
		style := explainStyleOf(verdict)
		parts = append(parts, fmt.Sprintf("%s%s%s %s %s", style.color, explainVerdictMark, colorReset, style.summary, humanizeBytes(summary.size[verdict])))
	}
	if summary.pending > 0 {
		parts = append(parts, fmt.Sprintf("%s%s%s %d en cours", colorCyan, explainPendingMark, colorReset, summary.pending))
	}
	if summary.failed > 0 {
		parts = append(parts, fmt.Sprintf("%s%s%s %d en échec", colorRed, explainFailedMark, colorReset, summary.failed))
	}
	if m.explain.storeErr != nil {
		parts = append(parts, fmt.Sprintf("%smémoire : %s%s", colorRed, compactExplainError(m.explain.storeErr), colorReset))
	}
	if len(parts) == 0 {
		return ""
	}
	line := explainPanelMargin + strings.Join(parts, colorGray+explainSummaryJoin+colorReset)
	if m.width > 0 && ansi.StringWidth(line) > m.width {
		line = ansi.Truncate(line, m.width-1, "") + explainPanelEllipsis + colorReset
	}
	return line
}

// explainSummaryRows is what the summary takes from the list viewport.
func (m model) explainSummaryRows() int {
	if m.explainSummaryLine() == "" {
		return 0
	}
	return 1 + explainSummaryRowGap
}

func (m model) writeExplainSummary(b *strings.Builder) {
	if line := m.explainSummaryLine(); line != "" {
		b.WriteString(line)
		b.WriteString(strings.Repeat("\n", 1+explainSummaryRowGap))
	}
}
