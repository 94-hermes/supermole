import Observation
import SupermoleCore
import SwiftUI

/// The installed apps, a preview of what uninstalling the ticked ones
/// removes, then the uninstall itself, all run by `mo uninstall`.
@MainActor
@Observable
final class UninstallModel {
    enum Phase: Equatable {
        case loading
        case list
        case planning
        case plan
        case uninstalling
        case done
        case failed(String)
    }

    /// An app `mo` sees for the first time has no size until its background
    /// measurement ends; one more listing after this pause fills it in.
    static let sizeRefreshDelay: Duration = .seconds(8)

    private(set) var phase: Phase = .loading
    private(set) var apps: [InstalledApp] = []
    /// Ticked apps, by bundle path.
    var selection: Set<String> = []
    var query = ""
    var order: InstalledApps.Order = .size
    private(set) var withData = false
    /// What uninstalling runs: the ticked apps that need no administrator.
    private(set) var plan: UninstallPlan?
    /// Ticked apps left out of the plan, each with its reason.
    private(set) var adminApps: [UninstallPlan.App] = []
    private(set) var blockedApps: [UninstallPlan.Blocked] = []
    private(set) var manualApps: [UninstallPlan.Manual] = []
    private(set) var log = RunLog()
    private(set) var result: HistoryReport.Session?
    /// Planned apps still installed after the run.
    private(set) var notRemoved: [String] = []
    private(set) var runCompleted = true
    private var task: Task<Void, Never>?
    private var hasLoaded = false

    var isBusy: Bool { phase == .planning || phase == .uninstalling }
    var shownApps: [InstalledApp] { InstalledApps.arranged(apps, matching: query, by: order) }
    var selectedApps: [InstalledApp] { apps.filter { selection.contains($0.path) } }
    var selectedBytes: Int64 { selectedApps.reduce(0) { $0 + ($1.bytes ?? 0) } }

    func loadIfNeeded(using runner: MoleRunner) {
        guard !hasLoaded else { return }
        hasLoaded = true
        load(using: runner)
    }

    func load(using runner: MoleRunner) {
        task?.cancel()
        phase = .loading
        task = Task {
            do {
                try await list(using: runner)
                if InstalledApps.lacksSizes(apps) {
                    try await Task.sleep(for: Self.sizeRefreshDelay)
                    try await list(using: runner)
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

    /// Lists the apps again; a ticked app that is gone is unticked.
    private func list(using runner: MoleRunner) async throws {
        let apps = try await runner.decode([InstalledApp].self, InstalledApp.arguments)
        try Task.checkCancellation()
        withAnimation(Motion.entrance) {
            self.apps = apps
            selection.formIntersection(apps.map(\.path))
            if phase == .loading { phase = .list }
        }
    }

    func setWithData(_ value: Bool, using runner: MoleRunner) {
        withData = value
        review(using: runner)
    }

    /// Previews the ticked apps. Apps that need an administrator are set
    /// aside and the rest previewed again on their own, so the plan shown is
    /// exactly what the uninstall runs.
    func review(using runner: MoleRunner) {
        let paths = selectedApps.map(\.path)
        guard !paths.isEmpty else { return }
        task?.cancel()
        phase = .planning
        let withData = withData
        task = Task {
            do {
                let first = try await runner.decodeReport(UninstallPlan.self, UninstallPlan.arguments(paths: paths, withData: withData))
                var plan = first
                if !first.appsNeedingAdmin.isEmpty, !first.appsWithoutAdmin.isEmpty {
                    plan = try await runner.decodeReport(
                        UninstallPlan.self,
                        UninstallPlan.arguments(paths: first.appsWithoutAdmin.map(\.path), withData: withData)
                    )
                }
                try Task.checkCancellation()
                withAnimation(Motion.entrance) {
                    adminApps = first.appsNeedingAdmin
                    blockedApps = first.blocked
                    manualApps = first.manual
                    self.plan = plan
                    phase = .plan
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

    func uninstall(using runner: MoleRunner) {
        guard let plan else { return }
        let planned = plan.appsWithoutAdmin
        guard !planned.isEmpty else { return }
        task?.cancel()
        phase = .uninstalling
        log = RunLog()
        result = nil
        notRemoved = []
        let arguments = UninstallPlan.uninstallArguments(paths: planned.map(\.path), withData: withData)
        task = Task {
            var exitedCleanly = true
            do {
                for try await line in runner.lines(arguments, includeErrors: true) {
                    log.append(line)
                }
            } catch MoleError.failed {
                // An app `mo` could not remove ends the run with a nonzero
                // status; the disk and the history say what went.
                exitedCleanly = false
            } catch {
                phase = .failed(error.localizedDescription)
                return
            }
            notRemoved = planned.filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.name)
            runCompleted = exitedCleanly && notRemoved.isEmpty
            selection.subtract(planned.map(\.path))
            do {
                let history = try await runner.decode(HistoryReport.self, HistoryReport.arguments(limit: 1))
                result = history.sessions?.first { $0.command == "uninstall" }
            } catch {
                log.append(error.localizedDescription)
            }
            withAnimation(Motion.entrance) { phase = .done }
            do {
                try await list(using: runner)
            } catch {
                log.append(error.localizedDescription)
            }
        }
    }

    func backToList() {
        task?.cancel()
        plan = nil
        withAnimation(Motion.entrance) { phase = apps.isEmpty ? .loading : .list }
    }
}

struct UninstallSection: View {
    let runner: MoleRunner
    @Bindable var model: UninstallModel

    @State private var confirmsUninstall = false

    /// Cards after this one enter together, so a long plan does not trickle in.
    private static let lastStaggeredCard = 8

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            switch model.phase {
            case .loading:
                LoadingCard(message: "Listing your apps…").entrance(2)
            case .list:
                AppListCard(model: model) { model.review(using: runner) }
                    .entrance(2)
            case .planning:
                WorkingCard(title: "Checking what each app leaves behind…", detail: "Nothing is removed. This takes a few seconds per app.")
                    .entrance(2)
            case .plan:
                if let plan = model.plan {
                    planContent(plan)
                }
            case .uninstalling:
                WorkingCard(title: "Uninstalling…", detail: "The apps and their files go to the Trash.")
                    .entrance(2)
            case .done:
                RunResultCard(
                    result: model.result,
                    completed: model.runCompleted,
                    nothingFreed: "The apps were removed.",
                    stoppedEarly: "Some apps were not removed.",
                    actionTitle: "Back to apps",
                    actionSymbol: "square.grid.2x2",
                    action: model.backToList,
                    warnings: model.notRemoved.map { String(localized: "\($0) is still installed.") }
                )
                .entrance(2)
            case .failed(let message):
                ErrorBanner(message: message)
                Button {
                    if model.apps.isEmpty {
                        model.load(using: runner)
                    } else {
                        model.backToList()
                    }
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)
            }
            if !model.log.isEmpty, model.phase == .uninstalling || model.phase == .done {
                LogCard(lines: model.log.lines).entrance(3)
            }
        }
        .onAppear { model.loadIfNeeded(using: runner) }
        .alert("Uninstall these apps?", isPresented: $confirmsUninstall) {
            Button("Uninstall apps", role: .destructive) { model.uninstall(using: runner) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: confirmationMessage)
        }
    }

    @ViewBuilder
    private func planContent(_ plan: UninstallPlan) -> some View {
        PlanSummaryCard(
            plan: plan,
            withData: Binding(get: { model.withData }, set: { model.setWithData($0, using: runner) }),
            back: model.backToList
        ) {
            confirmsUninstall = true
        }
        .entrance(2)
        if !model.adminApps.isEmpty || !model.blockedApps.isEmpty || !model.manualApps.isEmpty {
            LeftOutCard(admin: model.adminApps, blocked: model.blockedApps, manual: model.manualApps)
                .entrance(3)
        }
        ForEach(Array(plan.appsWithoutAdmin.enumerated()), id: \.element.id) { index, app in
            PlannedAppCard(app: app).entrance(min(4 + index, Self.lastStaggeredCard))
        }
    }

    private var confirmationMessage: String {
        let names = model.plan?.appsWithoutAdmin.map(\.name) ?? []
        let list = ListFormatter.localizedString(byJoining: names)
        var message = String(localized: "Going to the Trash with the files listed: \(list). Open apps are quit first.")
        if model.withData {
            message += " " + String(localized: "The personal data listed goes too.")
        }
        return message
    }
}

/// The installed apps, searchable and sortable, with a box to tick on each.
private struct AppListCard: View {
    @Bindable var model: UninstallModel
    let review: () -> Void

    var body: some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        if model.selection.isEmpty {
                            Text("Tick the apps to remove").font(.headline)
                            Text("Supermole shows what goes before anything is removed.")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(model.selection.count) selected")
                                .font(.headline)
                                .contentTransition(.numericText())
                            Text(verbatim: Formatting.bytes(model.selectedBytes))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        }
                    }
                    Spacer()
                    Button(action: review) {
                        Label("See what goes", systemImage: "list.bullet.rectangle")
                            .font(.body.weight(.semibold))
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(model.selection.isEmpty)
                }
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search apps", text: $model.query)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                    Picker("Sort by", selection: $model.order) {
                        Text("Size").tag(InstalledApps.Order.size)
                        Text("Name").tag(InstalledApps.Order.name)
                        Text("Last used").tag(InstalledApps.Order.lastUsed)
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                let shown = model.shownApps
                if shown.isEmpty {
                    Text("No app matches.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(shown) { app in
                            SelectableAppRow(name: app.name, path: app.path, bytes: app.bytes, isSelected: $model.selection.contains(app.path)) {
                                HStack(spacing: 8) {
                                    if app.isHomebrew {
                                        Pill(text: "Homebrew", color: Theme.amber)
                                    }
                                    if let lastUsed = app.lastUsed {
                                        Text("Used \(lastUsed, format: .relative(presentation: .named))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct PlanSummaryCard: View {
    let plan: UninstallPlan
    @Binding var withData: Bool
    let back: () -> Void
    let uninstall: () -> Void

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        CardLabel(title: "Uninstalling frees", symbol: "trash", tint: Theme.teal)
                        Text(verbatim: Formatting.bytes(plan.totalBytes))
                            .font(.system(size: 46, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.accent)
                            .contentTransition(.numericText())
                        Text("Everything listed below goes to the Trash.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: back) {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.glass)
                    Button(action: uninstall) {
                        Label("Uninstall apps", systemImage: "trash")
                            .font(.title3.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.rose)
                    .controlSize(.large)
                    .disabled(plan.appsWithoutAdmin.isEmpty)
                }
                Toggle(isOn: $withData) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Also remove my data in these apps")
                        Text("Settings, documents and saved states. Browser profiles and shared folders stay.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
        }
    }
}

/// Ticked apps the uninstall leaves alone, and why.
private struct LeftOutCard: View {
    let admin: [UninstallPlan.App]
    let blocked: [UninstallPlan.Blocked]
    let manual: [UninstallPlan.Manual]

    var body: some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                CardLabel(title: "Left alone", symbol: "hand.raised", tint: Theme.amber)
                if !admin.isEmpty {
                    Label {
                        Text("Needs your administrator password: \(ListFormatter.localizedString(byJoining: admin.map(\.name))). Supermole will ask for it in a coming version.")
                    } icon: {
                        Image(systemName: "lock")
                    }
                }
                ForEach(blocked) { app in
                    Label {
                        Text("\(app.name) needs its own uninstaller from \(app.vendor).")
                    } icon: {
                        Image(systemName: "shippingbox")
                    }
                }
                ForEach(manual) { app in
                    Label {
                        Text("Move \(app.name) to the Trash in the Finder; Supermole does not move it from where it is.")
                    } icon: {
                        Image(systemName: "folder")
                    }
                }
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One app of the plan: what goes, and what stays.
private struct PlannedAppCard: View {
    let app: UninstallPlan.App

    var body: some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    AppIcon(path: app.path, size: 36)
                    Text(verbatim: app.name).font(.title3.weight(.semibold))
                    Spacer()
                    Text(verbatim: Formatting.bytes(app.bytes))
                        .monospacedDigit()
                        .fontWeight(.semibold)
                }
                if app.running {
                    Label("Open now: Supermole quits it first.", systemImage: "exclamationmark.circle")
                        .foregroundStyle(Theme.amber)
                }
                ForEach(app.notes, id: \.self) { note in
                    Label {
                        Text(verbatim: note)
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .foregroundStyle(.secondary)
                }
                PathLine(path: app.path, note: PathLine.sizeNote(app.sizeKb.map { $0 * 1024 }))
                ForEach(app.leftovers + app.system) { row in
                    PathLine(path: row.path, note: PathLine.sizeNote(row.sizeKb.map { $0 * 1024 }))
                }
                if !app.personalData.remove.isEmpty || !app.personalData.keep.isEmpty {
                    Text("Your data").font(.callout.weight(.semibold)).padding(.top, 4)
                    ForEach(app.personalData.remove) { row in
                        PathLine(path: row.path, note: PathLine.sizeNote(row.sizeKb.map { $0 * 1024 }))
                    }
                    ForEach(app.personalData.keep) { row in
                        PathLine(path: row.path, note: String(localized: "kept"), dimmed: true)
                    }
                }
                if !app.reviewOnly.isEmpty {
                    Text("System files to check yourself").font(.callout.weight(.semibold)).padding(.top, 4)
                    ForEach(app.reviewOnly) { row in
                        PathLine(path: row.path, note: String(localized: "left in place"), dimmed: true)
                    }
                }
            }
        }
    }
}
