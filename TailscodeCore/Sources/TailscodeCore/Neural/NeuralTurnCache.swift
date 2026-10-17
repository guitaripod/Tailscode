import CodingAgentKit
import Foundation

/// Reads a conversation into turns without reading again what cannot have changed. A transcript is
/// rebuilt for every token that streams in, and partitioning a long conversation is the cost of
/// the conversation; a turn that finished a while ago has the same messages as it had last time,
/// so its reading is kept and only the turn that is changing is read again.
///
/// A turn is kept under a fingerprint of its messages (identity, how many parts, each part's kind
/// and its length or status, completion, error), of whether it was read as the running turn, and
/// of what the conversation was waiting on. All of it is integer arithmetic over the messages as
/// they stand, never a scan of their text. Hold one cache per conversation: it keeps the turns of
/// the last call, at most `capacity` of them, so a conversation that rotates its ids does not
/// grow it.
public final class NeuralTurnCache: @unchecked Sendable {
    private struct Entry {
        let fingerprint: Int
        let awaitingKey: Int
        let running: Bool
        let turn: NeuralTurn
    }

    public static let defaultCapacity = 512

    public let capacity: Int

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var partitions = 0
    private var reuses = 0

    public init(capacity: Int = NeuralTurnCache.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    /// How many turns were read from their messages over the cache's life: the test hook that
    /// proves a streamed token reads one turn and not the conversation.
    public var turnPartitions: Int { locked { partitions } }

    /// How many turns were handed back from the cache.
    public var turnReuses: Int { locked { reuses } }

    /// How many turns the cache holds.
    public var count: Int { locked { entries.count } }

    /// Forgets everything, and the counts with it.
    public func reset() {
        locked {
            entries = [:]
            partitions = 0
            reuses = 0
        }
    }

    /// The same turns `NeuralTurns.partition` returns for these messages, reading again only the
    /// turns whose fingerprint moved.
    public func partition(
        messages: [ChatMessage], running: Bool, awaiting: NeuralAwaiting = .none
    ) -> [NeuralTurn] {
        let groups = Self.groups(of: messages)
        let awaitingKey = awaiting.isEmpty ? 0 : awaiting.hashValue
        return locked {
            var next: [String: Entry] = [:]
            next.reserveCapacity(min(groups.count, capacity))
            var out: [NeuralTurn] = []
            out.reserveCapacity(groups.count)
            let last = groups.count - 1
            for (index, group) in groups.enumerated() {
                let isRunning = running && index == last
                let stamp = Self.fingerprint(of: group)
                let key = group[0].id
                let entry: Entry
                if let held = entries[key], held.fingerprint == stamp,
                    held.awaitingKey == awaitingKey, held.running == isRunning
                {
                    entry = held
                    reuses += 1
                } else {
                    partitions += 1
                    let read = NeuralTurns.partition(
                        messages: group, running: isRunning, awaiting: awaiting)
                    guard let turn = read.first else { continue }
                    entry = Entry(
                        fingerprint: stamp, awaitingKey: awaitingKey, running: isRunning, turn: turn)
                }
                out.append(entry.turn)
                if groups.count - index <= capacity { next[key] = entry }
            }
            entries = next
            return out
        }
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// The runs of assistant messages between user messages, the way the partition splits them:
    /// a message seen twice counts once, system messages are skipped, and a user message ends a run.
    static func groups(of messages: [ChatMessage]) -> [[ChatMessage]] {
        var groups: [[ChatMessage]] = []
        var current: [ChatMessage] = []
        var seen = Set<String>()
        for message in messages {
            guard seen.insert(message.id).inserted else { continue }
            switch message.role {
            case .user:
                if !current.isEmpty {
                    groups.append(current)
                    current = []
                }
            case .assistant:
                current.append(message)
            case .system:
                continue
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// One integer standing for everything about a run of messages that the partition reads and
    /// that can change while a conversation is open.
    static func fingerprint(of messages: [ChatMessage]) -> Int {
        var hasher = Hasher()
        hasher.combine(messages.count)
        for message in messages {
            hasher.combine(message.id)
            hasher.combine(message.parts.count)
            hasher.combine(message.isStreaming)
            hasher.combine(message.completedAt?.timeIntervalSinceReferenceDate.bitPattern)
            hasher.combine(message.error?.utf8.count)
            hasher.combine(message.finishReason?.utf8.count)
            hasher.combine(message.modelID?.utf8.count)
            hasher.combine(message.reasoningEffort?.utf8.count)
            for part in message.parts {
                hasher.combine(part.id)
                combine(part.kind, into: &hasher)
            }
        }
        return hasher.finalize()
    }

    private static func combine(_ kind: MessagePart.Kind, into hasher: inout Hasher) {
        switch kind {
        case .text(let words):
            hasher.combine(0)
            hasher.combine(words.utf8.count)
        case .reasoning(let words):
            hasher.combine(1)
            hasher.combine(words.utf8.count)
        case .tool(let call):
            hasher.combine(2)
            hasher.combine(call.id)
            hasher.combine(call.status)
            hasher.combine(call.output?.utf8.count)
            hasher.combine(weight(of: call.input))
        case .file:
            hasher.combine(3)
        case .compaction:
            hasher.combine(4)
        case .note:
            hasher.combine(5)
        case .unknown:
            hasher.combine(6)
        }
    }

    /// How much a call's input holds: its fields and the length of each string among them. The
    /// input of a streaming call can arrive after its part does, and this is what notices.
    private static func weight(of input: JSONValue?) -> Int {
        guard let input else { return -1 }
        guard case .object(let fields) = input else { return 0 }
        var total = fields.count
        for value in fields.values {
            switch value {
            case .string(let text): total &+= text.utf8.count
            case .array(let items): total &+= items.count
            case .object(let inner): total &+= inner.count
            default: total &+= 1
            }
        }
        return total
    }
}
