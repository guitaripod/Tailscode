import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite struct MediaMentionsTests {
    private let now = Date()

    private func prompt(_ id: String) -> ChatMessage {
        ChatMessage(
            id: id, role: .user, agentType: .claudeCode,
            parts: [MessagePart(id: "t", kind: .text("make it"))], createdAt: now)
    }

    private func answer(_ id: String, _ parts: [MessagePart], streaming: Bool = false) -> ChatMessage {
        ChatMessage(
            id: id, role: .assistant, agentType: .claudeCode, parts: parts, createdAt: now,
            isStreaming: streaming)
    }

    private func words(_ id: String, _ text: String) -> MessagePart {
        MessagePart(id: id, kind: .text(text))
    }

    private func files(_ message: ChatMessage) -> [(id: String, file: FileReference)] {
        message.parts.compactMap { part in
            guard case .file(let file) = part.kind else { return nil }
            return (part.id, file)
        }
    }

    @Test func findsPathsTheWayRepliesWriteThem() {
        let text = """
            The final picture is 4K:

            /mnt/nvme8tb/Pictures/flaccy-siri.png

            The clip is at `~/Clips/My Cuts/demo cut.mp4` and the bounce is [here](/tmp/mix/theme.m4a).
            Screenshot (/tmp/shots/ipad.PNG). Also **/srv/a.webm**, and file:///tmp/b%20c.mov.
            """
        #expect(
            MediaMentions.paths(in: text) == [
                "/mnt/nvme8tb/Pictures/flaccy-siri.png",
                "~/Clips/My Cuts/demo cut.mp4",
                "/tmp/mix/theme.m4a",
                "/tmp/shots/ipad.PNG",
                "/srv/a.webm",
                "/tmp/b c.mov",
            ])
    }

    @Test func leavesOutWhatIsNotAShowing() {
        let text = """
            Run this:

            ```
            ffmpeg -i /tmp/in.mp4 -vf scale=640:-1 /tmp/out.mp4
            /usr/bin/tool --write /tmp/flagged.png
            ```

            Shots land in /tmp/tailscode-*.png, look like /path/to/image.png, live under
            /tmp/shots/ and docs/mock.png, and https://example.com/a.png is a link.
            Code is in Sources/App.swift and /etc/hosts. A lone .png is no file.
            """
        #expect(MediaMentions.paths(in: text).isEmpty)
    }

    @Test func pathsComeInTheOrderTheWordsNameThem() {
        let text = "Recorded /tmp/m/run.webm and /tmp/m/memo.ogg; the cut, `/tmp/gone/cut.mp4`, is gone."
        #expect(MediaMentions.paths(in: text) == ["/tmp/m/run.webm", "/tmp/m/memo.ogg", "/tmp/gone/cut.mp4"])
    }

    @Test func aFencedLineThatIsOnlyAPathCounts() {
        let text = "Copy it:\n\n```\n/mnt/nvme8tb/Clips/launch film.mp4\n```\n"
        #expect(MediaMentions.paths(in: text) == ["/mnt/nvme8tb/Clips/launch film.mp4"])
    }

    @Test func aSettledReplyCarriesItsMediaAfterTheWordsThatNameIt() throws {
        let messages = [
            prompt("u1"),
            answer("a1", [words("t1", "Done:\n\n/tmp/out/hero.png\n\nand /tmp/out/cut.mp4"), words("t2", "Bye.")]),
        ]
        let expanded = MediaMentions.expanded(messages)
        let ids = expanded[1].parts.map(\.id)
        #expect(ids == ["t1", "t1#media0", "t1#media1", "t2"])
        let attached = files(expanded[1])
        #expect(attached.map(\.file.mime) == ["image/png", "video/mp4"])
        #expect(attached.map(\.file.filename) == ["hero.png", "cut.mp4"])
        #expect(ServerFile.path(of: attached[0].file) == "/tmp/out/hero.png")
        #expect(attached[0].file.url?.contains("rev=a1") == true)
    }

    @Test func aStreamingReplyWaitsUntilItSettles() {
        let messages = [prompt("u1"), answer("a1", [words("t", "Saved /tmp/a.png")], streaming: true)]
        #expect(MediaMentions.expanded(messages) == messages)
    }

    @Test func theNewestMessageOfAnOpenTurnWaitsToo() {
        let messages = [
            prompt("u1"), answer("a1", [words("t", "Wrote /tmp/a.png")]),
            answer("a2", [words("t", "and now /tmp/b.png")]),
        ]
        let open = MediaMentions.expanded(messages, turnOpen: true)
        #expect(files(open[1]).count == 1)
        #expect(files(open[2]).isEmpty)
        #expect(files(MediaMentions.expanded(messages)[2]).count == 1)
    }

    @Test func aTurnShowsAFileOnceAfterItsLastNaming() {
        let messages = [
            prompt("u1"),
            answer("a1", [words("t", "Rendering to /tmp/r/final.png now.")]),
            answer("a2", [words("t", "Here it is: /tmp/r/final.png")]),
        ]
        let expanded = MediaMentions.expanded(messages)
        #expect(files(expanded[1]).isEmpty)
        #expect(files(expanded[2]).map(\.id) == ["t#media0"])
    }

    @Test func eachTurnShowsTheFileItNamesFresh() {
        let messages = [
            prompt("u1"), answer("a1", [words("t", "/tmp/r/final.png")]),
            prompt("u2"), answer("a2", [words("t", "Bigger now: /tmp/r/final.png")]),
        ]
        let expanded = MediaMentions.expanded(messages)
        let first = files(expanded[1]).first?.file.url
        let second = files(expanded[3]).first?.file.url
        #expect(first != nil && second != nil && first != second)
    }

    @Test func aPictureAToolHandedBackIsLeftToPictureShowing() {
        let read = MessagePart(
            id: "r", kind: .tool(ToolCall(id: "r", name: "Read", status: .completed)))
        let handed = MessagePart(
            id: "p",
            kind: .file(FileReference(path: "/tmp/shots/home.png", mime: "image/png", filename: "home.png")))
        let messages = [
            prompt("u1"),
            answer("a1", [read, handed, words("t", "See /tmp/shots/home.png and /tmp/shots/clip.mp4")]),
        ]
        let expanded = MediaMentions.expanded(messages)
        #expect(files(expanded[1]).map(\.file.filename) == ["home.png", "clip.mp4"])
        #expect(files(expanded[1]).map(\.id) == ["p", "t#media0"])
    }

    @Test func thePersonsOwnWordsShowNothing() {
        let said = ChatMessage(
            id: "u1", role: .user, agentType: .claudeCode,
            parts: [MessagePart(id: "t", kind: .text("look at /tmp/a.png"))], createdAt: now)
        #expect(MediaMentions.expanded([said]) == [said])
    }

    @Test func aTranscriptNamingNothingIsHandedBackAsItIs() {
        let messages = [prompt("u1"), answer("a1", [words("t", "Fixed in Sources/App.swift.")])]
        #expect(MediaMentions.expanded(messages) == messages)
    }

    @Test func kindsAndApplePlayback() {
        #expect(MediaKind.of(path: "/a/b.MOV")?.kind == .video)
        #expect(MediaKind.of(path: "/a/b.opus")?.kind == .audio)
        #expect(MediaKind.of(path: "/a.dir/file") == nil)
        #expect(MediaKind.of(FileReference(mime: "audio/mpeg")) == .audio)
        #expect(MediaKind.of(FileReference(filename: "x.webm")) == .video)
        #expect(MediaKind.playsOnApple(path: "/a/b.m4a"))
        #expect(!MediaKind.playsOnApple(path: "/a/b.webm"))
        #expect(!MediaKind.playsOnApple(path: "/a/b.ogg"))
    }

    @Test func aSettledReplyIsReadOnce() {
        let long = String(repeating: "Nothing to see in Sources/App.swift. ", count: 2000)
        let messages = [prompt("u1"), answer("a1", [words("t", long + " /tmp/x.png")])]
        _ = MediaMentions.expanded(messages)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<2000 { _ = MediaMentions.expanded(messages) }
        }
        #expect(elapsed < .milliseconds(500))
    }
}

@Suite struct MediaTileReadingTests {
    @Test func clocksReadTheWayPlayersPrintThem() {
        #expect(MediaTileReading.clock(6) == "0:06")
        #expect(MediaTileReading.clock(754.9) == "12:34")
        #expect(MediaTileReading.clock(3723) == "1:02:03")
        #expect(MediaTileReading.progress(at: nil, of: 7.98) == "0:08")
        #expect(MediaTileReading.progress(at: 2.6, of: 7.98) == "0:02 / 0:08")
        #expect(MediaTileReading.progress(at: 9, of: 7.98) == "0:08 / 0:08")
        #expect(MediaTileReading.progress(at: nil, of: nil) == nil)
        #expect(MediaTileReading.fraction(at: 2, of: 8) == 0.25)
    }

    @Test func failuresAreReadFromWhatTheBackendThrew() {
        #expect(MediaTileReading.failure(AgentError.http(status: 404, body: "")) == .missing)
        #expect(MediaTileReading.failure(AgentError.unsupported("x")) == .unsendable)
        #expect(MediaTileReading.failure(URLError(.timedOut)) == .unreachable)
        #expect(NamedMediaFailure.unreachable.isRetryable)
        #expect(!NamedMediaFailure.missing.isRetryable)
    }
}

@Suite(.serialized) struct MediaMemoryTests {
    private let now = Date()

    @Test func aMissedPictureIsDrawnAsMissing() {
        let messages = [
            ChatMessage(
                id: "u-miss", role: .user, agentType: .claudeCode,
                parts: [MessagePart(id: "t", kind: .text("go"))], createdAt: now),
            ChatMessage(
                id: "a-miss", role: .assistant, agentType: .claudeCode,
                parts: [MessagePart(id: "t", kind: .text("See /tmp/gone/shot.png"))], createdAt: now),
        ]
        guard case .file(let first)? = MediaMentions.expanded(messages)[1].parts.last?.kind else {
            Issue.record("no mention")
            return
        }
        #expect(first.mime == "image/png")
        MediaMisses.note(first)
        guard case .file(let again)? = MediaMentions.expanded(messages)[1].parts.last?.kind else {
            Issue.record("no mention")
            return
        }
        #expect(MediaMisses.isMissed(again))
        #expect(MediaKind.of(again) == nil)
    }

    @Test func onlyANamedFileCanBeMissed() {
        MediaMisses.note(FileReference(path: "/tmp/tool.png", mime: "image/png", url: "/attachments/s/a.png"))
        #expect(!MediaMisses.contains("/attachments/s/a.png"))
        #expect(MediaMisses.isMissing(AgentError.http(status: 404, body: "")))
        #expect(!MediaMisses.isMissing(AgentError.http(status: 500, body: "")))
    }

    @Test func aPlayheadIsKeptOnlyWhereItIsWorthComingBackTo() {
        MediaPlayhead.keep(42, of: 120, for: "k1")
        #expect(MediaPlayhead.start(for: "k1") == 42)
        MediaPlayhead.keep(118, of: 120, for: "k1")
        #expect(MediaPlayhead.start(for: "k1") == nil)
        MediaPlayhead.keep(2, of: 120, for: "k2")
        #expect(MediaPlayhead.start(for: "k2") == nil)
    }

    @Test func shortClipsLoop() {
        #expect(MediaLoop.loops(duration: 6))
        #expect(!MediaLoop.loops(duration: 95))
        #expect(!MediaLoop.loops(duration: nil))
        #expect(MediaTileReading.failure(AgentError.http(status: 422, body: "")) == .unplayable)
    }
}
