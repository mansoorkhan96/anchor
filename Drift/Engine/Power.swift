import Foundation
import IOKit.pwr_mgt
import AppKit

/// System power helpers: keeping the Mac awake.
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
