import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// The line where the answering model changed: read once per settled answer, so a streamed token
/// costs the answer being written and nothing else.
@Suite struct ModelSeamTests {
    private let catalog = [
        ModelInfo(id: "qwen-daily", name: "Qwen Daily", providerID: "llama"),
        ModelInfo(id: "deepseek-v4", name: "DeepSeek V4", providerID: "opencode"),
    ]

    private func answer(
        _ id: String, model: String?, provider: String? = nil, effort: String? = nil,
        streaming: Bool = false
    ) -> ChatMessage {
        ChatMessage(
            id: id, role: .assistant, agentType: .openCode,
            parts: [MessagePart(id: id + "-t", kind: .text("text"))], createdAt: Date(),
            isStreaming: streaming, providerID: provider, modelID: model, reasoningEffort: effort)
    }

    private func question(_ id: String) -> ChatMessage {
        ChatMessage(
            id: id, role: .user, agentType: .openCode,
            parts: [MessagePart(id: id + "-t", kind: .text("q"))], createdAt: Date())
    }

    @Test func aChangeOfModelDrawsOneSeamAndTheFirstAnswerNone() {
        var tracker = ModelSeamTracker()
        let seams = tracker.update(
            [
                question("u1"), answer("a1", model: "deepseek-v4", provider: "opencode"),
                question("u2"), answer("a2", model: "qwen-daily", provider: "llama"),
            ], catalog: catalog)
        #expect(seams.count == 1)
        #expect(seams["a2"]?.to == "Qwen Daily")
        #expect(seams["a2"]?.from == "DeepSeek V4")
        #expect(seams["a2"]?.line == "Qwen Daily from DeepSeek V4")
    }

    @Test func effortAloneAndAnAliasAgainstItsResolvedIdMakeNoSeam() {
        var tracker = ModelSeamTracker()
        let seams = tracker.update(
            [
                answer("a1", model: "opus", provider: "anthropic", effort: "low"),
                answer("a2", model: "opus", provider: "anthropic", effort: "high"),
                answer("a3", model: "claude-opus-4-8", provider: "anthropic"),
            ], catalog: catalog)
        #expect(seams.isEmpty)
    }

    @Test func aStreamingAnswerShowsItsSeamAtOnceWithoutSettlingIt() {
        var tracker = ModelSeamTracker()
        let settled = [answer("a1", model: "deepseek-v4", provider: "opencode")]
        _ = tracker.update(settled, catalog: catalog)
        let live = settled + [answer("a2", model: "qwen-daily", provider: "llama", streaming: true)]
        #expect(tracker.update(live, catalog: catalog)["a2"]?.to == "Qwen Daily")
        #expect(tracker.update(live, catalog: catalog)["a2"]?.to == "Qwen Daily")
        let done = settled + [answer("a2", model: "qwen-daily", provider: "llama")]
        #expect(tracker.update(done, catalog: catalog)["a2"]?.to == "Qwen Daily")
        #expect(tracker.update(done, catalog: catalog).count == 1)
    }

    @Test func aReplacedTranscriptStartsOver() {
        var tracker = ModelSeamTracker()
        _ = tracker.update(
            [
                answer("a1", model: "deepseek-v4", provider: "opencode"),
                answer("a2", model: "qwen-daily", provider: "llama"),
            ], catalog: catalog)
        let other = tracker.update(
            [
                answer("b1", model: "qwen-daily", provider: "llama"),
                answer("b2", model: "qwen-daily", provider: "llama"),
            ], catalog: catalog)
        #expect(other.isEmpty)
    }

    @Test func aCatalogThatArrivesLaterRewordsTheSeam() {
        var tracker = ModelSeamTracker()
        let messages = [
            answer("a1", model: "deepseek-v4", provider: "opencode"),
            answer("a2", model: "qwen-daily", provider: "llama"),
        ]
        let bare = tracker.update(messages, catalog: [])
        let named = tracker.update(messages, catalog: catalog)
        #expect(bare["a2"]?.to != named["a2"]?.to)
        #expect(named["a2"]?.to == "Qwen Daily")
    }

    @Test func answersWithNoModelNeitherMakeNorBreakASeam() {
        var tracker = ModelSeamTracker()
        let seams = tracker.update(
            [
                answer("a1", model: "deepseek-v4", provider: "opencode"),
                answer("a2", model: nil),
                answer("a3", model: "deepseek-v4", provider: "opencode"),
            ], catalog: catalog)
        #expect(seams.isEmpty)
    }
}
