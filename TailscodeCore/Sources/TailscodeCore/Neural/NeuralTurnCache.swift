import CodingAgentKit
import Foundation

/// Reads a conversation into turns without reading again what cannot have changed. A transcript is
/// rebuilt for every token that streams in, so the cost of a token must not be the cost of the
/// conversation: a streamed token reads the parts of the message that grew and nothing else.
///
/// The cache remembers, per message, the thing that decides whether it is the message it saw last
/// time: its identity, its role, its scalar fields and the storage of its parts array (which the
/// cache holds, so any mutation of the parts by their owner is a different storage and is seen).
/// A call walks the messages before the last turn comparing those, which is a handful of integer
/// and pointer comparisons per message and visits no part; a message whose storage moved but whose
/// parts fingerprint the same (a transcript re-decoded to equal values) is kept and its parts are
/// visited once to prove it. Only the messages from the start of the last turn are read again, and
/// of those only the ones that changed: the others keep their `MessageReading`. The turns before
/// the last are handed back by reference in a `NeuralTurnList`, never copied.
///
/// The assumption is the one a value type gives: a message whose parts storage and scalar fields
/// are the same as the cache saw is the same message. `stablePrefix` lets a caller that knows how
/// many leading messages it has not touched skip even the comparison.
///
/// A conversation longer than `capacity` turns, a changed `awaiting`, or an earlier message that
/// really changed falls back to fingerprinting each turn (the old behaviour, bounded by
/// `capacity`) and rebuilds the fast state from the result. Hold one cache per conversation.
public final class NeuralTurnCache: @unchecked Sendable {
    private struct Entry {
        let fingerprint: Int
        let awaitingKey: Int
        let running: Bool
        let turn: NeuralTurn
    }

    /// What the cache keeps between calls so the next one reads only what changed.
    private struct FastState {
        /// What decides whether a message is the one that was seen: its identity, its role, the
        /// scalar fields a turn reads, and the storage of its parts, which is held here so that a
        /// mutation by the owner cannot reuse it.
        struct Seen {
            let id: String
            let role: MessageRole
            var parts: [MessagePart]
            let createdAt: Date
            let completedAt: Date?
            let isStreaming: Bool
            let error: String?
            let finishReason: String?
            let modelID: String?
            let effort: String?

            init(_ message: ChatMessage) {
                id = message.id
                role = message.role
                parts = message.parts
                createdAt = message.createdAt
                completedAt = message.completedAt
                isStreaming = message.isStreaming
                error = message.error
                finishReason = message.finishReason
                modelID = message.modelID
                effort = message.reasoningEffort
            }

            func matches(_ message: ChatMessage) -> Bool {
                withUnsafePointer(to: message) { matches($0) }
            }

            func matches(_ message: UnsafePointer<ChatMessage>) -> Bool {
                FastState.sameStorage(parts, message) && sameScalars(message)
            }

            func sameScalars(_ message: ChatMessage) -> Bool {
                withUnsafePointer(to: message) { sameScalars($0) }
            }

            func sameScalars(_ message: UnsafePointer<ChatMessage>) -> Bool {
                FastState.same(message.pointee.id, id) && message.pointee.role == role
                    && message.pointee.isStreaming == isStreaming
                    && message.pointee.completedAt == completedAt
                    && message.pointee.createdAt == createdAt
                    && FastState.same(message.pointee.error, error)
                    && FastState.same(message.pointee.finishReason, finishReason)
                    && FastState.same(message.pointee.modelID, modelID)
                    && FastState.same(message.pointee.reasoningEffort, effort)
            }

            func sameParts(_ message: UnsafePointer<ChatMessage>, _ proved: inout Int) -> Bool {
                let now = message.pointee.parts
                guard now.count == parts.count else { return false }
                proved += parts.count + now.count
                return NeuralTurnCache.partsFingerprint(parts) == NeuralTurnCache.partsFingerprint(now)
            }

            func sameParts(_ message: ChatMessage, _ proved: inout Int) -> Bool {
                withUnsafePointer(to: message) { sameParts($0, &proved) }
            }
        }

        /// A message read on its own, valid while the message is the one the seen record holds.
        struct Cached {
            let reading: NeuralTurns.MessageReading
        }

        /// Equal strings, decided by their bits when they are the same string (the same small
        /// value or the same storage, which is nearly always) and by comparing otherwise.
        @inline(__always)
        static func same(_ left: String, _ right: String) -> Bool {
            let a = unsafeBitCast(left, to: (UInt64, UInt64).self)
            let b = unsafeBitCast(right, to: (UInt64, UInt64).self)
            return (a.0 == b.0 && a.1 == b.1) || left == right
        }

        @inline(__always)
        static func same(_ left: String?, _ right: String?) -> Bool {
            let a = unsafeBitCast(left, to: (UInt64, UInt64).self)
            let b = unsafeBitCast(right, to: (UInt64, UInt64).self)
            return (a.0 == b.0 && a.1 == b.1) || left == right
        }

        static func sameStorage(_ left: [MessagePart], _ message: UnsafePointer<ChatMessage>) -> Bool {
            left.withUnsafeBufferPointer { a in
                message.pointee.parts.withUnsafeBufferPointer { b in
                    a.baseAddress == b.baseAddress && a.count == b.count
                }
            }
        }

        var seen: [Seen]
        var groupStarts: [Int]
        var lastIndices: [Int]
        var turns: NeuralTurnList
        var running: Bool
        var awaitingKey: Int
        var prefixIDs: Set<String>
        var readings: [String: Cached] = [:]

        var tailStart: Int { groupStarts[groupStarts.count - 1] }

        init(
            messages: [ChatMessage], groupStarts: [Int], lastIndices: [Int], turns: NeuralTurnList,
            running: Bool, awaitingKey: Int
        ) {
            seen = messages.map(Seen.init)
            self.groupStarts = groupStarts
            self.lastIndices = lastIndices
            self.turns = turns
            self.running = running
            self.awaitingKey = awaitingKey
            let start = groupStarts[groupStarts.count - 1]
            prefixIDs = Set(messages[0..<start].map(\.id))
        }
    }

    public static let defaultCapacity = 8_192

    public let capacity: Int

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var fast: FastState?
    private var partitions = 0
    private var reuses = 0
    private var visits = 0

    public init(capacity: Int = NeuralTurnCache.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    /// How many turns were read from their messages over the cache's life: the test hook that
    /// proves a streamed token reads one turn and not the conversation.
    public var turnPartitions: Int { locked { partitions } }

    /// How many turns were handed back from the cache.
    public var turnReuses: Int { locked { reuses } }

    /// How many message parts were read or fingerprinted over the cache's life.
    public var partVisits: Int { locked { visits } }

    /// How many turns the cache holds.
    public var count: Int { locked { fast?.turns.count ?? entries.count } }

    /// Forgets everything, and the counts with it.
    public func reset() {
        locked {
            entries = [:]
            fast = nil
            partitions = 0
            reuses = 0
            visits = 0
        }
    }

    /// The same turns `NeuralTurns.partition` returns for these messages.
    public func partition(
        messages: [ChatMessage], running: Bool, awaiting: NeuralAwaiting = .none
    ) -> [NeuralTurn] {
        partitionList(messages: messages, running: running, awaiting: awaiting).array
    }

    /// The same turns as `partition`, as a list whose turns before the last are shared with the
    /// list of the previous call rather than copied. `stablePrefix` is how many leading messages
    /// the caller promises it has not touched since the last call; they are not compared.
    public func partitionList(
        messages: [ChatMessage], running: Bool, awaiting: NeuralAwaiting = .none,
        stablePrefix: Int = 0
    ) -> NeuralTurnList {
        let awaitingKey = awaiting.isEmpty ? 0 : awaiting.hashValue
        return locked {
            if var state = fast {
                fast = nil
                if let list = advance(
                    &state, messages: messages, running: running, awaiting: awaiting,
                    awaitingKey: awaitingKey, stablePrefix: stablePrefix)
                {
                    fast = state.turns.count <= capacity ? state : nil
                    return list
                }
            }
            return rebuild(
                messages: messages, running: running, awaiting: awaiting, awaitingKey: awaitingKey)
        }
    }

    /// Reads every turn, keeping a turn whose fingerprint did not move, and sets up the fast state
    /// for the next call when the conversation fits.
    private func rebuild(
        messages: [ChatMessage], running: Bool, awaiting: NeuralAwaiting, awaitingKey: Int
    ) -> NeuralTurnList {
        let (groups, starts, lastIndices) = Self.grouped(messages)
        var next: [String: Entry] = [:]
        next.reserveCapacity(min(groups.count, capacity))
        var out: [NeuralTurn] = []
        out.reserveCapacity(groups.count)
        let last = groups.count - 1
        for (index, group) in groups.enumerated() {
            let isRunning = running && index == last
            let stamp = Self.fingerprint(of: group)
            visits += group.reduce(0) { $0 + $1.parts.count }
            let key = group[0].id
            let entry: Entry
            if let held = entries[key], held.fingerprint == stamp,
                held.awaitingKey == awaitingKey, held.running == isRunning
            {
                entry = held
                reuses += 1
            } else {
                partitions += 1
                visits += group.reduce(0) { $0 + $1.parts.count }
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
        let list = NeuralTurnList(out)
        if !groups.isEmpty, groups.count <= capacity, out.count == groups.count {
            fast = FastState(
                messages: messages, groupStarts: starts, lastIndices: lastIndices, turns: list,
                running: running, awaitingKey: awaitingKey)
        }
        return list
    }

    /// The fast path: the messages before the last turn are checked against what was seen, and
    /// only the last turn is read, and of that only the messages that changed. Nil means the call
    /// cannot be answered from the state, and the caller rebuilds.
    private func advance(
        _ state: inout FastState, messages: [ChatMessage], running: Bool,
        awaiting: NeuralAwaiting, awaitingKey: Int, stablePrefix: Int
    ) -> NeuralTurnList? {
        let tailStart = state.tailStart
        guard awaitingKey == state.awaitingKey, messages.count >= tailStart else { return nil }
        let trusted = max(0, min(stablePrefix, tailStart))
        var proved = 0
        let intact = messages.withUnsafeBufferPointer { buffer in
            state.seen.withUnsafeMutableBufferPointer { seen in
                guard let base = buffer.baseAddress else { return tailStart == 0 }
                for index in trusted..<tailStart {
                    let message = base + index
                    if seen[index].matches(message) { continue }
                    guard seen[index].sameScalars(message), seen[index].sameParts(message, &proved)
                    else { return false }
                    seen[index].parts = message.pointee.parts
                }
                return true
            }
        }
        visits += proved
        guard intact else { return nil }

        var tailSame = [Bool](repeating: false, count: messages.count - tailStart)
        var allSame = messages.count == state.seen.count
        for index in tailStart..<messages.count {
            let same = index < state.seen.count && unchanged(&state.seen[index], messages[index])
            tailSame[index - tailStart] = same
            if !same { allSame = false }
        }
        if allSame, running == state.running {
            reuses += state.turns.count
            return state.turns
        }

        var seenIDs = Set<String>()
        var tail: [(start: Int, indices: [Int])] = []
        var current: [Int] = []
        var currentStart = tailStart
        for index in tailStart..<messages.count {
            let message = messages[index]
            guard !state.prefixIDs.contains(message.id), seenIDs.insert(message.id).inserted
            else { continue }
            switch message.role {
            case .user:
                if !current.isEmpty {
                    tail.append((currentStart, current))
                    current = []
                }
            case .assistant:
                if current.isEmpty { currentStart = index }
                current.append(index)
            case .system:
                continue
            }
        }
        if !current.isEmpty { tail.append((currentStart, current)) }
        guard !tail.isEmpty else { return nil }

        var turns: [NeuralTurn] = []
        var readings: [String: FastState.Cached] = [:]
        for (position, group) in tail.enumerated() {
            let isRunning = running && position == tail.count - 1
            let members = group.indices.map { messages[$0] }
            if position == 0, isRunning == state.running, group.indices == state.lastIndices,
                group.indices.allSatisfy({ tailSame[$0 - tailStart] }),
                let held = state.turns.last, held.id == members[0].id
            {
                reuses += 1
                turns.append(held)
                for message in members { readings[message.id] = state.readings[message.id] }
                continue
            }
            partitions += 1
            var parts: [NeuralTurns.MessageReading] = []
            parts.reserveCapacity(members.count)
            for (member, message) in members.enumerated() {
                let index = group.indices[member]
                if let cached = state.readings[message.id], tailSame[index - tailStart] {
                    parts.append(cached.reading)
                    readings[message.id] = cached
                } else {
                    let reading = NeuralTurns.readMessage(message, awaiting: awaiting)
                    visits += message.parts.count
                    parts.append(reading)
                    readings[message.id] = FastState.Cached(reading: reading)
                }
            }
            turns.append(
                NeuralTurns.assemble(members, readings: parts, running: isRunning, awaiting: awaiting))
        }

        let kept = state.turns.count - 1
        state.turns = state.turns.replacingTail(keeping: kept, with: turns)
        state.groupStarts.removeLast()
        state.groupStarts.append(contentsOf: tail.map(\.start))
        let newTailStart = state.groupStarts[state.groupStarts.count - 1]
        for index in tailStart..<min(newTailStart, messages.count) { state.prefixIDs.insert(messages[index].id) }
        state.seen.removeSubrange(tailStart...)
        for index in tailStart..<messages.count { state.seen.append(FastState.Seen(messages[index])) }
        state.readings = readings
        state.lastIndices = tail[tail.count - 1].indices
        state.running = running
        return state.turns
    }

    /// Whether a message is the one that was seen: the same storage, or, when it was rebuilt, parts
    /// that fingerprint the same, which the seen record then adopts.
    private func unchanged(_ seen: inout FastState.Seen, _ message: ChatMessage) -> Bool {
        if seen.matches(message) { return true }
        var proved = 0
        defer { visits += proved }
        guard seen.sameScalars(message), seen.sameParts(message, &proved) else { return false }
        seen.parts = message.parts
        return true
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// The runs of assistant messages between user messages, the way the partition splits them:
    /// a message seen twice counts once, system messages are skipped, and a user message ends a run.
    static func groups(of messages: [ChatMessage]) -> [[ChatMessage]] { grouped(messages).groups }

    /// The runs, the index of each run's first message, and the indices of the last run's messages.
    static func grouped(_ messages: [ChatMessage]) -> (
        groups: [[ChatMessage]], starts: [Int], lastIndices: [Int]
    ) {
        var groups: [[ChatMessage]] = []
        var starts: [Int] = []
        var current: [ChatMessage] = []
        var indices: [Int] = []
        var currentStart = 0
        var seen = Set<String>()
        for (index, message) in messages.enumerated() {
            guard seen.insert(message.id).inserted else { continue }
            switch message.role {
            case .user:
                if !current.isEmpty {
                    groups.append(current)
                    starts.append(currentStart)
                    current = []
                    indices = []
                }
            case .assistant:
                if current.isEmpty { currentStart = index }
                current.append(message)
                indices.append(index)
            case .system:
                continue
            }
        }
        if !current.isEmpty {
            groups.append(current)
            starts.append(currentStart)
        }
        return (groups, starts, indices)
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

    /// One integer for the parts of a message: what `fingerprint(of:)` reads of them.
    static func partsFingerprint(_ parts: [MessagePart]) -> Int {
        var hasher = Hasher()
        hasher.combine(parts.count)
        for part in parts {
            hasher.combine(part.id)
            combine(part.kind, into: &hasher)
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
