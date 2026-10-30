import AppKit
import Charts
import Observation
import SupermoleCore
import SwiftUI

@MainActor
@Observable
final class DiskModel {
    /// The folders opened so far; `nil` is the whole-disk overview.
    private(set) var trail: [String?] = [nil]
    private(set) var result: AnalyzeResult?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var answers: [String: ExplainAnswers.Answer] = [:]
    private var loadTask: Task<Void, Never>?

    var canGoBack: Bool { trail.count > 1 }

    func open(_ path: String, using runner: MoleRunner) {
        trail.append(path)
        load(using: runner)
    }

    func back(using runner: MoleRunner) {
        guard canGoBack else { return }
        trail.removeLast()
        load(using: runner)
    }

    func load(using runner: MoleRunner) {
        loadTask?.cancel()
        let path = trail.last ?? nil
        isLoading = true
        errorMessage = nil
        loadTask = Task {
            do {
                let result = try await runner.decode(AnalyzeResult.self, AnalyzeResult.arguments(for: path))
                guard !Task.isCancelled else { return }
                self.result = result
                self.answers = try ExplainAnswers.load()
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
            }
            self.isLoading = false
        }
    }
}

struct DiskView: View {
    let runner: MoleRunner
    @State private var model = DiskModel()

    /// How many of the largest items the chart compares.
    private static let chartedEntries = 8

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                HStack(alignment: .firstTextBaseline) {
                    PageHeader(title: "Disk space", subtitle: model.result.map(subtitle))
                    if model.canGoBack {
                        Button {
                            model.back(using: runner)
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .buttonStyle(.glass)
                    }
                    Button {
                        model.load(using: runner)
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.glass)
                    .disabled(model.isLoading)
                }
                if let message = model.errorMessage {
                    ErrorBanner(message: message)
                }
                if model.isLoading {
                    LoadingCard(message: "Measuring folders… this can take a minute for the whole disk.")
                } else if let result = model.result {
                    let entries = result.sortedEntries
                    if !entries.isEmpty {
                        SizeChart(entries: Array(entries.prefix(Self.chartedEntries)))
                    }
                    EntryList(entries: entries, answers: model.answers) { path in
                        model.open(path, using: runner)
                    }
                }
            }
            .padding(Theme.pagePadding)
        }
        .task {
            if model.result == nil { model.load(using: runner) }
        }
    }

    private func subtitle(_ result: AnalyzeResult) -> String {
        let place = result.overview == true ? String(localized: "Whole disk") : result.path
        let total = Formatting.bytes(result.totalSize ?? 0)
        return result.isPartial
            ? String(localized: "\(place) · \(total) · some folders could not be read")
            : "\(place) · \(total)"
    }
}

private struct SizeChart: View {
    let entries: [AnalyzeResult.Entry]

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                CardLabel(title: "Largest items", symbol: "chart.bar.fill")
                Chart(entries) { entry in
                    BarMark(
                        x: .value("Size", entry.size),
                        y: .value("Name", MoleTerms.localized(entry.name, .place))
                    )
                    .cornerRadius(8)
                    .foregroundStyle(
                        LinearGradient(
                            colors: entry.insight == true ? [Theme.warning.opacity(0.7), Theme.warning] : [Theme.purple, Theme.indigo],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .annotation(position: .trailing, spacing: 8) {
                        Text(verbatim: Formatting.bytes(entry.size))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks { _ in AxisValueLabel().font(.callout) }
                }
                .frame(height: CGFloat(entries.count) * 34)
            }
        }
    }
}

private struct EntryList: View {
    let entries: [AnalyzeResult.Entry]
    let answers: [String: ExplainAnswers.Answer]
    let open: (String) -> Void

    var body: some View {
        GlassCard(padding: 10) {
            VStack(spacing: 2) {
                ForEach(entries) { entry in
                    EntryRow(entry: entry, largest: max(entries.first?.size ?? 1, 1), answer: answers[entry.path]) {
                        open(entry.path)
                    }
                }
            }
        }
    }
}

private struct EntryRow: View {
    let entry: AnalyzeResult.Entry
    let largest: Int64
    let answer: ExplainAnswers.Answer?
    let open: () -> Void

    @State private var showsAnswer = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: entry.isDir ? "folder.fill" : "doc.fill")
                .font(.title3)
                .foregroundStyle(entry.isDir ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(verbatim: MoleTerms.localized(entry.name, .place))
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if entry.insight == true {
                        Pill(text: "Worth a look", color: Theme.warning)
                    }
                    if let verdict = answer?.verdict {
                        VerdictPill(verdict: verdict)
                    }
                }
                GeometryReader { geometry in
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: max(4, geometry.size.width * Double(entry.size) / Double(largest)))
                }
                .frame(height: 6)
            }
            Text(verbatim: Formatting.bytes(entry.size))
                .monospacedDigit()
                .fontWeight(.semibold)
                .frame(width: 96, alignment: .trailing)
            // Every slot stays when unused, so all the bars have one length.
            Button {
                showsAnswer.toggle()
            } label: {
                Image(systemName: "sparkles")
            }
            .buttonStyle(.borderless)
            .help("What is it?")
            .opacity(answer == nil ? 0 : 1)
            .disabled(answer == nil)
            .popover(isPresented: $showsAnswer) {
                if let answer { AnswerView(answer: answer) }
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            Button(action: open) {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .help("Open")
            .opacity(entry.isDir ? 1 : 0)
            .disabled(!entry.isDir)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowRadius)
                .fill(.primary.opacity(isHovered ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) {
            if entry.isDir { open() }
        }
    }
}

private struct VerdictPill: View {
    let verdict: String

    var body: some View {
        switch verdict {
        case "safe": Pill(text: "Safe to delete", color: Theme.green)
        case "caution": Pill(text: "Check first", color: Theme.warning)
        case "keep": Pill(text: "Keep", color: Theme.danger)
        default: Pill(text: "Unsure", color: .secondary)
        }
    }
}

private struct AnswerView: View {
    let answer: ExplainAnswers.Answer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let what = answer.what {
                Text("What is it?").font(.headline)
                Text(verbatim: what)
            }
            if let ifDeleted = answer.ifDeleted {
                Text("If you delete it").font(.headline)
                Text(verbatim: ifDeleted)
            }
            if let advice = answer.advice {
                Text("Advice").font(.headline)
                Text(verbatim: advice)
            }
        }
        .padding(18)
        .frame(width: 380, alignment: .leading)
        .textSelection(.enabled)
    }
}
