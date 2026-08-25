import CodingAgentKit
import CodingAgentKitApple
import Foundation

/// Every server's catalog, kept where all three clients read it from. A catalog is expensive to ask
/// for and cheap to remember, and the model list has to be able to name a machine you are not
/// currently talking to — so what each server last reported is stored under its own profile and
/// survives the app.
public enum ModelCatalogStore {
    static let prefix = "tailscode.modelCatalog."

    public static func cached(_ profileID: String) -> [ModelInfo] {
        guard let data = UserDefaults.standard.data(forKey: prefix + profileID),
            let models = try? JSONDecoder().decode([ModelInfo].self, from: data)
        else { return [] }
        return models
    }

    public static func store(_ models: [ModelInfo], for profileID: String) {
        guard !models.isEmpty, let data = try? JSONEncoder().encode(models) else { return }
        UserDefaults.standard.set(data, forKey: prefix + profileID)
    }

    /// Forgets one server's catalog — what a removed profile leaves behind, and what a test that
    /// asserts on the first reading has to do before it asks, since the remembered list outlives
    /// the process that wrote it.
    public static func forget(_ profileID: String) {
        UserDefaults.standard.removeObject(forKey: prefix + profileID)
    }

    /// Asks a server what it runs and remembers the answer. Failure is silent on purpose: a server
    /// that cannot be reached keeps the catalog it last gave, which is what lets the chooser still
    /// name its models.
    @discardableResult
    public static func refresh(
        profileID: String, backend: any CodingAgentBackend
    ) async -> [ModelInfo] {
        guard let models = try? await backend.availableModels(), !models.isEmpty else {
            return cached(profileID)
        }
        store(models, for: profileID)
        return models
    }
}

/// The whole fleet as one model list. Which machine runs a model is part of the answer, so the
/// chooser is built from every server that has ever told us what it runs, with the one you are
/// working on marked as the one a pick applies to directly.
public enum ModelFleet {
    public static func sources(
        profiles: [ConnectionProfile], current: String?, currentModels: [ModelInfo] = [],
        allowsServerDefault: Bool = true, reachability: [String: Bool] = [:]
    ) -> [ModelSource] {
        let ordered = profiles.sorted { lhs, _ in lhs.id == current }
        return ordered.compactMap { profile in
            let isCurrent = profile.id == current
            let models =
                isCurrent && !currentModels.isEmpty
                ? currentModels : ModelCatalogStore.cached(profile.id)
            guard !models.isEmpty else { return nil }
            return ModelSource(
                profileID: profile.id, name: profile.name, backend: profile.backend,
                models: models, isCurrent: isCurrent,
                allowsServerDefault: isCurrent ? allowsServerDefault : true,
                acceptsAnyModelID: profile.backend != .openCode,
                isReachable: reachability[profile.id])
        }
    }

    /// What a client has to do when a pick lands on another machine. The chat you are in cannot
    /// change machines — it is a process on one of them — so the model is remembered as that
    /// server's own choice and the client starts a chat there, which then opens on it.
    public static func adopt(_ pick: ModelPick) {
        ModelPreferenceStore.recordPick(pick.selection, sessionKey: nil, contextID: pick.profileID)
    }

    /// The sentence a client puts in front of someone before moving their work, so the move is
    /// never a surprise and never silent.
    public static func moveTitle(_ pick: ModelPick) -> String {
        Localized.text("Start a new chat on %@?", pick.serverName)
    }

    public static func moveBody(_ pick: ModelPick) -> String {
        Localized.text(
            "%@ runs on %@, and a conversation lives on the machine that answers it. This chat stays where it is.",
            pick.modelName, pick.serverName)
    }

    public static var moveAction: String { Localized.text("New chat there") }
}
