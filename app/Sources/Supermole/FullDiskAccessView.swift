import AppKit
import SupermoleCore
import SwiftUI

/// The first-launch step that asks for Full Disk Access. It checks again each
/// time the app comes back to the front, so returning from System Settings
/// moves on by itself.
struct FullDiskAccessStep: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 20) {
            Label("Full Disk Access", systemImage: "lock.shield")
                .font(.title2.weight(.semibold))
            Text("To see your whole Mac, Supermole needs Full Disk Access. Without it, Mail, Messages, Safari and some caches stay hidden. Nothing leaves your Mac.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            VStack(alignment: .leading, spacing: 10) {
                Label("Open System Settings with the button below.", systemImage: "1.circle")
                Label("Turn on Supermole in the list. Not there? Click +, then choose Supermole in Applications.", systemImage: "2.circle")
                Label("If macOS offers to quit and reopen Supermole, accept.", systemImage: "3.circle")
            }
            .frame(maxWidth: 520, alignment: .leading)
            VStack(spacing: 12) {
                Button {
                    openURL(FullDiskAccess.settingsURL)
                } label: {
                    Text("Open System Settings")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                // Skipping is offered, not suggested: a plain link under the button.
                Button("Continue without") {
                    model.continueWithoutFullDiskAccess()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.recheckFullDiskAccess()
        }
    }
}

/// The state of the access, with the way to grant it, for the Settings window.
struct FullDiskAccessSettingsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section("Permissions") {
            LabeledContent("Full Disk Access") {
                switch model.fullDiskAccess {
                case .granted:
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.teal)
                case .denied:
                    Label("Not granted", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(Theme.amber)
                case .unknown:
                    Label("Could not be checked", systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
            if model.fullDiskAccess != .granted {
                Button("Open System Settings") {
                    openURL(FullDiskAccess.settingsURL)
                }
            }
        }
        .onAppear { model.recheckFullDiskAccess() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.recheckFullDiskAccess()
        }
    }
}
