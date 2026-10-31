import AppKit
import Charts
import Observation
import SupermoleCore
import SwiftUI

/// Preview first, then the real cleanup, both run by `mo clean`.
@MainActor
@Observable
final class CleanModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case preview
        case cleaning
        case done
        case failed(String)
    }

    /// How many lines of `mo clean`'s output the details keep.
    static let logLength = 200

    private(set) var phase: Phase = .idle
    private(set) var preview: CleanPreview?
    private(set) var currentSection: String?
    private(set) var finishedSections: [String] = []
    private(set) var log: [String] = []
    private(set) var result: HistoryReport.Session?
    /// False when `mo clean` stopped early (timeout, interruption).
    private(set) var cleanCompleted = true
    private var task: Task<Void, Never>?

    var isBusy: Bool { phase == .scanning || phase == .cleaning }

    func scan(using runner: MoleRunner) {
        task?.cancel()
        phase = .scanning
        task = Task {
            do {
                let preview = try await runner.decodeReport(CleanPreview.self, CleanPreview.arguments)
                guard !Task.isCancelled else { return }
                withAnimation(Motion.entrance) {
                    self.preview = preview
                    self.phase = .preview
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func clean(using runner: MoleRunner) {
        task?.cancel()
        phase = .cleaning
        currentSection = nil
        finishedSections = []
        log = []
        result = nil
        cleanCompleted = true
        task = Task {
            do {
                for try await line in runner.lines(CleanPreview.cleanArguments, includeErrors: true) {
                    record(line)
                }
            } catch MoleError.failed {
                // mo clean reports an early stop with a nonzero status; what it
                // removed until then is in the history like any run.
                cleanCompleted = false
            } catch {
                phase = .failed(error.localizedDescription)
                return
            }
            if Task.isCancelled {
                // Stopped by the person; what was removed until then is in
                // the history like any run.
                cleanCompleted = false
            }
            if let section = currentSection {
                finishedSections.append(section)
                currentSection = nil
            }
            do {
                let history = try await runner.decode(HistoryReport.self, HistoryReport.arguments(limit: 1))
                result = history.sessions?.first { $0.command == "clean" }
            } catch {
                log.append(error.localizedDescription)
            }
            withAnimation(Motion.entrance) { phase = .done }
        }
    }

    func stop() {
        task?.cancel()
    }

    private func record(_ line: String) {
        if let section = CleanProgress.section(in: line) {
            withAnimation(Motion.update) {
                if let previous = currentSection { finishedSections.append(previous) }
                currentSection = section
            }
        }
        let text = TerminalText.clean(line)
        guard !text.isEmpty else { return }
        log.append(text)
        if log.count > Self.logLength {
            log.removeFirst(log.count - Self.logLength)
        }
    }
}

struct CleanView: View {
    let runner: MoleRunner
    let model: CleanModel

    @State private var confirmsCleanup = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                PageHeader(title: "Clean up", subtitle: String(localized: "Caches, leftovers and files your Mac no longer needs."))
                    .entrance()
                switch model.phase {
                case .idle:
                    StartCard { model.scan(using: runner) }.entrance(1)
                case .scanning:
                    WorkingCard(title: "Looking for what can go…", detail: "Nothing is removed. This takes a minute or two.")
                        .entrance(1)
                case .preview:
                    if let preview = model.preview {
                        previewContent(preview)
                    }
                case .cleaning:
                    CleaningCard(
                        current: model.currentSection,
                        finished: model.finishedSections,
                        expected: model.preview?.sortedSections.count ?? 0
                    ) {
                        model.stop()
                    }
                    .entrance(1)
                case .done:
                    DoneCard(result: model.result, completed: model.cleanCompleted) {
                        model.scan(using: runner)
                    }
                    .entrance(1)
                case .failed(let message):
                    ErrorBanner(message: message)
                    StartCard { model.scan(using: runner) }
                }
                if !model.log.isEmpty, model.phase == .cleaning || model.phase == .done {
                    LogCard(lines: model.log).entrance(2)
                }
            }
            .padding(Theme.pagePadding)
        }
        .alert(confirmationTitle, isPresented: $confirmsCleanup) {
            Button("Clean up", role: .destructive) { model.clean(using: runner) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    @ViewBuilder
    private func previewContent(_ preview: CleanPreview) -> some View {
        SummaryCard(preview: preview, emptiesTrash: emptiesTrash(preview)) {
            confirmsCleanup = true
        } rescan: {
            model.scan(using: runner)
        }
        .entrance(1)
        if !preview.sortedSections.isEmpty {
            SectionChart(sections: preview.sortedSections).entrance(2)
        }
        if !preview.summaries.isEmpty {
            GlassCard(padding: 10) {
                VStack(spacing: 2) {
                    ForEach(preview.summaries) { summary in
                        SectionRow(summary: summary, entries: preview.entries(in: summary.name))
                    }
                }
            }
            .entrance(3)
        }
    }

    private func emptiesTrash(_ preview: CleanPreview) -> Bool {
        preview.emptiesTrash(home: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    private var confirmationTitle: String {
        guard let preview = model.preview else { return "" }
        return String(localized: "Clean up \(Formatting.bytes(preview.totalBytes))?")
    }

    private var confirmationMessage: String {
        let base = String(localized: "Supermole does everything shown under each category, tool commands such as Homebrew or npm included. Caches rebuild themselves when apps need them.")
        guard let preview = model.preview, emptiesTrash(preview) else { return base }
        return base + " " + String(localized: "The Trash will be emptied.")
    }
}

/// Everything before the first scan.
private struct StartCard: View {
    let scan: () -> Void

    var body: some View {
        GlassCard {
            VStack(spacing: 18) {
                Image(systemName: "sparkles")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 96, height: 96)
                    .glassEffect(.regular.tint(Theme.indigo.opacity(0.15)), in: .circle)
                Text("See what can be freed").font(.title2.weight(.semibold))
                Text("Supermole looks through caches, logs, leftovers of deleted apps and old downloads. Nothing is removed until you confirm.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                Button(action: scan) {
                    Label("Analyze", systemImage: "magnifyingglass")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }
}

private struct WorkingCard: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        GlassCard {
            HStack(spacing: 18) {
                ProgressView().controlSize(.large)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(detail).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
        }
    }
}

private struct SummaryCard: View {
    let preview: CleanPreview
    let emptiesTrash: Bool
    let clean: () -> Void
    let rescan: () -> Void

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        CardLabel(title: "Ready to free", symbol: "sparkles", tint: Theme.teal)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if preview.sizePartial {
                                Text("at least").font(.title3).foregroundStyle(.secondary)
                            }
                            Text(verbatim: Formatting.bytes(preview.totalBytes))
                                .font(.system(size: 46, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.accent)
                                .contentTransition(.numericText())
                        }
                        Text("\(preview.items) items in \(preview.summaries.count) categories")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: rescan) {
                        Label("Analyze again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.glass)
                    Button(action: clean) {
                        Label("Clean up", systemImage: "sparkles")
                            .font(.title3.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    // A preview that stopped early skipped later sections; the
                    // real run would clean them unseen.
                    .disabled(preview.summaries.isEmpty || !preview.isComplete)
                }
                if emptiesTrash {
                    Label("The Trash is emptied too.", systemImage: "trash")
                        .foregroundStyle(Theme.amber)
                }
                if !preview.isComplete {
                    Label("Part of the Mac could not be checked in time; Analyze again before cleaning.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.amber)
                }
                if preview.systemIncluded == true {
                    Label("System caches are included: an administrator session is open.", systemImage: "lock.open")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("System caches need an administrator password; that part comes in a later version.", systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The sections compared by size; three hues alternate so neighbours differ.
private struct SectionChart: View {
    let sections: [CleanPreview.Section]
    @State private var growth = 0.0

    private static let palette = [Theme.indigo, Theme.teal, Theme.amber]

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                CardLabel(title: "By category", symbol: "chart.bar.fill")
                Chart(Array(sections.enumerated()), id: \.element.id) { index, section in
                    BarMark(
                        x: .value("Size", Double(section.bytes) * growth),
                        y: .value("Name", MoleTerms.localized(section.name, .section))
                    )
                    .cornerRadius(8)
                    .foregroundStyle(Self.palette[index % Self.palette.count].gradient)
                    .annotation(position: .trailing, spacing: 8) {
                        Text(verbatim: Formatting.bytes(section.bytes))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .chartXAxis(.hidden)
                .chartXScale(domain: 0...Double(max(sections.first?.bytes ?? 1, 1)) * 1.15)
                .chartYAxis {
                    AxisMarks { _ in AxisValueLabel().font(.callout) }
                }
                .frame(height: CGFloat(sections.count) * 34)
                .onAppear { withAnimation(Motion.value) { growth = 1 } }
            }
        }
    }
}

/// One category, unfolding into what the cleanup does there (the lines the
/// terminal shows) and its largest items.
private struct SectionRow: View {
    let summary: CleanPreview.Summary
    let entries: [CleanPreview.Entry]
    @State private var isExpanded = false

    /// Rows shown when a category unfolds; the rest are summed up in a line.
    private static let shownEntries = 25
    /// mole_dry_run_detail records its lines with this indent.
    private static let detailIndent = "  "

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.hover) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: SectionStyle.symbol(for: summary.name))
                        .font(.title3)
                        .foregroundStyle(Theme.accent)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: MoleTerms.localized(summary.name, .section)).font(.body.weight(.medium))
                        if summary.items > 0 {
                            Text("\(summary.items) items").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Tool commands").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if summary.bytes > 0 {
                        Text(verbatim: Formatting.bytes(summary.bytes)).monospacedDigit().fontWeight(.semibold)
                    }
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
                // VoiceOver reads the category, its size and item count as one.
                .accessibilityElement(children: .combine)
            }
            .buttonStyle(.plain)
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    // As the terminal prints them: "→ npm cache · would clean",
                    // with a detail (an indented line) under its action.
                    ForEach(Array(summary.lines.enumerated()), id: \.offset) { _, line in
                        let isDetail = line.hasPrefix(Self.detailIndent)
                        Text(verbatim: isDetail ? line.trimmingCharacters(in: .whitespaces) : "→ " + line)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(isDetail ? .secondary : .primary)
                            .padding(.leading, isDetail ? 22 : 0)
                            .textSelection(.enabled)
                    }
                    if !entries.isEmpty, !summary.lines.isEmpty {
                        Divider().padding(.vertical, 4)
                    }
                    ForEach(entries.prefix(Self.shownEntries)) { entry in
                        EntryLine(entry: entry)
                    }
                    if entries.count > Self.shownEntries {
                        Text("and \(entries.count - Self.shownEntries) more").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 58)
                .padding(.trailing, 14)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct EntryLine: View {
    let entry: CleanPreview.Entry

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: Self.displayPath(entry.path))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            Spacer()
            Text(verbatim: entry.sizeKnown ? Formatting.bytes(entry.bytes) : "—")
                .font(.callout)
                .monospacedDigit()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
    }

    /// The path with the home folder written as ~.
    private static func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

private struct CleaningCard: View {
    let current: String?
    let finished: [String]
    let expected: Int
    let stop: () -> Void

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 16) {
                    ProgressView().controlSize(.large)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cleaning up…").font(.title2.weight(.semibold))
                        if let current {
                            Text(verbatim: MoleTerms.localized(current, .section))
                                .foregroundStyle(.secondary)
                                .contentTransition(.opacity)
                        }
                    }
                    Spacer()
                    Button("Stop", action: stop).buttonStyle(.glass)
                }
                if expected > 0 {
                    ProgressView(value: Double(min(finished.count, expected)), total: Double(expected))
                        .tint(Theme.teal)
                }
                ForEach(finished, id: \.self) { section in
                    Label(MoleTerms.localized(section, .section), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.teal)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
        }
    }
}

private struct DoneCard: View {
    let result: HistoryReport.Session?
    let completed: Bool
    let rescan: () -> Void

    @State private var appeared = false

    var body: some View {
        GlassCard {
            VStack(spacing: 14) {
                Image(systemName: completed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(completed ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.amber))
                    .scaleEffect(appeared ? 1 : 0.4)
                    .opacity(appeared ? 1 : 0)
                if let size = result?.size, let bytes = MoleText.bytes(fromHumanSize: size), bytes > 0 {
                    Text("\(Formatting.bytes(bytes)) freed")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                } else {
                    Text(completed ? "Your Mac was already clean." : "The cleanup stopped early.")
                        .font(.title2.weight(.semibold))
                }
                if let actions = result?.actions {
                    Text("\(actions.removed ?? 0) removed · \(actions.trashed ?? 0) to Trash")
                        .foregroundStyle(.secondary)
                }
                Button(action: rescan) {
                    Label("Analyze again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .onAppear { withAnimation(Motion.entrance.delay(0.15)) { appeared = true } }
    }
}

/// What `mo clean` printed, for the curious.
private struct LogCard: View {
    let lines: [String]
    @State private var isExpanded = false

    var body: some View {
        GlassCard(padding: 16) {
            DisclosureGroup(isExpanded: $isExpanded) {
                ScrollView {
                    Text(verbatim: lines.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 220)
            } label: {
                Label("Details", systemImage: "text.alignleft").foregroundStyle(.secondary)
            }
        }
    }
}

/// An icon for each section `mo clean` runs (start_section in bin/clean.sh).
private enum SectionStyle {
    private static let symbols: [String: String] = [
        "User essentials": "person.crop.circle",
        "App caches": "app.badge",
        "App leftovers": "trash.slash",
        "Application Support": "folder",
        "Apps & utilities": "square.grid.2x2",
        "Browsers": "safari",
        "Cloud & Office": "icloud",
        "Developer tools": "hammer",
        "Device backups & firmware": "iphone",
        "External volume": "externaldrive",
        "Large files": "doc.zipper",
        "Project artifacts": "folder.badge.gearshape",
        "System": "gearshape.2",
        "Time Machine": "clock.arrow.circlepath",
        "Virtualization": "shippingbox",
    ]

    static func symbol(for section: String) -> String {
        symbols[section] ?? "sparkles"
    }
}
