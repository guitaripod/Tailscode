import CodingAgentKit
import Foundation

/// A reading per message of a conversation, kept between states so that asking about the whole
/// transcript costs what changed in it rather than what it holds.
///
/// A conversation emits a state for every token and every state carries every message, so a fold
/// that rebuilds a dictionary of the whole transcript and compares each message with the one it
/// remembers pays for the conversation on each word of the answer. Here the entries sit in the
/// transcript's own order and the common state — the same messages, the last one a little longer,
/// or one more at the end — is a positional walk in which an unchanged message costs one equality
/// check that stops at the first buffer both states share, with no allocation and no hashing. A
/// message is read again only when it is not equal to the one its entry was read from, and only
/// when the walk finds the transcript no longer lines up (a message inserted, removed or moved) is
/// a dictionary built, once, to find where each message went.
public struct MessageMemo<Reading> {
    /// What one refresh did to the entries, so a caller that aggregates the readings can leave its
    /// aggregate alone when nothing it cares about moved.
    public enum Change: Equatable, Sendable {
        case none
        case readings
        case resized
        case reordered
    }

    private struct Entry {
        var message: ChatMessage
        var reading: Reading
    }

    private var entries: [Entry] = []

    public init() {}

    public var count: Int { entries.count }

    public func reading(at index: Int) -> Reading { entries[index].reading }

    public func forEachReading(_ body: (Reading) -> Void) {
        for entry in entries { body(entry.reading) }
    }

    /// Brings the entries to `messages`, reading only what is new or different.
    ///
    /// - Parameter read: reads one message.
    /// - Parameter changed: told of every entry that is replaced, added or dropped on the way, with
    ///   the reading it had (nil for a new one) and the reading it has (nil for a dropped one).
    /// - Returns: `.reordered` when messages were found in another place, `.resized` when messages
    ///   were added or dropped at the end, `.readings` when only entries were read again, `.none`
    ///   when every entry stood.
    @discardableResult
    public mutating func refresh(
        _ messages: [ChatMessage], read: (ChatMessage) -> Reading,
        changed: (Reading?, Reading?) -> Void = { _, _ in }
    ) -> Change {
        var change = Change.none
        let shared = min(entries.count, messages.count)
        var index = 0
        while index < shared {
            guard entries[index].message.id == messages[index].id else { break }
            if entries[index].message != messages[index] {
                let fresh = read(messages[index])
                changed(entries[index].reading, fresh)
                entries[index] = Entry(message: messages[index], reading: fresh)
                if change == .none { change = .readings }
            }
            index += 1
        }
        if index < shared {
            relocate(messages, from: index, read: read, changed: changed)
            return .reordered
        }
        if entries.count > messages.count {
            for dropped in entries[messages.count...] { changed(dropped.reading, nil) }
            entries.removeSubrange(messages.count...)
            change = .resized
        }
        if messages.count > entries.count {
            entries.reserveCapacity(messages.count)
            for message in messages[entries.count...] {
                let fresh = read(message)
                changed(nil, fresh)
                entries.append(Entry(message: message, reading: fresh))
            }
            change = .resized
        }
        return change
    }

    /// The walk found a message that is not where it was. Everything from there on is matched by
    /// id: an entry whose message is equal to the one now at that id keeps its reading wherever it
    /// went, and the rest are read.
    private mutating func relocate(
        _ messages: [ChatMessage], from start: Int, read: (ChatMessage) -> Reading,
        changed: (Reading?, Reading?) -> Void
    ) {
        var byID: [String: Int] = [:]
        byID.reserveCapacity(entries.count - start)
        for index in start..<entries.count where byID[entries[index].message.id] == nil {
            byID[entries[index].message.id] = index
        }
        var claimed = Set<Int>()
        var moved: [Entry] = []
        moved.reserveCapacity(messages.count - start)
        for message in messages[start...] {
            if let held = byID[message.id], !claimed.contains(held),
                entries[held].message == message
            {
                claimed.insert(held)
                moved.append(entries[held])
                continue
            }
            let fresh = read(message)
            if let held = byID[message.id], !claimed.contains(held) {
                claimed.insert(held)
                changed(entries[held].reading, fresh)
            } else {
                changed(nil, fresh)
            }
            moved.append(Entry(message: message, reading: fresh))
        }
        for index in start..<entries.count where !claimed.contains(index) {
            changed(entries[index].reading, nil)
        }
        entries.removeSubrange(start...)
        entries.append(contentsOf: moved)
    }
}
