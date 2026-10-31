import Observation
import SupermoleCore
import SwiftUI

@MainActor
@Observable
final class HistoryModel {
    private(set) var report: HistoryReport?
    private(set) var errorMessage: String?

    func load(using runner: MoleRunner) async {
        do {
            report = try await runner.decode(HistoryReport.self, HistoryReport.arguments())
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The inspector beside every space: what Supermole did, most recent first.
struct HistoryPanel: View {
    let runner: MoleRunner
    let model: HistoryModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("History").font(.title2.bold())
                Text("What Supermole did on this Mac, most recent first.")
                    .foregroundStyle(.secondary)
                if let message = model.errorMessage {
                    ErrorBanner(message: message)
                }
                if let sessions = model.report?.sessions {
                    if sessions.isEmpty {
                        Text("Nothing yet.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        SessionRow(session: session).entrance(index)
                    }
                } else if model.errorMessage == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(18)
        }
        .task { await model.load(using: runner) }
    }
}

private struct SessionRow: View {
    let session: HistoryReport.Session

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: Self.symbol(for: session.command))
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 36, height: 36)
                .glassEffect(.regular.tint(Theme.indigo.opacity(0.15)), in: .circle)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(Self.title(for: session.command)).font(.headline)
                    Spacer()
                    if let size = session.size, let bytes = MoleText.bytes(fromHumanSize: size), bytes > 0 {
                        Text(verbatim: Formatting.bytes(bytes))
                            .font(.headline)
                            .monospacedDigit()
                            .foregroundStyle(Theme.teal)
                    }
                }
                Text(verbatim: startedAt).font(.caption).foregroundStyle(.secondary)
                if let actions = session.actions {
                    Text("\(actions.removed ?? 0) removed · \(actions.trashed ?? 0) to Trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let failed = actions.failed, failed > 0 {
                        Text("\(failed) failed").font(.caption).foregroundStyle(Theme.amber)
                    }
                }
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.rowRadius))
    }

    private var startedAt: String {
        guard let text = session.startedAt else { return "" }
        guard let date = MoleText.historyDate(text) else { return text }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func title(for command: String) -> LocalizedStringKey {
        switch command {
        case "clean": return "Clean up"
        case "uninstall": return "Uninstall"
        case "optimize": return "Optimize"
        case "purge": return "Developer projects"
        case "installer": return "Installer files"
        case "slim": return "Slim apps"
        case "analyze": return "Analyze"
        default: return LocalizedStringKey(command)
        }
    }

    private static func symbol(for command: String) -> String {
        switch command {
        case "clean": return "sparkles"
        case "uninstall": return "trash"
        case "optimize": return "wand.and.stars"
        case "purge": return "hammer"
        case "installer": return "shippingbox"
        case "slim": return "scissors"
        case "analyze": return "chart.pie"
        default: return "terminal"
        }
    }
}
