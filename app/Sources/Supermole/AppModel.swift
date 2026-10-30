import Foundation
import Observation
import SupermoleCore

/// Whether the app has a `mo` to drive, and installing one when it does not.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case locating
        case missing
        case installing
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .locating
    private(set) var installLog: [String] = []
    private(set) var runner: MoleRunner?

    func locate() {
        if let executable = MoleLocator().locate() {
            runner = MoleRunner(executable: executable)
            phase = .ready
        } else {
            runner = nil
            phase = .missing
        }
    }

    func install() async {
        phase = .installing
        installLog = []
        do {
            for try await line in MoleInstaller().install() {
                let text = TerminalText.clean(line)
                if !text.isEmpty { installLog.append(text) }
            }
            locate()
            if phase != .ready {
                phase = .failed(String(localized: "The installer finished, but mo is still missing."))
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
