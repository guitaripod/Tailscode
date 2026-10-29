import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The wall's one notion of time. Everything that waits on a duration (the peek's way back, the
/// dim, the hold) reads it, so a check moves it forward instead of sleeping.
final class WatchClock: @unchecked Sendable {
    private(set) var skew: TimeInterval = 0

    var now: Date { Date().addingTimeInterval(skew) }

    var seconds: Double { Double(g_get_monotonic_time()) / 1_000_000 + skew }

    func advance(by seconds: TimeInterval) { skew += seconds }
}

/// The compositor's idle inhibit, behind a seam so a check can count what was asked.
protocol WatchInhibiting: AnyObject {
    func acquire(reason: String) -> UInt32
    func release(_ cookie: UInt32)
}

final class GtkInhibitor: WatchInhibiting {
    func acquire(reason: String) -> UInt32 {
        guard let application = g_application_get_default() else { return 0 }
        return gtk_application_inhibit(
            ptr(UnsafeMutableRawPointer(application)), nil, GTK_APPLICATION_INHIBIT_IDLE, reason)
    }

    func release(_ cookie: UInt32) {
        guard cookie != 0, let application = g_application_get_default() else { return }
        gtk_application_uninhibit(ptr(UnsafeMutableRawPointer(application)), cookie)
    }
}

/// A press that only counts once it has been held: a tap is a question ("hold to approve"), an
/// early release cancels, and the full hold fires once however long it is kept after.
struct HoldGauge: Equatable {
    enum Release: Equatable {
        case none
        case tap
        case cancelled
        case after
    }

    static let duration: TimeInterval = 0.8
    static let tapWithin: TimeInterval = 0.35

    private(set) var startedAt: Date?
    private(set) var fired = false

    var isHolding: Bool { startedAt != nil }

    mutating func begin(at now: Date) {
        guard startedAt == nil else { return }
        startedAt = now
        fired = false
    }

    func progress(at now: Date) -> Double {
        guard let startedAt else { return 0 }
        return fired ? 1 : min(1, max(0, now.timeIntervalSince(startedAt) / Self.duration))
    }

    mutating func advance(to now: Date) -> Bool {
        guard let startedAt, !fired, now.timeIntervalSince(startedAt) >= Self.duration else {
            return false
        }
        fired = true
        return true
    }

    mutating func release(at now: Date) -> Release {
        guard let startedAt else { return .none }
        let held = now.timeIntervalSince(startedAt)
        let was = fired
        self.startedAt = nil
        fired = false
        if was { return .after }
        return held < Self.tapWithin ? .tap : .cancelled
    }
}

/// How bright the wall is: full, dimmed by hand, or dimmed because nothing has happened for as
/// long as the style asks (ten minutes unless it says otherwise). An event of any kind brings it
/// back, and the amount eases there.
struct WatchDim {
    static let defaultCalmFor: TimeInterval = 600
    static let level = 0.6
    static let easeOut: TimeInterval = 4
    static let easeBack: TimeInterval = 1

    /// How long a calm wall waits before it dims by itself; nil never dims it, though a hand still can.
    var calmFor: TimeInterval? = Self.defaultCalmFor
    private(set) var calmSince: Date?
    private(set) var manual = false
    private(set) var amount = 0.0
    private var quiet = false

    func isDimmed(at now: Date) -> Bool {
        guard !quiet else { return false }
        if manual { return true }
        guard let calmSince, let calmFor else { return false }
        return now.timeIntervalSince(calmSince) >= calmFor
    }

    var scrim: Double { amount * Self.level }

    mutating func observe(_ mood: WallMood, at now: Date) {
        if mood == .calm {
            if calmSince == nil { calmSince = now }
            quiet = false
        } else {
            calmSince = nil
            quiet = true
            manual = false
        }
    }

    mutating func wake(at now: Date) {
        if calmSince != nil { calmSince = now }
    }

    mutating func toggle(at now: Date) {
        if isDimmed(at: now) {
            manual = false
            calmSince = quiet ? nil : now
        } else if !quiet {
            manual = true
        }
    }

    @discardableResult
    mutating func step(dt: TimeInterval, at now: Date, animated: Bool) -> Bool {
        let target = isDimmed(at: now) ? 1.0 : 0.0
        guard amount != target else { return false }
        guard animated else {
            amount = target
            return true
        }
        let rate = dt / (target > amount ? Self.easeOut : Self.easeBack)
        amount = target > amount ? min(target, amount + rate) : max(target, amount - rate)
        return true
    }
}
