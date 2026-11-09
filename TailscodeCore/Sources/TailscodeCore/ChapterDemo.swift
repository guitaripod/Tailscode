import CodingAgentKit
import Foundation

/// A conversation that has been through three chapters, for every client's screenshots, demo and
/// selftests: the same words and the same boundaries on three desks.
public enum ChapterDemo {
    public struct Conversation: Sendable {
        public let messages: [ChatMessage]
        public let chapters: [ConversationChapter]
    }

    private static let script: [(prompt: String, answer: String)] = [
        ("Reopening a chat after the phone slept freezes the stream. Look at the reconnect path.",
         "The stream reconnects, but the replay asks from a cursor the bridge already dropped, and URLSession never returns on the 401 that follows."),
        ("Fix it so a 401 fails fast and the chat re-reads the transcript.",
         "Done: a 401 now ends the stream at once and the conversation re-reads. Kit 0.42.3 is tagged."),
        ("Bridge restarts keep killing the turn I'm in. Make them wait.",
         "A restart now waits for a quiet machine: no turn open and nothing queued. The update holds until then."),
        ("And a machine with no supervisor?",
         "It is handed the command instead of being restarted, so nothing dies under you. Released as 1.21.0."),
        ("As the session goes on the title changes. I want to see how it evolved, at a glance.",
         "The bridge re-titles every three of your messages when the topic moves and throws the old title away. I'll keep each one as a chapter, with what it came to."),
        ("Show it in the transcript too, not only in a sheet.",
         "Each chapter gets a heading above the message it began at; pressing one opens the chapters on it."),
    ]

    public static func conversation(now: Date = Date(), agentType: AgentType = .claudeCode) -> Conversation {
        let start = now.addingTimeInterval(-3 * 3600)
        var messages: [ChatMessage] = []
        for (index, turn) in script.enumerated() {
            let asked = start.addingTimeInterval(Double(index) * 1800)
            messages.append(
                ChatMessage(
                    id: "chapter-demo-u\(index + 1)", role: .user, agentType: agentType,
                    parts: [MessagePart(id: "t", kind: .text(turn.prompt))], createdAt: asked))
            messages.append(
                ChatMessage(
                    id: "chapter-demo-a\(index + 1)", role: .assistant, agentType: agentType,
                    parts: [MessagePart(id: "t", kind: .text(turn.answer))],
                    createdAt: asked.addingTimeInterval(90)))
        }
        func at(_ turn: Int) -> Date { start.addingTimeInterval(Double(turn - 1) * 1800) }
        let chapters = [
            ConversationChapter(
                title: "Fix stream freeze on resume", turn: 1,
                messageID: "chapter-demo-u1", startedAt: at(1),
                gist: "Traced the freeze to URLSession hanging on a 401 and tagged Kit 0.42.3.",
                namedBy: .model),
            ConversationChapter(
                title: "Bridge restarts wait for quiet", turn: 3,
                messageID: "chapter-demo-u3", startedAt: at(3),
                gist: "Restarts now wait for a quiet machine; released claude-bridge 1.21.0.",
                namedBy: .model),
            ConversationChapter(
                title: "Chat title history as chapters", turn: 5,
                messageID: "chapter-demo-u5", startedAt: at(5), namedBy: .model),
        ]
        return Conversation(messages: messages, chapters: chapters)
    }
}
