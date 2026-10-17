import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Neural demo large turn")
struct NeuralDemoLargeTests {
    private func read(_ messages: [ChatMessage]) -> NeuralTurn {
        NeuralTurns.partition(messages: messages, running: false)[0]
    }

    private func toolIDs(_ messages: [ChatMessage]) -> [String] {
        messages.flatMap { message in
            message.parts.compactMap { part -> String? in
                if case .tool(let call) = part.kind { return call.id }
                return nil
            }
        }
    }

    @Test("the turn has the asked-for steps, failures, retries and every zone", arguments: [174, 2000])
    func shape(steps: Int) {
        let messages = NeuralDemo.largeTurn(steps: steps)
        let turn = read(messages)
        let low = Int(Double(steps) * 0.95)
        let high = Int(Double(steps) * 1.05)
        #expect((low...high).contains(turn.steps.count))
        #expect(turn.outcome == .settled)
        #expect(!turn.answerPartIDs.isEmpty)

        let failed = turn.steps.filter { $0.status == .failed }
        #expect(failed.count >= 5)
        let retried = failed.filter { step in
            guard step.recovered, step.tieIsCommand, let key = step.tieKey else { return false }
            return turn.steps[(step.index + 1)...].contains {
                $0.tieIsCommand && $0.tieKey == key && $0.status == .ok
            }
        }
        #expect(retried.count >= 2)
        #expect(failed.contains { !$0.recovered })
        let share = Double(failed.count) / Double(turn.steps.filter { $0.call != nil }.count)
        #expect(share > 0.03 && share < 0.1)

        let zones = Set(turn.steps.map(\.zone))
        #expect(zones.isSuperset(of: [.sense, .act, .shell, .delegate, .think, .say]))
    }

    @Test("a dozen shell calls run in a row")
    func burst() {
        let turn = read(NeuralDemo.largeTurn(steps: 174))
        var longest = 0
        var run = 0
        for step in turn.steps {
            run = step.zone == .shell ? run + 1 : 0
            longest = max(longest, run)
        }
        #expect(longest >= 12)
    }

    @Test("a fan-out puts several Task calls in one message")
    func fanOut() {
        let messages = NeuralDemo.largeTurn(steps: 174)
        let widest = messages.map { message in
            message.parts.filter {
                if case .tool(let call) = $0.kind { return call.name == "Task" }
                return false
            }.count
        }.max() ?? 0
        #expect(widest >= 3)
    }

    @Test("two thousand steps build in under two seconds")
    func speed() {
        let clock = ContinuousClock()
        var messages: [ChatMessage] = []
        let elapsed = clock.measure { messages = NeuralDemo.largeTurn(steps: 2000) }
        #expect(elapsed < .seconds(2))
        #expect(!messages.isEmpty)
    }

    @Test("two calls agree on every id, and ids are unique")
    func determinism() {
        let a = NeuralDemo.largeTurn(steps: 2000, prefix: "x-")
        let b = NeuralDemo.largeTurn(steps: 2000, prefix: "x-")
        #expect(a.map(\.id) == b.map(\.id))
        #expect(toolIDs(a) == toolIDs(b))
        #expect(a == b)
        #expect(Set(a.map(\.id)).count == a.count)
        let ids = toolIDs(a)
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0.hasPrefix("call-x-") })
        let c = NeuralDemo.largeTurn(steps: 2000, prefix: "y-")
        #expect(Set(a.map(\.id)).isDisjoint(with: Set(c.map(\.id))))
    }

    @Test("without the answer it is the same steps")
    func withoutAnswer() {
        let full = read(NeuralDemo.largeTurn(steps: 300))
        let bare = read(NeuralDemo.largeTurn(steps: 300, answer: false))
        #expect(full.steps.count == bare.steps.count)
        #expect(!full.answerPartIDs.isEmpty)
        #expect(bare.answerPartIDs.isEmpty)
    }

    @Test("edits carry a real diff")
    func diffs() {
        let turn = read(NeuralDemo.largeTurn(steps: 174))
        let edits = turn.steps.filter { $0.zone == .act && $0.title == "Edit" }
        #expect(!edits.isEmpty)
        #expect(edits.allSatisfy { ($0.added ?? 0) > 0 || ($0.removed ?? 0) > 0 || $0.status == .failed })
    }
}
