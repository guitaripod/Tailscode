import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite struct PictureShowingTests {
    private let now = Date()

    private func prompt(_ id: String, _ text: String = "look") -> ChatMessage {
        ChatMessage(
            id: id, role: .user, agentType: .openCode,
            parts: [MessagePart(id: "t", kind: .text(text))], createdAt: now)
    }

    private func answer(_ id: String, _ parts: [MessagePart]) -> ChatMessage {
        ChatMessage(id: id, role: .assistant, agentType: .openCode, parts: parts, createdAt: now)
    }

    private func read(_ id: String, _ path: String) -> MessagePart {
        MessagePart(
            id: id,
            kind: .tool(
                ToolCall(
                    id: id, name: "read", status: .completed,
                    input: .object(["filePath": .string(path)]))))
    }

    private func picture(_ id: String, named name: String?) -> MessagePart {
        MessagePart(id: id, kind: .file(FileReference(mime: "image/png", filename: name)))
    }

    private func words(_ id: String, _ text: String) -> MessagePart {
        MessagePart(id: id, kind: .text(text))
    }

    @Test func aPictureTheAgentOnlyLookedAtIsNotShown() {
        let messages = [
            prompt("u1"),
            answer("a1", [read("r1", "/tmp/shots/ipad.png"), picture("p1", named: "ipad.png")]),
            answer("a2", [words("t", "The tab bar now sits at the bottom in portrait.")]),
        ]
        #expect(PictureShowing.unshown(in: messages) == ["a1:p1"])
    }

    @Test func aPictureTheAgentNamesIsShown() {
        let messages = [
            prompt("u1"),
            answer("a1", [read("r1", "/tmp/shots/ipad.png"), picture("p1", named: "ipad.png")]),
            answer("a2", [words("t", "Here is the new layout: `/tmp/shots/ipad.png`")]),
        ]
        #expect(PictureShowing.unshown(in: messages).isEmpty)
    }

    @Test func aPictureWithoutAFilenameIsNamedByThePathItWasReadFrom() {
        let messages = [
            prompt("u1"),
            answer("a1", [read("r1", "/tmp/shots/landscape.png"), picture("p1", named: nil)]),
            answer("a2", [words("t", "landscape.png shows the sidebar.")]),
        ]
        #expect(PictureShowing.unshown(in: messages).isEmpty)
    }

    @Test func ofSeveralPicturesOfOneNameOnlyTheNewestIsShown() {
        let messages = [
            prompt("u1"),
            answer("a1", [read("r1", "/tmp/ipad.png"), picture("p1", named: "ipad.png")]),
            answer("a2", [read("r2", "/tmp/ipad.png"), picture("p2", named: "ipad.png")]),
            answer("a3", [read("r3", "/tmp/other.png"), picture("p3", named: "other.png")]),
            answer("a4", [words("t", "Fixed; ipad.png is the final layout.")]),
        ]
        #expect(PictureShowing.unshown(in: messages) == ["a1:p1", "a3:p3"])
    }

    @Test func wordsInAnotherTurnDoNotShowAPicture() {
        let messages = [
            prompt("u1"),
            answer("a1", [read("r1", "/tmp/ipad.png"), picture("p1", named: "ipad.png")]),
            prompt("u2", "what was ipad.png?"),
            answer("a2", [words("t", "ipad.png was the portrait screenshot.")]),
        ]
        #expect(PictureShowing.unshown(in: messages) == ["a1:p1"])
    }

    @Test func aPictureNoToolHandedBackAndThePersonsOwnAreAlwaysShown() {
        let mine = ChatMessage(
            id: "u1", role: .user, agentType: .openCode,
            parts: [picture("f", named: "mine.png")], createdAt: now)
        let messages = [
            mine,
            answer("a1", [picture("p1", named: "made.png"), words("t", "Done.")]),
        ]
        #expect(PictureShowing.unshown(in: messages).isEmpty)
    }

    @Test func aNameWithoutAnExtensionNamesNothing() {
        #expect(!PictureShowing.isNameable("screenshot"))
        #expect(!PictureShowing.isNameable(".png"))
        #expect(!PictureShowing.isNameable("shot."))
        #expect(PictureShowing.isNameable("shot.png"))
        #expect(PictureShowing.basename("/tmp/shots/") == "shots")
        #expect(PictureShowing.basename("a.png") == "a.png")
    }

    @Test func aTurnIsDecidedAgainWhenItsWordsGrow() {
        var messages = [
            prompt("grow-u1"),
            answer("grow-a1", [read("r1", "/tmp/grow.png"), picture("p1", named: "grow.png")]),
            answer("grow-a2", [words("t", "Checking")]),
        ]
        #expect(PictureShowing.unshown(in: messages) == ["grow-a1:p1"])
        messages[2] = answer("grow-a2", [words("t", "Checking grow.png")])
        #expect(PictureShowing.unshown(in: messages).isEmpty)
    }
}
