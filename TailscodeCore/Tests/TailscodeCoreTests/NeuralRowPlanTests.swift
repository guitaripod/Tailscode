import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Neural row plan")
struct NeuralRowPlanTests {
    typealias Fixtures = NeuralTurnFixtures

    private func conversation() -> [ChatMessage] {
        [
            Fixtures.user(0, "first"),
            Fixtures.message(1, [.reasoning("Plan it."), Fixtures.read("a/b/c.swift")]),
            Fixtures.message(2, [Fixtures.bash("make"), .text("Built.")]),
            Fixtures.user(3, "second"),
            Fixtures.message(4, [.text("Just words.")]),
            Fixtures.user(5, "third"),
            Fixtures.message(6, [Fixtures.edit("a.swift", added: 2, removed: 1)]),
            Fixtures.message(7, [.text("Edited.")]),
        ]
    }

    @Test("the TURN fixture anchors at its first member part and skips every member")
    func turnFixture() throws {
        let turn = BrainFixtures.turn()
        let plan = NeuralRowPlan(turns: [turn])
        #expect(plan.anchors == ["m1:p0": "m1"])
        #expect(plan.skip == turn.memberPartIDs)
        #expect(plan.skip.count == turn.memberPartIDs.count)
        #expect(plan.turnForPart.count == turn.memberPartIDs.count)
        #expect(plan.turnForPart.values.allSatisfy { $0 == "m1" })
        #expect(plan.order == ["m1"])
        #expect(plan.turns["m1"] == turn)
        #expect(!plan.skip.contains("m27:p0"))
        #expect(!plan.skip.contains("m27:p1"))
    }

    @Test("a card tool is a node but keeps its own row")
    func cardsAreNotSkipped() throws {
        let turn = BrainFixtures.turn()
        let cards = turn.steps.filter(\.isCard)
        #expect(cards.count == 1)
        let plan = NeuralRowPlan(turns: [turn])
        for card in cards { #expect(!plan.skips(card.id)) }
        #expect(turn.steps.count - cards.count == plan.skip.count)
    }

    @Test("BUILD_FIX anchors at its thought and skips its reads, edits and commands")
    func buildFix() {
        let turn = BrainFixtures.buildFix()
        let plan = NeuralRowPlan(turns: [turn])
        #expect(plan.anchors == ["m1:p0": "m1"])
        #expect(plan.skips("m1:p0"))
        #expect(plan.skips("m2:p1"))
        #expect(!plan.skips("m13:p0"))
        #expect(plan.turnID(anchoredAt: "m1:p0") == "m1")
        #expect(plan.turnID(anchoredAt: "m1:p1") == nil)
        #expect(plan.turn(anchoredAt: "m1:p0") == turn)
    }

    @Test("each turn of a conversation has its own anchor, and a turn with no steps has none")
    func conversationPlan() {
        let turns = NeuralTurns.partition(messages: conversation(), running: false)
        #expect(turns.count == 3)
        let plan = NeuralRowPlan(turns: turns)
        #expect(plan.anchors == ["m1:p0": "m1", "m6:p0": "m6"])
        #expect(plan.order == ["m1", "m6"])
        #expect(plan.skips("m1:p1"))
        #expect(plan.skips("m2:p0"))
        #expect(!plan.skips("m2:p1"))
        #expect(!plan.skips("m4:p0"))
        #expect(plan.turnForPart["m6:p0"] == "m6")
        #expect(plan.turnForPart["m4:p0"] == nil)
        #expect(plan.turns["m4"] == nil)
    }

    @Test("a turn made only of cards anchors at its first step")
    func cardOnly() throws {
        let messages = [
            Fixtures.user(0),
            Fixtures.message(1, [Fixtures.task("review", out: ["fine"])]),
        ]
        let turn = NeuralTurns.partition(messages: messages, running: false)[0]
        #expect(turn.steps.count == 1)
        #expect(turn.memberPartIDs.isEmpty)
        let plan = NeuralRowPlan(turns: [turn])
        #expect(plan.anchors == ["m1:p0": "m1"])
        #expect(plan.skip.isEmpty)
    }

    @Test("the Lines style plans nothing")
    func linesStyle() {
        let turns = NeuralTurns.partition(messages: conversation(), running: false)
        #expect(NeuralRowPlan.isEnabled(style: .brain))
        #expect(!NeuralRowPlan.isEnabled(style: .lines))
        let lines = NeuralRowPlan(turns: turns, style: .lines)
        #expect(lines == .empty)
        #expect(lines.isEmpty)
        #expect(lines.anchors.isEmpty)
        #expect(lines.skip.isEmpty)
        #expect(!NeuralRowPlan(turns: turns, style: .brain).isEmpty)
    }

    @Test("a running turn is planned as its steps arrive")
    func running() {
        var messages = [
            Fixtures.user(0),
            Fixtures.message(1, [.text("Starting")], streaming: true),
        ]
        var plan = NeuralRowPlan(turns: NeuralTurns.partition(messages: messages, running: true))
        #expect(plan.isEmpty)
        messages[1] = Fixtures.message(
            1, [Fixtures.bash("ls", status: .running)], streaming: true)
        plan = NeuralRowPlan(turns: NeuralTurns.partition(messages: messages, running: true))
        #expect(plan.anchors == ["m1:p0": "m1"])
        #expect(plan.skips("m1:p0"))
    }

    @Test("the same turns plan the same way")
    func deterministic() {
        let turns = NeuralTurns.partition(messages: conversation(), running: false)
        #expect(NeuralRowPlan(turns: turns) == NeuralRowPlan(turns: turns))
    }
}
