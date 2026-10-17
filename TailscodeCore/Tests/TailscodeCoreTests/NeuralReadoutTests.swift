import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

enum ReadoutFixtures {
    typealias Fixtures = NeuralTurnFixtures

    static let utc = TimeZone(identifier: "UTC")!

    static func model(_ turn: NeuralTurn? = nil) -> NeuralBrainModel {
        BrainFixtures.model(turn ?? BrainFixtures.buildFix())
    }

    static func readout(
        _ model: NeuralBrainModel, _ mode: NeuralReadout.Mode, clock: Double = 0,
        answer: String? = nil
    ) -> NeuralReadout {
        NeuralReadout.make(
            model: model, subject: mode, now: Date(timeIntervalSince1970: 1_000_100), tz: utc,
            clock: clock, answer: answer)
    }

    static func step(_ model: NeuralBrainModel, _ index: Int, pinned: Bool = false) -> NeuralReadout.Step {
        var held = model
        if pinned { held.togglePin(model.steps[index].id) }
        return readout(held, .step(model.steps[index].id)).step!
    }

    static func turn(_ messages: [ChatMessage], running: Bool = false) -> NeuralTurn {
        NeuralTurns.partition(messages: messages, running: running)[0]
    }

    static func waitingTurn(running: Bool = true) -> (turn: NeuralTurn, waitingID: String) {
        let messages = [
            NeuralTurnFixtures.user(0),
            NeuralTurnFixtures.message(1, [.reasoning("I need to remove it.")]),
            NeuralTurnFixtures.message(
                2, [NeuralTurnFixtures.bash("rm -rf build", status: .running)], streaming: true),
        ]
        let turn = NeuralTurns.partition(
            messages: messages, running: running,
            awaiting: NeuralAwaiting(approvals: ["m2:p0"]))[0]
        return (turn, "m2:p0")
    }

    static func longOutput(_ count: Int) -> String {
        (0..<count).map { "out \($0)" }.joined(separator: "\n")
    }
}

@Suite("Neural readout mode")
struct NeuralReadoutModeTests {
    @Test("a settled turn with nothing chosen reads as the digest")
    func settledIsDigest() {
        let model = ReadoutFixtures.model()
        #expect(NeuralReadout.mode(for: model, hover: nil) == .digest)
        #expect(model.readoutSubject(now: 0) == .digest)
    }

    @Test("a live turn reads as Now, and a waiting step turns Now into the ask")
    func liveIsNow() {
        let live = ReadoutFixtures.model(BrainFixtures.turn(running: true))
        #expect(NeuralReadout.mode(for: live, hover: nil) == .now)
        let waiting = ReadoutFixtures.model(ReadoutFixtures.waitingTurn().turn)
        guard case .ask(let id) = NeuralReadout.mode(for: waiting, hover: nil) else {
            Issue.record("expected the ask")
            return
        }
        #expect(waiting.step(id: id)?.status == .waitingApproval)
    }

    @Test("a pinned step outranks a hovered one, which outranks everything the turn calls for")
    func pinnedThenHovered() {
        var model = ReadoutFixtures.model()
        let first = model.steps[1].id
        let second = model.steps[2].id
        #expect(NeuralReadout.mode(for: model, hover: second) == .step(second))
        model.togglePin(first)
        #expect(NeuralReadout.mode(for: model, hover: second) == .step(first))
        model.togglePin(first)
        model.startReplay(now: 0)
        model.setDive(zone: .shell)
        #expect(NeuralReadout.mode(for: model, hover: second) == .step(second))
        #expect(NeuralReadout.mode(for: model, hover: nil) == .replay)
    }

    @Test("a dived zone is listed, and a replay outranks it")
    func zoneAndReplay() {
        var model = ReadoutFixtures.model()
        model.setDive(zone: .shell)
        #expect(NeuralReadout.mode(for: model, hover: nil) == .zone(.shell))
        model.startReplay(now: 0)
        #expect(NeuralReadout.mode(for: model, hover: nil) == .replay)
        model.stopReplay()
        model.setDive(zone: nil)
        #expect(NeuralReadout.mode(for: model, hover: nil) == .digest)
    }

    @Test("the model's own hovered node counts until the client drives the hover grace")
    func hoveredFallback() {
        var model = ReadoutFixtures.model()
        model.setHover(model.steps[3].id)
        #expect(NeuralReadout.mode(for: model, hover: nil) == .step(model.steps[3].id))
        model.pointer(over: nil, at: 0)
        #expect(NeuralReadout.mode(for: model, hover: nil) == .digest)
    }

    @Test("a step id the turn does not hold falls back to what the turn calls for")
    func unknownStep() {
        let model = ReadoutFixtures.model()
        let read = ReadoutFixtures.readout(model, .step("nope"))
        #expect(read.mode == .digest)
        let live = ReadoutFixtures.model(BrainFixtures.turn(running: true))
        #expect(ReadoutFixtures.readout(live, .ask("nope")).mode == .now)
    }
}

@Suite("Neural readout step")
struct NeuralReadoutStepTests {
    typealias F = ReadoutFixtures

    @Test("the header names the zone, the status chip, the counter and the pin")
    func header() {
        let model = F.model()
        let build = F.step(model, 5, pinned: true)
        #expect(build.header.zone == .shell)
        #expect(build.header.label == NeuralZone.shell.label)
        #expect(build.header.chip.kind == .retried)
        #expect(build.header.chip.tone == .quiet)
        #expect(build.header.chip.word == "RETRIED")
        #expect(build.header.counter == "6 of 14")
        #expect(build.header.isPinned)
        let later = F.step(model, 10)
        #expect(later.header.chip.kind == .done)
        #expect(later.header.chip.tone == .live)
        #expect(!later.header.isPinned)
    }

    @Test("a failure nobody retried wears FAILED in the danger tone")
    func failedChip() {
        let messages = [
            NeuralTurnFixtures.user(0),
            NeuralTurnFixtures.message(
                1, [NeuralTurnFixtures.bash("false", out: ["boom"], status: .error)]),
        ]
        let step = F.step(F.model(F.turn(messages)), 0)
        #expect(step.header.chip.kind == .failed)
        #expect(step.header.chip.tone == .danger)
        #expect(step.header.chip.word == "FAILED")
    }

    @Test("a command is kept whole, with its line breaks, and wraps to four lines before Show all")
    func commandSubject() {
        let command = "set -e\ncd out\nmake clean\nmake all\nmake install\n"
        let messages = [
            NeuralTurnFixtures.user(0),
            NeuralTurnFixtures.message(
                1, [NeuralTurnFixtures.tool("Bash", ["command": .string(command), "description": .string("Build it")], out: ["ok"])]),
        ]
        let step = F.step(F.model(F.turn(messages)), 0)
        #expect(step.subject.kind == .command)
        #expect(step.subject.primary == "set -e\ncd out\nmake clean\nmake all\nmake install")
        #expect(step.subject.secondary == "Build it")
        #expect(step.subject.lineCount == 5)
        #expect(step.subject.collapsedLines == 4)
        #expect(step.subject.hasMore)
        #expect(step.subject.copyText == step.subject.primary)
    }

    @Test("a path splits into a dimmed directory and an emphasised name, and a search keeps its scope")
    func pathAndPattern() {
        let model = F.model()
        let read = F.step(model, 2)
        #expect(read.subject.kind == .path)
        #expect(read.subject.directory == "TailscodeLinux/Sources/Chat/")
        #expect(read.subject.fileName == "TranscriptRows.swift")
        #expect(read.subject.collapsedLines == 1)
        let grep = F.step(model, 1)
        #expect(grep.subject.kind == .pattern)
        #expect(grep.subject.primary == "case .compaction")
        #expect(grep.subject.secondary == "TailscodeLinux/Sources")
        let agent = F.step(model, 12)
        #expect(agent.subject.kind == .agent)
        #expect(agent.subject.primary.hasPrefix("Review the diff"))
        #expect(agent.subject.copyText == nil)
    }

    @Test("a fetch is a url and a thought or a note is the words themselves")
    func urlAndWords() {
        let messages = [
            NeuralTurnFixtures.user(0),
            NeuralTurnFixtures.message(
                1, [
                    .reasoning("Check the docs first.\nThen the page."),
                    NeuralTurnFixtures.tool("WebFetch", ["url": .string("https://example.com/a")], out: ["<html>"]),
                    .text("Fetched it."),
                    NeuralTurnFixtures.read("a.txt", out: ["x"]),
                ]),
        ]
        let model = F.model(F.turn(messages))
        let thought = F.step(model, 0)
        #expect(thought.subject.kind == .thought)
        #expect(thought.subject.primary == "Check the docs first.")
        guard case .text(let words)? = thought.result else {
            Issue.record("a thought's result is its text")
            return
        }
        #expect(words.text == "Check the docs first.\nThen the page.")
        #expect(words.lineCount == 2)
        #expect(thought.why == nil)
        let fetch = F.step(model, 1)
        #expect(fetch.subject.kind == .url)
        #expect(fetch.subject.primary == "https://example.com/a")
        #expect(F.step(model, 2).subject.kind == .note)
    }

    @Test("the facts carry the message and the clock and never a duration")
    func facts() {
        let model = F.model()
        let step = F.step(model, 1)
        #expect(step.facts.message == "3 calls in one message")
        #expect(step.facts.clock == "13:46:42")
        #expect(step.facts.started == "started 13:46:42")
        #expect(step.facts.turnBegan == "turn began 13:46:41")
        let lone = F.step(model, 4)
        #expect(lone.facts.message == "message 3")
        let mirror = Mirror(reflecting: step.facts)
        #expect(mirror.children.allSatisfy { !($0.label ?? "").lowercased().contains("duration") })
    }

    @Test("a ganglion's leader says which steps it gathers")
    func gathered() throws {
        let model = F.model(BrainFixtures.turn())
        let ganglion = try #require(model.layout.ganglia.first)
        let step = try #require(
            F.readout(model, .step(ganglion.leader)).step)
        #expect(step.gathered == ganglion.members)
    }
}

@Suite("Neural readout why")
struct NeuralReadoutWhyTests {
    typealias F = ReadoutFixtures

    @Test("the thought before a call is its reason")
    func thoughtBefore() {
        let model = F.model()
        let why = F.step(model, 7).why
        #expect(why?.label == "WHY")
        #expect(why?.text == "The build names .note, which my first edit did not cover.")
        #expect(why?.sourceStepID == model.steps[6].id)
        #expect(why?.isTruncated == false)
    }

    @Test("parallel calls share one reason, found by walking back over their siblings")
    func parallelCalls() {
        let model = F.model()
        let reason = model.steps[0].text
        for index in 1...3 { #expect(F.step(model, index).why?.full == reason) }
    }

    @Test("a call after another message's call has no reason, and neither has a first call")
    func noReason() {
        let model = F.model()
        #expect(F.step(model, 4).why == nil)
        #expect(F.step(model, 8).why == nil)
        let first = F.model(BrainFixtures.turn())
        #expect(F.step(first, 0).why?.sourceStepID == first.steps[0].id || F.step(first, 0).why == nil)
        let bare = F.model(F.turn([
            NeuralTurnFixtures.user(0),
            NeuralTurnFixtures.message(1, [NeuralTurnFixtures.bash("ls", out: ["a"])]),
        ]))
        #expect(F.step(bare, 0).why == nil)
    }

    @Test("a long reason is cut at 240 characters on a word, and the whole stays for Show more")
    func longReason() {
        let words = (0..<80).map { "word\($0)" }.joined(separator: " ")
        let model = F.model(F.turn([
            NeuralTurnFixtures.user(0),
            NeuralTurnFixtures.message(1, [.reasoning(words)]),
            NeuralTurnFixtures.message(2, [NeuralTurnFixtures.bash("ls", out: ["a"])]),
        ]))
        let why = F.step(model, 1).why
        #expect(why?.isTruncated == true)
        #expect(why?.full == words)
        let text = why?.text ?? ""
        #expect(text.hasSuffix("\u{2026}"))
        #expect(text.count <= 241)
        let kept = text.dropLast().split(separator: " ")
        #expect(kept.allSatisfy { $0.hasPrefix("word") && Int($0.dropFirst(4)) != nil })
    }
}

@Suite("Neural readout result")
struct NeuralReadoutResultTests {
    typealias F = ReadoutFixtures

    @Test("a shell step shows its first eight lines, counts the rest and keeps the full output")
    func shellOutput() throws {
        let output = F.longOutput(30)
        let model = F.model(F.turn([
            NeuralTurnFixtures.user(0),
            NeuralTurnFixtures.message(1, [NeuralTurnFixtures.tool("Bash", ["command": .string("seq 30")], out: [output])]),
        ]))
        guard case .shell(let shown)? = F.step(model, 0).result else {
            Issue.record("expected shell output")
            return
        }
        #expect(shown.lines.count == 8)
        #expect(shown.lines.first?.text == "out 0")
        #expect(shown.total == 30)
        #expect(shown.hiddenCount == 22)
        #expect(shown.moreLabel == "22 more lines")
        #expect(shown.lines.allSatisfy { $0.tone == .dim })
        let full = NeuralReadout.fullOutput(of: model.steps[0])
        #expect(full.count == 30)
        #expect(full.last?.text == "out 29")
    }

    @Test("failed output is danger, and the line that names the error is in full ink")
    func failedOutput() throws {
        let model = F.model()
        guard case .shell(let output)? = F.step(model, 5).result else {
            Issue.record("expected shell output")
            return
        }
        #expect(output.lines.count == 2)
        #expect(output.lines[0].tone == .emphasis)
        #expect(output.lines[0].text.contains("error: switch must be exhaustive"))
        #expect(output.lines[1].tone == .danger)
        #expect(output.moreLabel == nil)
    }

    @Test("lines match error, FAILED and fatal anywhere")
    func errorLines() {
        for line in ["x error: y", "Error: y", "BUILD FAILED", "fatal: not a repo", "FATAL ERROR"] {
            #expect(NeuralReadoutText.isErrorLine(line), Comment(rawValue: line))
        }
        for line in ["all good", "errors: 0", "failed softly"] {
            #expect(!NeuralReadoutText.isErrorLine(line), Comment(rawValue: line))
        }
    }

    @Test("an edit shows a diff of its strings with the tally of the app, removed lines first")
    func editDiff() throws {
        let model = F.model()
        guard case .edit(let edit)? = F.step(model, 4).result else {
            Issue.record("expected an edit")
            return
        }
        #expect(edit.fileName == "TranscriptRows.swift")
        #expect(edit.added == 6)
        #expect(edit.removed == 1)
        #expect(edit.tally == "+6 \u{2212}1")
        #expect(edit.lines.count == 7)
        #expect(edit.lines.first?.kind == .remove)
        #expect(edit.lines.dropFirst().allSatisfy { $0.kind == .add })
        #expect(edit.total == 7)
        #expect(edit.moreLabel == nil)
    }

    @Test("a long diff is capped at fourteen lines shared between both sides")
    func longDiff() throws {
        let old = (0..<20).map { "old \($0)" }.joined(separator: "\n")
        let new = (0..<20).map { "new \($0)" }.joined(separator: "\n")
        let model = F.model(F.turn([
            NeuralTurnFixtures.user(0),
            NeuralTurnFixtures.message(1, [
                NeuralTurnFixtures.tool("Edit", ["file_path": .string("a.swift"), "old_string": .string(old), "new_string": .string(new)], out: ["ok"])
            ]),
        ]))
        guard case .edit(let edit)? = F.step(model, 0).result else {
            Issue.record("expected an edit")
            return
        }
        #expect(edit.lines.count == 14)
        #expect(edit.lines.filter { $0.kind == .remove }.count == 7)
        #expect(edit.lines.filter { $0.kind == .add }.count == 7)
        #expect(edit.total == 40)
        #expect(edit.moreLabel == "26 more lines")
        #expect(NeuralReadout.fullDiff(of: model.steps[0]).count == 40)
    }

    @Test("a write is all additions and a read says the path and the lines it returned")
    func writeAndRead() throws {
        let model = F.model(F.turn([
            NeuralTurnFixtures.user(0),
            NeuralTurnFixtures.message(1, [
                NeuralTurnFixtures.tool("Write", ["file_path": .string("a.txt"), "content": .string("one\ntwo\n")], out: ["done"]),
                NeuralTurnFixtures.read("dir/b.txt", out: ["1\tx\n2\ty\n3\tz"]),
            ]),
        ]))
        guard case .edit(let edit)? = F.step(model, 0).result else {
            Issue.record("expected an edit")
            return
        }
        #expect(edit.lines.map(\.kind) == [.add, .add])
        #expect(edit.lines.map(\.text) == ["one", "two"])
        guard case .read(let read)? = F.step(model, 1).result else {
            Issue.record("expected a read")
            return
        }
        #expect(read.fileName == "b.txt")
        #expect(read.directory == "dir/")
        #expect(read.lines == 3)
    }

    @Test("a search shows its first matches and a subagent its summary with the Open agent action")
    func searchAndAgent() throws {
        let matches = (0..<12).map { "file.swift:\($0)" }.joined(separator: "\n")
        let model = F.model(F.turn([
            NeuralTurnFixtures.user(0),
            NeuralTurnFixtures.message(1, [
                NeuralTurnFixtures.tool("Grep", ["pattern": .string("foo"), "path": .string("src")], out: [matches]),
                NeuralTurnFixtures.task("Look around", out: ["Found it.", "Line two."]),
            ]),
        ]))
        guard case .search(let search)? = F.step(model, 0).result else {
            Issue.record("expected a search")
            return
        }
        #expect(search.pattern == "foo")
        #expect(search.scope == "src")
        #expect(search.matches.count == 8)
        #expect(search.total == 12)
        #expect(search.moreLabel == "4 more lines")
        guard case .subagent(let agent)? = F.step(model, 1).result else {
            Issue.record("expected a subagent")
            return
        }
        #expect(agent.summary == ["Found it.", "Line two."])
        #expect(agent.canOpen)
        #expect(agent.openLabel == "Open agent")
    }

    @Test("a call that has said nothing yet has no result block")
    func quietCall() {
        let model = F.model(F.turn([
            NeuralTurnFixtures.user(0),
            NeuralTurnFixtures.message(1, [NeuralTurnFixtures.bash("sleep 9", status: .running)], streaming: true),
        ], running: true))
        #expect(F.step(model, 0).result == nil)
    }
}

@Suite("Neural readout relations")
struct NeuralReadoutRelationTests {
    typealias F = ReadoutFixtures

    @Test("steps on one file are chips that name the others")
    func sameFile() {
        let model = F.model()
        let edit = F.step(model, 4)
        let chip = edit.relations.first { $0.kind == .sameFile }
        #expect(chip?.label == "same file as 3, 10")
        #expect(chip?.numbers == [3, 10])
        #expect(chip?.stepIDs == [model.steps[2].id, model.steps[9].id])
    }

    @Test("a failure a later run cleared says where it was retried and does not repeat itself as the same command")
    func retried() {
        let model = F.model()
        let failed = F.step(model, 5)
        #expect(failed.relations.map(\.kind) == [.retriedAt])
        #expect(failed.relations[0].label == "retried at 11")
        #expect(failed.relations[0].stepIDs == [model.steps[10].id])
        let retry = F.step(model, 10)
        #expect(retry.relations.map(\.kind) == [.sameCommand])
        #expect(retry.relations[0].label == "same command as 6")
    }

    @Test("a step with nothing in common has no chips")
    func none() {
        #expect(F.step(F.model(), 11).relations.isEmpty)
    }
}

@Suite("Neural readout digest")
struct NeuralReadoutDigestTests {
    typealias F = ReadoutFixtures

    private func readDigest(_ model: NeuralBrainModel = F.model(), answer: String? = nil) throws -> NeuralReadout.Digest {
        try #require(F.readout(model, .digest, answer: answer).digest)
    }

    @Test("the headline is the turn's one sentence")
    func headline() throws {
        let model = F.model()
        let digest = try readDigest(model)
        #expect(digest.headline.hasPrefix("12 tools"))
        #expect(digest.headline.contains("ran 4 commands"))
    }

    @Test("zone bars run from the busiest zone and leave out the empty ones")
    func zoneBars() throws {
        let digest = try readDigest()
        #expect(digest.zoneBars.map(\.zone) == [.think, .sense, .act, .shell, .delegate])
        #expect(digest.zoneBars.map(\.count) == [2, 4, 3, 4, 1])
        #expect(digest.zoneBars[1].fraction == 1)
        #expect(digest.zoneBars[4].fraction == 0.25)
    }

    @Test("one tick per step in order, failures marked, and the answer's place at the end")
    func ticks() throws {
        let model = F.model()
        let digest = try readDigest(model)
        #expect(digest.ticks.count == 14)
        #expect(digest.ticks.map(\.index) == Array(0..<14))
        #expect(digest.ticks.filter(\.isFailure).map(\.index) == [5])
        #expect(digest.ticks[5].isRecovered)
        #expect(digest.answerBegins == 14)
        #expect(digest.ticks.last?.answerFollows == true)
        #expect(digest.ticks.dropLast().allSatisfy { !$0.answerFollows })
        let bare = F.model(F.turn(Array(NeuralTurnFixtures.buildFix(answer: false))))
        #expect(try readDigest(bare).answerBegins == nil)
    }

    @Test("changed files merge repeated edits and tally them")
    func changed() throws {
        let model = F.model()
        let digest = try readDigest(model)
        #expect(digest.changed.map(\.fileName) == ["TranscriptRows.swift", "Parity.swift"])
        let rows = digest.changed[0]
        #expect(rows.added == 8)
        #expect(rows.removed == 3)
        #expect(rows.stepID == model.steps[4].id)
        #expect(rows.stepIDs == [model.steps[4].id, model.steps[9].id])
        #expect(rows.tally == "+8 \u{2212}3")
        #expect(digest.changed[1].added == 3)
    }

    @Test("failures name the first error line and where the step was retried")
    func failures() throws {
        let digest = try readDigest()
        #expect(digest.failures.count == 1)
        let failure = digest.failures[0]
        #expect(failure.number == 6)
        #expect(failure.firstLine.contains("error: switch must be exhaustive"))
        #expect(failure.retriedNumber == 11)
        #expect(failure.label == "retried at 11")
        let never = F.model(F.turn([
            NeuralTurnFixtures.user(0),
            NeuralTurnFixtures.message(1, [NeuralTurnFixtures.bash("false", out: ["boom"], status: .error)]),
        ]))
        let lone = try readDigest(never).failures[0]
        #expect(lone.retriedAt == nil)
        #expect(lone.label == "never retried")
        #expect(lone.firstLine == "boom")
    }

    @Test("the answer's first line comes from the text the client passes")
    func answer() throws {
        let digest = try readDigest(answer: "\n\nFixed it.\nSecond line.")
        #expect(digest.answer == "Fixed it.")
        #expect(try readDigest().answer == nil)
    }
}

@Suite("Neural readout now, zone, replay and ask")
struct NeuralReadoutOtherModeTests {
    typealias F = ReadoutFixtures

    @Test("Now follows the step that is running, tails its output and sums the turn up compactly")
    func now() throws {
        let output = F.longOutput(20)
        let model = F.model(F.turn([
            NeuralTurnFixtures.user(0),
            NeuralTurnFixtures.message(1, [.reasoning("Run the long thing.")]),
            NeuralTurnFixtures.message(2, [NeuralTurnFixtures.tool("Bash", ["command": .string("long")], out: [output], status: .running)], streaming: true),
        ], running: true))
        let read = F.readout(model, .now)
        guard case .now(let now) = read.body else {
            Issue.record("expected Now")
            return
        }
        #expect(now.label == "NOW")
        #expect(now.tone == .live)
        #expect(now.step?.stepID == model.steps[1].id)
        #expect(now.step?.header.chip.kind == .running)
        #expect(now.step?.why?.full == "Run the long thing.")
        #expect(now.tail.lines.count == 8)
        #expect(now.tail.lines.first?.text == "out 12")
        #expect(now.tail.lines.last?.text == "out 19")
        #expect(now.tail.total == 20)
        #expect(now.soFar.headline.hasPrefix("1 tool"))
        #expect(now.soFar.chips.map(\.zone) == [.think, .shell])
        #expect(now.soFar.chips.map(\.count) == [1, 1])
    }

    @Test("Now reads the output that has grown since, without the layout changing")
    func nowGrows() {
        let messages = { (lines: Int) in [
            NeuralTurnFixtures.user(0),
            NeuralTurnFixtures.message(1, [NeuralTurnFixtures.tool("Bash", ["command": .string("long")], out: [F.longOutput(lines)], status: .running)], streaming: true),
        ] }
        var model = F.model(F.turn(messages(10), running: true))
        let revision = model.revision
        #expect(F.readout(model, .now).digest == nil)
        model.update(turn: F.turn(messages(40), running: true), context: .none)
        #expect(model.revision == revision)
        guard case .now(let now) = F.readout(model, .now).body else {
            Issue.record("expected Now")
            return
        }
        #expect(now.tail.total == 40)
        #expect(now.tail.lines.last?.text == "out 39")
    }

    @Test("a waiting step replaces Now with the ask in the attention tone")
    func ask() throws {
        let (turn, waitingID) = F.waitingTurn()
        let model = F.model(turn)
        let mode = model.readoutSubject(now: 0)
        #expect(mode == .ask(waitingID))
        guard case .ask(let ask) = F.readout(model, mode).body else {
            Issue.record("expected the ask")
            return
        }
        #expect(ask.isApproval)
        #expect(ask.tone == .attention)
        #expect(ask.sentence == "Waiting for your approval")
        #expect(ask.actionLabel == "Go to approval")
        #expect(ask.step.stepID == waitingID)
        #expect(ask.step.header.chip.kind == .waiting)
    }

    @Test("a zone lists its steps with numbers, one-line arguments and tones")
    func zone() throws {
        let model = F.model()
        guard case .zone(let list) = F.readout(model, .zone(.shell)).body else {
            Issue.record("expected a zone list")
            return
        }
        #expect(list.rows.map(\.number) == [6, 11, 12, 14])
        #expect(list.rows[0].tone == .quiet)
        #expect(list.rows[1].tone == .live)
        #expect(list.rows[0].status == .failed)
        #expect(list.rows[0].argument.hasPrefix("swift build"))
        #expect(list.rows.allSatisfy { !$0.argument.contains("\n") })
        #expect(list.rows.map(\.stepID) == [5, 10, 11, 13].map { model.steps[$0].id })
    }

    @Test("a replay shows the step firing at the playhead and the steps before it, newest first")
    func replay() throws {
        var model = F.model()
        model.startReplay(now: 100)
        let timeline = model.timeline
        let target = 6
        let clock = 100 + timeline.fireTimes[target] + 0.001
        guard case .replay(let replay) = F.readout(model, .replay, clock: clock).body else {
            Issue.record("expected a replay")
            return
        }
        #expect(replay.current?.stepID == model.steps[target].id)
        #expect(replay.log.map(\.number) == [6, 5, 4, 3, 2, 1])
        #expect(replay.hiddenBefore == 0)
        #expect(replay.fraction > 0 && replay.fraction < 1)
        guard case .replay(let before) = F.readout(model, .replay, clock: 100 - 1).body else {
            Issue.record("expected a replay")
            return
        }
        #expect(before.current?.stepID == model.steps[0].id)
        #expect(before.log.isEmpty)
    }

    @Test("every mode announces itself for a screen reader")
    func announcements() {
        let model = F.model()
        #expect(F.readout(model, .step(model.steps[1].id)).announcement == NeuralReading.announcement(for: model.steps[1], of: 14))
        #expect(F.readout(model, .digest).announcement == NeuralReading.spoken(model.turn, now: Date(timeIntervalSince1970: 1_000_100)))
        #expect(!F.readout(model, .zone(.act)).announcement.isEmpty)
    }
}

@Suite("Neural readout hover grace")
struct NeuralHoverGraceTests {
    @Test("a node is entered after 40 ms of rest and not before")
    func intent() {
        var grace = NeuralHoverGrace()
        grace.pointer(over: "a", at: 10)
        #expect(grace.resolved(at: 10.039) == nil)
        #expect(grace.resolved(at: 10.040) == "a")
        #expect(grace.nextChange(after: 10.01) == 10.04)
    }

    @Test("arriving from another node is at once, and leaving keeps the node for 400 ms")
    func arriveAndLeave() {
        var grace = NeuralHoverGrace()
        grace.pointer(over: "a", at: 0)
        grace.pointer(over: "a", at: 0.1)
        grace.pointer(over: "b", at: 0.2)
        #expect(grace.resolved(at: 0.2) == "b")
        grace.pointer(over: nil, at: 1)
        #expect(grace.resolved(at: 1.39) == "b")
        #expect(grace.resolved(at: 1.40) == nil)
        #expect(grace.nextChange(after: 1.1) == 1.4)
    }

    @Test("a drift across a wire and back inside the grace does not flash the digest")
    func drift() {
        var grace = NeuralHoverGrace()
        grace.pointer(over: "a", at: 0)
        grace.pointer(over: "a", at: 0.1)
        grace.pointer(over: nil, at: 0.2)
        #expect(grace.resolved(at: 0.35) == "a")
        grace.pointer(over: "c", at: 0.35)
        #expect(grace.resolved(at: 0.35) == "c")
        grace.pointer(over: nil, at: 0.4)
        grace.pointer(over: "c", at: 0.5)
        #expect(grace.resolved(at: 0.9) == "c")
    }

    @Test("a pointer that comes from empty space after the grace waits the 40 ms again")
    func fromSpace() {
        var grace = NeuralHoverGrace()
        grace.pointer(over: "a", at: 0)
        grace.pointer(over: nil, at: 0.1)
        grace.pointer(over: "b", at: 2)
        #expect(grace.resolved(at: 2.01) == nil)
        #expect(grace.resolved(at: 2.05) == "b")
    }

    @Test("a pointer inside the readout keeps the node, and leaving it starts the grace")
    func readoutHold() {
        var grace = NeuralHoverGrace()
        grace.pointer(over: "a", at: 0)
        grace.pointer(over: "a", at: 0.1)
        grace.pointer(over: nil, at: 0.2)
        grace.readoutPointer(inside: true, at: 0.25)
        #expect(grace.resolved(at: 5) == "a")
        #expect(grace.nextChange(after: 1) == nil)
        grace.readoutPointer(inside: false, at: 5)
        #expect(grace.resolved(at: 5.3) == "a")
        #expect(grace.resolved(at: 5.4) == nil)
    }

    @Test("the model follows the pointer for the readout and returns to the digest, or to Now while live")
    func modelFlow() {
        var model = ReadoutFixtures.model()
        let id = model.steps[2].id
        model.pointer(over: id, at: 0)
        #expect(model.readoutSubject(now: 0.01) == .digest)
        #expect(model.readoutSubject(now: 0.05) == .step(id))
        model.pointer(over: nil, at: 1)
        #expect(model.readoutSubject(now: 1.3) == .step(id))
        #expect(model.readoutSubject(now: 1.41) == .digest)
        #expect(model.nextReadoutChange(after: 1.1) == 1.4)

        var live = ReadoutFixtures.model(BrainFixtures.turn(running: true))
        let liveID = live.steps[2].id
        live.pointer(over: liveID, at: 0)
        live.pointer(over: nil, at: 1)
        #expect(live.readoutSubject(now: 2.4) == .step(liveID))
        #expect(live.readoutSubject(now: 2.6) == .now)
    }

    @Test("a pinned step holds the readout whatever the pointer does")
    func pinnedHolds() {
        var model = ReadoutFixtures.model()
        let pinned = model.steps[1].id
        model.togglePin(pinned)
        model.pointer(over: model.steps[3].id, at: 0)
        #expect(model.readoutSubject(now: 1) == .step(pinned))
        model.pointer(over: nil, at: 2)
        #expect(model.readoutSubject(now: 9) == .step(pinned))
    }

    @Test("the model's readout convenience reads the subject it resolved")
    func convenience() {
        var model = ReadoutFixtures.model()
        let id = model.steps[3].id
        model.pointer(over: id, at: 0)
        let read = model.readout(now: Date(timeIntervalSince1970: 1_000_100), tz: ReadoutFixtures.utc, clock: 1)
        #expect(read.mode == .step(id))
    }
}

@Suite("Neural step call")
struct NeuralStepCallTests {
    @Test("a step holds the call it was read from, with its whole output")
    func holdsTheCall() throws {
        let model = ReadoutFixtures.model()
        let step = model.steps[5]
        #expect(step.call?.call.name == "Bash")
        #expect(step.call?.call.output?.contains("note: add missing case") == true)
        #expect(model.steps[0].call == nil)
    }

    @Test("equality is the call's revision, so a long output is never compared word for word")
    func cheapEquality() {
        let base = ToolCall(id: "c", name: "Bash", status: .running, input: .object(["command": .string("x")]), output: "a")
        let same = NeuralStepCall(base)
        #expect(same == NeuralStepCall(base))
        var grown = base
        grown.output = "ab"
        #expect(same != NeuralStepCall(grown))
        var done = base
        done.status = .completed
        #expect(same != NeuralStepCall(done))
        var edited = base
        edited.input = .object(["command": .string("xyz")])
        #expect(same != NeuralStepCall(edited))
        #expect(same.hashValue == NeuralStepCall(base).hashValue)
    }

    @Test("a grown output is read again by the turn cache and the model keeps its layout")
    func cacheNoticesGrowth() {
        let cache = NeuralTurnCache()
        func messages(_ out: String) -> [ChatMessage] {
            let call = ToolCall(
                id: "fixed", name: "Bash", status: .running,
                input: .object(["command": .string("x")]), output: out)
            return [NeuralTurnFixtures.user(0), NeuralTurnFixtures.message(1, [.tool(call)], streaming: true)]
        }
        let first = cache.partition(messages: messages("a"), running: true)
        let again = cache.partition(messages: messages("a"), running: true)
        #expect(cache.turnPartitions == 1)
        #expect(first == again)
        let grown = cache.partition(messages: messages("a\nb\nc\nd\ne\nf"), running: true)
        #expect(cache.turnPartitions == 2)
        #expect(grown[0].steps[0].call?.call.output == "a\nb\nc\nd\ne\nf")
        #expect(first != grown)
    }

    @Test("reading output costs only the lines asked for")
    func cheapReading() {
        let huge = (0..<200_000).map { "line \($0)" }.joined(separator: "\n")
        #expect(NeuralReadoutText.firstLines(huge, 3) == ["line 0", "line 1", "line 2"])
        #expect(NeuralReadoutText.lastLines(huge, 2) == ["line 199998", "line 199999"])
        #expect(NeuralReadoutText.lineCount(huge) == 200_000)
        #expect(NeuralReadoutText.lineCount("a\n\n\n") == 1)
        #expect(NeuralReadoutText.lineCount("") == 0)
        #expect(NeuralReadoutText.firstLines("\n\na\r\nb\n", 5) == ["a", "b"])
        #expect(NeuralReadoutText.rawLineCount("a\nb\n") == 2)
        #expect(NeuralReadoutText.rawLineCount("a\nb") == 2)
    }
}


@Suite("Neural readout design review")
struct NeuralReadoutReviewTests {
    typealias F = ReadoutFixtures

    @Test("a step reads header, subject, relations, WHY, result, facts, in that order")
    func stepOrder() {
        #expect(NeuralReadout.StepSection.allCases == [.header, .subject, .relations, .why, .result, .facts])
        let labels = Mirror(reflecting: F.step(F.model(), 5)).children.compactMap(\.label)
        let order = labels.filter { ["header", "subject", "relations", "why", "result", "facts"].contains($0) }
        #expect(order == ["header", "subject", "relations", "why", "result", "facts"])
    }

    @Test("the digest reads bars with the timeline, then failures, then changed, then the answer")
    func digestOrder() {
        #expect(NeuralReadout.DigestSection.allCases == [.headline, .barsAndTimeline, .failures, .changed, .answer])
        let digest = F.readout(F.model(), .digest).digest!
        let labels = Mirror(reflecting: digest).children.compactMap(\.label)
        let order = labels.filter { ["zoneBars", "ticks", "failures", "changed", "answer"].contains($0) }
        #expect(order == ["zoneBars", "ticks", "failures", "changed", "answer"])
    }

    @Test("a changed file shortens to an ellipsis, its last directory and the file name")
    func shortPath() {
        let digest = F.readout(F.model(), .digest).digest!
        #expect(digest.changed[0].shortDirectory == "\u{2026}/Chat/")
        #expect(digest.changed[0].fileName == "TranscriptRows.swift")
        #expect(digest.changed[1].shortDirectory == "\u{2026}/Sources/")
        let one = NeuralReadout.shortPath("dir/b.txt")
        #expect(one.directory == "dir/" && one.fileName == "b.txt")
        let bare = NeuralReadout.shortPath("b.txt")
        #expect(bare.directory == "" && bare.fileName == "b.txt")
        let deep = NeuralReadout.shortPath("/a/b/c/d.swift")
        #expect(deep.directory == "\u{2026}/c/" && deep.fileName == "d.swift")
    }

    @Test("Now's So far is the headline and the card's zone chips, in zone order")
    func soFar() throws {
        let model = F.model(BrainFixtures.turn(running: true))
        guard case .now(let now) = F.readout(model, .now).body else {
            Issue.record("expected Now")
            return
        }
        let card = model.brainCard(now: Date())
        #expect(now.soFar.chips == card.chips)
        #expect(now.soFar.chips.map(\.zone) == card.chips.map(\.zone))
    }

    @Test("a 20-line output shows eight lines wide and five narrow, and fades where more lies below")
    func narrowOutput() throws {
        let model = F.model(F.turn([
            NeuralTurnFixtures.user(0),
            NeuralTurnFixtures.message(1, [NeuralTurnFixtures.tool("Bash", ["command": .string("seq")], out: [F.longOutput(20)])]),
        ]))
        let wide = NeuralStageMetrics.make(width: 1300, density: .comfortable)
        let narrow = NeuralStageMetrics.make(width: 1000, density: .comfortable)
        #expect(wide.outputLinesShown == 8)
        #expect(narrow.outputLinesShown == 5)
        for (metrics, count) in [(wide, 8), (narrow, 5)] {
            let read = NeuralReadout.make(
                model: model, subject: .step(model.steps[0].id), now: Date(timeIntervalSince1970: 1_000_100),
                tz: F.utc, outputLines: metrics.outputLinesShown)
            guard case .shell(let output)? = read.step?.result else {
                Issue.record("expected output")
                return
            }
            #expect(output.lines.count == count)
            #expect(output.total == 20)
            #expect(output.fades)
            #expect(output.moreLabel == "\(20 - count) more lines")
        }
        let short = F.model(F.turn([
            NeuralTurnFixtures.user(0),
            NeuralTurnFixtures.message(1, [NeuralTurnFixtures.tool("Bash", ["command": .string("seq")], out: [F.longOutput(3)])]),
        ]))
        guard case .shell(let few)? = F.step(short, 0).result else {
            Issue.record("expected output")
            return
        }
        #expect(!few.fades)
    }

    @Test("pinning a ganglion member pins the ganglion and shows that member's readout")
    func ganglionMember() throws {
        var model = F.model(BrainFixtures.turn())
        let ganglion = try #require(model.layout.ganglia.first { $0.zone == .shell })
        let member = ganglion.members[3]
        model.setDive(zone: .shell)
        guard case .zone(let list) = F.readout(model, model.readoutSubject(now: 0)).body else {
            Issue.record("expected the zone list")
            return
        }
        #expect(Set(list.rows.map(\.stepID)).isSuperset(of: Set(ganglion.members)))
        model.togglePin(member)
        #expect(model.pinned == ganglion.leader)
        #expect(model.pinnedStep == member)
        let read = F.readout(model, model.readoutSubject(now: 0))
        #expect(read.mode == .step(member))
        #expect(read.step?.stepID == member)
        #expect(read.step?.header.isPinned == true)
        model.togglePin(ganglion.members[5])
        #expect(model.pinned == ganglion.leader)
        #expect(F.readout(model, model.readoutSubject(now: 0)).step?.stepID == ganglion.members[5])
        model.togglePin(ganglion.members[5])
        #expect(model.pinned == nil)
        #expect(model.pinnedStep == nil)
        model.togglePin(ganglion.leader)
        #expect(model.pinnedStep == ganglion.leader)
    }

    @Test("the leader goes to the step the panel shows, and the digest has none")
    func leaderTarget() {
        let model = F.model()
        #expect(F.readout(model, .digest).leaderStepID == nil)
        #expect(F.readout(model, .step(model.steps[3].id)).leaderStepID == model.steps[3].id)
        let live = F.model(BrainFixtures.turn(running: true))
        #expect(F.readout(live, .now).leaderStepID == live.steps.last?.id)
    }

    @Test("chips and the leader sit on the canvas in the corrected tones, the head wears the lifted ones")
    func toneSets() {
        let chip = F.step(F.model(), 5).header.chip
        #expect(chip.toneSet == .corrected)
        #expect(NeuralToneSet.set(for: .node) == .lifted)
        #expect(NeuralToneSet.set(for: .cardLight) == .lifted)
        #expect(NeuralToneSet.set(for: .leader) == .corrected)
        #expect(NeuralToneSet.set(for: .leaderTab) == .corrected)
        #expect(NeuralToneSet.set(for: .text) == .corrected)
    }
}
