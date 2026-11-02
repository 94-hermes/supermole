import AppKit
import Charts
import Observation
import QuickLook
import SupermoleCore
import SwiftUI

/// Analyze, driven like `mo analyze` in the terminal: a selection moved with
/// the arrows, folders opened with → and left with ←, and the E key asking the
/// AI about the selected row, its answer in a panel under the list.
@MainActor
@Observable
final class DiskModel {
    enum ExplainState: Equatable {
        case asking(deep: Bool, since: Date)
        case failed(String)
    }

    /// The folders opened so far; `nil` is the whole-disk overview.
    private(set) var trail: [String?] = [nil]
    private(set) var result: AnalyzeResult?
    /// No result for this folder on screen yet.
    private(set) var isLoading = false
    /// A result is on screen while a fresh one is measured.
    private(set) var isRefreshing = false
    /// When the result on screen was measured, while it is one kept from
    /// earlier; nil once it was measured just now.
    private(set) var keptSince: Date?
    private(set) var errorMessage: String?
    private(set) var answers: [String: ExplainAnswers.Answer] = [:]
    private(set) var explainStates: [String: ExplainState] = [:]
    var selectedPath: String?

    /// A kept measurement younger than this is shown without measuring
    /// again: longer for the whole disk, whose scan takes a while.
    static let overviewFreshness: TimeInterval = 15 * 60
    static let folderFreshness: TimeInterval = 5 * 60

    private let cache = ResultCache()
    private var loadTask: Task<Void, Never>?
    private var explainQueue: [ExplainRequest] = []
    private var explainTask: Task<Void, Never>?

    /// The result's rows, largest first, sorted once when it arrives.
    private(set) var entries: [AnalyzeResult.Entry] = []
    private var rowByPath: [String: Int] = [:]

    var canGoBack: Bool { trail.count > 1 }
    var selectedEntry: AnalyzeResult.Entry? {
        selectedPath.flatMap { rowByPath[$0] }.map { entries[$0] }
    }

    // MARK: Navigation

    func open(_ entry: AnalyzeResult.Entry, using runner: MoleRunner) {
        guard entry.isDir else { return }
        trail.append(entry.path)
        load(using: runner)
    }

    func back(using runner: MoleRunner) {
        guard canGoBack else { return }
        let leaving = trail.removeLast()
        load(using: runner, select: leaving)
    }

    func moveSelection(by offset: Int) {
        guard !entries.isEmpty else { return }
        let current = selectedPath.flatMap { rowByPath[$0] } ?? (offset > 0 ? -1 : entries.count)
        selectedPath = entries[min(max(current + offset, 0), entries.count - 1)].path
    }

    /// Shows the folder at the end of the trail: the measurement kept from
    /// earlier at once, then a fresh one unless the kept one is recent.
    /// `refresh` (the Refresh button, R) always measures again.
    func load(using runner: MoleRunner, select: String? = nil, refresh: Bool = false) {
        loadTask?.cancel()
        let path = trail.last ?? nil
        let arguments = AnalyzeResult.arguments(for: path)
        let freshness = path == nil ? Self.overviewFreshness : Self.folderFreshness
        errorMessage = nil
        loadTask = Task {
            do {
                var onScreen = refresh && result != nil
                if !refresh, let kept = await cache.kept(AnalyzeResult.self, for: arguments) {
                    guard !Task.isCancelled else { return }
                    try await show(kept.value, select: select)
                    keptSince = kept.savedAt
                    onScreen = true
                    if kept.isRecent(within: freshness) {
                        isLoading = false
                        isRefreshing = false
                        return
                    }
                }
                isLoading = !onScreen
                isRefreshing = onScreen
                let fresh = try await runner.decode(AnalyzeResult.self, arguments, keepingIn: cache)
                guard !Task.isCancelled else { return }
                // A refresh keeps the row the person was on.
                try await show(fresh, select: onScreen ? selectedPath : select)
                keptSince = nil
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            isLoading = false
            isRefreshing = false
        }
    }

    private func show(_ result: AnalyzeResult, select: String?) async throws {
        let answers = try await Self.readAnswers()
        // A newer load may have started while the store was read.
        try Task.checkCancellation()
        let rows = result.sortedEntries
        self.result = result
        self.answers = answers
        entries = rows
        rowByPath = Dictionary(rows.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { first, _ in first })
        // Coming back up keeps the folder just left selected, as the
        // terminal does; anything else starts at the top.
        selectedPath = select.flatMap { rowByPath[$0] }.map { rows[$0].path } ?? rows.first?.path
    }

    /// The explain store holds every answer ever given: read it off the
    /// main thread.
    nonisolated private static func readAnswers() async throws -> [String: ExplainAnswers.Answer] {
        try ExplainAnswers.load()
    }

    // MARK: Explain

    /// E: the selected row; asking again after an answer that wants to look
    /// inside does the deep, read-only pass, as in the terminal.
    func explainSelected(using runner: MoleRunner) {
        guard let entry = selectedEntry, !isAsking(entry.path) else { return }
        let answer = answers[entry.path]
        let deep = answer?.needsExploration == true && answer?.explored != true
        enqueue(ExplainRequest(items: [Self.item(entry)], deep: deep), urgent: true, using: runner)
    }

    /// ⇧E: every row on screen without an answer yet.
    func explainAll(using runner: MoleRunner) {
        let pending = entries.filter { answers[$0.path] == nil && !isAsking($0.path) }.map(Self.item)
        for request in ExplainRequest.batches(of: pending) {
            enqueue(request, urgent: false, using: runner)
        }
    }

    func isAsking(_ path: String) -> Bool {
        if case .asking = explainStates[path] { return true }
        return false
    }

    private static func item(_ entry: AnalyzeResult.Entry) -> ExplainRequest.Item {
        .init(path: entry.path, label: entry.name, size: entry.size)
    }

    private func enqueue(_ request: ExplainRequest, urgent: Bool, using runner: MoleRunner) {
        let now = Date()
        for item in request.items {
            explainStates[item.path] = .asking(deep: request.deep, since: now)
        }
        if urgent {
            explainQueue.insert(request, at: 0)
        } else {
            explainQueue.append(request)
        }
        guard explainTask == nil else { return }
        explainTask = Task { await drainExplainQueue(using: runner) }
    }

    /// One request at a time: the AI agent is the heavy part, and the queue
    /// keeps the app light while a whole screen is explained.
    private func drainExplainQueue(using runner: MoleRunner) async {
        while !explainQueue.isEmpty {
            let request = explainQueue.removeFirst()
            do {
                let report = try await runner.decodeReport(ExplainReport.self, try request.arguments())
                withAnimation(Motion.update) {
                    for (path, answer) in report.answers {
                        answers[path] = answer
                        explainStates[path] = nil
                    }
                    for (path, message) in report.errors {
                        explainStates[path] = .failed(message)
                    }
                }
            } catch {
                for item in request.items {
                    explainStates[item.path] = .failed(error.localizedDescription)
                }
            }
        }
        explainTask = nil
    }
}

struct DiskView: View {
    let runner: MoleRunner
    /// Owned by the window, so coming back to this space shows the last
    /// scan instead of measuring the whole disk again.
    @Bindable var model: DiskModel

    @FocusState private var listFocused: Bool
    @State private var quickLookURL: URL?

    /// How many of the largest items the chart compares.
    private static let chartedEntries = 8

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.spacing) {
                        header
                        if let message = model.errorMessage {
                            ErrorBanner(message: message)
                        }
                        if model.isLoading {
                            LoadingCard(message: "Measuring folders… this can take a minute for the whole disk.")
                        } else if model.result != nil {
                            content
                        }
                    }
                    .padding(Theme.pagePadding)
                }
                .onChange(of: model.selectedPath) { _, path in
                    guard let path else { return }
                    withAnimation(Motion.hover) { proxy.scrollTo(path) }
                }
            }
            if model.result != nil, !model.isLoading {
                ExplainPanel(
                    entry: model.selectedEntry,
                    answer: model.selectedEntry.flatMap { model.answers[$0.path] },
                    state: model.selectedEntry.flatMap { model.explainStates[$0.path] }
                )
                .padding(.horizontal, Theme.pagePadding)
                .padding(.bottom, 10)
                KeyHints()
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.bottom, 14)
            }
        }
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down, action: handleKey)
        .quickLookPreview($quickLookURL)
        .task {
            if model.result == nil { model.load(using: runner) }
            listFocused = true
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            PageHeader(title: "Analyze", subtitle: model.result.map(subtitle))
            if model.canGoBack {
                Button {
                    model.back(using: runner)
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.glass)
            }
            if let keptSince = model.keptSince {
                UpdatedLabel(savedAt: keptSince, isRefreshing: model.isRefreshing)
            }
            Button {
                model.load(using: runner, select: model.selectedPath, refresh: true)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.glass)
            .disabled(model.isLoading || model.isRefreshing)
        }
        .entrance()
    }

    @ViewBuilder
    private var content: some View {
        let entries = model.entries
        if !entries.isEmpty {
            SizeChart(entries: Array(entries.prefix(Self.chartedEntries)))
                .entrance(1)
                .id(model.result?.path ?? "")
        }
        VerdictSummary(entries: entries, answers: model.answers)
        GlassCard(padding: 10, liftsOnHover: false) {
            LazyVStack(spacing: 2) {
                ForEach(entries) { entry in
                    EntryRow(
                        entry: entry,
                        largest: max(entries.first?.size ?? 1, 1),
                        answer: model.answers[entry.path],
                        state: model.explainStates[entry.path],
                        isSelected: entry.path == model.selectedPath
                    ) {
                        model.selectedPath = entry.path
                        listFocused = true
                    } open: {
                        model.open(entry, using: runner)
                    }
                    .id(entry.path)
                }
            }
        }
        .entrance(2)
    }

    private func subtitle(_ result: AnalyzeResult) -> String {
        let place = result.overview == true ? String(localized: "Whole disk") : result.path
        let total = Formatting.bytes(result.totalSize ?? 0)
        return result.isPartial
            ? String(localized: "\(place) · \(total) · some folders could not be read")
            : "\(place) · \(total)"
    }

    /// The terminal's keys (cmd/analyze/update.go).
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .upArrow:
            model.moveSelection(by: -1)
        case .downArrow:
            model.moveSelection(by: 1)
        case .rightArrow, .return:
            guard let entry = model.selectedEntry else { return .ignored }
            model.open(entry, using: runner)
        case .leftArrow, .escape, .delete:
            guard model.canGoBack else { return .ignored }
            model.back(using: runner)
        default:
            return handleLetter(press.characters)
        }
        return .handled
    }

    private func handleLetter(_ characters: String) -> KeyPress.Result {
        let entry = model.selectedEntry
        switch characters {
        case "e":
            model.explainSelected(using: runner)
        case "E":
            model.explainAll(using: runner)
        case "o", "O":
            guard let entry else { return .ignored }
            NSWorkspace.shared.open(URL(fileURLWithPath: entry.path))
        case "p", "P", " ":
            guard let entry, !entry.isDir else { return .ignored }
            quickLookURL = URL(fileURLWithPath: entry.path)
        case "f", "F":
            guard let entry else { return .ignored }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
        case "r", "R":
            model.load(using: runner, select: model.selectedPath, refresh: true)
        default:
            return .ignored
        }
        return .handled
    }
}

private struct SizeChart: View {
    let entries: [AnalyzeResult.Entry]

    /// The bars grow from zero when the chart appears.
    @State private var growth = 0.0

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                CardLabel(title: "Largest items", symbol: "chart.bar.fill")
                Chart(entries) { entry in
                    BarMark(
                        x: .value("Size", Double(entry.size) * growth),
                        y: .value("Name", MoleTerms.localized(entry.name, .place))
                    )
                    .cornerRadius(8)
                    .foregroundStyle(
                        LinearGradient(
                            colors: entry.insight == true ? [Theme.amber.opacity(0.65), Theme.amber] : [Theme.indigo, Theme.teal],
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
                .chartXScale(domain: 0...Double(max(entries.first?.size ?? 1, 1)) * 1.12)
                .chartYAxis {
                    AxisMarks { _ in AxisValueLabel().font(.callout) }
                }
                .frame(height: CGFloat(entries.count) * 30)
                .onAppear { withAnimation(Motion.value) { growth = 1 } }
            }
        }
    }
}

private struct EntryRow: View {
    let entry: AnalyzeResult.Entry
    let largest: Int64
    let answer: ExplainAnswers.Answer?
    let state: DiskModel.ExplainState?
    let isSelected: Bool
    let select: () -> Void
    let open: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            RowMark(answer: answer, state: state)
                .frame(width: 14)
            Image(systemName: entry.isDir ? "folder.fill" : "doc.fill")
                .font(.title3)
                .foregroundStyle(entry.isDir ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(verbatim: MoleTerms.localized(entry.name, .place))
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if entry.insight == true {
                        Pill(text: "Worth a look", color: Theme.amber)
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
            Image(systemName: "chevron.right")
                .foregroundStyle(.secondary)
                .opacity(entry.isDir ? 1 : 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowRadius)
                .fill(isSelected ? AnyShapeStyle(Theme.indigo.opacity(0.16)) : AnyShapeStyle(.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.rowRadius)
                .strokeBorder(isSelected ? Theme.indigo.opacity(0.45) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: open)
        .onTapGesture(perform: select)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The mark the terminal puts in place of a row's separator: a colored dot
/// once answered, a hollow one while the AI is asked, ! after a failure.
private struct RowMark: View {
    let answer: ExplainAnswers.Answer?
    let state: DiskModel.ExplainState?

    var body: some View {
        switch state {
        case .asking:
            Text(verbatim: "◌").foregroundStyle(Theme.teal)
        case .failed:
            Text(verbatim: "!").fontWeight(.bold).foregroundStyle(Theme.rose)
        case nil:
            if let verdict = answer?.verdict {
                Text(verbatim: "●").foregroundStyle(VerdictStyle(verdict).color)
            }
        }
    }
}

/// The terminal's verdict words and colors (cmd/analyze/explain_view.go).
private struct VerdictStyle {
    let label: LocalizedStringKey
    let color: Color

    init(_ verdict: String) {
        switch verdict {
        case "safe": (label, color) = ("Safe to delete", Theme.teal)
        case "caution": (label, color) = ("Check first", Theme.amber)
        case "keep": (label, color) = ("Keep", Theme.rose)
        default: (label, color) = ("Unsure", .secondary)
        }
    }
}

private struct VerdictPill: View {
    let verdict: String

    var body: some View {
        let style = VerdictStyle(verdict)
        Pill(text: style.label, color: style.color)
    }
}

/// "Safe to delete 3 · 1.2 GB · Check first 2 · 300 MB", as the terminal sums
/// the answered rows above its list.
private struct VerdictSummary: View {
    let entries: [AnalyzeResult.Entry]
    let answers: [String: ExplainAnswers.Answer]

    private static let order = ["safe", "caution", "keep", "unknown"]

    var body: some View {
        let groups = Self.order.compactMap { verdict -> (String, Int, Int64)? in
            let rows = entries.filter { (answers[$0.path]?.verdict ?? "") == verdict }
            return rows.isEmpty ? nil : (verdict, rows.count, rows.reduce(0) { $0 + $1.size })
        }
        if !groups.isEmpty {
            HStack(spacing: 16) {
                ForEach(groups, id: \.0) { verdict, count, bytes in
                    let style = VerdictStyle(verdict)
                    HStack(spacing: 6) {
                        Circle().fill(style.color).frame(width: 8, height: 8)
                        Text(style.label)
                        Text(verbatim: "\(count) · \(Formatting.bytes(bytes))").foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

/// The terminal's explain panel: title, verdict line, then what it is, what
/// happens if it goes, and the advice.
private struct ExplainPanel: View {
    let entry: AnalyzeResult.Entry?
    let answer: ExplainAnswers.Answer?
    let state: DiskModel.ExplainState?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                Text(verbatim: title).font(.headline).lineLimit(1)
                Spacer()
                if let hint {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
            }
            bodyText
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 132, maxHeight: 190, alignment: .topLeading)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.cardRadius))
        .animation(Motion.update, value: answer)
    }

    private var title: String {
        guard let entry else { return String(localized: "Explain") }
        var parts = [MoleTerms.localized(entry.name, .place), Formatting.bytes(entry.size)]
        if let provider = answer?.provider, state == nil { parts.append(provider) }
        return parts.joined(separator: " · ")
    }

    /// The key the panel's lower edge offers in the terminal.
    private var hint: LocalizedStringKey? {
        switch state {
        case .failed: return "E: try again"
        case .asking: return nil
        case nil:
            guard let answer, answer.needsExploration == true, answer.explored != true else { return nil }
            return "E: look inside (read-only)"
        }
    }

    @ViewBuilder
    private var bodyText: some View {
        switch state {
        case .asking(let deep, let since):
            TimelineView(.periodic(from: since, by: 1)) { context in
                let seconds = Int(context.date.timeIntervalSince(since))
                Label {
                    Text(deep ? "The AI is looking inside, read-only… \(seconds) s" : "The AI is thinking… \(seconds) s")
                } icon: {
                    ProgressView().controlSize(.small)
                }
                .foregroundStyle(Theme.teal)
            }
        case .failed(let message):
            Text("Could not get an explanation.").foregroundStyle(Theme.rose)
            Text(verbatim: message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        case nil:
            if entry == nil {
                Text("Nothing to explain here.").foregroundStyle(.secondary)
            } else if let answer {
                answerText(answer)
            } else {
                Text("Not explained yet. Press E to ask the AI.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func answerText(_ answer: ExplainAnswers.Answer) -> some View {
        let style = VerdictStyle(answer.verdict ?? "unknown")
        HStack(spacing: 6) {
            Text(verbatim: "●")
            Text(style.label).textCase(.uppercase).fontWeight(.semibold)
            Text(verbatim: "·")
            Text(answer.explored == true ? "after reading the files" : "without opening the files")
            if let date = answer.answeredDate {
                Text(verbatim: "·")
                Text("answer of \(date.formatted(.dateTime.day().month(.twoDigits)))")
            }
        }
        .font(.callout)
        .foregroundStyle(style.color)
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                labeled(String(localized: "What it is: "), answer.what)
                labeled(String(localized: "If I delete it: "), answer.ifDeleted)
                labeled(String(localized: "Advice: "), answer.advice)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func labeled(_ label: String, _ text: String?) -> some View {
        if let text, !text.isEmpty {
            Text(Self.paragraph(label, text)).font(.callout)
        }
    }

    /// A bold lead-in and the answer's text, wrapping as one paragraph.
    private static func paragraph(_ label: String, _ text: String) -> AttributedString {
        var lead = AttributedString(label)
        lead.inlinePresentationIntent = .stronglyEmphasized
        return lead + AttributedString(text)
    }
}

/// The terminal's footer, as keycaps.
private struct KeyHints: View {
    private let hints: [(keys: String, label: LocalizedStringKey)] = [
        ("↑↓←→", "Move"),
        ("↩", "Open"),
        ("E", "Explain"),
        ("⇧E", "All"),
        ("O", "Open file"),
        ("P", "Preview"),
        ("F", "Finder"),
        ("R", "Refresh"),
    ]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(hints, id: \.keys) { hint in
                HStack(spacing: 5) {
                    Text(verbatim: hint.keys)
                        .font(.caption.weight(.semibold).monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .glassEffect(.regular, in: .rect(cornerRadius: 5))
                    Text(hint.label).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
