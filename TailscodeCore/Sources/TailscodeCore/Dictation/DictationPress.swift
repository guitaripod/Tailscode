import Foundation

/// One control, two hands, decided the same way for a finger, a mouse button and a key: the
/// microphone opens on the way down, hands-free, so the first word is never lost; a press still
/// down at `holdThreshold` engages a hold, and from then the take lasts only while it is held. A
/// press lifted before the hold engaged leaves the take open, hands-free, until the next press. A
/// key's auto-repeat is a press that is already down, and does nothing.
public struct DictationPress: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case open
        case stop
        case becomeHeld
        case none
    }

    public static let holdThreshold: TimeInterval = 0.28

    private var downAt: TimeInterval?
    private var opened = false
    private var engaged = false

    public init() {}

    public var isDown: Bool { downAt != nil }

    /// Whether the press that is down has engaged its hold.
    public var isEngaged: Bool { engaged }

    /// A press went down. `listening` is whether a take is open right now.
    public mutating func down(at time: TimeInterval, listening: Bool) -> Action {
        guard downAt == nil else { return .none }
        downAt = time
        engaged = false
        if listening {
            opened = false
            return .stop
        }
        opened = true
        return .open
    }

    /// Asked once the threshold has passed since a press went down: a press that opened the take
    /// and is still down engages its hold, once.
    public mutating func tick(at time: TimeInterval) -> Action {
        guard let downAt, opened, !engaged, time - downAt >= Self.holdThreshold else { return .none }
        engaged = true
        return .becomeHeld
    }

    /// The press came up. A hold ends its take; a press that never held leaves the take open, and a
    /// press that stopped a take has nothing more to do. A hold whose tick came late still counts
    /// as one when the press lasted past the threshold.
    public mutating func up(at time: TimeInterval) -> Action {
        guard let start = downAt else { return .none }
        downAt = nil
        let held = engaged || time - start >= Self.holdThreshold
        engaged = false
        guard opened else { return .none }
        opened = false
        return held ? .stop : .none
    }

    /// The press was taken away without coming up (the window lost focus, the gesture was
    /// cancelled): it ends the way a lifted press would. A hold's take ends, because a microphone
    /// must never stay open on a press nobody is making; a tap's take was already hands-free and
    /// stays open, exactly as a tap that came up.
    public mutating func abandon(at time: TimeInterval) -> Action {
        up(at: time)
    }

    /// Whether a press still down has become a hold, engaged or due.
    public func isHeld(at time: TimeInterval) -> Bool {
        guard let downAt, opened else { return false }
        return engaged || time - downAt >= Self.holdThreshold
    }
}

/// Where a held press is armed to go, from how far it has travelled. Sliding away arms a cancel;
/// reaching Send arms a send. Distances are in the toolkit's own points or pixels.
public enum DictationSlide {
    public static let touchCancelDistance: Double = 72
    public static let pointerCancelDistance: Double = 60
    public static let sendSlop: Double = 12

    public static func arm(travelled dx: Double, overSend: Bool, cancelDistance: Double) -> DictationArm {
        if overSend { return .send }
        if dx <= -cancelDistance { return .cancel }
        return .none
    }
}
