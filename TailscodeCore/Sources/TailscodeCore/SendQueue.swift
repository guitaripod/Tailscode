import CodingAgentKit
import Foundation

/// A prompt written while a turn was running, held here rather than handed over.
///
/// The whole reason it is held on the device is that a message you can still change is worth more
/// than a message that is one place further along. Sending during a live turn is the normal way to
/// work — you think of the next thing while the last one runs — and the next thing is exactly what
/// you most often want to reword, reorder or take back once you have read another paragraph of the
/// answer. Once it is on the server it is a queue entry nobody can reach.
public struct QueuedSend: Sendable, Hashable, Identifiable {
    /// What the message will be when it goes: an ordinary prompt, or a slash command with its
    /// arguments, which is a turn like any other and queues the same way.
    public enum Kind: Sendable, Hashable {
        case prompt
        case command(name: String, arguments: String)
    }

    public let id: UUID
    public var text: String
    public var model: ModelSelection?
    public var effort: String?
    public var attachments: [PromptAttachment]
    public var kind: Kind

    public init(
        id: UUID = UUID(), text: String, model: ModelSelection? = nil, effort: String? = nil,
        attachments: [PromptAttachment] = [], kind: Kind = .prompt
    ) {
        self.id = id
        self.text = text
        self.model = model
        self.effort = effort
        self.attachments = attachments
        self.kind = kind
    }

    public var isCommand: Bool {
        if case .command = kind { return true }
        return false
    }
}

/// The messages waiting behind a live turn, in the order they will go.
///
/// Deliberately a value: a pane holds one, hands out what it contains, and every change to it is a
/// change a client can render from. Nothing here talks to a server — draining is the caller's, and
/// happens the moment the turn yields.
public struct SendQueue: Sendable, Hashable {
    public private(set) var items: [QueuedSend] = []

    public init(items: [QueuedSend] = []) {
        self.items = items
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    @discardableResult
    public mutating func append(_ send: QueuedSend) -> QueuedSend {
        items.append(send)
        return send
    }

    /// Puts a message that failed to go back at the head rather than at the tail, so a blip on the
    /// connection cannot silently reorder what somebody wrote.
    public mutating func requeueAtHead(_ send: QueuedSend) {
        items.insert(send, at: 0)
    }

    @discardableResult
    public mutating func remove(id: UUID) -> QueuedSend? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    /// The next message to go, taken off the front.
    public mutating func takeFirst() -> QueuedSend? {
        items.isEmpty ? nil : items.removeFirst()
    }

    /// The last message written, taken back — what an up-arrow from an empty composer means. The
    /// most recent is the one being reconsidered; anything earlier is reached by clicking it.
    public mutating func takeLast() -> QueuedSend? {
        items.popLast()
    }

    public func item(id: UUID) -> QueuedSend? {
        items.first { $0.id == id }
    }

    /// Rewrites one waiting message in place, keeping its position in the order. Empty words with
    /// nothing attached is a deletion — a person who cleared the box meant to take it back.
    @discardableResult
    public mutating func replace(id: UUID, text: String, attachments: [PromptAttachment]) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else {
            items.remove(at: index)
            return true
        }
        items[index].text = text
        items[index].attachments = attachments
        return true
    }

    public mutating func removeAll() {
        items.removeAll()
    }
}

/// Everything a client says about a waiting message, written once so three clients say it the same.
///
/// A queued message is not a sent one and must never look like it: it is dimmer, it is marked, and
/// it says what it is waiting for. It is also the one thing in a transcript that is still yours —
/// so it states, in the row itself, that it can be changed.
public enum SendQueueReading {
    /// The mark a waiting row wears on the text clients.
    public static let glyph = "⏳"
    /// The symbol it wears on the Apple clients.
    public static let symbol = "clock.badge"

    public static func rowTitle(_ send: QueuedSend) -> String {
        guard case let .command(name, arguments) = send.kind else { return send.text }
        return arguments.isEmpty ? "/\(name)" : "/\(name) \(arguments)"
    }

    /// What the row says under the words: that it has not gone, and what to do about it.
    public static var hint: String {
        Localized.text("Waiting for this turn — click to edit, or press ↑ in an empty composer")
    }

    /// The short form, for a row too narrow for the sentence.
    public static var badge: String { Localized.text("waiting") }

    /// A queue stops draining when the message at its head fails to go, and it stays stopped
    /// until the server answers again — sending the next one into the same fault is how a single
    /// tailnet blip used to destroy everything behind it. That hold is a state, and it belongs on
    /// the row it is holding rather than nowhere: a queue that has quietly stopped looks exactly
    /// like a queue waiting its turn, and the difference is the only thing worth knowing.
    public static var heldBadge: String { Localized.text("held") }

    /// The mark a held row wears instead of the hourglass, because a queue that has stopped is a
    /// different fact from a queue that is waiting and must not wear the same face.
    public static let heldGlyph = "⏸"
    public static let heldSymbol = "pause.circle"

    /// The whole visible line of a waiting row, so three clients cannot drift on what it says.
    public static func rowLine(_ send: QueuedSend, held: Bool = false) -> String {
        held
            ? "\(heldGlyph) \(heldBadge) · \(rowTitle(send))"
            : "\(glyph) \(rowTitle(send))"
    }

    public static func heldHint(reason: String?) -> String {
        guard let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines),
            !reason.isEmpty
        else {
            return Localized.text("Held — the last send didn't go. It goes when the server answers.")
        }
        return Localized.text("Held — %@. It goes when the server answers.", reason)
    }

    public static func spoken(_ send: QueuedSend, position: Int, of total: Int) -> String {
        let where_ = total > 1
            ? Localized.text("%d of %d waiting", position, total)
            : Localized.text("waiting to send")
        return "\(where_). \(rowTitle(send))"
    }

    public static func removed(_ send: QueuedSend) -> String {
        Localized.text("Taken out of the queue.")
    }

    /// Whether an up-arrow in the composer should take the last queued message back rather than
    /// doing whatever the composer does with an arrow. Only from an empty box: a person editing a
    /// paragraph is moving the caret, and stealing that key would be the worse bug.
    public static func upArrowTakesBack(composerText: String, queue: SendQueue) -> Bool {
        !queue.isEmpty
            && composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
