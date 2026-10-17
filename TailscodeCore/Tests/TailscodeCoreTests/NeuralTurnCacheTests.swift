import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Neural turn cache")
struct NeuralTurnCacheTests {
    typealias Fixtures = NeuralTurnFixtures

    private func conversation(turns: Int) -> [ChatMessage] {
        var out: [ChatMessage] = []
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
                        MessagePart(id: "p1", kind: .text("Done \(index).")),
                    ], createdAt: Fixtures.date(index * 2 + 1),
                    completedAt: Fixtures.date(index * 2 + 1).addingTimeInterval(1)))
        }
        return out
    }

    private func streaming(_ words: String, id: String = "live") -> ChatMessage {
        ChatMessage(
            id: id, role: .assistant, agentType: .claudeCode,
            parts: [
                MessagePart(id: "p0", kind: Fixtures.bash("swift build", status: .running)),
                MessagePart(id: "p1", kind: .reasoning(words)),
            ], createdAt: Fixtures.date(10_000), isStreaming: true)
    }

    @Test("the cache returns exactly what the partition does")
    func sameAsPartition() {
        let cache = NeuralTurnCache()
        for messages in [Fixtures.turn(), Fixtures.buildFix(), conversation(turns: 5), []] {
            for running in [false, true] {
                let expected = NeuralTurns.partition(messages: messages, running: running)
                #expect(cache.partition(messages: messages, running: running) == expected)
                #expect(cache.partition(messages: messages, running: running) == expected)
            }
        }
    }

    @Test("the same conversation twice reads each turn once")
    func hits() {
        let cache = NeuralTurnCache()
        let messages = conversation(turns: 20)
        let first = cache.partition(messages: messages, running: false)
        #expect(first.count == 20)
        #expect(cache.turnPartitions == 20)
        #expect(cache.turnReuses == 0)
        let second = cache.partition(messages: messages, running: false)
        #expect(second == first)
        #expect(cache.turnPartitions == 20)
        #expect(cache.turnReuses == 20)
        #expect(cache.count == 20)
    }

    @Test("fifty streamed tokens in a 400-message conversation read the last turn and no other")
    func streamedTokens() {
        let cache = NeuralTurnCache()
        var messages = conversation(turns: 200)
        #expect(messages.count == 400)
        messages.append(
            ChatMessage(
                id: "ulast", role: .user, agentType: .claudeCode,
                parts: [MessagePart(id: "t", kind: .text("now"))], createdAt: Fixtures.date(9_999)))
        messages.append(streaming("w"))
        _ = cache.partition(messages: messages, running: true)
        let warm = cache.turnPartitions
        #expect(warm == 201)

        var words = "w"
        var last: [NeuralTurn] = []
        for token in 0..<50 {
            words += " token\(token)"
            messages[messages.count - 1] = streaming(words)
            last = cache.partition(messages: messages, running: true)
        }
        #expect(cache.turnPartitions - warm <= 51)
        #expect(cache.turnPartitions - warm == 50)
        #expect(last.count == 201)
        #expect(last == NeuralTurns.partition(messages: messages, running: true))
        #expect(last[200].steps.last?.text == words)
        #expect(last[200].outcome == .running)
    }

    @Test("a tool that finishes, or whose input arrives late, is read again")
    func midTurnChanges() throws {
        let cache = NeuralTurnCache()
        func message(_ status: ToolStatus, input: JSONValue?, out: String?) -> [ChatMessage] {
            [
                Fixtures.user(0),
                ChatMessage(
                    id: "a", role: .assistant, agentType: .claudeCode,
                    parts: [
                        MessagePart(
                            id: "p0",
                            kind: .tool(ToolCall(id: "c", name: "Bash", status: status, input: input, output: out)))
                    ], createdAt: Fixtures.date(1)),
            ]
        }
        let running = cache.partition(messages: message(.running, input: nil, out: nil), running: true)
        #expect(running[0].steps[0].status == .running)
        #expect(running[0].steps[0].detail.isEmpty)
        let named = cache.partition(
            messages: message(.running, input: .object(["command": .string("make")]), out: nil), running: true)
        #expect(named[0].steps[0].detail == "make")
        #expect(named[0].steps[0].tieKey == "make")
        let done = cache.partition(
            messages: message(.completed, input: .object(["command": .string("make")]), out: "ok"), running: false)
        #expect(done[0].steps[0].status == .ok)
        #expect(done[0].steps[0].outputLines == ["ok"])
        #expect(done[0].outcome != .running)
        #expect(cache.turnPartitions == 3)
    }

    @Test("a flip of running, or of what the conversation waits on, reads the turn again")
    func runningAndAwaiting() {
        let cache = NeuralTurnCache()
        let messages = [Fixtures.user(0), Fixtures.message(1, [Fixtures.bash("make", status: .running)], streaming: true)]
        let running = cache.partition(messages: messages, running: true)
        #expect(running[0].outcome == .running)
        let again = cache.partition(messages: messages, running: true)
        #expect(again == running)
        #expect(cache.turnPartitions == 1)
        let waiting = cache.partition(
            messages: messages, running: true, awaiting: NeuralAwaiting(approvals: ["m1:p0"]))
        #expect(waiting[0].steps[0].status == .waitingApproval)
        #expect(cache.turnPartitions == 2)
        let settled = cache.partition(messages: messages, running: false)
        #expect(settled[0].outcome != .running)
        #expect(cache.turnPartitions == 3)
    }

    @Test("an earlier turn is never read as the running one")
    func earlierTurnNotRunning() {
        let cache = NeuralTurnCache()
        var messages = conversation(turns: 3)
        let turns = cache.partition(messages: messages, running: true)
        #expect(turns.map(\.outcome) == [.settled, .settled, .running])
        messages.append(Fixtures.user(500))
        messages.append(Fixtures.message(501, [Fixtures.bash("ls", status: .running)], streaming: true))
        let more = cache.partition(messages: messages, running: true)
        #expect(more.map(\.outcome) == [.settled, .settled, .settled, .running])
        #expect(more == NeuralTurns.partition(messages: messages, running: true))
    }

    @Test("a turn that grows a message is read again and the older ones are not")
    func growth() {
        let cache = NeuralTurnCache()
        var messages = conversation(turns: 4)
        _ = cache.partition(messages: messages, running: false)
        messages.append(
            ChatMessage(
                id: "more", role: .assistant, agentType: .claudeCode,
                parts: [MessagePart(id: "p0", kind: Fixtures.read("x/y/z.swift"))],
                createdAt: Fixtures.date(99), completedAt: Fixtures.date(100)))
        let grown = cache.partition(messages: messages, running: false)
        #expect(grown[3].steps.count == 3)
        #expect(cache.turnPartitions == 5)
        #expect(grown == NeuralTurns.partition(messages: messages, running: false))
    }

    @Test("duplicated and system messages are read as the partition reads them")
    func oddMessages() {
        let cache = NeuralTurnCache()
        var messages = conversation(turns: 2)
        messages.insert(messages[1], at: 2)
        messages.append(
            ChatMessage(
                id: "sys", role: .system, agentType: .claudeCode,
                parts: [MessagePart(id: "t", kind: .text("note"))], createdAt: Fixtures.date(7)))
        #expect(
            cache.partition(messages: messages, running: false)
                == NeuralTurns.partition(messages: messages, running: false))
    }

    @Test("the cache holds at most its capacity, the latest turns, and reset forgets everything")
    func capacityAndReset() {
        let cache = NeuralTurnCache(capacity: 3)
        let messages = conversation(turns: 10)
        _ = cache.partition(messages: messages, running: false)
        #expect(cache.count == 3)
        #expect(cache.turnPartitions == 10)
        _ = cache.partition(messages: messages, running: false)
        #expect(cache.turnPartitions == 17)
        #expect(cache.turnReuses == 3)

        cache.reset()
        #expect(cache.count == 0)
        #expect(cache.turnPartitions == 0)
        #expect(cache.turnReuses == 0)
        _ = cache.partition(messages: messages, running: false)
        #expect(cache.turnPartitions == 10)
        #expect(NeuralTurnCache(capacity: 0).capacity == 1)
    }

    @Test("a conversation that changes under the cache is never answered from another's turns")
    func otherConversation() {
        let cache = NeuralTurnCache()
        let a = conversation(turns: 3)
        _ = cache.partition(messages: a, running: false)
        var b = conversation(turns: 3)
        b[1].parts[0] = MessagePart(id: "p0", kind: Fixtures.bash("different", out: ["ok"]))
        let read = cache.partition(messages: b, running: false)
        #expect(read == NeuralTurns.partition(messages: b, running: false))
    }

    @Test("the cache is safe to call from many threads")
    func threads() async {
        let cache = NeuralTurnCache()
        let messages = conversation(turns: 30)
        let expected = NeuralTurns.partition(messages: messages, running: false)
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask { cache.partition(messages: messages, running: false) == expected }
            }
            for await ok in group { #expect(ok) }
        }
        #expect(cache.turnPartitions + cache.turnReuses == 8 * 30)
    }
}
