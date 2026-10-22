import Foundation

/// Which conversation a push is aimed at: the server that holds it and its id, the same pair the
/// rest of the app keys a chat by.
public struct ChatTarget: Hashable, Sendable {
    public let contextID: String
    public let sessionID: String

    public init(contextID: String, sessionID: String) {
        self.contextID = contextID
        self.sessionID = sessionID
    }
}

/// Whether a chat may be pushed onto a navigation stack right now.
///
/// A stack that is animating refuses nothing, it queues the push behind the animation, and a second
/// push begun on top of a first, or on top of a pop, leaves the interactive pop recogniser waiting
/// for a transition that no longer finishes the way it expected. So every road that opens a chat
/// asks here first, with the two facts only the stack knows: which chat is on top, and whether a
/// transition is running. The guard keeps nothing but the one push it is holding, so a flag that
/// could outlive its transition has nowhere to live.
///
/// A held push is the latest one asked for: the person who pressed twice meant the second.
public struct ChatNavigationGuard: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        case push
        case alreadyOnTop
        case hold
    }

    public private(set) var held: ChatTarget?

    public init() {}

    public mutating func request(
        _ target: ChatTarget, top: ChatTarget?, transitioning: Bool
    ) -> Verdict {
        if top == target {
            held = nil
            return .alreadyOnTop
        }
        if transitioning {
            held = target
            return .hold
        }
        held = nil
        return .push
    }

    /// The transition ended, so the push that was waiting for it may go, unless the stack has
    /// since come to show that very chat.
    public mutating func settled(top: ChatTarget?) -> ChatTarget? {
        defer { held = nil }
        guard let waiting = held, waiting != top else { return nil }
        return waiting
    }
}
