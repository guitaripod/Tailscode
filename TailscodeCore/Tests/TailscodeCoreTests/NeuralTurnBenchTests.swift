import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

enum TurnBenchFixtures {
    typealias Fixtures = NeuralTurnFixtures

    static func conversation(turns: Int) -> [ChatMessage] {
        var out: [ChatMessage] = []
        out.reserveCapacity(turns * 2 + 2)
        for index in 0..<turns {
            out.append(
                ChatMessage(
                    id: "u\(index)", role: .user, agentType: .claudeCode,
                    parts: [MessagePart(id: "t", kind: .text("go \(index)"))],
                    createdAt: Fixtures.date(index * 2), completedAt: Fixtures.date(index * 2)))
            out.append(
                ChatMessage(
                    id: "a\(index)", role: .assistant, agentType: .claudeCode,
                    parts: [
                        MessagePart(id: "p0", kind: Fixtures.bash("make \(index)", out: ["ok"])),
                        MessagePart(id: "p1", kind: .reasoning("thinking \(index)")),
                        MessagePart(id: "p2", kind: Fixtures.read("src/File\(index).swift", out: ["x"])),
                        MessagePart(id: "p3", kind: .text("Done \(index).")),
                    ], createdAt: Fixtures.date(index * 2 + 1),
                    completedAt: Fixtures.date(index * 2 + 1).addingTimeInterval(1)))
        }
        out.append(
            ChatMessage(
                id: "ulast", role: .user, agentType: .claudeCode,
                parts: [MessagePart(id: "t", kind: .text("now"))], createdAt: Fixtures.date(900_000),
                completedAt: Fixtures.date(900_000)))
        return out
    }

    /// The last turn: three settled messages of work, then a streaming one whose note grows.
    static func settledTail() -> [ChatMessage] {
        (0..<3).map { index in
            ChatMessage(
                id: "t\(index)", role: .assistant, agentType: .claudeCode,
                parts: [
                    MessagePart(id: "p0", kind: Fixtures.bash("swift build \(index)", out: ["ok"])),
                    MessagePart(id: "p1", kind: Fixtures.read("src/Tail\(index).swift", out: ["x"])),
                ], createdAt: Fixtures.date(900_001 + index),
                completedAt: Fixtures.date(900_001 + index).addingTimeInterval(0.5))
        }
    }

    static func streaming(_ words: String) -> ChatMessage {
        ChatMessage(
            id: "live", role: .assistant, agentType: .claudeCode,
            parts: [
                MessagePart(id: "p0", kind: Fixtures.bash("swift test", status: .running)),
                MessagePart(id: "p1", kind: .reasoning(words)),
            ], createdAt: Fixtures.date(900_100), isStreaming: true)
    }

    static func tokens(_ count: Int) -> [ChatMessage] {
        var words = "w"
        return (0..<count).map { token in
            words += " token\(token)"
            return streaming(words)
        }
    }
}

@Suite("Neural turn cache bench")
struct NeuralTurnBenchTests {
    typealias B = TurnBenchFixtures

    private enum Mode: String, CaseIterable { case array, list, trusted }

    @Test(
        "release microbenchmark: a streamed token costs the same at 100, 600 and 2,400 turns",
        .enabled(if: ProcessInfo.processInfo.environment["NEURAL_TURN_BENCH"] != nil))
    func bench() {
        for turns in [100, 600, 2_400] {
            for mode in Mode.allCases {
                var messages = B.conversation(turns: turns) + B.settledTail()
                messages.append(B.streaming("w"))
                let tokens = B.tokens(400)
                let cache = NeuralTurnCache()
                let first = cache.partitionList(messages: messages, running: true)
                var model = NeuralBrainModel(turn: first[first.count - 1])
                let clock = ContinuousClock()
                var partitionTime = Duration.zero
                var updateTime = Duration.zero
                for token in tokens {
                    messages[messages.count - 1] = token
                    let start = clock.now
                    let last: NeuralTurn
                    switch mode {
                    case .array:
                        let all = cache.partition(messages: messages, running: true)
                        last = all[all.count - 1]
                    case .list:
                        let all = cache.partitionList(messages: messages, running: true)
                        last = all[all.count - 1]
                    case .trusted:
                        let all = cache.partitionList(
                            messages: messages, running: true, stablePrefix: messages.count - 4)
                        last = all[all.count - 1]
                    }
                    let mid = clock.now
                    model.update(turn: last, context: .none)
                    let end = clock.now
                    partitionTime += mid - start
                    updateTime += end - mid
                }
                func millis(_ value: Duration) -> Double {
                    let parts = value.components
                    return (Double(parts.seconds) + Double(parts.attoseconds) / 1e18) * 1000
                        / Double(tokens.count)
                }
                print(
                    "NEURAL-TURN-BENCH turns=\(turns) mode=\(mode.rawValue) partition=\(String(format: "%.4f", millis(partitionTime)))ms update=\(String(format: "%.4f", millis(updateTime)))ms total=\(String(format: "%.4f", millis(partitionTime + updateTime)))ms visits=\(cache.partVisits)"
                )
            }
        }
    }
}

@Suite("Neural turn cache: a token costs the last message, not the conversation")
struct NeuralTurnIncrementalTests {
    typealias B = TurnBenchFixtures
    typealias Fixtures = NeuralTurnFixtures

    private func warm(turns: Int) -> (NeuralTurnCache, [ChatMessage]) {
        var messages = B.conversation(turns: turns) + B.settledTail()
        messages.append(B.streaming("w"))
        let cache = NeuralTurnCache()
        _ = cache.partitionList(messages: messages, running: true)
        return (cache, messages)
    }

    @Test("tokens streamed into the last message of a 2,000-message conversation visit only that message's parts")
    func visitsAreIndependentOfHistory() {
        var perToken: [Int] = []
        for turns in [50, 1_000] {
            var (cache, messages) = warm(turns: turns)
            if turns == 1_000 { #expect(messages.count == 2_005) }
            let tokens = B.tokens(100)
            let before = cache.partVisits
            let partitions = cache.turnPartitions
            for token in tokens {
                messages[messages.count - 1] = token
                _ = cache.partitionList(messages: messages, running: true)
            }
            perToken.append((cache.partVisits - before) / tokens.count)
            #expect(cache.turnPartitions - partitions == tokens.count)
        }
        #expect(perToken[0] == perToken[1])
        #expect(perToken[0] <= 4 * 2)
    }

    @Test("a streamed token reads exactly what the full partition reads, at every step")
    func sameAsPartitionEveryStep() {
        var (cache, messages) = warm(turns: 40)
        for token in B.tokens(30) {
            messages[messages.count - 1] = token
            #expect(cache.partition(messages: messages, running: true) == NeuralTurns.partition(messages: messages, running: true))
        }
        messages[messages.count - 1].isStreaming = false
        messages[messages.count - 1].completedAt = Fixtures.date(900_200)
        #expect(cache.partition(messages: messages, running: false) == NeuralTurns.partition(messages: messages, running: false))
        messages.append(Fixtures.user(900_300))
        messages.append(B.streaming("next"))
        messages[messages.count - 1] = ChatMessage(
            id: "live2", role: .assistant, agentType: .claudeCode,
            parts: [MessagePart(id: "p0", kind: .reasoning("again"))], createdAt: Fixtures.date(900_301), isStreaming: true)
        #expect(cache.partition(messages: messages, running: true) == NeuralTurns.partition(messages: messages, running: true))
        messages.removeLast()
        #expect(cache.partition(messages: messages, running: false) == NeuralTurns.partition(messages: messages, running: false))
        messages.removeLast(3)
        #expect(cache.partition(messages: messages, running: false) == NeuralTurns.partition(messages: messages, running: false))
        _ = cache
    }

    @Test("a change to an earlier message's parts, a deleted message, or a new awaiting set is seen")
    func earlierChanges() {
        var (cache, messages) = warm(turns: 20)
        messages[5].parts[0] = MessagePart(id: "p0", kind: Fixtures.bash("different", out: ["ok"]))
        #expect(cache.partition(messages: messages, running: true) == NeuralTurns.partition(messages: messages, running: true))
        messages[7].parts[3] = MessagePart(id: "p3", kind: .text("changed words"))
        #expect(cache.partition(messages: messages, running: true) == NeuralTurns.partition(messages: messages, running: true))
        messages.remove(at: 10)
        #expect(cache.partition(messages: messages, running: true) == NeuralTurns.partition(messages: messages, running: true))
        let awaiting = NeuralAwaiting(approvals: ["live:p0"])
        #expect(
            cache.partition(messages: messages, running: true, awaiting: awaiting)
                == NeuralTurns.partition(messages: messages, running: true, awaiting: awaiting))
        #expect(cache.partition(messages: messages, running: true) == NeuralTurns.partition(messages: messages, running: true))
    }

    @Test("messages rebuilt to equal values keep their turns, and visit their parts once to prove it")
    func rebuiltMessages() {
        let conversation = B.conversation(turns: 30) + B.settledTail()
        let cache = NeuralTurnCache()
        let first = cache.partition(messages: conversation, running: false)
        let partitions = cache.turnPartitions
        let rebuilt = conversation.map { message -> ChatMessage in
            var copy = message
            copy.parts = message.parts.map { MessagePart(id: $0.id, kind: $0.kind) }
            return copy
        }
        let again = cache.partition(messages: rebuilt, running: false)
        #expect(again == first)
        #expect(cache.turnPartitions == partitions)
    }

    @Test("a stable prefix the caller vouches for is not compared, and the answer is the same")
    func stablePrefix() {
        var (cache, messages) = warm(turns: 200)
        for token in B.tokens(5) {
            messages[messages.count - 1] = token
            let trusted = cache.partitionList(messages: messages, running: true, stablePrefix: messages.count - 4)
            #expect(trusted.array == NeuralTurns.partition(messages: messages, running: true))
        }
    }

    @Test("the same conversation twice reads nothing the second time, and the turns come back by reference")
    func unchangedIsFree() {
        var (cache, messages) = warm(turns: 300)
        let first = cache.partitionList(messages: messages, running: true)
        let visits = cache.partVisits
        let second = cache.partitionList(messages: messages, running: true)
        #expect(second == first)
        #expect(cache.partVisits == visits)
        messages[messages.count - 1] = B.tokens(1)[0]
        let third = cache.partitionList(messages: messages, running: true)
        #expect(third.count == first.count && third[0] == first[0] && third[299] == first[299])
        #expect(third[third.count - 1] != first[first.count - 1])
    }
}

@Suite("Neural turn list")
struct NeuralTurnListTests {
    private func turns(_ count: Int) -> [NeuralTurn] { (0..<count).map { NeuralTurn(id: "t\($0)") } }

    @Test("it is the same sequence as the array, at every chunk boundary")
    func sequence() {
        for count in [0, 1, 63, 64, 65, 127, 128, 129, 300] {
            let list = NeuralTurnList(turns(count))
            #expect(list.count == count && list.array == turns(count))
            #expect(Array(list) == turns(count))
            #expect(list.last?.id == (count > 0 ? "t\(count - 1)" : nil))
        }
    }

    @Test("replacing the tail keeps the head and takes the new turns, at every boundary")
    func replacing() {
        for count in [1, 64, 65, 128, 200] {
            let list = NeuralTurnList(turns(count))
            for kept in [0, count / 2, count - 1, count] {
                let extra = [NeuralTurn(id: "x0"), NeuralTurn(id: "x1")]
                let next = list.replacingTail(keeping: kept, with: extra)
                #expect(next.array == Array(turns(count)[0..<kept]) + extra)
            }
            #expect(list.array == turns(count))
            #expect(list.replacingTail(keeping: count + 10, with: []).array == turns(count))
        }
    }
}
