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
