import CodingAgentKit
import Foundation

/// A scripted conversation for every client's demo and for looking at a brain without a server:
/// the two turns the design mock was drawn from, as the messages a transcript holds.
public enum NeuralDemo {
    /// The build-fix turn: fourteen steps, a failed `swift build` retried to success, three calls in
    /// one message, a Task and a two-line answer.
    public static func buildFix(prefix: String = "", origin: TimeInterval = 1_792_000_000, answer: Bool = true) -> [ChatMessage] {
        Script(prefix: prefix, origin: origin).buildFix(answer: answer)
    }

    /// The long turn: twenty-nine steps across every zone, two notes, a Task, a failed ffmpeg mux
    /// retried, and the answer.
    public static func turn(prefix: String = "", origin: TimeInterval = 1_792_000_000, answer: Bool = true) -> [ChatMessage] {
        Script(prefix: prefix, origin: origin).turn(answer: answer)
    }

    /// Both turns one after the other, ids kept apart.
    public static func conversation() -> [ChatMessage] {
        buildFix(prefix: "a-", origin: 1_792_000_000) + turn(prefix: "b-", origin: 1_792_003_600)
    }

    private struct Script {
        let prefix: String
        let origin: TimeInterval
        let flac = "/mnt/nvme8tb/Music/Pantera-/203-pantera-walk.flac"

        func date(_ n: Int) -> Date { Date(timeIntervalSince1970: origin + Double(n) * 18) }

        func user(_ n: Int, _ text: String = "go") -> ChatMessage {
            ChatMessage(
                id: "\(prefix)u\(n)", role: .user, agentType: .claudeCode,
                parts: [MessagePart(id: "t", kind: .text(text))], createdAt: date(n),
                completedAt: date(n))
        }

        func message(
            _ n: Int, _ kinds: [MessagePart.Kind], streaming: Bool = false, error: String? = nil,
            finish: String? = nil, model: String? = nil, effort: String? = nil
        ) -> ChatMessage {
            ChatMessage(
                id: "\(prefix)m\(n)", role: .assistant, agentType: .claudeCode,
                parts: kinds.enumerated().map { MessagePart(id: "p\($0.offset)", kind: $0.element) },
                createdAt: date(n), completedAt: streaming ? nil : date(n).addingTimeInterval(0.5),
                isStreaming: streaming, error: error, modelID: model, reasoningEffort: effort,
                finishReason: finish)
        }

        func tool(
            _ name: String, _ input: [String: JSONValue], out: [String] = [], status: ToolStatus = .completed
        ) -> MessagePart.Kind {
            .tool(
                ToolCall(
                    id: "call-\(UUID().uuidString)", name: name, status: status, input: .object(input),
                    output: out.isEmpty ? nil : out.joined(separator: "\n")))
        }

        func bash(_ command: String, out: [String] = [], status: ToolStatus = .completed)
            -> MessagePart.Kind
        {
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

        func skill(_ name: String, out: [String]) -> MessagePart.Kind {
            tool("Skill", ["skill": .string(name)], out: out)
        }

        let answer: [String] = [
            "Done. The demo is at out/demo/tailscode-demo.mp4: 62 s, 3840×2160 at 30 fps.",
            "The first tap lands exactly on the riff, cut by out/demo/cut-list.json. Everything is mock data.",
        ]

        func buildFix(answer: Bool = true) -> [ChatMessage] {
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

        func turn(answer: Bool = true) -> [ChatMessage] {
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
    }
}
