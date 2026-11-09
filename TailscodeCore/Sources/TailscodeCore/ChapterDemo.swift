import CodingAgentKit
import Foundation

/// A conversation that has been through three chapters, in the demo world's own project, for every
/// client's demo, screenshots and selftests: the same words and the same boundaries on three desks.
public enum ChapterDemo {
    public struct Conversation: Sendable {
        public let messages: [ChatMessage]
        public let chapters: [ConversationChapter]
    }

    private static let script: [(prompt: String, answer: String)] = [
        ("Reopening the app after the phone slept leaves the feed blank. Look at the resume path.",
         "The feed reconnects, but the replay asks from a cursor the server already dropped, and the request that follows a 401 never times out."),
        ("Make a 401 fail fast and reload the feed.",
         "Done: a 401 now ends the stream at once and the feed reloads. Tagged pulse-ios 2.4.1."),
        ("Server deploys keep cutting off uploads in progress. Make them wait.",
         "A deploy now waits until no upload is open and nothing is queued, then restarts."),
        ("And a node with no supervisor?",
         "It is handed the restart instead of being killed, so no upload dies under anyone. Released as pulse-server 3.2."),
        ("Settings needs a way to see what changed in each release, at a glance.",
         "I'll group the changelog by release, with one line on what each release came to."),
        ("Show it inline too, not only in a sheet.",
         "Each release gets a heading above where it starts; tapping one opens the list on it."),
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
                title: "Blank feed after resume", turn: 1,
                messageID: "chapter-demo-u1", startedAt: at(1),
                gist: "Traced the blank feed to a request hanging on a 401 and tagged pulse-ios 2.4.1.",
                namedBy: .model),
            ConversationChapter(
                title: "Deploys wait for idle uploads", turn: 3,
                messageID: "chapter-demo-u3", startedAt: at(3),
                gist: "Deploys now wait until no upload is open; released pulse-server 3.2.",
                namedBy: .model),
            ConversationChapter(
                title: "Release notes in settings", turn: 5,
                messageID: "chapter-demo-u5", startedAt: at(5), namedBy: .model),
        ]
        return Conversation(messages: messages, chapters: chapters)
    }
}
