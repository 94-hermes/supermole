//go:build darwin

package main

import (
	"fmt"
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
)

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

func explainVerdictLabel(verdict explainVerdict) (label, color string) {
	switch verdict {
	case explainVerdictSafe:
		return "SUPPRIMABLE", colorGreen
	case explainVerdictCaution:
		return "PRUDENCE", colorYellow
	case explainVerdictKeep:
		return "À GARDER", colorRed
	default:
		return "INCERTAIN", colorGray
	}
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
		label, color := explainVerdictLabel(result.Verdict)
		verdict := explainParagraph{text: "● " + label, color: color}
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
