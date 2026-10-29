import Foundation
import TailscodeCore

/// How bright the wall is: full, dimmed by hand, or dimmed because nothing has run for as long as the
/// style says. An event of any kind brings it back, and the amount eases there, slowly down and
/// quickly up. A wall with something running is never dimmed, by hand or by the clock.
struct WatchDimmer {
    static let easeOut: TimeInterval = 4
    static let easeBack: TimeInterval = 1

    private(set) var calmSince: Date?
    private(set) var manual = false
    private(set) var amount = 0.0
    private var busy = false

    func isDimmed(at now: Date, after: TimeInterval?) -> Bool {
        guard !busy else { return false }
        if manual { return true }
        guard let after, let calmSince else { return false }
        return now.timeIntervalSince(calmSince) >= after
    }

    mutating func observe(_ mood: WallMood, at now: Date) {
        if mood == .calm {
            if calmSince == nil { calmSince = now }
            busy = false
        } else {
            calmSince = nil
            busy = true
            manual = false
        }
    }

    /// A key, the pointer moving or something happening: the calm starts again from now. An event
    /// also lets go of a dim the person asked for; the pointer does not.
    mutating func wake(at now: Date, clearingManual: Bool = false) {
        if calmSince != nil { calmSince = now }
        if clearingManual { manual = false }
    }

    mutating func toggle(at now: Date, after: TimeInterval?) {
        if isDimmed(at: now, after: after) {
            manual = false
            calmSince = busy ? nil : now
        } else if !busy {
            manual = true
        }
    }

    @discardableResult
    mutating func step(dt: TimeInterval, at now: Date, after: TimeInterval?, animated: Bool) -> Bool {
        let target = isDimmed(at: now, after: after) ? 1.0 : 0.0
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

/// A press-and-hold on an ask, read from the clock and never counted in frames, so a slow frame
/// cannot make an approval harder or easier to give.
struct WatchHoldGauge: Equatable {
    enum Release: Equatable {
        case none
        case tap
        case cancelled
        case after
    }

    static let duration: TimeInterval = 0.8
    static let tapWithin: TimeInterval = 0.35

    private(set) var tile: String?
    private(set) var point = CGPoint.zero
    private(set) var startedAt: TimeInterval?
    private(set) var fired = false

    var isHolding: Bool { startedAt != nil }

    mutating func begin(tile: String, at point: CGPoint, now: TimeInterval) {
        guard startedAt == nil else { return }
        self.tile = tile
        self.point = point
        startedAt = now
        fired = false
    }

    func progress(at now: TimeInterval) -> Double {
        guard let startedAt else { return 0 }
        return fired ? 1 : min(1, max(0, (now - startedAt) / Self.duration))
    }

    /// Whether the hold has just reached its length; true once.
    mutating func advance(to now: TimeInterval) -> Bool {
        guard let startedAt, !fired, now - startedAt >= Self.duration else { return false }
        fired = true
        return true
    }

    mutating func release(at now: TimeInterval) -> Release {
        guard let startedAt else { return .none }
        let held = now - startedAt
        let was = fired
        self.startedAt = nil
        tile = nil
        fired = false
        if was { return .after }
        return held < Self.tapWithin ? .tap : .cancelled
    }

    mutating func cancel() {
        startedAt = nil
        tile = nil
        fired = false
    }
}
