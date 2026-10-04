import Foundation
import IOKit.pwr_mgt
import AppKit

/// What to do once every download has finished.
enum WhenDoneAction: String, CaseIterable, Identifiable {
    case nothing, quit, sleep, shutDown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nothing: "Do Nothing"
        case .quit: "Quit Drift"
        case .sleep: "Sleep"
        case .shutDown: "Shut Down"
        }
    }

    var symbol: String {
        switch self {
        case .nothing: "minus.circle"
        case .quit: "xmark.circle"
        case .sleep: "moon"
        case .shutDown: "power"
        }
    }
}

/// System power helpers: keeping the Mac awake, and sleeping or shutting it down.
@MainActor
enum Power {
    private static var assertion: IOPMAssertionID = 0
    private static var holding = false

    /// Prevents idle sleep while `awake` is true. The display may still turn off.
    static func keepAwake(_ awake: Bool) {
        if awake, !holding {
            holding = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                  IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                  "Drift is downloading" as CFString, &assertion) == kIOReturnSuccess
        } else if !awake, holding {
            IOPMAssertionRelease(assertion)
            holding = false
        }
    }

    static func perform(_ action: WhenDoneAction) {
        switch action {
        case .nothing:
            break
        case .quit:
            NSApp.terminate(nil)
        case .sleep:
            let task = Process()
            task.executableURL = URL(filePath: "/usr/bin/pmset")
            task.arguments = ["sleepnow"]
            try? task.run()
        case .shutDown:
            // Asks System Events, which shows the normal shut-down flow (apps get to save their work).
            NSAppleScript(source: "tell application \"System Events\" to shut down")?.executeAndReturnError(nil)
        }
    }
}

/// Quick speed presets (FDM's traffic modes), shared by the header menu and the app menu.
enum SpeedMode: String, CaseIterable, Identifiable {
    case full, high, medium, low, custom

    var id: String { rawValue }
    static var presets: [SpeedMode] { [.full, .high, .medium, .low] }
    static var allCases: [SpeedMode] { presets }

    var kb: Int? {
        switch self {
        case .full, .custom: nil
        case .high: 10_000
        case .medium: 2_000
        case .low: 512
        }
    }

    var title: String {
        switch self {
        case .full: "Full Speed"
        case .high: "High · 10 MB/s"
        case .medium: "Medium · 2 MB/s"
        case .low: "Low · 512 KB/s"
        case .custom: "Custom"
        }
    }

    @MainActor static func current(_ settings: AppSettings) -> SpeedMode {
        guard settings.speedLimitEnabled else { return .full }
        return presets.first { $0.kb == settings.speedLimitKB } ?? .custom
    }

    @MainActor func apply(to settings: AppSettings) {
        if let kb {
            settings.speedLimitKB = kb
            settings.speedLimitEnabled = true
        } else if self == .full {
            settings.speedLimitEnabled = false
        }
    }
}
