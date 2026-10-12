import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("The words of a chat that did not go as hoped")
struct ChatReadingsTests {
    private static func assistant(error: String?, model: String? = nil) -> ChatMessage {
        ChatMessage(
            id: "a", role: .assistant, agentType: .claudeCode, createdAt: Date(), error: error,
            modelID: model)
    }

    private static func prompt(_ words: String) -> ChatMessage {
        ChatMessage(
            id: "u", role: .user, agentType: .claudeCode,
            parts: [MessagePart(id: "p", kind: .text(words))], createdAt: Date())
    }

    @Test("A failure becomes a card carrying the server's words and the prompt to send again")
    func aFailureReads() throws {
        let turn = try #require(
            FailedTurnReading.read(
                Self.assistant(error: "API Error:\n  529 overloaded", model: "opus"),
                prompt: Self.prompt("fix it")))
        #expect(turn.reason == "API Error: 529 overloaded")
        #expect(turn.prompt == "fix it")
        #expect(turn.offersRemedy)
        #expect(turn.spoken.contains(turn.reason))
    }

    @Test("A turn with no error, an empty one, or a user message reads as no failure")
    func noFailureNoCard() {
        #expect(FailedTurnReading.read(Self.assistant(error: nil), prompt: nil) == nil)
        #expect(FailedTurnReading.read(Self.assistant(error: " \n "), prompt: nil) == nil)
    }

    @Test("A very long error is cut once and the cut is marked")
    func longErrorsAreCut() throws {
        let turn = try #require(
            FailedTurnReading.read(
                Self.assistant(error: String(repeating: "word ", count: 200)), prompt: nil))
        #expect(turn.reason.count <= FailedTurnReading.longest + 1)
        #expect(turn.reason.hasSuffix("…"))
        #expect(!turn.offersRemedy)
    }

    @Test("Every empty-chat starter has words, a symbol and a glyph")
    func startersAreComplete() {
        let all = ChatSuggestion.all
        #expect(all.count == 4)
        for suggestion in all {
            #expect(!suggestion.title.isEmpty && !suggestion.prompt.isEmpty)
            #expect(!suggestion.symbol.isEmpty && suggestion.glyph.count == 1)
        }
        #expect(Set(all.map(\.id)).count == all.count)
    }

    @Test("The jump control names what is waiting before it counts what arrived")
    func jumpSaysWhatMatters() {
        #expect(JumpReading.read(rowsNow: 40, rowsAtDeparture: nil, needsYou: false).label == nil)
        #expect(JumpReading.read(rowsNow: 40, rowsAtDeparture: 40, needsYou: false).cause == .plain)
        #expect(JumpReading.read(rowsNow: 43, rowsAtDeparture: 40, needsYou: false).cause == .news)
        let waiting = JumpReading.read(rowsNow: 43, rowsAtDeparture: 40, needsYou: true)
        #expect(waiting.cause == .needsYou)
        #expect(waiting.tone == .attention)
        #expect(JumpReading.read(rowsNow: 43, rowsAtDeparture: 40, needsYou: false).tone == .quiet)
    }
}

@Suite("The scale a chat's chrome is drawn from")
struct ChatChromeTests {
    @Test("A touch chip is answered by a 44-point target however small it is drawn")
    func touchTargetsAreFingerSized() {
        let touch = ChatChrome.chip(on: .touch)
        #expect(touch.hit >= 44)
        #expect(touch.height < touch.hit)
        #expect(ChatChrome.chip(on: .pointer).height == 24)
    }

    @Test("Every kind of chip has a fill that is its own colour")
    func fillsAreOpaque() {
        for kind in ChatChrome.Kind.allCases {
            #expect(ChatChrome.fill(kind).opaque, "\(kind) lets the transcript show through")
        }
        #expect(ChatChrome.fill(.control).outlined)
        #expect(!ChatChrome.fill(.fact).outlined)
    }

    @Test("A live chip is never quiet: something is going on")
    func liveChipsAreLive() {
        #expect(ChatChrome.glyphTone(.live, tone: .quiet) == .live)
        #expect(ChatChrome.glyphTone(.live, tone: .attention) == .attention)
        #expect(ChatChrome.glyphTone(.fact, tone: .quiet) == .quiet)
    }
}
