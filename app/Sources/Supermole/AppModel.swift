import Foundation
import Observation
import SupermoleCore

/// Whether the app has a `mo` to drive, and installing one when it does not;
/// then whether macOS lets it see the whole Mac.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case locating
        case missing
        case installing
        /// `mo` is there, but macOS hides part of the Mac from it.
        case needsFullDiskAccess
        case ready
        case failed(String)
    }

    /// Remembers "Continue without", so the access is asked for once. Seeing
    /// the access granted forgets it: losing the access again, as an update of
    /// the ad hoc signed app does, brings the step back.
    static let fullDiskAccessDeclinedKey = "FullDiskAccessDeclined"

    private(set) var phase: Phase = .locating
    private(set) var installLog: [String] = []
    private(set) var runner: MoleRunner?
    private(set) var fullDiskAccess: FullDiskAccess.Status = .unknown

    func locate() {
        if let executable = MoleLocator().locate() {
            runner = MoleRunner(executable: executable)
            readFullDiskAccess()
            let declined = UserDefaults.standard.bool(forKey: Self.fullDiskAccessDeclinedKey)
            phase = fullDiskAccess == .denied && !declined ? .needsFullDiskAccess : .ready
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
            if runner == nil {
                phase = .failed(String(localized: "The installer finished, but mo is still missing."))
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Reads the access again, and leaves the step once macOS grants it.
    func recheckFullDiskAccess() {
        readFullDiskAccess()
        if phase == .needsFullDiskAccess, fullDiskAccess != .denied {
            phase = .ready
        }
    }

    func continueWithoutFullDiskAccess() {
        UserDefaults.standard.set(true, forKey: Self.fullDiskAccessDeclinedKey)
        phase = .ready
    }

    private func readFullDiskAccess() {
        fullDiskAccess = FullDiskAccess.status()
        if fullDiskAccess == .granted {
            UserDefaults.standard.removeObject(forKey: Self.fullDiskAccessDeclinedKey)
        }
    }
}
