import SupermoleCore
import SwiftUI

/// The four spaces of the sidebar. History opens in the inspector and
/// Settings in the standard Settings window.
enum AppSpace: String, CaseIterable, Identifiable, Hashable {
    case home
    case clean
    case apps
    case disk

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .home: return "Home"
        case .clean: return "Clean up"
        case .apps: return "Apps"
        case .disk: return "Analyze"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "gauge.with.dots.needle.67percent"
        case .clean: return "sparkles"
        case .apps: return "square.grid.2x2"
        case .disk: return "chart.pie"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var space: AppSpace? = .home
    @State private var showsHistory = false
    // Kept for the window's life, so switching spaces never repeats a scan.
    @State private var home = HomeModel()
    @State private var disk = DiskModel()
    @State private var clean = CleanModel()
    @State private var apps = AppsModel()
    @State private var history = HistoryModel()

    var body: some View {
        if model.phase == .ready, let runner = model.runner {
            NavigationSplitView {
                List(AppSpace.allCases, selection: $space) { space in
                    Label(space.title, systemImage: space.symbol)
                        .tag(space)
                }
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
            } detail: {
                SpaceView(space: space ?? .home, runner: runner, home: home, clean: clean, apps: apps, disk: disk) { space = $0 }
                    .id(space)
                    .transition(.opacity.combined(with: .offset(y: 12)))
                    .animation(Motion.space, value: space)
                    .background(AmbientBackground())
                    .inspector(isPresented: $showsHistory) {
                        HistoryPanel(runner: runner, model: history)
                            .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
                    }
                    .toolbar(removing: .title)
                    .toolbar {
                        ToolbarSpacer(.flexible)
                        ToolbarItemGroup(placement: .primaryAction) {
                            Button {
                                showsHistory.toggle()
                            } label: {
                                Label("History", systemImage: "clock.arrow.circlepath")
                            }
                            .help("History")
                            SettingsLink {
                                Label("Settings", systemImage: "gearshape")
                            }
                            .help("Settings")
                        }
                    }
            }
        } else {
            SetupView()
                .background(AmbientBackground())
        }
    }
}

private struct SpaceView: View {
    let space: AppSpace
    let runner: MoleRunner
    let home: HomeModel
    let clean: CleanModel
    let apps: AppsModel
    let disk: DiskModel
    let navigate: (AppSpace) -> Void

    var body: some View {
        switch space {
        case .home:
            HomeView(runner: runner, model: home, navigate: navigate)
        case .disk:
            DiskView(runner: runner, model: disk)
        case .clean:
            CleanView(runner: runner, model: clean)
        case .apps:
            AppsView(runner: runner, model: apps)
        }
    }
}

/// Stands in for a space while it is being built; never ships in a release.
private struct UpcomingView: View {
    let space: AppSpace
    let summary: LocalizedStringKey

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: space.symbol)
                .font(.system(size: 52, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 110, height: 110)
                .glassEffect(.regular.tint(Theme.indigo.opacity(0.15)), in: .circle)
            Text(space.title)
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text(summary)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Text("Coming soon")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
        }
        .padding(Theme.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
