import TailscodeCore
import UIKit

/// What the device says about its power, in the words the wall's frame cap and keep-awake read.
@MainActor
enum WatchPower {
    static let lowBattery: Float = 0.2

    static func thermal(_ state: ProcessInfo.ThermalState) -> WallCadence.Thermal {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .serious
        }
    }

    static var isCharging: Bool {
        let state = UIDevice.current.batteryState
        return state == .charging || state == .full
    }

    /// Whether the battery is so low the screen should be left to sleep: below a fifth and not on
    /// power. A device that cannot say (the simulator) is never low.
    static var isLow: Bool {
        let level = UIDevice.current.batteryLevel
        return level >= 0 && level < lowBattery && !isCharging
    }

    /// Whether the style wants the screen kept on right now, and whether a low battery is the only
    /// thing that says no.
    static func keepsAwake(_ keep: WallStyle.KeepAwake) -> (awake: Bool, heldByBattery: Bool) {
        let wanted: Bool
        switch keep {
        case .always: wanted = true
        case .whileCharging: wanted = isCharging
        case .never: wanted = false
        }
        guard wanted else { return (false, false) }
        return isLow ? (false, true) : (true, false)
    }
}

/// The one place the idle timer is touched: it is off while at least one wall in a foreground scene
/// asks for the screen to stay on, and back on when the last one lets go. Walls in several scenes
/// count, so closing one never puts the screen to sleep under another.
@MainActor
enum WatchAwake {
    private static var wanting: Set<ObjectIdentifier> = []
    private static var watching = 0
    private static var batteryWasOn = false

    static func set(_ wall: AnyObject, wants: Bool) {
        if wants {
            wanting.insert(ObjectIdentifier(wall))
        } else {
            wanting.remove(ObjectIdentifier(wall))
        }
        UIApplication.shared.isIdleTimerDisabled = !wanting.isEmpty
    }

    static func drop(_ id: ObjectIdentifier) {
        wanting.remove(id)
        UIApplication.shared.isIdleTimerDisabled = !wanting.isEmpty
    }

    static func beginWatchingBattery() {
        if watching == 0 {
            batteryWasOn = UIDevice.current.isBatteryMonitoringEnabled
            UIDevice.current.isBatteryMonitoringEnabled = true
        }
        watching += 1
    }

    static func endWatchingBattery() {
        guard watching > 0 else { return }
        watching -= 1
        if watching == 0 { UIDevice.current.isBatteryMonitoringEnabled = batteryWasOn }
    }
}
