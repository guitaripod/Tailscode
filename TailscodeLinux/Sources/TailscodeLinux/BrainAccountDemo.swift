import CodingAgentKit
import Foundation
import TailscodeCore

/// The turns the account is looked at on: the build fix the design was drawn from, told with the
/// agent's own notes between its calls, in the three states it was drawn in (settled, waiting on
/// an approval, running a command that prints), and the very large turn the account's widget
/// budget is measured on.
enum BrainAccountDemo {
    struct Script {
        var messages: [ChatMessage]
        var running: Bool
        var waiting: Bool
    }

    static let model = "claude-sonnet-4-5"

    static func script(kind: String, now: Date) -> Script? {
        switch kind {
        case "account": return Script(messages: settled(origin: now.timeIntervalSince1970 - 3_600), running: false, waiting: false)
        case "accountwait": return Script(messages: waiting(origin: now.timeIntervalSince1970 - 400), running: true, waiting: true)
        case "accountlive": return Script(messages: live(origin: now.timeIntervalSince1970 - 600), running: true, waiting: false)
        case "write":
            return Script(
                messages: NeuralDemo.writing(prefix: "acr-", origin: now.timeIntervalSince1970 - 900), running: false,
                waiting: false)
        case "livetest", "liveread", "liveedit", "liveerror":
            return Script(messages: liveStep(kind, origin: now.timeIntervalSince1970 - 7 * 22 - 3), running: true, waiting: false)
        default:
            guard kind.hasPrefix("big"), let steps = Int(kind.dropFirst(3)) else { return nil }
            let origin = now.timeIntervalSince1970 - 7_200
            return Script(
                messages: NeuralDemo.largeTurn(steps: steps, prefix: "big-", origin: origin), running: false,
                waiting: false)
        }
    }

    private struct Builder {
        let prefix: String
        let origin: TimeInterval

        func date(_ n: Int) -> Date { Date(timeIntervalSince1970: origin + Double(n) * 22) }

        func user(_ text: String) -> ChatMessage {
            ChatMessage(
                id: "\(prefix)u0", role: .user, agentType: .claudeCode,
                parts: [MessagePart(id: "t", kind: .text(text))], createdAt: date(0), completedAt: date(0))
        }

        func message(_ n: Int, _ kinds: [MessagePart.Kind], streaming: Bool = false) -> ChatMessage {
            ChatMessage(
                id: "\(prefix)m\(n)", role: .assistant, agentType: .claudeCode,
                parts: kinds.enumerated().map { MessagePart(id: "p\($0.offset)", kind: $0.element) },
                createdAt: date(n), completedAt: streaming ? nil : date(n).addingTimeInterval(0.5),
                isStreaming: streaming, modelID: BrainAccountDemo.model, reasoningEffort: "high")
        }

        func tool(
            _ name: String, _ input: [String: JSONValue], out: [String] = [], status: ToolStatus = .completed
        ) -> MessagePart.Kind {
            .tool(
                ToolCall(
                    id: "call-\(prefix)\(UUID().uuidString)", name: name, status: status, input: .object(input),
                    output: out.isEmpty ? nil : out.joined(separator: "\n")))
        }

        func bash(_ command: String, out: [String] = [], status: ToolStatus = .completed) -> MessagePart.Kind {
            tool("Bash", ["command": .string(command)], out: out, status: status)
        }

        func read(_ path: String, out: [String] = []) -> MessagePart.Kind {
            tool("Read", ["file_path": .string(path)], out: out)
        }

        func edit(_ path: String, added: Int, removed: Int) -> MessagePart.Kind {
            func lines(_ count: Int) -> String { (0..<count).map { "line \($0)" }.joined(separator: "\n") }
            return tool(
                "Edit",
                [
                    "file_path": .string(path), "old_string": .string(lines(removed)),
                    "new_string": .string(lines(added)),
                ], out: ["The file \(path) has been updated."])
        }

        func grep(_ pattern: String, in path: String, out: [String]) -> MessagePart.Kind {
            tool("Grep", ["pattern": .string(pattern), "path": .string(path)], out: out)
        }

        func task(_ description: String, out: [String]) -> MessagePart.Kind {
            tool("Task", ["description": .string(description)], out: out)
        }

        static let buildPlan = [
            "Find every switch over the part kind",
            "Answer the Compaction case in the Linux rows",
            "Build the release and read what the compiler says",
            "Answer the Note case the build names",
            "Check the Mac manifest answers the same capability",
            "Run the parity check, then ask a reviewer for other switches",
            "Install the release on this machine",
        ]

        static let filmPlan = [
            "Look at the film rig and the track",
            "Map the song to a cut list",
            "Record the Linux app in demo mode",
            "Resample the iOS tour to 30 fps",
            "Cut both to the riff at 8.75 s",
            "Lay the track under the cut",
            "Check the first tap lands on the riff",
        ]

        /// The agent's task list as it stands: the first `done` items completed, the next one in
        /// progress and the rest waiting.
        func todo(_ items: [String], done: Int) -> MessagePart.Kind {
            let entries: [JSONValue] = items.enumerated().map { offset, text in
                .object([
                    "content": .string(text),
                    "status": .string(offset < done ? "completed" : offset == done ? "in_progress" : "pending"),
                    "activeForm": .string(text),
                ])
            }
            return tool("TodoWrite", ["todos": .array(entries)], out: ["Todos have been modified successfully."])
        }

        static let rows = "TailscodeLinux/Sources/Chat/TranscriptRows.swift"
        static let build = "swift build -c release 2>&1 | tail -20"
        static let compileError = [
            "[1/3] Compiling TailscodeLinux TranscriptRows.swift",
            "TailscodeLinux/Chat/TranscriptRows.swift:212:9: error: switch must be exhaustive",
            "210 |         switch part.kind {",
            "211 |         case .text, .reasoning:",
            "212 |             return proseRows(part)",
            "    |         `- note: add missing case: '.note(_)'",
            "213 |         case .tool, .file:",
            "[2/3] Compiling TailscodeLinux RowFactory.swift",
            "[3/3] Compiling TailscodeLinux Parity.swift",
            "error: fatalError",
            "Build failed (212.4s)",
        ]

        func opening(_ out: inout [ChatMessage]) {
            out.append(user("Fix the Linux build: it stops in TranscriptRows."))
            out.append(
                message(
                    1,
                    [
                        .reasoning(
                            "The Linux build stops in TranscriptRows: a Compaction case reached the switch and nothing answers it, so the first thing to learn is who else already handles it."),
                        todo(Self.buildPlan, done: 0),
                    ]))
            out.append(
                message(
                    2,
                    [
                        .text(
                            "I\u{2019}ll start by finding every place that already names the Compaction case, so I don\u{2019}t add a second answer to a switch that has one."),
                        grep("case .compaction", in: "TailscodeLinux/Sources", out: ["TranscriptRows.swift:212"]),
                        read(Self.rows, out: ["204 lines"]),
                        read("TailscodeLinux/Sources/Parity.swift", out: ["388 lines"]),
                        edit(Self.rows, added: 6, removed: 1),
                    ]))
            out.append(
                message(
                    3,
                    [
                        .text(
                            "That covers Compaction as a divider. Building the release now to see whether the compiler wants anything else before I touch the Mac client."),
                        bash(Self.build, out: Self.compileError, status: .error),
                    ]))
            out.append(
                message(
                    4,
                    [
                        .reasoning(
                            "The build names .note, which my first edit did not cover. The Mac client answers the same capability in its own file, so it will need the same case.")
                    ]))
            out.append(
                message(
                    5,
                    [
                        .text(
                            "The build stops on `.note`, which my first edit did not cover. Notes read like prose with a quieter tone, so rather than give them an arm of their own I\u{2019}m folding them into the prose case and letting the tone follow the part kind. That keeps the rows identical for every other client and means the Mac manifest needs only one new answer. I\u{2019}m making the edit now and building again; the release build takes about three and a half minutes on this machine, so while it runs I\u{2019}ll read the Mac manifest, because it answers the same capability in its own file and I would rather find out now that it needs a case than after the install. If the second build is clean I will run the parity check, ask a reviewer to look for any other switch over the part kind, and install."),
                        edit(Self.rows, added: 2, removed: 2),
                        bash(Self.build, out: ["Compiling TailscodeLinux", "Build complete! (212.4s)"]),
                        read("TailscodeMac/Sources/Parity.swift", out: ["412 lines"]),
                        edit("TailscodeMac/Sources/Parity.swift", added: 3, removed: 0),
                        bash("scripts/parity.sh --check", out: ["parity: 3 clients, 0 undeclared"]),
                    ]))
        }
    }

    static func settled(origin: TimeInterval) -> [ChatMessage] {
        let b = Builder(prefix: "acc-", origin: origin)
        var out: [ChatMessage] = []
        b.opening(&out)
        out.append(
            b.message(
                6,
                [
                    b.todo(Builder.buildPlan, done: 7),
                    b.bash("scripts/install-linuxapp.sh", out: ["Installed Tailscode 1.79 (pid 41872)"]),
                    b.task(
                        "Review the diff for any switch over the part kind that is still not exhaustive",
                        out: ["No other switch is affected."]),
                ]))
        out.append(
            b.message(
                7,
                [
                    .text(
                        "Fixed. The build stopped on two switches that did not answer the new Compaction and Note cases. Both do now, the Mac manifest answers the same capability, and the parity check reports no gaps."),
                    .text("Tailscode 1.79 is installed on this machine (pid 41872)."),
                ]))
        return out
    }

    static func waiting(origin: TimeInterval) -> [ChatMessage] {
        let b = Builder(prefix: "acw-", origin: origin)
        var out: [ChatMessage] = []
        b.opening(&out)
        var last = b.message(
            6,
            [
                b.todo(Builder.buildPlan, done: 5),
                .text(
                    "Both builds are green and the parity check reports 0 undeclared. I\u{2019}d like to install the release over the app that is running; it restarts Tailscode, so I\u{2019}m asking first."),
                .tool(
                    ToolCall(
                        id: "call-wait", name: "Bash", status: .running,
                        input: .object(["command": .string("scripts/install-linuxapp.sh")]))),
            ], streaming: true)
        last.completedAt = nil
        out.append(last)
        return out
    }

    /// The build fix with its last step still in flight, three seconds old: one step per kind a live
    /// card's third line has to say, so each can be looked at.
    static func liveStep(_ kind: String, origin: TimeInterval) -> [ChatMessage] {
        let b = Builder(prefix: "acs-", origin: origin)
        var out: [ChatMessage] = []
        b.opening(&out)
        let running: (String, [String: JSONValue], [String]) =
            switch kind {
            case "liveread":
                ("Read", ["file_path": .string("TailscodeCore/Sources/TailscodeCore/Quota/QuotaGlance.swift")], ["212 lines"])
            case "liveedit":
                ("Edit", ["file_path": .string("TailscodeLinux/Sources/Chat/TranscriptRows.swift"), "old_string": .string("a"), "new_string": .string("b\nc")], [])
            case "liveerror":
                ("Bash", ["command": .string("swift build -c release 2>&1 | tail -20")], ["[1/3] Compiling TailscodeLinux TranscriptRows.swift"])
            default:
                (
                    "Bash", ["command": .string("swift test --filter TranscriptRowsTests")],
                    ["Test Case 'TranscriptRowsTests.testNotes' started.", "Test Case 'TranscriptRowsTests.testNotes' passed (0.003 seconds)."]
                )
            }
        var parts: [MessagePart.Kind] = []
        if kind == "liveerror" {
            parts.append(.text("The build stopped again on a missing case, so I am adding it and building once more."))
            parts.append(b.bash(Builder.build, out: Builder.compileError, status: .error))
        } else {
            parts.append(.text("Both builds are green, so I am running the transcript tests before the parity check."))
        }
        parts.append(
            .tool(
                ToolCall(
                    id: "call-running", name: running.0, status: .running, input: .object(running.1),
                    output: running.2.isEmpty ? nil : running.2.joined(separator: "\n"))))
        var last = b.message(7, parts, streaming: true)
        last.completedAt = nil
        out.append(last)
        return out
    }

    static func live(origin: TimeInterval) -> [ChatMessage] {
        let b = Builder(prefix: "acl-", origin: origin)
        var out: [ChatMessage] = [b.user("Make a product demonstration using mock data but the real apps .mp4")]
        let flac = "/mnt/nvme8tb/Music/Pantera-/203-pantera-walk.flac"
        out.append(
            b.message(
                1,
                [
                    .reasoning("He wants a shareable mp4 made with the real apps and mock data."),
                    b.todo(Builder.filmPlan, done: 3),
                    .text(
                        "The film rig already records the Linux app in demo mode and cuts the iOS tour, so I\u{2019}ll reuse it rather than build a new one."),
                    b.bash("ls ~/Dev/film/tailscode-everywhere", out: ["README.md  cut.sh"]),
                    b.bash("ffprobe -v error -show_entries format=duration -of csv=p=0 \(flac)", out: ["336.12"]),
                    b.bash("sed -n 1,60p scripts/film.sh", out: ["#!/usr/bin/env bash", "set -euo pipefail"]),
                ]))
        out.append(
            b.message(
                2,
                [
                    .text(
                        "Building it from the existing film rig: Linux app in --demo on a private 4K display, plus the iOS demo tour, cut to \u{201C}Walk\u{201D}."),
                    b.bash("scripts/dev-linuxapp.sh start --release --drive demo.drive", out: ["started pid 38214"]),
                    b.bash("scripts/dev-linuxapp.sh shot out/demo/01.png", out: ["out/demo/01.png 3840x2160"]),
                ]))
        out.append(
            b.message(
                3,
                [
                    .text(
                        "The track is 115 BPM in half time and the first riff lands at 8.75 s. Everything else is cut to that."),
                    b.bash("python3 scripts/beats.py \(flac)", out: ["tempo 115.0"]),
                    b.read("out/demo/cut-list.json", out: ["{ \"riff\": 8.75 }"]),
                ]))
        let frames = [
            "Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'ios-tour/walk.mov':",
            "  Duration: 00:01:02.04, bitrate: 38211 kb/s",
            "  Stream #0:0: Video: hevc (Main), 2622x1206, 60 fps",
            "Stream mapping: #0:0 -> #0:0 (hevc -> h264 (libx264))",
            "frame=  412 fps= 96 q=22.0 size=  4352kB time=00:00:13.73",
            "frame=  596 fps= 98 q=22.0 size=  7168kB time=00:00:19.86",
            "frame=  781 fps= 99 q=21.0 size= 10240kB time=00:00:26.03",
            "frame=  968 fps=100 q=21.0 size= 13312kB time=00:00:32.26",
        ]
        var tail = b.message(
            4,
            [
                .text(
                    "The iOS tour is 60 fps and the Linux capture is 30, so I\u{2019}m resampling the tour once before cutting both to the riff."),
                b.edit("out/demo/cut-list.json", added: 4, removed: 1),
                .tool(
                    ToolCall(
                        id: "call-running", name: "Bash", status: .running,
                        input: .object([
                            "command": .string(
                                "ffmpeg -i ios-tour/walk.mov -vf fps=30 -c:v libx264 -crf 18 -preset slow out/demo/ios-30.mp4")
                        ]), output: frames.joined(separator: "\n"))),
            ], streaming: true)
        tail.completedAt = nil
        out.append(tail)
        return out
    }
}
