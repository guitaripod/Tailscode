import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Neural demo")
struct NeuralDemoTests {
    @Test("the demo conversation is two turns with the mock's step counts and distinct ids")
    func twoTurns() {
        let messages = NeuralDemo.conversation()
        #expect(Set(messages.map(\.id)).count == messages.count)
        let turns = NeuralTurns.partition(messages: messages, running: false)
        #expect(turns.count == 2)
        #expect(turns[0].steps.count == 14)
        #expect(turns[1].steps.count == 29)
        #expect(turns[1].steps.filter { $0.zone == .shell }.count == 18)
        #expect(turns.allSatisfy { $0.outcome == .settled })
        #expect((turns[0].startedAt ?? .distantPast) < (turns[1].startedAt ?? .distantPast))
    }

    @Test("a turn without its answer is the same steps")
    func withoutAnswer() {
        let full = NeuralTurns.partition(messages: NeuralDemo.turn(), running: false)[0]
        let bare = NeuralTurns.partition(messages: NeuralDemo.turn(answer: false), running: false)[0]
        #expect(full.steps.count == bare.steps.count)
        #expect(!full.answerPartIDs.isEmpty)
        #expect(bare.answerPartIDs.isEmpty)
    }
}
