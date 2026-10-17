import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

enum AccountFixtures {
    typealias NF = NeuralTurnFixtures

    static let utc = TimeZone(identifier: "UTC")!

    /// thought, two commands, a note, an edit, a read, a command that fails, a note of eight
    /// lines, the same command again, and the final message.
    static func messages(answer: Bool = true, streaming: Bool = false, secondNote: String? = nil) -> [ChatMessage] {
        let long = secondNote ?? (1...8).map { "line \($0) of the second note" }.joined(separator: "\n")
        var out: [ChatMessage] = [
            NF.user(0),
            NF.message(1, [.reasoning("Plan it.\nSecond line.")], model: "fable"),
            NF.message(2, [NF.bash("ls", out: ["a"]), NF.bash("pwd", out: ["/x"])], model: "fable"),
            NF.message(3, [.text("Building it from the existing film rig; checking the iOS footage first.")], model: "fable"),
            NF.message(4, [NF.edit("src/Chat/Rows.swift", added: 3, removed: 1), NF.read("src/Chat/Other.swift", out: ["x"])], model: "fable"),
            NF.message(5, [NF.bash("make all", out: ["error: no rule"], status: .error)], model: "fable"),
            NF.message(6, [.text(long)], model: "fable"),
            NF.message(7, [NF.bash("make all", out: ["built"])], model: "fable", effort: nil),
        ]
        if answer { out.append(NF.message(8, [.text("All built.\nSecond line of the answer.")], streaming: streaming, model: "fable")) }
        return out
    }

    static func model(_ messages: [ChatMessage]? = nil, running: Bool = false) -> NeuralBrainModel {
        BrainFixtures.model(NeuralTurns.partition(messages: messages ?? self.messages(), running: running)[0])
    }

    static func account(_ model: NeuralBrainModel, answer: String? = "All built.\nSecond line of the answer.") -> NeuralAccount {
        model.account(tz: utc, answer: answer)
    }
}

@Suite("Neural account items")
struct NeuralAccountItemTests {
    typealias A = AccountFixtures

    private func kinds(_ account: NeuralAccount) -> [String] {
        account.items.map {
            switch $0 {
            case .said: return "said"
            case .thought: return "thought"
            case .work: return "work"
            case .ask: return "ask"
            case .answer: return "answer"
            }
        }
    }

    @Test("the turn reads as thought, work, said, work, said, work, answer, in the transcript's order")
    func order() {
        let account = A.account(A.model())
        #expect(kinds(account) == ["thought", "work", "said", "work", "said", "work", "answer"])
        #expect(account.utteranceCount == 2)
        #expect(account.thoughtCount == 1)
        #expect(!account.needsYou)
        #expect(account.askItem == nil)
        #expect(account.speaker == "Fable")
    }

    @Test("a said note carries its words whole, the speaker, the clock, its step id and number")
    func said() throws {
        let model = A.model()
        let account = A.account(model)
        guard case .said(let first) = account.items[2] else {
            Issue.record("expected a note")
            return
        }
        #expect(first.stepID == model.steps[3].id)
        #expect(first.number == 4)
        #expect(first.id == "said:" + model.steps[3].id)
        #expect(first.speaker == "Fable" && first.family == .fable)
        #expect(first.clock == "13:46:43")
        #expect(first.text == "Building it from the existing film rig; checking the iOS footage first.")
        #expect(first.showsSpeaker)
        #expect(!first.hasMore && first.lineCount == 1)
        guard case .said(let second) = account.items[4] else {
            Issue.record("expected a second note")
            return
        }
        #expect(second.lineCount == 8 && second.collapsedLines == 6 && second.hasMore)
        #expect(second.text.hasPrefix("line 1 of the second note"))
        #expect(!second.showsSpeaker)
    }

    @Test("the speaker is written again when the speaker or a long pause changes")
    func speakerGap() {
        var messages = A.messages()
        let gap = NeuralTurnFixtures.date(3).addingTimeInterval(120)
        messages[6] = ChatMessage(
            id: "m6", role: .assistant, agentType: .claudeCode,
            parts: [MessagePart(id: "p0", kind: .text("After a pause."))], createdAt: gap,
            completedAt: gap.addingTimeInterval(0.5), modelID: "fable")
        let account = A.account(A.model(messages))
        guard case .said(let late) = account.items[4] else {
            Issue.record("expected a note")
            return
        }
        #expect(late.showsSpeaker)
    }

    @Test("a thought is one muted line with the rest to unfold")
    func thought() {
        let model = A.model()
        guard case .thought(let thought) = A.account(model).items[0] else {
            Issue.record("expected a thought")
            return
        }
        #expect(thought.firstLine == "Plan it.")
        #expect(thought.text == "Plan it.\nSecond line.")
        #expect(thought.canUnfold && thought.lineCount == 2)
        #expect(thought.stepID == model.steps[0].id && thought.number == 1)
    }

    @Test("the steps between two utterances fold to one work line with marks, counts and the words")
    func work() {
        let model = A.model()
        let account = A.account(model)
        guard case .work(let first) = account.items[1] else {
            Issue.record("expected work")
            return
        }
        #expect(first.stepIDs == [model.steps[1].id, model.steps[2].id])
        #expect(first.numbers == [2, 3])
        #expect(first.clusters == [NeuralAccount.Cluster(zone: .shell, count: 2, failed: 0)])
        #expect(first.words == "Ran 2 commands.")
        #expect(first.failureCount == 0 && first.firstFailedStepID == nil)
        #expect(first.changes.isEmpty && first.tally == nil)
        #expect(first.id == "work:" + model.steps[1].id)
    }

    @Test("a work line names its failures, where they were retried and the files it changed")
    func workDetails() {
        let model = A.model()
        let account = A.account(model)
        guard case .work(let work) = account.items[3] else {
            Issue.record("expected work")
            return
        }
        #expect(work.numbers == [5, 6, 7])
        #expect(work.clusters == [
            NeuralAccount.Cluster(zone: .act, count: 1, failed: 0),
            NeuralAccount.Cluster(zone: .sense, count: 1, failed: 0),
            NeuralAccount.Cluster(zone: .shell, count: 1, failed: 1),
        ])
        #expect(work.failureCount == 1)
        #expect(work.firstFailedStepID == model.steps[6].id)
        #expect(work.retries == [
            NeuralAccount.Retry(failedStepID: model.steps[6].id, retryStepID: model.steps[8].id, number: 9, label: "retried at 9")
        ])
        #expect(work.changes.count == 1)
        #expect(work.changes[0].fileName == "Rows.swift")
        #expect(work.changes[0].shortDirectory == "\u{2026}/Chat/")
        #expect(work.added == 3 && work.removed == 1)
        #expect(work.tally == "+3 \u{2212}1")
        #expect(work.words == "Ran 1 command, read 1 file, edited 1 file.")
    }

    @Test("clusters merge a run of one zone and keep the order")
    func clusters() {
        let messages = [
            NeuralTurnFixtures.user(0),
            NeuralTurnFixtures.message(1, [
                NeuralTurnFixtures.bash("a", out: ["x"]), NeuralTurnFixtures.bash("b", out: ["x"]),
                NeuralTurnFixtures.read("f", out: ["x"]), NeuralTurnFixtures.bash("c", out: ["x"]),
            ]),
        ]
        let account = A.account(A.model(messages), answer: nil)
        guard case .work(let work) = account.items[0] else {
            Issue.record("expected work")
            return
        }
        #expect(work.clusters.map(\.zone) == [.shell, .sense, .shell])
        #expect(work.clusters.map(\.count) == [2, 1, 1])
    }

    @Test("the answer is the first line of the final message once the turn is over, and nothing while it runs")
    func answer() {
        let settled = A.account(A.model())
        #expect(settled.answer?.firstLine == "All built.")
        #expect(settled.answer?.label == "Then it answered")
        guard case .answer(let item) = settled.items.last else {
            Issue.record("expected the answer last")
            return
        }
        #expect(item.firstLine == "All built.")
        #expect(settled.answer?.id == "answer:" + A.model().turn.id)
        let running = A.account(A.model(A.messages(answer: false), running: true))
        #expect(running.answer == nil)
        #expect(kinds(running).last == "work")
        let withoutText = A.account(A.model(), answer: nil)
        #expect(withoutText.answer != nil && withoutText.answer?.firstLine == nil)
        let silent = A.account(A.model(A.messages(answer: false)), answer: nil)
        #expect(silent.answer == nil)
    }

    @Test("an approval the agent waits on leads the items, in its own words with the reason before it")
    func ask() throws {
        let (turn, id) = ReadoutFixtures.waitingTurn()
        let model = BrainFixtures.model(turn)
        let account = A.account(model, answer: nil)
        #expect(account.needsYou)
        guard case .ask(let ask) = account.items[0] else {
            Issue.record("the ask leads")
            return
        }
        #expect(ask.stepID == id && ask.number == 2)
        #expect(ask.isApproval)
        #expect(ask.sentence == "Waiting for your approval")
        #expect(ask.actionLabel == "Go to approval")
        #expect(ask.subject == "rm -rf build" && ask.subjectKind == .command)
        #expect(ask.why?.text == "I need to remove it.")
        #expect(ask.options.isEmpty)
        #expect(account.askItem == ask)
        #expect(account.story.count == account.items.count - 1)
        #expect(!account.story.contains { if case .ask = $0 { return true } else { return false } })
        guard case .work(let work)? = account.item(containing: id) else {
            Issue.record("the step still belongs to its work line")
            return
        }
        #expect(work.stepIDs == [id])
    }

    @Test("a question names its question and its options and goes to the question")
    func question() throws {
        let call = ToolCall(
            id: "q", name: "AskUserQuestion", status: .running,
            input: .object([
                "questions": .array([
                    .object([
                        "question": .string("Which build?"), "header": .string("Build"),
                        "options": .array([
                            .object(["label": .string("Debug"), "description": .string("fast")]),
                            .object(["label": .string("Release"), "description": .string("slow")]),
                        ]),
                        "multiSelect": .bool(false),
                    ])
                ])
            ]))
        let turn = NeuralTurns.partition(
            messages: [NeuralTurnFixtures.user(0), NeuralTurnFixtures.message(1, [.tool(call)], streaming: true)],
            running: true, awaiting: NeuralAwaiting(answers: ["q"]))[0]
        let account = A.account(BrainFixtures.model(turn), answer: nil)
        guard case .ask(let ask)? = account.items.first else {
            Issue.record("expected the ask: \(turn.steps.map(\.status)) \(account.items.count)")
            return
        }
        #expect(!ask.isApproval)
        #expect(ask.sentence == "Waiting for your answer" && ask.actionLabel == "Go to question")
        #expect(ask.subject == "Which build?")
        #expect(ask.options == ["Debug", "Release"])
    }
}

@Suite("Neural account walking")
struct NeuralAccountWalkTests {
    typealias A = AccountFixtures

    @Test("a step finds the item it belongs to, a said or thought step being its own")
    func containing() {
        let model = A.model()
        let account = A.account(model)
        #expect(account.item(containing: model.steps[3].id)?.id == "said:" + model.steps[3].id)
        #expect(account.item(containing: model.steps[0].id)?.id == "thought:" + model.steps[0].id)
        #expect(account.item(containing: model.steps[2].id)?.id == "work:" + model.steps[1].id)
        #expect(account.item(containing: model.steps[7].id)?.id == "said:" + model.steps[7].id)
        #expect(account.item(containing: "nope") == nil)
        for item in account.items { for id in item.stepIDs { #expect(account.item(containing: id) != nil) } }
    }

    @Test("next and previous said go from any step, never wrap, and number the notes")
    func saidWalk() {
        let model = A.model()
        let account = A.account(model)
        let first = model.steps[3].id
        let second = model.steps[7].id
        #expect(account.nextSaid(after: nil)?.stepID == first)
        #expect(account.nextSaid(after: model.steps[0].id)?.stepID == first)
        #expect(account.nextSaid(after: first)?.stepID == second)
        #expect(account.nextSaid(after: second) == nil)
        #expect(account.previousSaid(before: nil)?.stepID == second)
        #expect(account.previousSaid(before: second)?.stepID == first)
        #expect(account.previousSaid(before: first) == nil)
        #expect(account.nextSaid(after: model.steps[5].id)?.stepID == second)
        #expect(account.saidOrdinal(of: first) == 1 && account.saidOrdinal(of: second) == 2)
        #expect(account.saidOrdinal(of: model.steps[0].id) == nil)
    }

    @Test("next and previous item walk the story, not the pinned ask, and stop at the ends")
    func itemWalk() {
        let model = A.model()
        let account = A.account(model)
        let ids = account.items.map(\.id)
        #expect(account.nextItem(after: ids[0])?.id == ids[1])
        #expect(account.previousItem(before: ids[1])?.id == ids[0])
        #expect(account.previousItem(before: ids[0]) == nil)
        #expect(account.nextItem(after: ids[ids.count - 1]) == nil)
        #expect(account.position(of: ids[2]) == 2)
        let (turn, _) = ReadoutFixtures.waitingTurn()
        let asked = A.account(BrainFixtures.model(turn), answer: nil)
        let askID = asked.items[0].id
        #expect(asked.nextItem(after: askID) == nil)
        #expect(asked.position(of: askID) == nil)
        #expect(asked.nextItem(after: asked.story[0].id)?.id == asked.story[1].id)
    }

    @Test("the quote is the first said words on one line, cut at a word with an ellipsis")
    func quote() {
        let account = A.account(A.model())
        #expect(account.quote(maxChars: 200) == "Building it from the existing film rig; checking the iOS footage first.")
        let cut = account.quote(maxChars: 30)
        #expect(cut == "Building it from the existing\u{2026}")
        #expect(account.quoteLine(maxChars: 40)?.hasPrefix("Fable: ") == true)
        #expect(account.quoteLine(maxChars: 200) == "Fable: Building it from the existing film rig; checking the iOS footage first.")
        let none = NeuralTurns.partition(messages: [
            NeuralTurnFixtures.user(0), NeuralTurnFixtures.message(1, [NeuralTurnFixtures.bash("ls", out: ["a"])]),
        ], running: false)[0]
        #expect(A.account(BrainFixtures.model(none), answer: nil).quote(maxChars: 80) == nil)
        for width in 10...120 {
            let text = account.quote(maxChars: width) ?? ""
            #expect(text.count <= width + 1)
            #expect(!text.contains("\n"))
        }
        #expect(NeuralAccount.speakerName(modelID: nil) == "Agent")
        #expect(NeuralAccount.speakerName(modelID: "gpt-5") == "GPT")
        #expect(NeuralAccount.speakerName(modelID: "ollama/some-unknown-model") == "some-unknown-model")
    }

    @Test("a streamed token changes only the last item, and every other item keeps its id and its content")
    func streaming() {
        func account(_ note: String) -> NeuralAccount {
            let messages = [
                NeuralTurnFixtures.user(0),
                NeuralTurnFixtures.message(1, [NeuralTurnFixtures.bash("ls", out: ["a"])], model: "fable"),
                NeuralTurnFixtures.message(2, [.text(note)], streaming: true, model: "fable"),
                NeuralTurnFixtures.message(3, [NeuralTurnFixtures.bash("pwd", status: .running)], streaming: true, model: "fable"),
            ]
            return A.account(A.model(messages, running: true), answer: nil)
        }
        let before = account("Checking")
        let after = account("Checking the footage")
        #expect(before.items.map(\.id) == after.items.map(\.id))
        #expect(before.items[0] == after.items[0])
        #expect(before.items != after.items)
        guard case .said(let grown) = after.items[1] else {
            Issue.record("expected a note")
            return
        }
        #expect(grown.text == "Checking the footage")
    }

    @Test("the model reads the account once per change, however often it is asked")
    func memo() {
        let model = A.model()
        #expect(model.accountReads == 0)
        let first = model.account(tz: A.utc)
        _ = model.account(tz: A.utc)
        _ = model.account(tz: A.utc)
        #expect(model.accountReads == 1)
        #expect(model.account(tz: A.utc) == first)
        _ = model.account(tz: TimeZone(identifier: "Asia/Tokyo")!)
        #expect(model.accountReads == 2)
        var live = A.model(A.messages(answer: false), running: true)
        _ = live.account(tz: A.utc)
        let reads = live.accountReads
        live.update(turn: NeuralTurns.partition(messages: A.messages(answer: false), running: true)[0], context: .none)
        _ = live.account(tz: A.utc)
        #expect(live.accountReads == reads)
        func ending(_ tail: [ChatMessage]) -> [ChatMessage] {
            Array(A.messages(answer: false).prefix(7)) + tail
        }
        let note = NeuralTurnFixtures.message(7, [.text("A longer second note")], streaming: true, model: "fable")
        let tool = NeuralTurnFixtures.message(8, [NeuralTurnFixtures.bash("make", status: .running)], streaming: true, model: "fable")
        live.update(turn: NeuralTurns.partition(messages: ending([note]), running: true)[0], context: .none)
        let streamed = live.account(tz: A.utc)
        let readsBefore = live.accountReads
        _ = live.account(tz: A.utc)
        #expect(live.accountReads == readsBefore)
        #expect(streamed.utteranceCount == 1)
        live.update(turn: NeuralTurns.partition(messages: ending([note, tool]), running: true)[0], context: .none)
        let grown = live.account(tz: A.utc)
        #expect(live.accountReads == readsBefore + 1)
        #expect(grown.utteranceCount == 3)
        #expect(Array(grown.items.prefix(streamed.items.count)) == streamed.items)
        #expect(grown.items.count == streamed.items.count + 3)
        guard case .said(let said) = grown.items[streamed.items.count + 1] else {
            Issue.record("expected the note to become said once a call follows it")
            return
        }
        #expect(said.text == "A longer second note")
    }

    @Test("the account of a large turn is read once and is linear")
    func large() {
        let steps = StepListFixtures.synthetic(2_000)
        let turn = NeuralTurn(id: "big", steps: steps, answerPartIDs: ["a"], outcome: .settled)
        let model = BrainFixtures.model(turn)
        let clock = ContinuousClock()
        var account: NeuralAccount?
        let elapsed = clock.measure { account = model.account(tz: A.utc, answer: "done") }
        #expect(account?.items.isEmpty == false)
        #expect(account?.utteranceCount == 333)
        #expect(account?.thoughtCount == 334)
        let parts = elapsed.components
        #expect(Double(parts.seconds) + Double(parts.attoseconds) / 1e18 < 2)
        let again = clock.measure { _ = model.account(tz: A.utc, answer: "done") }
        #expect(again < elapsed || model.accountReads == 1)
        #expect(model.accountReads == 1)
    }
}
