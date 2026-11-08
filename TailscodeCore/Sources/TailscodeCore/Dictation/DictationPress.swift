import Foundation

/// One control, two hands, decided the same way for a finger, a mouse button and a key: the
/// microphone opens on the way down, a press lifted inside `holdThreshold` leaves it open until the
/// next press, and a press held past it keeps it open only while held. A key's auto-repeat is a
/// press that is already down, and does nothing.
public struct DictationPress: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case open
        case stop
        case becomeHandsFree
        case none
    }

    public static let holdThreshold: TimeInterval = 0.28

    private var downAt: TimeInterval?
    private var opened = false

    public init() {}

    public var isDown: Bool { downAt != nil }

    /// A press went down. `listening` is whether a take is open right now.
    public mutating func down(at time: TimeInterval, listening: Bool) -> Action {
        guard downAt == nil else { return .none }
        downAt = time
        if listening {
            opened = false
            return .stop
        }
        opened = true
        return .open
    }

    /// The press came up. A press that opened the take and was short leaves it open; a long one
    /// ends it. A press that stopped a take has nothing more to do.
    public mutating func up(at time: TimeInterval) -> Action {
        guard let start = downAt else { return .none }
        downAt = nil
        guard opened else { return .none }
        opened = false
        return time - start < Self.holdThreshold ? .becomeHandsFree : .stop
    }

    /// The press was taken away without coming up (the window lost focus, the gesture was
    /// cancelled): treated as a release of a hold, because a microphone must never stay open on a
    /// press nobody is making.
    public mutating func abandon(at time: TimeInterval) -> Action {
        guard downAt != nil else { return .none }
        let action = up(at: time + Self.holdThreshold)
        return action == .becomeHandsFree ? .stop : action
    }

    /// Whether a press still down has become a hold.
    public func isHeld(at time: TimeInterval) -> Bool {
        guard let downAt, opened else { return false }
        return time - downAt >= Self.holdThreshold
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
