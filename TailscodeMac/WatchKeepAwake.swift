import Foundation
import IOKit.pwr_mgt
import IOKit.ps
import TailscodeCore

/// The one power assertion the wall holds: the display does not go to sleep while the wall is on
/// screen and the style allows it, and it is let go the moment the wall leaves, the window closes or
/// the style no longer allows it. Never held for a wall nobody can see.
@MainActor
final class WatchKeepAwake {
    private var assertion = IOPMAssertionID(0)
    private(set) var isHeld = false

    isolated deinit {
        if isHeld { IOPMAssertionRelease(assertion) }
    }

    /// Whether this Mac is running on mains power; a Mac with no battery always is.
    static func onMains() -> Bool {
        guard let kind = IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() else { return true }
        return (kind as String) == "AC Power"
    }

    static func allows(_ style: WallStyle, onMains: Bool = WatchKeepAwake.onMains()) -> Bool {
        switch style.keepAwake {
        case .always: return true
        case .whileCharging: return onMains
        case .never: return false
        }
    }

    func hold(_ wanted: Bool) {
        if wanted, !isHeld {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                "PreventUserIdleDisplaySleep" as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                Localized.text("The Agents wall is on screen") as CFString, &id)
            guard result == kIOReturnSuccess else { return }
            assertion = id
            isHeld = true
        } else if !wanted, isHeld {
            IOPMAssertionRelease(assertion)
            assertion = IOPMAssertionID(0)
            isHeld = false
        }
    }
}
