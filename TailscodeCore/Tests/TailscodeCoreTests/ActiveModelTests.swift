import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Active model")
struct ActiveModelTests {
    private let now = Date()

    private func assistant(
        _ model: String?, via provider: String? = nil, error: String? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: UUID().uuidString, role: .assistant, agentType: .openCode, createdAt: now,
            error: error, providerID: provider, modelID: model)
    }

    private func session(model: String?, via provider: String? = nil) -> AgentSession {
        AgentSession(
            id: "s", agentType: .openCode, title: "t", createdAt: now, updatedAt: now,
            model: model, modelProviderID: provider)
    }

    private let catalog = [
        ModelInfo(id: "qwen38-nvfp4", name: "Qwen 3.8", providerID: "llama-server"),
        ModelInfo(id: "kimi-k2.5", name: "Kimi", providerID: "opencode-go"),
    ]

    @Test("The pick wins over everything")
    func pick() {
        let picked = ModelSelection(providerID: "opencode-go", modelID: "kimi-k2.5")
        let got = ActiveModel.selection(
            picked: picked, messages: [assistant("qwen38-nvfp4", via: "llama-server")],
            session: session(model: "qwen38-nvfp4", via: "llama-server"), catalog: catalog)
        #expect(got == picked)
    }

    @Test("The transcript carries the door the last answer came through")
    func transcriptDoor() {
        let got = ActiveModel.selection(
            picked: nil,
            messages: [
                assistant("kimi-k2.5", via: "opencode-go"),
                assistant("qwen38-nvfp4", via: "llama-server"),
            ],
            session: session(model: "kimi-k2.5", via: "opencode-go"))
        #expect(got == ModelSelection(providerID: "llama-server", modelID: "qwen38-nvfp4"))
    }

    @Test("A transcript that names only the model is looked up in the catalog")
    func catalogDoor() {
        let got = ActiveModel.selection(
            picked: nil, messages: [assistant("qwen38-nvfp4")], session: nil, catalog: catalog)
        #expect(got?.providerID == "llama-server")
        let unknown = ActiveModel.selection(
            picked: nil, messages: [assistant("mystery-9")], session: nil, catalog: catalog)
        #expect(unknown == ModelSelection(providerID: ActiveModel.unknownDoor, modelID: "mystery-9"))
    }

    @Test("The session record is the fallback and keeps its own door")
    func sessionDoor() {
        let recorded = ActiveModel.selection(
            picked: nil, messages: [], session: session(model: "qwen38-nvfp4", via: "llama-server"))
        #expect(recorded == ModelSelection(providerID: "llama-server", modelID: "qwen38-nvfp4"))
        let bare = ActiveModel.selection(
            picked: nil, messages: [], session: session(model: "qwen38-nvfp4"), catalog: catalog)
        #expect(bare?.providerID == "llama-server")
        let slashed = ActiveModel.selection(
            picked: nil, messages: [], session: session(model: "llama-server/qwen38-nvfp4"))
        #expect(slashed?.providerID == "llama-server")
        #expect(ActiveModel.selection(picked: nil, messages: [], session: session(model: nil)) == nil)
    }

    @Test("The failed turn names the door it died on")
    func failedTurn() {
        let messages = [
            assistant("qwen38-nvfp4", via: "llama-server"),
            assistant("kimi-k2.5", via: "opencode-go", error: "monthly usage limit reached"),
            assistant("qwen38-nvfp4", via: "llama-server"),
        ]
        #expect(
            ActiveModel.failedTurn(in: messages)
                == ModelSelection(providerID: "opencode-go", modelID: "kimi-k2.5"))
        #expect(ActiveModel.failedTurn(in: [assistant("kimi-k2.5", via: "opencode-go")]) == nil)
    }
}
