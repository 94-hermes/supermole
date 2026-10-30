import AppKit
import SwiftUI

@main
struct SupermoleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    private static let minimumSize = CGSize(width: 900, height: 640)
    private static let defaultSize = CGSize(width: 1240, height: 860)

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
                .tint(Theme.purple)
                .task { model.locate() }
        }
        .defaultSize(Self.defaultSize)
        .windowToolbarStyle(.unified)
        .commands {
            // One window holds everything; a second one would run mo twice.
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environment(model)
                .tint(Theme.purple)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
