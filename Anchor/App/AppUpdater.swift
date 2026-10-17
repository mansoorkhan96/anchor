import Foundation
import Observation
import Sparkle

/// Checks GitHub for a newer Anchor and installs it, through Sparkle. The feed is the newest release's appcast.xml,
/// whose download is checked against the EdDSA public key in Info.plist (`SUPublicEDKey`).
@MainActor @Observable
final class AppUpdater {
    static let shared = AppUpdater()

    @ObservationIgnored private let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil,
                                                                              userDriverDelegate: nil)
    @ObservationIgnored private var observation: NSKeyValueObservation?
    /// False until the updater has started, and while a check is already running.
    private(set) var canCheck = false
    /// Check once a day in the background.
    var automaticallyChecks = false {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }

    private init() {}

    /// Starts the updater, which then checks on its own schedule. Called once at launch.
    func start() {
        // Debug builds share the version of the release they come from: don't offer them updates.
        #if !DEBUG
        controller.startUpdater()
        #endif
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { updater, _ in
            let can = updater.canCheckForUpdates
            Task { @MainActor in AppUpdater.shared.canCheck = can }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
