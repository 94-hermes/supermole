import Observation
import SupermoleCore
import SwiftUI

/// The apps whose Intel code `mo slim` can remove, then slimming the ones the
/// person ticks. Nothing is ever ticked for them.
@MainActor
@Observable
final class SlimModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case list
        case slimming
        case done
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var preview: SlimPreview?
    /// Ticked apps, by bundle path.
    var selection: Set<String> = []
    private(set) var log = RunLog()
    private(set) var result: HistoryReport.Session?
    private(set) var runCompleted = true
    private var task: Task<Void, Never>?

    var isBusy: Bool { phase == .scanning || phase == .slimming }
    var selectedApps: [SlimPreview.App] { preview?.apps.filter { selection.contains($0.path) } ?? [] }
    var selectedBytes: Int64 { selectedApps.reduce(0) { $0 + $1.intelBytes } }

    func scan(using runner: MoleRunner) {
        task?.cancel()
        phase = .scanning
        task = Task {
            do {
                let preview = try await runner.decode(SlimPreview.self, SlimPreview.arguments)
                try Task.checkCancellation()
                withAnimation(Motion.entrance) {
                    self.preview = preview
                    selection = []
                    phase = .list
                }
            } catch is CancellationError {
                // A newer request replaced this one.
                return
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func slim(using runner: MoleRunner) {
        let paths = selectedApps.map(\.path)
        guard !paths.isEmpty else { return }
        task?.cancel()
        phase = .slimming
        log = RunLog()
        result = nil
        task = Task {
            var exitedCleanly = true
            do {
                for try await line in runner.lines(SlimPreview.slimArguments(paths: paths), includeErrors: true) {
                    log.append(line)
                }
            } catch MoleError.failed {
                // An app left unchanged (open, or its copy failed a check)
                // ends the run with a nonzero status; the summary says which.
                exitedCleanly = false
            } catch {
                phase = .failed(error.localizedDescription)
                return
            }
            runCompleted = exitedCleanly
            selection = []
            do {
                let history = try await runner.decode(HistoryReport.self, HistoryReport.arguments(limit: 1))
                result = history.sessions?.first { $0.command == "slim" }
            } catch {
                log.append(error.localizedDescription)
            }
            withAnimation(Motion.entrance) { phase = .done }
        }
    }
}

struct SlimSection: View {
    let runner: MoleRunner
    @Bindable var model: SlimModel

    @State private var confirmsSlim = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            switch model.phase {
            case .idle:
                SlimStartCard { model.scan(using: runner) }.entrance(2)
            case .scanning:
                WorkingCard(title: "Looking for apps to slim…", detail: "Nothing is changed. This takes about twenty seconds.")
                    .entrance(2)
            case .list:
                if let preview = model.preview {
                    SlimListCard(preview: preview, model: model, rescan: { model.scan(using: runner) }) {
                        confirmsSlim = true
                    }
                    .entrance(2)
                }
            case .slimming:
                WorkingCard(title: "Slimming…", detail: "Each app is rebuilt on a copy that must pass Apple's checks before it replaces the app.")
                    .entrance(2)
            case .done:
                RunResultCard(
                    result: model.result,
                    completed: model.runCompleted,
                    nothingFreed: "No app was slimmed.",
                    stoppedEarly: "Some apps were left unchanged; the details say why.",
                    actionTitle: "Analyze again",
                    actionSymbol: "arrow.clockwise"
                ) {
                    model.scan(using: runner)
                }
                .entrance(2)
            case .failed(let message):
                ErrorBanner(message: message)
                SlimStartCard { model.scan(using: runner) }
            }
            if !model.log.isEmpty, model.phase == .slimming || model.phase == .done {
                LogCard(lines: model.log.lines).entrance(3)
            }
        }
        .alert("Slim these apps?", isPresented: $confirmsSlim) {
            Button("Slim apps") { model.slim(using: runner) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each app is rebuilt on a copy that must pass Apple's signature and Gatekeeper checks before it replaces the app; the original goes to the Trash. Open apps are skipped. An app update brings the Intel code back.")
        }
    }
}

private struct SlimStartCard: View {
    let scan: () -> Void

    var body: some View {
        GlassCard {
            VStack(spacing: 18) {
                Image(systemName: "scissors")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 96, height: 96)
                    .glassEffect(.regular.tint(Theme.indigo.opacity(0.15)), in: .circle)
                Text("Slim down your apps").font(.title2.weight(.semibold))
                Text("Many apps also carry code for older Intel Macs, which yours never runs. Supermole lists them first; nothing changes until you choose apps and confirm.")
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

private struct SlimListCard: View {
    let preview: SlimPreview
    @Bindable var model: SlimModel
    let rescan: () -> Void
    let slim: () -> Void

    var body: some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        CardLabel(title: "Intel code in your apps", symbol: "cpu", tint: Theme.teal)
                        Text(verbatim: Formatting.bytes(preview.totalIntelBytes))
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.accent)
                        Group {
                            if model.selection.isEmpty {
                                Text("Tick the apps to slim; nothing is ticked for you.")
                            } else {
                                Text("\(model.selection.count) selected · \(Formatting.bytes(model.selectedBytes))")
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: rescan) {
                        Label("Analyze again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.glass)
                    Button(action: slim) {
                        Label("Slim apps", systemImage: "scissors")
                            .font(.title3.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(model.selection.isEmpty)
                }
                if preview.apps.isEmpty {
                    Text("No app carries Intel code Supermole can remove.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(preview.apps) { app in
                            SelectableAppRow(name: app.name, path: app.path, bytes: app.intelBytes, isSelected: $model.selection.contains(app.path)) {
                                if app.running {
                                    Text("Open: quit it before slimming, or it is skipped.")
                                        .font(.caption)
                                        .foregroundStyle(Theme.amber)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
