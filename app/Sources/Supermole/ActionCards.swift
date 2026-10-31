import AppKit
import SupermoleCore
import SwiftUI

/// Cards shared by the spaces that preview, then run, a `mo` command that
/// removes or changes things (Clean up, Apps).

/// A `mo` command at work.
struct WorkingCard: View {
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

/// The end of a run, as `mo history` recorded it: what was freed, how many
/// items went, and what to do next.
struct RunResultCard: View {
    let result: HistoryReport.Session?
    /// False when the run stopped early or left something undone.
    let completed: Bool
    /// Shown when the run completed and freed nothing.
    let nothingFreed: LocalizedStringKey
    /// Shown when the run did not complete and freed nothing.
    let stoppedEarly: LocalizedStringKey
    let actionTitle: LocalizedStringKey
    let actionSymbol: String
    let action: () -> Void
    /// What the run could not do, one line each.
    var warnings: [String] = []

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
                    Text(completed ? nothingFreed : stoppedEarly)
                        .font(.title2.weight(.semibold))
                }
                if let actions = result?.actions {
                    Text("\(actions.removed ?? 0) removed · \(actions.trashed ?? 0) to Trash")
                        .foregroundStyle(.secondary)
                }
                ForEach(warnings, id: \.self) { warning in
                    Label {
                        Text(verbatim: warning)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .foregroundStyle(Theme.amber)
                }
                Button(action: action) {
                    Label(actionTitle, systemImage: actionSymbol)
                }
                .buttonStyle(.glass)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .onAppear { withAnimation(Motion.entrance.delay(0.15)) { appeared = true } }
    }
}

/// What the `mo` command printed, for the curious.
struct LogCard: View {
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

/// One file or folder of a preview: its path with the home folder as ~, a
/// note on the right (usually its size), and a button that shows it in the
/// Finder.
struct PathLine: View {
    let path: String
    let note: String?
    /// For what stays where it is.
    var dimmed = false

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: Self.displayPath(path))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(dimmed ? .tertiary : .secondary)
            Spacer()
            if let note {
                Text(verbatim: note)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(dimmed ? .tertiary : .primary)
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
    }

    /// The path with the home folder written as ~.
    static func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// A measured size, or a dash when `mo` could not measure it.
    static func sizeNote(_ bytes: Int64?) -> String {
        bytes.map { Formatting.bytes($0) } ?? "—"
    }
}
