import Foundation

/// The turns of a conversation as a persistent list: a streamed token replaces the last turn
/// without copying the others. Turns live in chunks of 64; changing the tail copies the chunk it
/// lands in and the array of chunk references (a few dozen at 2,400 turns) and shares every other
/// chunk with the list it came from, so the cost of a change is independent of how long the
/// conversation is. It is an ordinary random-access collection of `NeuralTurn`.
public struct NeuralTurnList: RandomAccessCollection, Sendable, Equatable {
    static let chunkSize = 64

    private var chunks: [[NeuralTurn]]
    public private(set) var count: Int

    public init() {
        chunks = []
        count = 0
    }

    public init(_ turns: [NeuralTurn]) {
        chunks = []
        count = 0
        append(turns[...])
    }

    public var startIndex: Int { 0 }
    public var endIndex: Int { count }

    public subscript(position: Int) -> NeuralTurn {
        chunks[position / Self.chunkSize][position % Self.chunkSize]
    }

    /// Every turn as one array: a copy of the whole list, for a caller that needs one.
    public var array: [NeuralTurn] {
        var out: [NeuralTurn] = []
        out.reserveCapacity(count)
        for chunk in chunks { out.append(contentsOf: chunk) }
        return out
    }

    /// The list with only its first `kept` turns, followed by `turns`. The kept turns are shared,
    /// not copied, apart from the chunk the cut falls in.
    public func replacingTail(keeping kept: Int, with turns: [NeuralTurn]) -> NeuralTurnList {
        let kept = Swift.max(0, Swift.min(kept, count))
        var next = NeuralTurnList()
        let whole = kept / Self.chunkSize
        next.chunks = Array(chunks[0..<whole])
        next.count = whole * Self.chunkSize
        let partial = kept % Self.chunkSize
        if partial > 0 { next.append(chunks[whole][0..<partial]) }
        next.append(turns[...])
        return next
    }

    private mutating func append(_ turns: ArraySlice<NeuralTurn>) {
        for turn in turns {
            if count % Self.chunkSize == 0 {
                var chunk: [NeuralTurn] = []
                chunk.reserveCapacity(Self.chunkSize)
                chunks.append(chunk)
            }
            chunks[chunks.count - 1].append(turn)
            count += 1
        }
    }
}
