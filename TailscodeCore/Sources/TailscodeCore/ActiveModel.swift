import CodingAgentKit
import Foundation

/// The model a chat is on, with the door it runs through. An explicit pick wins, then the
/// transcript — the last assistant message names the model that wrote it, and on opencode the
/// provider that ran it — and the session record is the fallback for a chat with no answer in it
/// yet. A record that names only the model is looked up in the catalog before the door is given
/// up as `server`, because the door is what every quota reading bills against: a `qwen` with no
/// door is assumed to be the reseller's, and a `qwen` on `llama-server` is the machine's own.
public enum ActiveModel {
    /// The placeholder door for a model whose provider nobody recorded.
    public static let unknownDoor = "server"

    public static func selection(
        picked: ModelSelection?, messages: [ChatMessage], session: AgentSession?,
        catalog: [ModelInfo] = []
    ) -> ModelSelection? {
        if let picked { return picked }
        if let observed = lastAssistant(in: messages) {
            return ModelSelection(
                providerID: door(observed.providerID, model: observed.modelID ?? "", catalog: catalog),
                modelID: observed.modelID ?? "")
        }
        if let stored = session?.model, !stored.isEmpty {
            return ModelSelection(
                providerID: door(session?.modelProviderID, model: stored, catalog: catalog),
                modelID: stored)
        }
        return nil
    }

    /// The model the failed turn actually went out on — the provenance of a failure, which the
    /// failure string itself rarely carries. Only a backend that stamps its messages answers.
    public static func failedTurn(in messages: [ChatMessage]) -> ModelSelection? {
        guard let failed = messages.last(where: { $0.role == .assistant && $0.error != nil }),
            let model = failed.modelID, !model.isEmpty
        else { return nil }
        return ModelSelection(providerID: failed.providerID ?? unknownDoor, modelID: model)
    }

    private static func lastAssistant(in messages: [ChatMessage]) -> ChatMessage? {
        messages.last { $0.role == .assistant && !($0.modelID ?? "").isEmpty }
    }

    private static func door(_ recorded: String?, model: String, catalog: [ModelInfo]) -> String {
        if let recorded, !recorded.isEmpty { return recorded }
        if let known = catalog.first(where: { $0.id == model }) { return known.providerID }
        if let parsed = ModelSelection(string: model), ProviderIdentity.slug(parsed.providerID) != nil
            || ProviderIdentity.isLocal(parsed.providerID)
        {
            return parsed.providerID
        }
        return unknownDoor
    }
}
