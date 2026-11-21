import Foundation

/// What one press of a prompt box's button will do, which is what the button shows. A phone has
/// room for one button, and it used to wear the same arrow for three different acts: sending,
/// queueing behind a running turn, and saving the rewrite of a message that was waiting.
public enum SendFace: Sendable, Equatable, CaseIterable {
    /// Nothing to send and nothing to stop.
    case idle
    case send
    /// A turn is running and there are words: they wait their turn behind it.
    case queue
    /// A turn is running and the box is empty.
    case stop
    /// A waiting message is open in the box: the press puts the rewrite back in its place.
    case save
    /// A waiting message is open and the box was emptied: the press takes it out of the queue.
    case takeBack

    public enum Tone: Sendable, Equatable {
        case accent
        case danger
        case quiet
    }

    public static func read(holdsWords: Bool, busy: Bool, editingQueued: Bool) -> SendFace {
        if editingQueued { return holdsWords ? .save : .takeBack }
        if holdsWords { return busy ? .queue : .send }
        return busy ? .stop : .idle
    }

    public var symbol: String {
        switch self {
        case .idle, .send: return "arrow.up"
        case .queue: return "arrow.up.to.line"
        case .stop: return "stop.fill"
        case .save: return "checkmark"
        case .takeBack: return "arrow.uturn.backward"
        }
    }

    public var tone: Tone {
        switch self {
        case .idle, .takeBack: return .quiet
        case .send, .queue, .save: return .accent
        case .stop: return .danger
        }
    }

    /// Whether a press does anything.
    public var acts: Bool { self != .idle }

    /// The button's name for a screen reader, which cannot read a glyph.
    public var spoken: String {
        switch self {
        case .idle, .send: return Localized.text("Send")
        case .queue: return Localized.text("Queue message")
        case .stop: return Localized.text("Stop")
        case .save: return Localized.text("Save changes to the waiting message")
        case .takeBack: return Localized.text("Take the waiting message back")
        }
    }

    /// Whether the glyph leaves upward when pressed: words going out, as opposed to a turn being
    /// stopped or a rewrite being put back.
    public var launches: Bool { self == .send || self == .queue }
}
