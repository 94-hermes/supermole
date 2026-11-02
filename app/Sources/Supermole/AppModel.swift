import Foundation
import Observation
import SupermoleCore

/// Whether the app has a `mo` to drive, and installing one when it has none
/// or only ones older than itself; then whether macOS lets it see the whole Mac.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case locating
        case missing
        case installing
        /// Every `mo` found is older than the app, so a copy for this account
        /// is being installed.
        case updatingEngine
        /// `mo` is there, but macOS hides part of the Mac from it.
        case needsFullDiskAccess
        case ready
        case failed(String)
    }

    /// Remembers "Continue without", so the access is asked for once. Seeing
    /// the access granted forgets it: losing the access again, as an update of
    /// the ad hoc signed app does, brings the step back.
    static let fullDiskAccessDeclinedKey = "FullDiskAccessDeclined"

    /// The oldest `mo` the app can drive: the app's own release, which the
    /// dmg build takes from `mo`'s VERSION. Nil outside a built app bundle.
    static let requiredEngine = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        .flatMap { EngineVersion($0) }

    private(set) var phase: Phase = .locating
    private(set) var installLog: [String] = []
    private(set) var runner: MoleRunner?
    private(set) var fullDiskAccess: FullDiskAccess.Status = .unknown

    func locate() async {
        await settle(afterInstall: false)
    }

    /// The Install button, and Try again after a failure.
    func install() async {
        phase = .installing
        await runInstaller()
    }

    private func runInstaller() async {
        installLog = []
        do {
            for try await line in MoleInstaller().install() {
                let text = TerminalText.clean(line)
                if !text.isEmpty { installLog.append(text) }
            }
            await settle(afterInstall: true)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Picks the `mo` to drive. Right after an install, finding none, or only
    /// older ones, is a failure to show rather than a reason to install again.
    private func settle(afterInstall: Bool) async {
        let choice = await MoleLocator().choose(minimum: Self.requiredEngine) { executable in
            try await EngineVersion.read(from: MoleRunner(executable: executable))
        }
        switch choice {
        case .found(let executable):
            runner = MoleRunner(executable: executable)
            readFullDiskAccess()
            let declined = UserDefaults.standard.bool(forKey: Self.fullDiskAccessDeclinedKey)
            phase = fullDiskAccess == .denied && !declined ? .needsFullDiskAccess : .ready
        case .missing:
            runner = nil
            phase = afterInstall
                ? .failed(String(localized: "The installer finished, but mo is still missing."))
                : .missing
        case .outdated(_, let version):
            runner = nil
            if afterInstall {
                phase = .failed(Self.outdatedMessage(installed: version))
            } else {
                phase = .updatingEngine
                await runInstaller()
            }
        }
    }

    private static func outdatedMessage(installed: EngineVersion?) -> String {
        guard let installed, let required = requiredEngine else {
            return String(localized: "The engine just installed did not report a version this app can use.")
        }
        return String(localized: "The newest published engine (\(installed.description)) is older than this app (\(required.description)). Try again later.")
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
