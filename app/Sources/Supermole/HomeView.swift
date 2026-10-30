import Observation
import SupermoleCore
import SwiftUI

/// Follows `mo status --watch` and keeps the last minutes of CPU and memory.
///
/// One reading every five seconds, and only while the app is in front: the
/// view cancels the watch otherwise, which stops `mo`, so an idle Supermole
/// runs no collector at all.
@MainActor
@Observable
final class HomeModel {
    static let interval = "5s"
    static let arguments = ["status", "--watch", "--interval", interval]
    static let oneReading = ["status", "--json"]
    /// Five minutes of readings.
    static let historyLength = 60

    private(set) var snapshot: StatusSnapshot?
    private(set) var cpuHistory: [Sample] = []
    private(set) var memoryHistory: [Sample] = []
    private(set) var errorMessage: String?
    private var readings = 0

    func watch(using runner: MoleRunner) async {
        errorMessage = nil
        do {
            for try await line in runner.lines(Self.arguments) where !line.isEmpty {
                do {
                    let snapshot = try MoleJSON.decode(StatusSnapshot.self, from: Data(line.utf8))
                    withAnimation(Motion.update) { record(snapshot) }
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// A single reading, for a window that is visible but not in front and
    /// has nothing to show yet.
    func readOnce(using runner: MoleRunner) async {
        do {
            let snapshot = try await runner.decode(StatusSnapshot.self, Self.oneReading)
            withAnimation(Motion.update) { record(snapshot) }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func record(_ snapshot: StatusSnapshot) {
        self.snapshot = snapshot
        readings += 1
        if let usage = snapshot.cpu?.usage {
            append(Sample(id: readings, value: usage), to: &cpuHistory)
        }
        if let memory = snapshot.memory, let used = memory.used, let total = memory.total, total > 0 {
            append(Sample(id: readings, value: Double(used) / Double(total) * 100), to: &memoryHistory)
        }
    }

    private func append(_ sample: Sample, to history: inout [Sample]) {
        history.append(sample)
        if history.count > Self.historyLength {
            history.removeFirst(history.count - Self.historyLength)
        }
    }
}

struct HomeView: View {
    let runner: MoleRunner
    let model: HomeModel
    let navigate: (AppSpace) -> Void

    /// False once another app comes to the front: the watch stops with it.
    /// `scenePhase` stays active while the window is merely visible.
    @Environment(\.appearsActive) private var appearsActive
    @State private var contentWidth: CGFloat = 0

    /// From this width up, Health and Storage sit side by side.
    private static let sideBySideWidth: CGFloat = 760

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                PageHeader(title: "Home", subtitle: model.snapshot?.hardware.map(Self.hardwareLine))
                    .entrance()
                if let message = model.errorMessage {
                    ErrorBanner(message: message)
                }
                if let snapshot = model.snapshot {
                    GlassEffectContainer(spacing: Theme.spacing) {
                        VStack(spacing: Theme.spacing) {
                            // Side by side when the window is wide enough, stacked otherwise.
                            heroLayout {
                                HealthCard(snapshot: snapshot).entrance(1)
                                StorageCard(snapshot: snapshot).entrance(2)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            HStack(alignment: .top, spacing: Theme.spacing) {
                                MemoryTile(snapshot: snapshot, history: model.memoryHistory).entrance(3)
                                ProcessorTile(snapshot: snapshot, history: model.cpuHistory).entrance(4)
                                BatteryTile(snapshot: snapshot).entrance(5)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    FreeSpaceCall { navigate(.clean) }.entrance(6)
                    BusiestApps(snapshot: snapshot).entrance(7)
                } else if model.errorMessage == nil {
                    LoadingCard(message: "Reading your Mac…")
                }
            }
            .padding(Theme.pagePadding)
        }
        // The scroll view's width, which the layout choice cannot change: measuring
        // the content instead fed back into itself and AppKit aborted the app.
        .onGeometryChange(for: CGFloat.self) { $0.size.width - 2 * Theme.pagePadding } action: { contentWidth = $0 }
        .task(id: appearsActive) {
            if appearsActive {
                await model.watch(using: runner)
            } else if model.snapshot == nil {
                await model.readOnce(using: runner)
            }
        }
    }

    private var heroLayout: AnyLayout {
        contentWidth >= Self.sideBySideWidth
            ? AnyLayout(HStackLayout(alignment: .top, spacing: Theme.spacing))
            : AnyLayout(VStackLayout(spacing: Theme.spacing))
    }

    private static func hardwareLine(_ hardware: StatusSnapshot.Hardware) -> String {
        [hardware.model, hardware.cpuModel, hardware.osVersion]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// The diameter of the two large gauges, sized so both cards fit side by
/// side in the narrowest window.
private let largeGaugeSize: CGFloat = 128

private struct HealthCard: View {
    let snapshot: StatusSnapshot

    var body: some View {
        let score = snapshot.healthScore ?? 0
        let message = MoleText.healthMessage(snapshot.healthScoreMsg ?? "")
        GlassCard {
            HStack(spacing: 22) {
                RingGauge(fraction: Double(score) / 100, colors: Theme.scoreColors(score), lineWidth: 16) {
                    VStack(spacing: 0) {
                        Text(verbatim: "\(score)")
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .contentTransition(.numericText(value: Double(score)))
                        Text("out of 100").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: largeGaugeSize, height: largeGaugeSize)
                VStack(alignment: .leading, spacing: 10) {
                    CardLabel(title: "Health", symbol: "heart.fill", tint: Theme.scoreColor(score))
                    Text(verbatim: MoleTerms.localized(message.rating, .health))
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                    if message.issues.isEmpty {
                        Text("Nothing needs your attention.").foregroundStyle(.secondary)
                    } else {
                        ForEach(message.issues, id: \.self) { issue in
                            Label(MoleTerms.localized(issue, .issue), systemImage: "exclamationmark.circle.fill")
                                .foregroundStyle(Theme.amber)
                        }
                    }
                    if let seconds = snapshot.uptimeSeconds {
                        Text("Running for \(Formatting.duration(seconds: seconds))")
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct StorageCard: View {
    let snapshot: StatusSnapshot

    var body: some View {
        GlassCard {
            if let disk = snapshot.startupDisk, let used = disk.used, let total = disk.total, total > 0 {
                let purgeable = min(disk.purgeable ?? 0, used)
                let free = total > used ? total - used : 0
                HStack(spacing: 22) {
                    StorageDonut(slices: [
                        StorageSlice(id: "used", label: "Used", bytes: used - purgeable, color: Theme.indigo),
                        StorageSlice(id: "purgeable", label: "Purgeable", bytes: purgeable, color: Theme.indigo.opacity(0.4)),
                        StorageSlice(id: "free", label: "Free", bytes: free, color: Theme.teal),
                    ]) {
                        VStack(spacing: 0) {
                            Text(verbatim: Formatting.bytes(free))
                                .font(.system(size: 19, weight: .bold, design: .rounded))
                            Text("free").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: largeGaugeSize, height: largeGaugeSize)
                    VStack(alignment: .leading, spacing: 12) {
                        CardLabel(title: "Storage", symbol: "internaldrive.fill")
                        LegendRow(color: Theme.indigo, label: "Used", value: Formatting.bytes(used - purgeable))
                        LegendRow(color: Theme.indigo.opacity(0.4), label: "Purgeable", value: Formatting.bytes(purgeable))
                        LegendRow(color: Theme.teal, label: "Free", value: Formatting.bytes(free))
                        Text("\(Formatting.bytes(total)) in total").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                CardLabel(title: "Storage", symbol: "internaldrive.fill")
                Text("Unavailable").foregroundStyle(.secondary)
            }
        }
    }
}

/// A small card: a caption, a large figure, and a chart or a line under it.
private struct MetricTile<Footer: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    let value: String
    var tint: Color = Theme.indigo
    @ViewBuilder let footer: Footer

    var body: some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 8) {
                CardLabel(title: title, symbol: symbol, tint: tint)
                Text(verbatim: value)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                footer
            }
        }
    }
}

private struct MemoryTile: View {
    let snapshot: StatusSnapshot
    let history: [Sample]

    var body: some View {
        let share = history.last.map { $0.value / 100 } ?? 0
        MetricTile(title: "Memory", symbol: "memorychip.fill", value: Formatting.percent(share * 100)) {
            Sparkline(samples: history, color: Theme.usageColor(share)).frame(height: 54)
            if let used = snapshot.memory?.used, let total = snapshot.memory?.total {
                Text("\(Formatting.bytes(used)) of \(Formatting.bytes(total))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ProcessorTile: View {
    let snapshot: StatusSnapshot
    let history: [Sample]

    var body: some View {
        let usage = snapshot.cpu?.usage ?? 0
        MetricTile(title: "Processor", symbol: "cpu.fill", value: Formatting.percent(usage), tint: Theme.teal) {
            Sparkline(samples: history, color: Theme.usageColor(usage / 100, tint: Theme.teal)).frame(height: 54)
            if let model = snapshot.hardware?.cpuModel {
                Text(verbatim: model).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct BatteryTile: View {
    let snapshot: StatusSnapshot

    var body: some View {
        if let battery = snapshot.batteries?.first, let percent = battery.percent {
            MetricTile(title: "Battery", symbol: battery.status == "charging" ? "battery.100.bolt" : "battery.75", value: Formatting.percent(percent), tint: Theme.teal) {
                HStack(spacing: 14) {
                    RingGauge(fraction: percent / 100, colors: [Theme.teal, Theme.indigo], lineWidth: 8) {
                        EmptyView()
                    }
                    .frame(width: 46, height: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        if let health = battery.health {
                            Text("Condition \(MoleTerms.localized(health, .battery))")
                        }
                        if let cycles = battery.cycleCount {
                            Text("\(cycles) cycles").foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
            }
        } else {
            MetricTile(title: "Trash", symbol: "trash.fill", value: Formatting.bytes(snapshot.trashSize ?? 0)) {
                Text("Emptied by Clean up").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// The one big action of the home screen.
private struct FreeSpaceCall: View {
    let action: () -> Void

    var body: some View {
        GlassCard {
            HStack(spacing: 20) {
                Image(systemName: "sparkles")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 60, height: 60)
                    .glassEffect(.regular.tint(Theme.indigo.opacity(0.15)), in: .circle)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Free up space").font(.title2.weight(.semibold))
                    Text("Supermole finds caches, leftovers and files you no longer need, and shows you everything before it removes anything.")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button(action: action) {
                    Label("Start", systemImage: "arrow.right")
                        .labelStyle(.titleAndIcon)
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
        }
    }
}

private struct BusiestApps: View {
    let snapshot: StatusSnapshot

    var body: some View {
        if let processes = snapshot.topProcesses, !processes.isEmpty {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    CardLabel(title: "Busiest apps", symbol: "flame.fill", tint: Theme.amber)
                    ForEach(processes.prefix(5)) { process in
                        let usage = process.cpu ?? 0
                        HStack(spacing: 12) {
                            Text(verbatim: process.name ?? "?").lineLimit(1)
                            Spacer()
                            Capsule()
                                .fill(usage / 100 > Theme.nearlyFullShare ? AnyShapeStyle(Theme.amber) : AnyShapeStyle(Theme.accent))
                                .frame(width: max(4, min(usage, 100) * 1.4), height: 8)
                            Text(verbatim: Formatting.percent(usage))
                                .monospacedDigit()
                                .frame(width: 52, alignment: .trailing)
                            Text(verbatim: Formatting.bytes(process.memoryBytes ?? 0))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 84, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }
}
