import CodingAgentKit
import Foundation

/// One turn of a conversation, held as its outline and read into steps only when somebody asks.
/// Opening a chat needs only the outline of every turn (is it a brain, where does its row go,
/// what does it consume), and the steps of the few turns that are looked at; a turn that nobody
/// looks at is never read into steps.
final class NeuralTurnSlot: @unchecked Sendable {
    struct Source {
        let messages: [ChatMessage]
        let running: Bool
        let awaiting: NeuralAwaiting
        let counter: NeuralTurnCounter?
    }

    private static let lock = NSLock()

    let outline: NeuralTurnOutline
    let generation: Int
    private var held: NeuralTurn?
    private var source: Source?

    init(outline: NeuralTurnOutline, generation: Int, source: Source) {
        self.outline = outline
        self.generation = generation
        self.source = source
    }

    init(turn: NeuralTurn, generation: Int) {
        outline = turn.outline
        self.generation = generation
        held = turn
    }

    var isRealised: Bool { Self.lock.withLock { held != nil } }

    var messages: [ChatMessage]? { Self.lock.withLock { source?.messages } }

    var turn: NeuralTurn {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        if let held { return held }
        guard let source else { return NeuralTurn(id: outline.id) }
        let read =
            NeuralTurns.partition(
                messages: source.messages, running: source.running, awaiting: source.awaiting
            ).first ?? NeuralTurn(id: outline.id)
        source.counter?.noteRead()
        held = read
        self.source = nil
        return read
    }
}

/// How many turns were read into steps, for the test hook that proves a streamed token reads one
/// turn and not the conversation.
final class NeuralTurnCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0

    var value: Int { lock.withLock { reads } }

    func noteRead() { lock.withLock { reads += 1 } }

    func reset() { lock.withLock { reads = 0 } }
}

/// The turns of a conversation as a persistent list: a streamed token replaces the last turn
/// without copying the others. Turns live in chunks of 64; changing the tail copies the chunk it
/// lands in and the array of chunk references (a few dozen at 2,400 turns) and shares every other
/// chunk with the list it came from, so the cost of a change is independent of how long the
/// conversation is. It is an ordinary random-access collection of `NeuralTurn`.
///
/// A list a cache made when a chat opened holds the outline of each turn and reads a turn into
/// steps the first time it is indexed: `outline(at:)` never does, and asking only for outlines
/// leaves every turn unread. The turns are the same either way.
public struct NeuralTurnList: RandomAccessCollection, Sendable, Equatable {
    static let chunkSize = 64

    private var chunks: [[NeuralTurnSlot]]
    public private(set) var count: Int

    public init() {
        chunks = []
        count = 0
    }

    public init(_ turns: [NeuralTurn]) {
        chunks = []
        count = 0
        append(turns.enumerated().map { NeuralTurnSlot(turn: $1, generation: -$0 - 1) }[...])
    }

    init(slots: [NeuralTurnSlot]) {
        chunks = []
        count = 0
        append(slots[...])
    }

    public var startIndex: Int { 0 }
    public var endIndex: Int { count }

    public subscript(position: Int) -> NeuralTurn { slot(at: position).turn }

    func slot(at position: Int) -> NeuralTurnSlot {
        chunks[position / Self.chunkSize][position % Self.chunkSize]
    }

    /// The outline of a turn, which reads none of its steps.
    public func outline(at position: Int) -> NeuralTurnOutline { slot(at: position).outline }

    /// A number that is the same for as long as the turn is the same turn: a list made from a
    /// conversation hands back the very turn it held for every message that did not change, and a
    /// new number for one that did.
    public func generation(at position: Int) -> Int { slot(at: position).generation }

    /// Whether the turn at `position` has been read into steps.
    public func isRead(at position: Int) -> Bool { slot(at: position).isRealised }

    /// Every turn as one array: a copy of the whole list, for a caller that needs one.
    public var array: [NeuralTurn] {
        var out: [NeuralTurn] = []
        out.reserveCapacity(count)
        for chunk in chunks { for slot in chunk { out.append(slot.turn) } }
        return out
    }

    public static func == (left: NeuralTurnList, right: NeuralTurnList) -> Bool {
        guard left.count == right.count else { return false }
        for index in 0..<left.count {
            let a = left.slot(at: index)
            let b = right.slot(at: index)
            if a === b { continue }
            if a.turn != b.turn { return false }
        }
        return true
    }

    /// The list with only its first `kept` turns, followed by `turns`. The kept turns are shared,
    /// not copied, apart from the chunk the cut falls in.
    public func replacingTail(keeping kept: Int, with turns: [NeuralTurn]) -> NeuralTurnList {
        replacingTail(
            keeping: kept,
            slots: turns.enumerated().map { NeuralTurnSlot(turn: $1, generation: -$0 - 1) })
    }

    func replacingTail(keeping kept: Int, slots: [NeuralTurnSlot]) -> NeuralTurnList {
        let kept = Swift.max(0, Swift.min(kept, count))
        var next = NeuralTurnList()
        let whole = kept / Self.chunkSize
        next.chunks = Array(chunks[0..<whole])
        next.count = whole * Self.chunkSize
        let partial = kept % Self.chunkSize
        if partial > 0 { next.append(chunks[whole][0..<partial]) }
        next.append(slots[...])
        return next
    }

    private mutating func append(_ slots: ArraySlice<NeuralTurnSlot>) {
        for slot in slots {
            if count % Self.chunkSize == 0 {
                var chunk: [NeuralTurnSlot] = []
                chunk.reserveCapacity(Self.chunkSize)
                chunks.append(chunk)
            }
            chunks[chunks.count - 1].append(slot)
            count += 1
        }
    }
}
