import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Neural entity: header and vitals")
struct NeuralEntityHeaderTests {
    typealias A = AccountFixtures
    typealias NF = NeuralTurnFixtures

    private let ended = NeuralTurnFixtures.date(8).addingTimeInterval(0.5)

    @Test("the header names the entity, the verdict in words, the counts and the errors fixed")
    func header() {
        let account = A.account(A.model())
        let header = account.header
        #expect(header.speaker == "Fable" && header.family == .fable)
        #expect(header.verdict == .doneAfterRetries(1))
        #expect(header.verdictWord == "Done, fixed 1 error" && header.tone == .quiet)
        #expect(header.pillWord == "Done" && header.clause == "fixed 1 error on the way")
        #expect(header.stepCount == 9 && header.saidCount == 2 && header.thoughtCount == 1)
        #expect(header.fixedCount == 1 && header.unfixedCount == 0)
        #expect(header.fixedWords == "Fixed 1 error on the way")
        #expect(!header.isRunning && header.nowTitle == nil)
        #expect(header.startedAt == NF.date(1) && header.endedAt == ended)
    }

    @Test("a settled turn says when it finished and how long it took")
    func finished() {
        let account = A.account(A.model())
        let vitals = account.vitals(now: ended.addingTimeInterval(389))
        #expect(vitals.statusLine == "Finished, 6m 29s ago")
        #expect(vitals.elapsedWords == "8s")
        #expect(vitals.counts == "2 said · 9 steps · 1 error fixed")
        #expect(vitals.silentFor == nil && !vitals.isSilent && vitals.silentWords == nil)
    }

    @Test("a running turn says what it is working on and how long nothing has arrived")
    func running() {
        let model = A.model(A.messages(answer: false), running: true)
        let account = A.account(model, answer: nil)
        #expect(account.header.isRunning)
        #expect(account.header.verdict == .working)
        let last = NF.date(7)
        let fresh = account.vitals(now: last.addingTimeInterval(5))
        #expect(fresh.statusLine == "Working on: Ran the build again")
        #expect(fresh.silentFor == 5 && !fresh.isSilent)
        let quiet = account.vitals(now: last.addingTimeInterval(40))
        #expect(quiet.isSilent && quiet.silentFor == 40)
        #expect(quiet.silentWords == "silent for 40s")
        let seen = account.vitals(now: last.addingTimeInterval(40), lastActivity: last.addingTimeInterval(35))
        #expect(!seen.isSilent && seen.silentFor == 5)
        #expect(account.vitals(now: last.addingTimeInterval(40)).isSilent)
        #expect(!account.vitals(now: last.addingTimeInterval(39.9)).isSilent)
        #expect(NeuralAccount.silentAfter == 40)
        #expect(account.vitals(now: last.addingTimeInterval(65)).elapsed != nil)
    }

    @Test("needs you, stuck and the other endings each say so")
    func endings() {
        let (turn, _) = ReadoutFixtures.waitingTurn()
        let waiting = A.account(BrainFixtures.model(turn), answer: nil)
        #expect(waiting.vitals(now: NF.date(9)).statusLine == "Waiting for you")
        let stuck = A.account(BrainFixtures.model(VerdictFixtures.turn(
            [[VerdictFixtures.bash("sleep", running: true)]], running: true, awaiting: NeuralAwaiting(stalled: ["m1:p0"]))), answer: nil)
        #expect(stuck.vitals(now: NF.date(1).addingTimeInterval(40)).statusLine == "Stuck for 40s")
        let failed = A.account(BrainFixtures.model(VerdictFixtures.turn([[VerdictFixtures.bash("make", ok: false)]])), answer: nil)
        #expect(failed.header.verdictWord == "Failed")
        #expect(failed.vitals(now: NF.date(1).addingTimeInterval(61)).statusLine.hasPrefix("Failed, "))
    }
}

@Suite("Neural entity: asked, plan, live")
struct NeuralEntityPlanTests {
    typealias A = AccountFixtures
    typealias NF = NeuralTurnFixtures

    private func planTurn(_ calls: [(String, [String: JSONValue])]) -> NeuralBrainModel {
        let messages = [NF.user(0)] + calls.enumerated().map { offset, call in
            NF.message(offset + 1, [NF.tool(call.0, call.1, out: ["ok"])])
        } + [NF.message(calls.count + 1, [.text("done")])]
        return BrainFixtures.model(NeuralTurns.partition(messages: messages, running: false)[0])
    }

    private func todo(_ content: String, _ status: String, active: String? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["content": .string(content), "status": .string(status)]
        if let active { object["activeForm"] = .string(active) }
        return .object(object)
    }

    @Test("the prompt is the asked item: two lines, the whole text and Show all")
    func asked() {
        let account = A.model().account(tz: A.utc, prompt: "  Build it\nand check the footage\nthen share it  ")
        let asked = account.asked
        #expect(asked?.lines == ["Build it", "and check the footage"])
        #expect(asked?.text == "Build it\nand check the footage\nthen share it")
        #expect(asked?.lineCount == 3 && asked?.hasMore == true)
        #expect(asked?.id == "asked:" + A.model().turn.id)
        #expect(A.model().account(tz: A.utc).asked == nil)
        #expect(A.model().account(tz: A.utc, prompt: "   ").asked == nil)
        #expect(A.model().account(tz: A.utc, prompt: "one line").asked?.hasMore == false)
        let model = A.model()
        _ = model.account(tz: A.utc, prompt: "a")
        _ = model.account(tz: A.utc, prompt: "a")
        #expect(model.accountReads == 1)
        _ = model.account(tz: A.utc, prompt: "b")
        #expect(model.accountReads == 2)
    }

    @Test("a TodoWrite list is the plan: its states, the one in progress flagged, and how many are done")
    func todoWrite() throws {
        let model = planTurn([("TodoWrite", ["todos": .array([
            todo("Read the code", "completed"), todo("Write the fix", "in_progress", active: "Writing the fix"),
            todo("Run the tests", "pending"),
        ])])])
        let plan = try #require(model.account(tz: A.utc).plan)
        #expect(plan.items.map(\.text) == ["Read the code", "Write the fix", "Run the tests"])
        #expect(plan.items.map(\.state) == [.done, .inProgress, .pending])
        #expect(plan.current?.activeForm == "Writing the fix" && plan.items[1].isCurrent)
        #expect(plan.done == 1 && plan.total == 3 && plan.label == "1 of 3 done")
        #expect(plan.stepID == model.steps[0].id && plan.number == 1)
    }

    @Test("the latest list wins, and later task updates fold into it")
    func latestWins() throws {
        let model = planTurn([
            ("TodoWrite", ["todos": .array([todo("old a", "pending"), todo("old b", "pending")])]),
            ("TodoWrite", ["todos": .array([todo("a", "completed"), todo("b", "completed"), todo("c", "in_progress")])]),
        ])
        let plan = try #require(model.account(tz: A.utc).plan)
        #expect(plan.items.map(\.text) == ["a", "b", "c"] && plan.label == "2 of 3 done" && plan.number == 2)
        let incremental = planTurn([
            ("TaskCreate", ["subject": .string("first")]), ("TaskCreate", ["subject": .string("second")]),
            ("TaskUpdate", ["taskId": .string("1"), "status": .string("completed")]),
        ])
        let folded = try #require(incremental.account(tz: A.utc).plan)
        #expect(folded.items.map(\.text) == ["first", "second"])
        #expect(folded.items.map(\.state) == [.done, .pending])
    }

    @Test("other shapes and spellings are read: a plan array of steps, done and in progress")
    func tolerant() throws {
        let model = planTurn([("update_plan", ["plan": .array([
            .object(["step": .string("Inspect"), "status": .string("done")]),
            .object(["step": .string("Patch"), "status": .string("In progress")]),
            .object(["step": .string("Verify"), "status": .string("not started")]),
            .object(["step": .string("Mystery"), "status": .string("???")]),
        ])])])
        let plan = try #require(model.account(tz: A.utc).plan)
        #expect(plan.items.map(\.state) == [.done, .inProgress, .pending, .pending])
        #expect(plan.label == "1 of 4 done")
    }

    @Test("no plan, an empty list or a malformed one is nil")
    func none() {
        #expect(A.model().account(tz: A.utc).plan == nil)
        #expect(planTurn([("TodoWrite", ["todos": .array([])])]).account(tz: A.utc).plan == nil)
        #expect(planTurn([("TodoWrite", ["todos": .string("oops")])]).account(tz: A.utc).plan == nil)
        #expect(planTurn([("TodoWrite", ["todos": .array([.string("x"), .object(["status": .string("pending")])])])]).account(tz: A.utc).plan == nil)
        #expect(planTurn([("TaskUpdate", ["taskId": .string("9"), "status": .string("completed")])]).account(tz: A.utc).plan == nil)
    }

    @Test("the step in flight is a plain title, an argument, an output tail and its last line")
    func live() throws {
        let output = (1...12).map { "line \($0)" }.joined(separator: "\n")
        let messages = [
            NF.user(0),
            NF.message(1, [NF.bash("swift test --filter Neural", out: [output], status: .running)], streaming: true),
        ]
        let model = BrainFixtures.model(NeuralTurns.partition(messages: messages, running: true)[0])
        let live = try #require(model.account(tz: A.utc).live)
        #expect(live.title == "Ran the tests" && live.rawTitle == "Bash")
        #expect(live.argument == "swift test --filter Neural")
        #expect(live.verdict == .running && live.number == 1)
        #expect(live.tail.count == 8 && live.lastLine == "line 12" && live.tail.first?.text == "line 5")
        #expect(model.account(tz: A.utc).header.nowTitle == "Ran the tests")
        #expect(A.account(A.model()).live == nil)
    }
}

@Suite("Neural entity: work lines and the result")
struct NeuralEntityResultTests {
    typealias A = AccountFixtures
    typealias NF = NeuralTurnFixtures

    @Test("a work line reads as sentences with how each went, and the amber words for what was fixed")
    func workLine() throws {
        let account = A.account(A.model())
        guard case .work(let work) = account.items[3] else {
            Issue.record("expected work")
            return
        }
        #expect(work.titles == ["Edited Rows.swift (+3 \u{2212}1)", "Read Other.swift", "Built the project"])
        #expect(work.line == "Edited Rows.swift (+3 \u{2212}1), Read Other.swift, Built the project")
        #expect(work.entries.map(\.verdict) == [.done, .done, .fixed])
        #expect(work.fixedCount == 1 && work.unfixedCount == 0 && work.fixedWords == ["fixed an error at step 7"])
        guard case .work(let first) = account.items[1] else {
            Issue.record("expected work")
            return
        }
        #expect(first.titles == ["Looked at files"] && first.entries[0].count == 2)
        guard case .work(let last) = account.items[5] else {
            Issue.record("expected work")
            return
        }
        #expect(last.titles == ["Ran the build again"])
        #expect(account.items.compactMap { item -> Int? in
            if case .work(let work) = item { return work.stepIDs.count }
            return nil
        } == [2, 3, 1])
    }

    @Test("work clauses fold runs, repeats and edits, and keep the rest behind plus N more")
    func clauses() throws {
        let messages = [
            NF.user(0),
            NF.message(1, [NF.read("a.swift"), NF.read("b.swift")]),
            NF.message(2, [NF.edit("Rows.swift", added: 3, removed: 1), NF.edit("Rows.swift", added: 3, removed: 0)]),
            NF.message(3, [NF.bash("git push", out: ["ok"]), NF.bash("git push", out: ["ok"]), NF.bash("ls", out: ["a"])]),
            NF.message(4, [NF.bash("swift build", out: ["ok"]), NF.bash("pwd", out: ["a"])]),
            NF.message(5, [.text("done")]),
        ]
        let model = BrainFixtures.model(NeuralTurns.partition(messages: messages, running: false)[0])
        let account = model.account(tz: A.utc, answer: "done")
        let works = account.items.compactMap { item -> NeuralAccount.Work? in
            if case .work(let work) = item { return work }
            return nil
        }
        let work = try #require(works.first)
        let texts = work.clauseList.map(\.text)
        #expect(texts.first == "Read 2 files")
        #expect(texts.contains("Edited Rows.swift +6 \u{2212}1"))
        #expect(texts.contains("Pushed (2x)"))
        let split = work.clauses(limit: 4)
        #expect(split.shown.count == min(4, texts.count) && split.more == max(0, texts.count - 4))
    }

    private func resultTurn() -> NeuralBrainModel {
        let messages = [
            NF.user(0),
            NF.message(1, [NF.edit("Sources/Chat/Rows.swift", added: 3, removed: 1)]),
            NF.message(2, [NF.edit("Sources/Chat/Rows.swift", added: 2, removed: 0), NF.edit("Sources/Other.swift", added: 1, removed: 1)]),
            NF.message(3, [NF.bash("swift build", out: ["Rows.swift:1: error: nope"], status: .error)]),
            NF.message(4, [NF.bash("swift build", out: ["Build complete"])]),
            NF.message(5, [NF.bash("swift test", out: ["Executed 12 tests"])]),
            NF.message(6, [NF.bash("swiftlint", out: ["Rows.swift:9: error: line too long"], status: .error)]),
            NF.message(7, [NF.bash("ls", out: ["a"])]),
            NF.message(8, [.text("Everything works except the linter.\nSecond line.")]),
        ]
        return BrainFixtures.model(NeuralTurns.partition(messages: messages, running: false)[0])
    }

    @Test("the result is the files changed, the checks with their verdicts, what stayed failed and the answer")
    func result() throws {
        let model = resultTurn()
        let result = try #require(model.account(tz: A.utc, answer: "Everything works except the linter.\nSecond line.").result)
        #expect(result.changes.map(\.fileName) == ["Rows.swift", "Other.swift"])
        #expect(result.changes[0].added == 5 && result.changes[0].removed == 1 && result.changes[0].stepID == model.steps[0].id)
        #expect(result.added == 6 && result.removed == 2 && result.tally == "+6 \u{2212}2")
        #expect(result.checks.map(\.kind) == [.build, .test, .lint])
        #expect(result.checks.map(\.title) == ["Built the project", "Ran the tests", "Ran the linter"])
        #expect(result.checks.map(\.verdict) == [.fixed, .done, .failed])
        #expect(result.checks[0].retries == 1 && result.checks[0].retriesWords == "after 1 retry")
        #expect(result.checks[0].stepID == model.steps[4].id && result.checks[0].number == 5)
        #expect(result.checks[0].stepIDs == [model.steps[3].id, model.steps[4].id])
        #expect(result.checks[1].retriesWords == nil && result.checks[2].retriesWords == nil)
        #expect(result.checks.map(\.label) == ["Build", "Tests", "Lint"])
        #expect(result.checks.map(\.command) == ["swift build", "swift test", "swiftlint"])
        #expect(result.checks.map(\.verdictWords) == ["passed after 1 retry", "passed", "failed"])
        #expect(result.checks[0].numbers == [4, 5])
        #expect(result.changedWords == nil && result.answerWords == nil)
        #expect(NeuralAccount.Result.headings == ["Changed", "Checks", "Still failing", "Then it answered"])
        #expect(result.unfixed.count == 1)
        #expect(result.unfixed[0].title == "Ran the linter" && result.unfixed[0].number == 7)
        #expect(result.unfixed[0].firstLine == "Rows.swift:9: error: line too long")
        #expect(result.answer == "Everything works except the linter.")
        #expect(!result.isEmpty)
    }

    @Test("two retries read as after 2 retries, and nothing is invented for a command that is no check")
    func retries() throws {
        let messages = [
            NF.user(0),
            NF.message(1, [NF.bash("swift test", out: ["error: a"], status: .error)]),
            NF.message(2, [NF.bash("swift test", out: ["error: a"], status: .error)]),
            NF.message(3, [NF.bash("swift test", out: ["ok"])]),
            NF.message(4, [NF.bash("make all", out: ["ok"]), NF.bash("ffmpeg -i a b", out: ["ok"]), NF.bash("ls", out: ["ok"])]),
            NF.message(5, [.text("fine")]),
        ]
        let model = BrainFixtures.model(NeuralTurns.partition(messages: messages, running: false)[0])
        let result = try #require(model.account(tz: A.utc, answer: "fine").result)
        #expect(result.checks.count == 2)
        #expect(result.checks[0].retries == 2 && result.checks[0].retriesWords == "after 2 retries")
        #expect(result.checks[1].kind == .build && result.checks[1].retries == 0 && result.checks[1].verdict == .done)
        #expect(result.unfixed.isEmpty && result.changes.isEmpty)
    }

    @Test("empty parts are omitted, a running turn has no result, and a silent turn's is empty")
    func empty() throws {
        let running = A.model(A.messages(answer: false), running: true)
        #expect(running.account(tz: A.utc).result == nil)
        let messages = [NF.user(0), NF.message(1, [NF.bash("ls", out: ["a"])])]
        let model = BrainFixtures.model(NeuralTurns.partition(messages: messages, running: false)[0])
        let result = try #require(model.account(tz: A.utc).result)
        #expect(result.isEmpty && result.changes.isEmpty && result.checks.isEmpty && result.unfixed.isEmpty)
        #expect(result.answer == nil && result.tally == nil)
        #expect(result.changedWords == "It changed no files.")
        let looked = [NF.user(0), NF.message(1, [NF.read("a.swift"), NF.read("b.swift")])]
        let lookedModel = BrainFixtures.model(NeuralTurns.partition(messages: looked, running: false)[0])
        let lookedResult = try #require(lookedModel.account(tz: A.utc, answer: "Fine").result)
        #expect(lookedResult.changedWords == "It only looked: read 2 files, changed nothing.")
        let answered = try #require(model.account(tz: A.utc, answer: "Done.").result)
        #expect(!answered.isEmpty && answered.answer == "Done.")
    }

    @Test("item ids stay stable and the memo stays keyed on the revision with the new parts in")
    func stable() {
        let model = A.model()
        let first = model.account(tz: A.utc, answer: "x", prompt: "p")
        let again = model.account(tz: A.utc, answer: "x", prompt: "p")
        #expect(first == again && model.accountReads == 1)
        #expect(first.items.map(\.id) == A.account(A.model(), answer: "x").items.map(\.id))
    }
}
