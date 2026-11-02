import SupermoleCore
import SwiftUI

/// The standard Settings window (⌘,).
struct SettingsView: View {
    private static let moleRepository = URL(string: "https://github.com/tw93/Mole")!

    @Environment(AppModel.self) private var model
    @State private var version: String?

    var body: some View {
        Form {
            Section("Engine") {
                LabeledContent("Mole") {
                    Text(verbatim: model.runner?.executable.path ?? String(localized: "Not installed"))
                        .textSelection(.enabled)
                }
                if let version {
                    LabeledContent("Version") { Text(verbatim: version) }
                }
            }
            FullDiskAccessSettingsSection()
            Section("About") {
                Text("Supermole is an unofficial fork of Mole, modified by Airkul. It is not affiliated with or endorsed by the Mole project.")
                    .foregroundStyle(.secondary)
                Link("Mole on GitHub", destination: Self.moleRepository)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .task {
            guard let runner = model.runner else { return }
            version = await Self.version(using: runner)
        }
    }

    /// The version `mo --version` reports, or why it could not be read.
    private static func version(using runner: MoleRunner) async -> String {
        do {
            return try await EngineVersion.read(from: runner).description
        } catch {
            return error.localizedDescription
        }
    }
}
