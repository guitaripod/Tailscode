import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// The mock's `BUILD_FIX` and `TURN` re-expressed as the messages a conversation holds.
enum NeuralTurnFixtures {
    static let flac = "/mnt/nvme8tb/Music/Pantera-/203-pantera-walk.flac"

    static func date(_ n: Int) -> Date { Date(timeIntervalSince1970: 1_000_000 + Double(n)) }

    static func user(_ n: Int, _ text: String = "go") -> ChatMessage {
        ChatMessage(
            id: "u\(n)", role: .user, agentType: .claudeCode,
            parts: [MessagePart(id: "t", kind: .text(text))], createdAt: date(n),
            completedAt: date(n))
    }

    static func message(
        _ n: Int, _ kinds: [MessagePart.Kind], streaming: Bool = false, error: String? = nil,
        finish: String? = nil, model: String? = nil, effort: String? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: "m\(n)", role: .assistant, agentType: .claudeCode,
            parts: kinds.enumerated().map { MessagePart(id: "p\($0.offset)", kind: $0.element) },
            createdAt: date(n), completedAt: streaming ? nil : date(n).addingTimeInterval(0.5),
            isStreaming: streaming, error: error, modelID: model, reasoningEffort: effort,
            finishReason: finish)
    }

    static func tool(
        _ name: String, _ input: [String: JSONValue], out: [String] = [], status: ToolStatus = .completed
    ) -> MessagePart.Kind {
        .tool(
            ToolCall(
                id: "call-\(UUID().uuidString)", name: name, status: status, input: .object(input),
                output: out.isEmpty ? nil : out.joined(separator: "\n")))
    }

    static func bash(_ command: String, out: [String] = [], status: ToolStatus = .completed)
        -> MessagePart.Kind
    {
        tool("Bash", ["command": .string(command)], out: out, status: status)
    }

    static func read(_ path: String, out: [String] = []) -> MessagePart.Kind {
        tool("Read", ["file_path": .string(path)], out: out)
    }

    static func edit(_ path: String, added: Int, removed: Int) -> MessagePart.Kind {
        func lines(_ count: Int) -> String { (0..<count).map { "line \($0)" }.joined(separator: "\n") }
        return tool(
            "Edit",
            [
                "file_path": .string(path), "old_string": .string(lines(removed)),
                "new_string": .string(lines(added)),
            ], out: ["The file \(path) has been updated."])
    }

    static func grep(_ pattern: String, in path: String, out: [String]) -> MessagePart.Kind {
        tool("Grep", ["pattern": .string(pattern), "path": .string(path)], out: out)
    }

    static func task(_ description: String, out: [String]) -> MessagePart.Kind {
        tool("Task", ["description": .string(description)], out: out)
    }

    static func skill(_ name: String, out: [String]) -> MessagePart.Kind {
        tool("Skill", ["skill": .string(name)], out: out)
    }

    static let answer: [String] = [
        "Done. The demo is at out/demo/tailscode-demo.mp4: 62 s, 3840×2160 at 30 fps.",
        "The first tap lands exactly on the riff, cut by out/demo/cut-list.json. Everything is mock data.",
    ]

    static func buildFix(answer: Bool = true) -> [ChatMessage] {
        var out: [ChatMessage] = [user(0, "Fix the Linux build: it stops in TranscriptRows.")]
        let build = "swift build -c release 2>&1 | tail -20"
        let rows = "TailscodeLinux/Sources/Chat/TranscriptRows.swift"
        out.append(message(1, [.reasoning("The Linux build stops in TranscriptRows: a case reached the switch.")]))
        out.append(
            message(
                2,
                [
                    grep("case .compaction", in: "TailscodeLinux/Sources", out: ["TranscriptRows.swift:212"]),
                    read(rows, out: ["204 lines"]),
                    read("TailscodeLinux/Sources/Parity.swift", out: ["388 lines"]),
                ]))
        out.append(message(3, [edit(rows, added: 6, removed: 1)]))
        out.append(
            message(
                4,
                [
                    bash(
                        build,
                        out: ["TranscriptRows.swift:212: error: switch must be exhaustive", "  note: add missing case: .note(_)"],
                        status: .error)
                ]))
        out.append(message(5, [.reasoning("The build names .note, which my first edit did not cover.")]))
        out.append(message(6, [read("TailscodeMac/Sources/Parity.swift", out: ["412 lines"])]))
        out.append(message(7, [edit("TailscodeMac/Sources/Parity.swift", added: 3, removed: 0)]))
        out.append(message(8, [edit(rows, added: 2, removed: 2)]))
        out.append(message(9, [bash(build, out: ["Compiling TailscodeLinux", "Build complete! (212.4s)"])]))
        out.append(message(10, [bash("scripts/parity.sh --check", out: ["parity: 3 clients"])]))
        out.append(
            message(11, [task("Review the diff for any switch that is still not exhaustive", out: ["No other switch is affected."])]))
        out.append(message(12, [bash("scripts/install-linuxapp.sh", out: ["Installed Tailscode 1.79"])]))
        if answer {
            out.append(message(13, [.text("Fixed. Both switches answer the new cases."), .text("Installed 1.79.")]))
        }
        return out
    }

    static func turn(answer: Bool = true) -> [ChatMessage] {
        var out: [ChatMessage] = [user(0, "Make a product demonstration .mp4")]
        func add(_ n: Int, _ kinds: MessagePart.Kind...) { out.append(message(n, kinds)) }
        let mux = "ffmpeg -f concat -i out/demo/cut-list.txt -i \(flac) -map 1:a -shortest out/demo/tailscode-demo.mp4"
        add(1, .reasoning("He wants a shareable mp4 made with the real apps and mock data."))
        add(2,
            bash("ls ~/Dev/film/tailscode-everywhere", out: ["README.md  cut.sh"]),
            bash("ffprobe -v error -show_entries format=duration -of csv=p=0 \(flac)", out: ["336.12"]))
        add(3, bash("sed -n 1,60p scripts/film.sh", out: ["#!/usr/bin/env bash", "set -euo pipefail"]))
        add(4, bash("rg -n \"demo\" scripts/dev-linuxapp.sh scripts/run-mac.sh", out: ["scripts/run-mac.sh:41"]))
        add(5, bash("scripts/dev-linuxapp.sh status", out: ["running"]))
        add(6, .text("Building it from the existing film rig."))
        add(7,
            bash("ffmpeg -i \(flac) -af astats -f null -", out: ["Overall RMS"]),
            bash("python3 scripts/beats.py \(flac)", out: ["tempo 115.0"]))
        add(8, bash("python3 scripts/beats.py --grid 8.75 --bars 16", out: ["16 bars"]))
        add(9, bash("scripts/dev-linuxapp.sh start --release --drive demo.drive", out: ["started pid 38214"]))
        add(10, bash("scripts/dev-linuxapp.sh shot out/demo/01.png", out: ["out/demo/01.png 3840×2160"]))
        add(11, bash("scripts/dev-linuxapp.sh drive '2000:open=1;4000:splits'", out: ["ok"]))
        add(12, .text("Song mapped; building the Linux release while I check the iOS footage."))
        add(13,
            bash("scripts/install-linuxapp.sh", out: ["Installed Tailscode 1.79"]),
            read("docs/marketing-2026-10.md", out: ["## Preview video"]))
        add(14, skill("frames-cli", out: ["Launching skill: frames-cli"]))
        add(15, read("scripts/film.sh", out: ["204 lines"]))
        add(16, bash("frames doctor", out: ["frames 0.9.2"]))
        add(17, bash("ffprobe -v error -show_streams ios-tour/walk.mov", out: ["codec hevc"]))
        add(18, .reasoning("The iOS tour is 60 fps and the Linux capture is 30."))
        add(19, read("out/demo/cut-list.json", out: ["{ \"riff\": 8.75 }"]))
        add(20, edit("out/demo/cut-list.json", added: 4, removed: 1))
        add(21, bash("ffmpeg -i ios-tour/walk.mov -vf fps=30 -c:v libx264 out/demo/ios-30.mp4", out: ["frame= 1260"]))
        add(22, bash(mux, out: ["Stream map '1:a' matches no streams."], status: .error))
        add(23, edit("out/demo/cut-list.json", added: 1, removed: 1))
        add(24, bash(mux, out: ["video:19.4MiB audio:1.4MiB"]))
        add(25, bash("ffprobe -v error -show_entries format=duration out/demo/tailscode-demo.mp4", out: ["62.04"]))
        add(26, task("Watch the cut and confirm the first tap lands on the riff", out: ["First tap at 8.74 s."]))
        if answer { add(27, .text(self.answer[0]), .text(self.answer[1])) }
        return out
    }

    static func steps(_ messages: [ChatMessage]) -> [NeuralStep] {
        NeuralTurns.partition(messages: messages, running: false)[0].steps
    }

    static func count(_ steps: [NeuralStep], _ zone: NeuralZone) -> Int {
        steps.filter { $0.zone == zone }.count
    }
}

@Suite("Neural turn partition")
struct NeuralTurnTests {
    typealias Fixtures = NeuralTurnFixtures

    @Test("BUILD_FIX reads as 14 steps in 12 messages")
    func buildFix() throws {
        let turns = NeuralTurns.partition(messages: Fixtures.buildFix(), running: false)
        #expect(turns.count == 1)
        let turn = turns[0]
        #expect(turn.id == "m1")
        #expect(turn.steps.count == 14)
        #expect(Fixtures.count(turn.steps, .think) == 2)
        #expect(Fixtures.count(turn.steps, .sense) == 4)
        #expect(Fixtures.count(turn.steps, .act) == 3)
        #expect(Fixtures.count(turn.steps, .shell) == 4)
        #expect(Fixtures.count(turn.steps, .delegate) == 1)
        #expect(Set(turn.steps.map(\.group)).count == 12)
        #expect(turn.steps.map(\.index) == Array(0..<14))
        let parallel = turn.steps.filter { $0.messageID == "m2" }
        #expect(parallel.count == 3)
        #expect(Set(parallel.map(\.group)).count == 1)
        #expect(parallel.map(\.title) == ["Grep", "Read", "Read"])
        #expect(turn.answerPartIDs == ["m13:p0", "m13:p1"])
        #expect(turn.outcome == .settled)
        #expect(turn.steps.allSatisfy { !$0.id.isEmpty && $0.id.contains(":") })
    }

    @Test("a failed build retried word for word to success is recovered")
    func recoveredBuild() {
        let steps = Fixtures.steps(Fixtures.buildFix())
        let builds = steps.filter { $0.tieIsCommand && $0.detail.hasPrefix("swift build") }
        #expect(builds.count == 2)
        #expect(builds[0].status == .failed)
        #expect(builds[0].recovered)
        #expect(builds[1].status == .ok)
        #expect(!builds[1].recovered)
        #expect(builds[0].tieKey == builds[1].tieKey)
    }

    @Test("a failure nothing retried stays a wound")
    func unrecovered() {
        let messages = [
            Fixtures.user(0),
            Fixtures.message(1, [Fixtures.bash("make", out: ["error"], status: .error)]),
            Fixtures.message(2, [Fixtures.bash("make", out: ["error"], status: .error)]),
        ]
        let steps = Fixtures.steps(messages)
        #expect(steps.allSatisfy { $0.status == .failed && !$0.recovered })
    }

    @Test("TURN reads as 29 steps with the mock's mix")
    func turnMix() {
        let turn = NeuralTurns.partition(messages: Fixtures.turn(), running: false)[0]
        #expect(turn.steps.count == 29)
        #expect(Fixtures.count(turn.steps, .think) == 2)
        #expect(Fixtures.count(turn.steps, .sense) == 3)
        #expect(Fixtures.count(turn.steps, .act) == 2)
        #expect(Fixtures.count(turn.steps, .shell) == 18)
        #expect(Fixtures.count(turn.steps, .delegate) == 2)
        #expect(Fixtures.count(turn.steps, .say) == 2)
        #expect(Set(turn.steps.map(\.group)).count == 26)
    }

    @Test("the answer is the trailing text and notes are say steps")
    func answerAndNotes() {
        let turn = NeuralTurns.partition(messages: Fixtures.turn(), running: false)[0]
        #expect(turn.answerPartIDs == ["m27:p0", "m27:p1"])
        let notes = turn.steps.filter { $0.zone == .say }
        #expect(notes.map(\.title) == ["Said", "Said"])
        #expect(notes[0].text == "Building it from the existing film rig.")
        #expect(notes[1].id == "m12:p0")
        #expect(!turn.memberPartIDs.contains("m27:p0"))
        #expect(turn.memberPartIDs.contains("m6:p0"))
        let thoughts = turn.steps.filter { $0.zone == .think }
        #expect(thoughts.map(\.title) == ["Thinking", "Thinking"])
        #expect(thoughts[0].text.hasPrefix("He wants"))
    }

    @Test("a running turn holds a short trailing note out of the chat until it outgrows a note or a tool follows")
    func runningTrailingText() {
        var messages: [ChatMessage] = [
            Fixtures.user(0),
            Fixtures.message(1, [Fixtures.read("a/b/c.swift", out: ["10 lines"])]),
            Fixtures.message(2, [.text("Looking at it now")], streaming: true),
        ]
        var turn = NeuralTurns.partition(messages: messages, running: true)[0]
        #expect(turn.steps.count == 1)
        #expect(turn.answerPartIDs.isEmpty)
        #expect(turn.memberPartIDs.contains("m2:p0"))
        #expect(turn.outcome == .running)
        #expect(turn.endedAt == nil)

        let written = String(repeating: "Looking at it now. ", count: 20)
        messages[2] = Fixtures.message(2, [.text(written)], streaming: true)
        turn = NeuralTurns.partition(messages: messages, running: true)[0]
        #expect(turn.steps.count == 1)
        #expect(turn.answerPartIDs == ["m2:p0"])
        #expect(!turn.memberPartIDs.contains("m2:p0"))

        messages[2] = Fixtures.message(
            2, [.text("Looking at it now"), Fixtures.bash("ls", status: .running)], streaming: true)
        turn = NeuralTurns.partition(messages: messages, running: true)[0]
        #expect(turn.answerPartIDs.isEmpty)
        #expect(turn.steps.map(\.zone) == [.sense, .say, .shell])
        #expect(turn.steps[1].text == "Looking at it now")
        #expect(turn.steps[1].id == "m2:p0")
        #expect(turn.steps[2].status == .running)
        #expect(turn.outcome == .running)
    }

    @Test("a short trailing line is the answer once the turn has ended, and the first words of a turn with no work are never held")
    func shortAnswersStand() {
        var messages: [ChatMessage] = [
            Fixtures.user(0),
            Fixtures.message(1, [Fixtures.read("a/b/c.swift", out: ["10 lines"])]),
            Fixtures.message(2, [.text("Done.")]),
        ]
        var turn = NeuralTurns.partition(messages: messages, running: false)[0]
        #expect(turn.answerPartIDs == ["m2:p0"])
        #expect(!turn.memberPartIDs.contains("m2:p0"))

        messages = [Fixtures.user(0), Fixtures.message(1, [.text("Hello")], streaming: true)]
        turn = NeuralTurns.partition(messages: messages, running: true)[0]
        #expect(turn.answerPartIDs == ["m1:p0"])
    }

    @Test("the outline holds the same words the turn does, and releases them at the same size")
    func outlineHoldsToo() {
        let held = [
            Fixtures.user(0),
            Fixtures.message(1, [Fixtures.read("a/b/c.swift", out: ["10 lines"])]),
            Fixtures.message(2, [.text("Looking at it now")], streaming: true),
        ]
        let outline = NeuralTurns.outline(messages: Array(held.dropFirst()), running: true)
        #expect(outline.answerPartIDs.isEmpty)
        #expect(outline.consumes("m2:p0"))
        #expect(outline.stepCount == 1)

        let written = String(repeating: "Looking at it now. ", count: 20)
        let grown = Array(held.dropFirst().dropLast()) + [
            Fixtures.message(2, [.text(written)], streaming: true)
        ]
        let released = NeuralTurns.outline(messages: grown, running: true)
        #expect(released.answerPartIDs == ["m2:p0"])
        #expect(!released.consumes("m2:p0"))
    }

    @Test("a thought still being written is the running step")
    func runningThought() {
        let messages = [
            Fixtures.user(0),
            Fixtures.message(1, [.reasoning("Checking the")], streaming: true),
        ]
        let turn = NeuralTurns.partition(messages: messages, running: true)[0]
        #expect(turn.steps.count == 1)
        #expect(turn.steps[0].status == .running)
        #expect(turn.steps[0].zone == .think)
        let settled = NeuralTurns.partition(messages: messages, running: false)[0]
        #expect(settled.steps[0].status == .ok)
    }

    @Test("only the last turn of a running conversation runs")
    func onlyLastRuns() {
        let messages =
            Fixtures.buildFix(answer: true)
            + [Fixtures.user(20), Fixtures.message(21, [Fixtures.bash("ls", status: .running)], streaming: true)]
        let turns = NeuralTurns.partition(messages: messages, running: true)
        #expect(turns.count == 2)
        #expect(turns[0].outcome == .settled)
        #expect(turns[1].outcome == .running)
        #expect(turns[1].steps[0].status == .running)
    }

    @Test("empty and whitespace thoughts and texts are not steps and not the answer")
    func emptyParts() {
        let messages = [
            Fixtures.user(0),
            Fixtures.message(
                1,
                [
                    .reasoning("   \n"), .text(""), Fixtures.read("a/b.swift"), .text("  "),
                    .reasoning(""),
                ]),
        ]
        let turn = NeuralTurns.partition(messages: messages, running: false)[0]
        #expect(turn.steps.count == 1)
        #expect(turn.answerPartIDs.isEmpty)
        #expect(turn.memberPartIDs == ["m1:p0", "m1:p1", "m1:p2", "m1:p3", "m1:p4"])
    }

    @Test("file, compaction, note and unknown parts are never steps but the turn consumes them")
    func nonSteps() {
        let messages = [
            Fixtures.user(0),
            Fixtures.message(
                1,
                [
                    .file(FileReference(path: "x.png", mime: "image/png")),
                    .unknown(type: "step-start"),
                    Fixtures.read("a/b.swift"),
                    .unknown(type: "step-finish"),
                    .text("Done"),
                ]),
        ]
        let turn = NeuralTurns.partition(messages: messages, running: false)[0]
        #expect(turn.steps.count == 1)
        #expect(turn.answerPartIDs == ["m1:p4"])
        #expect(turn.memberPartIDs == ["m1:p0", "m1:p1", "m1:p2", "m1:p3"])
    }

    /// A tool's picture and a note the server wrote while the turn ran are the turn's work, so the
    /// brain consumes them with its steps. A picture the agent delivered after its answer is the
    /// answer's own, and keeps its row.
    @Test("a tool's picture and a note go with the brain, a delivered picture does not")
    func workPartsGoWithTheBrain() {
        let picture = MessagePart.Kind.file(FileReference(path: "shot.png", mime: "image/png"))
        let delivered = MessagePart.Kind.file(FileReference(path: "out.png", mime: "image/png"))
        let note = ChatMessage(
            id: "n2", role: .system, agentType: .claudeCode,
            parts: [
                MessagePart(
                    id: "note", kind: .note(TranscriptNote(.workFinished("swift build", work: .command, outcome: .completed))))
            ],
            createdAt: Fixtures.date(2), completedAt: Fixtures.date(2))
        let messages = [
            Fixtures.user(0),
            Fixtures.message(1, [Fixtures.read("a/b.swift"), picture]),
            note,
            Fixtures.message(3, [.text("Done"), delivered]),
        ]
        let turn = NeuralTurns.partition(messages: messages, running: false)[0]
        #expect(turn.steps.count == 1)
        #expect(turn.answerPartIDs == ["m3:p0"])
        #expect(turn.memberPartIDs.contains("m1:p1"))
        #expect(turn.memberPartIDs.contains("n2:note"))
        #expect(!turn.memberPartIDs.contains("m3:p0"))
        #expect(!turn.memberPartIDs.contains("m3:p1"))
        #expect(turn.memberMessageIDs == ["m1", "n2", "m3"])
    }

    @Test("user messages split turns and a turn needs an assistant message")
    func splitsTurns() {
        let messages =
            [Fixtures.user(0), Fixtures.user(1)]
            + [Fixtures.message(2, [Fixtures.read("a/b.swift")]), Fixtures.user(3)]
            + [Fixtures.message(4, [Fixtures.bash("ls")]), Fixtures.message(5, [.text("ok")])]
        let turns = NeuralTurns.partition(messages: messages, running: false)
        #expect(turns.map(\.id) == ["m2", "m4"])
        #expect(turns[1].steps.map(\.group) == [0])
        #expect(turns[1].answerPartIDs == ["m5:p0"])
    }

    @Test("a repeated message is read once")
    func duplicateMessages() {
        let one = Fixtures.message(1, [Fixtures.read("a/b.swift")])
        let turn = NeuralTurns.partition(messages: [Fixtures.user(0), one, one], running: false)[0]
        #expect(turn.steps.count == 1)
    }

    @Test("card kinds are steps with isCard and stay out of the members")
    func cardKinds() {
        let todo = Fixtures.tool("TodoWrite", ["todos": .array([])])
        let ask = Fixtures.tool("AskUserQuestion", ["questions": .array([])], status: .running)
        let workflow = Fixtures.tool("RunWorkflow", ["name": .string("release")])
        let design = Fixtures.tool(
            "Write", ["file_path": .string(".tailscode/design/neural/board.json"), "content": .string("{}")])
        let plainWrite = Fixtures.tool(
            "Write", ["file_path": .string("notes/todo.txt"), "content": .string("x")])
        let messages = [
            Fixtures.user(0),
            Fixtures.message(
                1,
                [
                    Fixtures.task("Review", out: []), todo, ask, workflow, design, plainWrite,
                    Fixtures.skill("frames-cli", out: []), Fixtures.bash("ls"),
                ]),
        ]
        let turn = NeuralTurns.partition(messages: messages, running: false)[0]
        #expect(turn.steps.map(\.isCard) == [true, true, true, true, true, false, false, false])
        #expect(turn.steps.map(\.zone) == [.delegate, .think, .think, .delegate, .act, .act, .delegate, .shell])
        #expect(turn.memberPartIDs == ["m1:p5", "m1:p6", "m1:p7"])
    }

    @Test("status maps from the call and from what the conversation is waiting on")
    func statuses() {
        func call(_ id: String, _ name: String, _ status: ToolStatus) -> (MessagePart.Kind, String) {
            (.tool(ToolCall(id: id, name: name, status: status, input: .object([:]))), id)
        }
        let kinds = [
            call("a", "Bash", .pending), call("b", "Bash", .running), call("c", "Bash", .completed),
            call("d", "Bash", .error), call("e", "Bash", .stopped), call("f", "Bash", .running),
            call("g", "AskUserQuestion", .running), call("h", "Bash", .running),
            call("i", "Bash", .completed),
        ]
        let messages = [Fixtures.user(0), Fixtures.message(1, kinds.map(\.0))]
        let awaiting = NeuralAwaiting(
            approvals: ["f", "i"], answers: ["g"], stalled: ["h"])
        let steps = NeuralTurns.partition(messages: messages, running: true, awaiting: awaiting)[0].steps
        #expect(
            steps.map(\.status) == [
                .running, .running, .ok, .failed, .stopped, .waitingApproval, .waitingAnswer,
                .stalled, .ok,
            ])
        #expect(steps[5].mark == "⏸")
        #expect(steps[6].mark == "?")
        #expect(steps[7].mark == nil)
        #expect(steps[8].mark == nil)
    }

    @Test("a pending call matches by part id and step id as well")
    func awaitingIdentities() {
        let call = ToolCall(id: "call-1", name: "Bash", status: .pending, input: .object([:]))
        let messages = [Fixtures.user(0), Fixtures.message(1, [.tool(call), .tool(call)])]
        let byPart = NeuralAwaiting(approvals: ["p0"])
        let byStep = NeuralAwaiting(approvals: ["m1:p1"])
        #expect(NeuralTurns.partition(messages: messages, running: true, awaiting: byPart)[0].steps[0].status == .waitingApproval)
        #expect(NeuralTurns.partition(messages: messages, running: true, awaiting: byStep)[0].steps[1].status == .waitingApproval)
    }

    @Test("the outcome follows how the turn ended")
    func outcomes() {
        let work = Fixtures.read("a/b.swift")
        func outcome(_ last: ChatMessage, running: Bool = false, awaiting: NeuralAwaiting = .none)
            -> NeuralOutcome
        {
            let messages = [Fixtures.user(0), Fixtures.message(1, [work]), last]
            return NeuralTurns.partition(messages: messages, running: running, awaiting: awaiting)[0].outcome
        }
        #expect(outcome(Fixtures.message(2, [.text("done")])) == .settled)
        #expect(outcome(Fixtures.message(2, [.text("done")], streaming: true), running: true) == .running)
        #expect(outcome(Fixtures.message(2, [.text("partial")], error: "boom")) == .failed)
        #expect(outcome(Fixtures.message(2, [.text("partial")], finish: "abort")) == .stopped)
        #expect(outcome(Fixtures.message(2, [.text("partial")], finish: "Stop-By-User")) == .stopped)
        #expect(
            outcome(Fixtures.message(2, [.text("partial")]), awaiting: NeuralAwaiting(interrupted: ["m2"]))
                == .interrupted)
        let stopped = Fixtures.message(2, [Fixtures.bash("sleep 9", status: .stopped)])
        #expect(outcome(stopped) == .stopped)
        let running = Fixtures.message(2, [.text("x")], error: "boom")
        #expect(outcome(running, running: true) == .running)
    }

    @Test("a turn of step markers only is answerless")
    func answerless() {
        let messages = [
            Fixtures.user(0),
            Fixtures.message(1, [.unknown(type: "step-start"), .unknown(type: "step-finish")], finish: "unknown"),
        ]
        let turn = NeuralTurns.partition(messages: messages, running: false)[0]
        #expect(turn.outcome == .answerless)
        #expect(turn.steps.isEmpty)
        #expect(turn.answerPartIDs.isEmpty)
    }

    @Test("an edit carries its tally and a read does not")
    func diffTally() {
        let steps = Fixtures.steps(Fixtures.buildFix())
        let edits = steps.filter { $0.zone == .act }
        #expect(edits.map { $0.added } == [6, 3, 2])
        #expect(edits.map { $0.removed } == [1, 0, 2])
        #expect(steps.filter { $0.zone == .sense }.allSatisfy { $0.added == nil && $0.removed == nil })
    }

    @Test("detail is one line and ties are literal")
    func detailAndTies() {
        let messages = [
            Fixtures.user(0),
            Fixtures.message(
                1,
                [
                    Fixtures.bash("cat <<EOF\n  one   two\nEOF\n"),
                    Fixtures.bash("cat <<EOF\none two\nEOF"),
                    Fixtures.bash("echo   hi"),
                    Fixtures.bash("echo hi"),
                    Fixtures.read("src/x.swift"),
                    Fixtures.edit("src/x.swift", added: 1, removed: 0),
                    Fixtures.tool("Grep", ["pattern": .string("foo"), "path": .string("src")]),
                    Fixtures.tool("Grep", ["pattern": .string("bar")]),
                    Fixtures.tool("WebFetch", ["url": .string("https://example.com/a")]),
                ]),
        ]
        let steps = NeuralTurns.partition(messages: messages, running: false)[0].steps
        #expect(steps[0].detail == "cat <<EOF one two EOF")
        #expect(steps[0].tieKey == steps[1].tieKey)
        #expect(steps[2].tieKey == "echo hi")
        #expect(steps[2].tieKey == steps[3].tieKey)
        #expect(steps[0].tieIsCommand && steps[2].tieIsCommand)
        #expect(steps[4].tieKey == "src/x.swift")
        #expect(steps[4].tieKey == steps[5].tieKey)
        #expect(!steps[4].tieIsCommand)
        #expect(steps[6].detail == "foo src")
        #expect(steps[6].tieKey == "src")
        #expect(steps[7].tieKey == nil)
        #expect(steps[8].detail == "https://example.com/a")
        #expect(steps[8].tieKey == nil)
    }

    @Test("the TURN's cut-list ties three steps and its mux ties two commands")
    func turnTies() {
        let steps = Fixtures.steps(Fixtures.turn())
        let cut = steps.filter { $0.tieKey == "out/demo/cut-list.json" }
        #expect(cut.count == 3)
        #expect(cut.map(\.zone) == [.sense, .act, .act])
        let mux = steps.filter { $0.tieKey?.hasPrefix("ffmpeg -f concat") == true }
        #expect(mux.count == 2)
        #expect(mux.allSatisfy { $0.tieIsCommand })
        #expect(mux[0].status == .failed && mux[0].recovered)
    }

    @Test("output keeps four non-empty lines, each at most 160 characters")
    func outputLines() {
        let long = String(repeating: "x", count: 400)
        let output = ["", "one", "  ", "two  ", long, "four", "five", "six"]
        let messages = [
            Fixtures.user(0),
            Fixtures.message(1, [Fixtures.tool("Bash", ["command": .string("x")], out: output)]),
        ]
        let step = NeuralTurns.partition(messages: messages, running: false)[0].steps[0]
        #expect(step.outputLines.count == 4)
        #expect(step.outputLines[0] == "one")
        #expect(step.outputLines[1] == "two")
        #expect(step.outputLines[2].count == 160)
        #expect(step.outputLines[3] == "four")
    }

    @Test("time, model and effort come from the turn's messages")
    func timesAndModel() {
        let messages = [
            Fixtures.user(0),
            Fixtures.message(1, [Fixtures.read("a/b.swift")], model: "sonnet", effort: "high"),
            Fixtures.message(2, [.text("done")], model: "opus"),
        ]
        let turn = NeuralTurns.partition(messages: messages, running: false)[0]
        #expect(turn.startedAt == Fixtures.date(1))
        #expect(turn.endedAt == Fixtures.date(2).addingTimeInterval(0.5))
        #expect(turn.modelID == "opus")
        #expect(turn.effort == "high")
        #expect(turn.steps[0].at == Fixtures.date(1))
    }

    @Test("a long streaming turn partitions in one pass")
    func largeTurn() {
        var kinds: [MessagePart.Kind] = []
        for index in 0..<4000 { kinds.append(Fixtures.bash("echo \(index)", out: ["line"])) }
        let messages = [Fixtures.user(0), Fixtures.message(1, kinds, streaming: true)]
        let turn = NeuralTurns.partition(messages: messages, running: true)[0]
        #expect(turn.steps.count == 4000)
        #expect(Set(turn.steps.map(\.id)).count == 4000)
    }
}
