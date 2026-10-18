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

    @Test("every turn is closed until the person opens one, the latest and the running one included")
    func defaults() {
        let fresh = policy(["a", "b", "c"])
        #expect(fresh.latest == "c")
        #expect(fresh.openTurnID == nil)
        #expect(!fresh.isOpen(turnID: "c"))
        #expect(!fresh.isOpen(turnID: "a"))
        #expect(policy(["a", "b", "c"], running: true).openTurnID == nil)
        #expect(!policy(["a"], running: true).openBrainIsLive)
        #expect(NeuralOpenPolicy(turnIDs: []).openTurnID == nil)
        #expect(!NeuralOpenPolicy(turnIDs: []).isOpen(turnID: "a"))
    }

    @Test("opening the running turn makes it the live brain, closing it does not")
    func live() {
        let opened = policy(["a"], running: true).toggle(turnID: "a")
        #expect(policy(["a"], running: true, choices: opened).openBrainIsLive)
        #expect(!policy(["a"], running: false, choices: opened).openBrainIsLive)
        let closed = policy(["a"], running: true, choices: opened).toggle(turnID: "a")
        #expect(!policy(["a"], running: true, choices: closed).openBrainIsLive)
    }

    @Test("the person opens the latest turn, closes it, and it stays closed")
    func openAndCloseLatest() {
        let opened = policy(["a", "b"], choices: policy(["a", "b"]).toggle(turnID: "b"))
        #expect(opened.openTurnID == "b")
        let closed = policy(["a", "b"], choices: opened.toggle(turnID: "b"))
        #expect(closed.openTurnID == nil)
        #expect(!closed.isOpen(turnID: "b"))
        let reopened = policy(["a", "b"], choices: closed.toggle(turnID: "b"))
        #expect(reopened.openTurnID == "b")
    }

    @Test("opening one turn closes the other, and only one brain is ever open")
    func openOne() {
        let ids = ["a", "b", "c"]
        let first = policy(ids, choices: policy(ids).toggle(turnID: "a"))
        #expect(first.openTurnID == "a")
        let second = policy(ids, choices: first.toggle(turnID: "b"))
        #expect(second.openTurnID == "b")
        #expect(!second.isOpen(turnID: "a") && !second.isOpen(turnID: "c"))
        let third = policy(ids, choices: second.toggle(turnID: "c"))
        #expect(third.openTurnID == "c")
        #expect(!third.isOpen(turnID: "b"))
        #expect(ids.filter { third.isOpen(turnID: $0) }.count == 1)
    }

    @Test("closing the open turn leaves nothing open")
    func closeOpen() {
        let opened = policy(["a", "b"], choices: policy(["a", "b"]).toggle(turnID: "a"))
        let closed = policy(["a", "b"], choices: opened.toggle(turnID: "a"))
        #expect(closed.openTurnID == nil)
    }

    @Test("a new turn never opens itself and never closes what the person opened")
    func newTurnLeavesChoicesAlone() {
        let choices = policy(["a", "b"]).toggle(turnID: "a")
        #expect(policy(["a", "b"], choices: choices).openTurnID == "a")
        let after = policy(["a", "b", "c"], running: true, choices: choices)
        #expect(after.choicesAreCurrent)
        #expect(after.openTurnID == "a")
        #expect(after.isOpen(turnID: "a") && !after.isOpen(turnID: "c"))
        let afterTwo = policy(["a", "b", "c", "d"], choices: choices)
        #expect(afterTwo.openTurnID == "a")

        let closed = policy(["a", "b"]).toggle(turnID: "b")
        let closedAgain = policy(["a", "b"], choices: closed).toggle(turnID: "b")
        let newer = policy(["a", "b", "c"], choices: closedAgain)
        #expect(newer.openTurnID == nil)
    }

    @Test("toggling after a newer turn keeps the choice the person made and opens the pressed one")
    func toggleAfterNewer() {
        let earlier = policy(["a", "b"]).toggle(turnID: "a")
        let fresh = policy(["a", "b", "c"], choices: earlier)
        let toggled = fresh.toggle(turnID: "b")
        #expect(toggled["a"] == false)
        #expect(toggled["b"] == true)
        #expect(toggled["c"] == nil)
        #expect(policy(["a", "b", "c"], choices: toggled).openTurnID == "b")
    }

    @Test("a relaunch has no choices and so no open brain")
    func relaunch() {
        #expect(policy(["a", "b", "c"], choices: [:]).openTurnID == nil)
    }

    @Test("toggling an unknown turn changes nothing")
    func unknown() {
        let choices = policy(["a", "b"]).toggle(turnID: "z")
        #expect(choices.isEmpty)
        let kept = policy(["a", "b"], choices: ["b": false]).toggle(turnID: "z")
        #expect(kept == ["b": false])
    }

    @Test("two entries marked open still show one brain, the newest, and a press leaves just one")
    func hardened() {
        let policy = policy(["a", "b", "c"], choices: ["a": true, "b": true, "c": false])
        #expect(policy.openTurnID == "b")
        let closed = policy.toggle(turnID: "b")
        #expect(closed["a"] == false && closed["b"] == false)
        #expect(NeuralOpenPolicy(turnIDs: ["a", "b", "c"], choices: closed).openTurnID == nil)
    }

    @Test("a choice for a turn the conversation no longer holds is forgotten")
    func forgets() {
        let policy = policy(["b", "c"], choices: ["a": true, "b": true, "c": false])
        #expect(policy.currentChoices == ["b": true, "c": false])
        #expect(policy.toggle(turnID: "c")["a"] == nil)
        #expect(!NeuralOpenPolicy(turnIDs: ["b"], choices: ["a": true]).choicesAreCurrent)
    }

    @Test("an explicit latest only says which turn is the live one")
    func explicitLatest() {
        let policy = NeuralOpenPolicy(turnIDs: ["a", "b", "c"], latest: "b")
        #expect(policy.openTurnID == nil)
        let opened = NeuralOpenPolicy(
            turnIDs: ["a", "b", "c"], latest: "b", isRunning: true, choices: ["b": true])
        #expect(opened.openBrainIsLive)
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
