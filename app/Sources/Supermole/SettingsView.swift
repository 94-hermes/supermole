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

    /// The first line `mo --version` prints, which names the version.
    private static func version(using runner: MoleRunner) async -> String {
        do {
            let output = try await runner.run(["--version"])
            let text = String(decoding: output.stdout, as: UTF8.self)
            return text.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { String($0) } ?? text
        } catch {
            return error.localizedDescription
        }
    }
}
