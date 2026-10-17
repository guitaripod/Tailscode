import Foundation
import Testing

@testable import TailscodeCore

@Suite("Neural open policy")
struct NeuralOpenPolicyTests {
    private func policy(
        _ ids: [String], running: Bool = false, choices: [String: Bool] = [:]
    ) -> NeuralOpenPolicy {
        NeuralOpenPolicy(turnIDs: ids, isRunning: running, choices: choices)
    }

    @Test("the latest turn is open by default and no other")
    func defaults() {
        let policy = policy(["a", "b", "c"])
        #expect(policy.latest == "c")
        #expect(policy.openTurnID == "c")
        #expect(policy.isOpen(turnID: "c"))
        #expect(!policy.isOpen(turnID: "a"))
        #expect(!policy.isOpen(turnID: "b"))
        #expect(NeuralOpenPolicy(turnIDs: []).openTurnID == nil)
        #expect(!NeuralOpenPolicy(turnIDs: []).isOpen(turnID: "a"))
    }

    @Test("a running turn is the live brain and a settled one is not")
    func live() {
        #expect(policy(["a"], running: true).openBrainIsLive)
        #expect(!policy(["a"], running: false).openBrainIsLive)
        let closed = policy(["a"], running: true).toggle(turnID: "a")
        #expect(!policy(["a"], running: true, choices: closed).openBrainIsLive)
    }

    @Test("the person closes the latest turn and it stays closed")
    func closeLatest() {
        let choices = policy(["a", "b"]).toggle(turnID: "b")
        let closed = policy(["a", "b"], choices: choices)
        #expect(closed.openTurnID == nil)
        #expect(!closed.isOpen(turnID: "b"))
        let reopened = policy(["a", "b"], choices: closed.toggle(turnID: "b"))
        #expect(reopened.openTurnID == "b")
    }

    @Test("opening an older turn closes the latest, and only one brain is ever open")
    func openOlder() {
        let choices = policy(["a", "b", "c"]).toggle(turnID: "a")
        let next = policy(["a", "b", "c"], choices: choices)
        #expect(next.openTurnID == "a")
        #expect(next.isOpen(turnID: "a"))
        #expect(!next.isOpen(turnID: "c"))
        let other = policy(["a", "b", "c"], choices: next.toggle(turnID: "b"))
        #expect(other.openTurnID == "b")
        #expect(!other.isOpen(turnID: "a"))
        #expect(!other.isOpen(turnID: "c"))
        let backToLatest = policy(["a", "b", "c"], choices: other.toggle(turnID: "c"))
        #expect(backToLatest.openTurnID == "c")
        #expect(!backToLatest.isOpen(turnID: "b"))
    }

    @Test("closing the open older turn leaves nothing open")
    func closeOlder() {
        let opened = policy(["a", "b"], choices: policy(["a", "b"]).toggle(turnID: "a"))
        let closed = policy(["a", "b"], choices: opened.toggle(turnID: "a"))
        #expect(closed.openTurnID == nil)
    }

    @Test("a newer turn drops every choice and only the latest default applies")
    func newerTurnDropsChoices() {
        let choices = policy(["a", "b"]).toggle(turnID: "a")
        #expect(policy(["a", "b"], choices: choices).openTurnID == "a")
        let after = policy(["a", "b", "c"], choices: choices)
        #expect(!after.choicesAreCurrent)
        #expect(after.currentChoices.isEmpty)
        #expect(after.openTurnID == "c")
        #expect(!after.isOpen(turnID: "a"))

        let closedLatest = policy(["a", "b"]).toggle(turnID: "b")
        let newer = policy(["a", "b", "c"], choices: closedLatest)
        #expect(newer.openTurnID == "c")
        #expect(!newer.isOpen(turnID: "b"))
    }

    @Test("toggling after a newer turn starts from the default")
    func toggleAfterNewer() {
        let stale = policy(["a", "b"]).toggle(turnID: "a")
        let fresh = policy(["a", "b", "c"], choices: stale)
        let toggled = fresh.toggle(turnID: "b")
        #expect(toggled["a"] == nil)
        #expect(toggled["b"] == true)
        #expect(toggled["c"] == false)
        #expect(policy(["a", "b", "c"], choices: toggled).openTurnID == "b")
    }

    @Test("toggling an unknown turn changes nothing")
    func unknown() {
        let choices = policy(["a", "b"]).toggle(turnID: "z")
        #expect(choices.isEmpty)
        let kept = policy(["a", "b"], choices: ["b": false]).toggle(turnID: "z")
        #expect(kept == ["b": false])
    }

    @Test("two entries marked open still show one brain, the newest")
    func hardened() {
        let policy = policy(["a", "b", "c"], choices: ["a": true, "b": true, "c": false])
        #expect(policy.openTurnID == "b")
    }

    @Test("a choice for a turn the conversation no longer holds is forgotten")
    func forgets() {
        let policy = policy(["b", "c"], choices: ["a": true, "b": true, "c": false])
        #expect(policy.currentChoices == ["b": true, "c": false])
        #expect(policy.toggle(turnID: "c")["a"] == nil)
    }

    @Test("an explicit latest is honoured over the last id")
    func explicitLatest() {
        let policy = NeuralOpenPolicy(turnIDs: ["a", "b", "c"], latest: "b")
        #expect(policy.openTurnID == "b")
    }

    @Test("a turn is a brain with one step, and its row id is the turn's")
    func brainsAndRows() {
        let empty = NeuralTurn(id: "m4")
        #expect(!NeuralOpenPolicy.isBrain(turn: empty))
        let one = NeuralTurn(id: "m4", steps: [ReadingFixtures.step(0, .shell, "Bash")])
        #expect(NeuralOpenPolicy.isBrain(turn: one))
        #expect(NeuralOpenPolicy.rowID(turn: one) == "brain:m4")
        #expect(NeuralOpenPolicy.rowID(turnID: "x") == "brain:x")
        #expect(NeuralOpenPolicy.turnID(forRowID: "brain:m4") == "m4")
        #expect(NeuralOpenPolicy.turnID(forRowID: "m4:p0") == nil)
        #expect(NeuralOpenPolicy.turnID(forRowID: "brain:") == nil)
    }

    @Test("a policy reads its turns from the turns themselves")
    func fromTurns() {
        let turns = [NeuralTurn(id: "a"), NeuralTurn(id: "b")]
        let policy = NeuralOpenPolicy(turns: turns, isRunning: true)
        #expect(policy.turnIDs == ["a", "b"])
        #expect(policy.latest == "b")
        #expect(policy.isRunning)
    }
}
