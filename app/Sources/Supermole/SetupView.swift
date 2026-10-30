import AppKit
import SwiftUI

/// First launch: looks for `mo`, and installs it when it is missing.
struct SetupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .shadow(color: Theme.purple.opacity(0.35), radius: 24, y: 8)
            Text("Welcome to Supermole")
                .font(.system(size: 34, weight: .bold, design: .rounded))

            switch model.phase {
            case .locating:
                ProgressView()
            case .missing:
                Text("Supermole needs its engine, the free Mole tool, to clean and analyze your Mac. It installs in a few seconds, for your account only, without an administrator password.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                installButton
            case .installing:
                ProgressView("Installing…")
                installLog
            case .failed(let message):
                ErrorBanner(message: message).frame(maxWidth: 560)
                installLog
                installButton
            case .ready:
                EmptyView()
            }
        }
        .padding(48)
        .glassEffect(.regular, in: .rect(cornerRadius: 34))
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var installButton: some View {
        Button {
            Task { await model.install() }
        } label: {
            Text("Install")
                .font(.title3.weight(.semibold))
                .frame(minWidth: 160)
                .padding(.vertical, 4)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
    }

    @ViewBuilder
    private var installLog: some View {
        if !model.installLog.isEmpty {
            ScrollView {
                Text(verbatim: model.installLog.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: 560, maxHeight: 170)
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: Theme.rowRadius))
        }
    }
}
