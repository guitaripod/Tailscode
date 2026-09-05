import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("How full the context window is")
struct ContextWindowTests {
    private static func user(_ id: String, _ text: String) -> ChatMessage {
        ChatMessage(
            id: id, role: .user, agentType: .claudeCode,
            parts: [MessagePart(id: "t", kind: .text(text))], createdAt: Date())
    }

    private static func assistant(
        _ id: String, model: String? = "claude-opus-4-8-20260101", text: String = "ok",
        usage: MessageUsage? = nil, context: MessageUsage? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: id, role: .assistant, agentType: .claudeCode,
            parts: [MessagePart(id: "t", kind: .text(text))], createdAt: Date(),
            modelID: model, usage: usage, context: context)
    }

    private static func seam(_ id: String, after: Int?, summary: String = "") -> ChatMessage {
        ChatMessage(
            id: id, role: .system, agentType: .claudeCode,
            parts: [
                MessagePart(
                    id: "c",
                    kind: .compaction(Compaction(tokensBefore: 180_000, tokensAfter: after, summary: summary)))
            ], createdAt: Date())
    }

    @Test("The fill is the last request's footprint, never the turn's bill")
    func footprintNotBill() {
        let bill = MessageUsage(input: 400, output: 3000, cacheRead: 900_000, cacheWrite: 5_000)
        let footprint = MessageUsage(input: 20, output: 700, cacheRead: 140_000, cacheWrite: 0)
        let fill = ContextFill.read(messages: [
            Self.user("u1", "go"), Self.assistant("a1", usage: bill, context: footprint),
        ])
        #expect(fill?.used == 140_720)
        #expect(fill?.basis == .reported)
        #expect(fill?.window == 200_000)
        #expect(fill?.percent == 70)
        #expect(fill?.tone == .attention)
        #expect(fill?.badge == "70% · 140.7k")
    }

    @Test("A transcript nobody measured is estimated and says so")
    func estimatedWhenUnreported() {
        let fill = ContextFill.read(messages: [
            Self.user("u1", String(repeating: "word ", count: 800)),
            Self.assistant("a1", text: String(repeating: "word ", count: 800)),
        ])
        #expect(fill?.basis == .estimated)
        #expect(fill?.isEstimate == true)
        #expect(fill?.badge.hasPrefix("1% · ~") == true)
    }

    @Test("A compaction resets the count to what survived it")
    func compactionResets() {
        let fill = ContextFill.read(messages: [
            Self.user("u1", "go"),
            Self.assistant("a1", context: MessageUsage(input: 10, output: 10, cacheRead: 190_000)),
            Self.seam("s1", after: 24_000),
            Self.user("u2", "carry on"),
        ])
        #expect(fill?.used == 24_000)
        #expect(fill?.basis == .compacted)
        #expect(fill?.tone == .quiet)
    }

    @Test("An answer after the seam is the fill again")
    func answerAfterSeamWins() {
        let fill = ContextFill.read(messages: [
            Self.seam("s1", after: 24_000),
            Self.user("u2", "carry on"),
            Self.assistant("a2", context: MessageUsage(input: 100, output: 900, cacheRead: 30_000)),
        ])
        #expect(fill?.used == 31_000)
        #expect(fill?.basis == .reported)
    }

    @Test("The catalog's limit outranks the name, and an alias matches a dated id")
    func catalogOutranksName() {
        let catalog = [
            ModelInfo(id: "opus", name: "Opus", providerID: "anthropic", contextWindow: 1_000_000),
            ModelInfo(id: "qwen3-coder:30b", name: "Qwen", providerID: "ollama", contextWindow: 65_536),
        ]
        #expect(ContextWindow.resolve(model: "claude-opus-4-8-20260101", catalog: catalog, observed: 10) == 1_000_000)
        #expect(ContextWindow.resolve(model: "qwen3-coder:30b", catalog: catalog, observed: 10) == 65_536)
        #expect(ContextWindow.resolve(model: "claude-sonnet-5", catalog: catalog, observed: 10) == 200_000)
    }

    @Test("A name nobody knows has no share, only a count")
    func unknownModelHasNoShare() {
        let fill = ContextFill.read(
            messages: [
                Self.user("u1", "go"),
                Self.assistant("a1", model: "mystery-7b", context: MessageUsage(input: 5_000, output: 500)),
            ])
        #expect(fill?.window == nil)
        #expect(fill?.percent == nil)
        #expect(fill?.badge == "5.5k")
        #expect(fill?.tone == .quiet)
        #expect(fill?.summary.contains("not reported") == true)
    }

    @Test("A fill past Claude's matched window is the million-token window")
    func stretchesToTheMillion() {
        let fill = ContextFill.read(messages: [
            Self.assistant("a1", model: "claude-opus-4-8", context: MessageUsage(input: 1000, cacheRead: 450_000)),
        ])
        #expect(fill?.window == 1_000_000)
        #expect(fill?.percent == 45)
    }

    @Test("A local model on the person's own machine reads the same way")
    func localModel() {
        let fill = ContextFill.read(
            messages: [
                Self.assistant("a1", model: "qwen3:30b", context: MessageUsage(input: 40_000, output: 2_000)),
            ], catalog: [ModelInfo(id: "qwen3:30b", name: "Qwen", providerID: "ollama", contextWindow: 262_144)])
        #expect(fill?.window == 262_144)
        #expect(fill?.percent == 16)
        #expect(fill?.slices.map(\.id) == ["input", "output"])
    }

    @Test("Slices are shares of the window and the words carry the tone")
    func slicesAndWords() {
        let fill = ContextFill(
            used: 170_000, window: 200_000, model: "claude-fable-5", basis: .reported,
            tiers: MessageUsage(input: 4_000, output: 6_000, cacheRead: 160_000))
        #expect(fill.tone == .danger)
        #expect(fill.advice != nil)
        #expect(fill.slices.first?.id == "cacheRead")
        #expect(abs((fill.slices.first?.share ?? 0) - 0.8) < 0.001)
        #expect(fill.headline == "170.0k of 200.0k")
        #expect(fill.summary.contains("85%"))
        #expect(fill.facts.map(\.label) == ["in use", "window", "free", "model"])
    }

    @Test("The band segment wears the fill and opens it")
    func bandSegment() {
        let fill = ContextFill(used: 20_000, window: 200_000, model: "claude-haiku-4-5", basis: .reported)
        var state = ConversationState()
        state.connection = .live
        let facts = StatusFacts.from(state: state, agents: [], usage: nil, attachments: 0, context: fill)
        let segment = facts.segments.first { $0.id == "context" }
        #expect(segment?.text == "10% · 20.0k")
        #expect(segment?.css == "seg-dim")
        #expect(segment?.action == .context)
        #expect(abs((segment?.meter ?? 0) - 0.1) < 0.001)
    }
}
