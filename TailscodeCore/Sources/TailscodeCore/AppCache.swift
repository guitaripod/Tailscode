import CodingAgentKit
import Foundation

public enum AppCache {
    public static let sessionCache: SessionCache? = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sessions", isDirectory: true)
        return try? FileSessionCache(directory: dir)
    }()
}

/// Persists the user's chosen model per session (keyed by connection + session id) so a
/// per-message model choice survives reopening the chat. Also stores a global default per
/// context (without session id) so new chats default to the last-used model.
public enum ModelPreferenceStore {
    private static let prefix = "tailscode.selectedModel."

    public static func model(forKey key: String) -> ModelSelection? {
        guard let raw = UserDefaults.standard.string(forKey: prefix + key) else { return nil }
        return ModelSelection(string: raw)
    }

    public static func setModel(_ model: ModelSelection?, forKey key: String) {
        let defaults = UserDefaults.standard
        if let model {
            defaults.set(model.rawValue, forKey: prefix + key)
        } else {
            defaults.removeObject(forKey: prefix + key)
        }
    }

    public static func globalModel(forContextID contextID: String) -> ModelSelection? {
        model(forKey: contextID)
    }

    public static func setGlobalModel(_ model: ModelSelection?, forContextID contextID: String) {
        setModel(model, forKey: contextID)
    }

    /// The model a chat opens with, in the exact order its chat row reads (`ModelBadge.chip(for
    /// entry:)`): this device's recorded pick, else what the server says the session runs, else
    /// the last model used anywhere on that server. The row and the composer above it must never
    /// name different models, so a session driven from another device opens on the model its row
    /// wears — not on this server's global default — and a pick made here still wins until the
    /// record catches up with it.
    public static func initialModel(
        sessionKey: String?, contextID: String, sessionModel: String? = nil,
        sessionModelProviderID: String? = nil
    ) -> ModelSelection? {
        sessionKey.flatMap { model(forKey: $0) }
            ?? resolveSessionModel(
                sessionModel, contextID: contextID, providerID: sessionModelProviderID)
            ?? globalModel(forContextID: contextID)
    }

    /// A session record names a model as one bare string — a bridge writes `claude-fable-5`
    /// where its catalog offers `fable` — and a send needs provider and id. The string is read
    /// against the server's own cached catalog: by id, by display name, then by the family name
    /// the row's chip would print for it, so the record and the catalog meet exactly where the
    /// reader already sees them agree. The `provider/model` parse is the last resort, not the
    /// first — an opencode id can itself contain a slash — and a name nothing can place resolves
    /// to nothing rather than to a fabricated provider.
    ///
    /// When the record says which door the session runs through, that door settles the match
    /// rather than the catalog's own order: two gateways offering the same model id bill it
    /// differently, and the session's own door is the one fact that tells them apart.
    public static func resolveSessionModel(
        _ raw: String?, contextID: String, providerID: String? = nil
    ) -> ModelSelection? {
        guard let raw, !raw.isEmpty else { return nil }
        let catalog = ModelCatalogStore.cached(contextID)
        let family = ModelBadge.shortName(raw)
        if let providerID, !providerID.isEmpty,
            let match = catalog.first(where: {
                $0.providerID.caseInsensitiveCompare(providerID) == .orderedSame
                    && ($0.id.caseInsensitiveCompare(raw) == .orderedSame
                        || $0.name.caseInsensitiveCompare(raw) == .orderedSame
                        || $0.name.caseInsensitiveCompare(family) == .orderedSame)
            })
        {
            return ModelSelection(providerID: match.providerID, modelID: match.id)
        }
        if let match = catalog.first(where: { $0.id.caseInsensitiveCompare(raw) == .orderedSame })
            ?? catalog.first(where: { $0.name.caseInsensitiveCompare(raw) == .orderedSame })
            ?? catalog.first(where: { $0.name.caseInsensitiveCompare(family) == .orderedSame })
        {
            return ModelSelection(providerID: match.providerID, modelID: match.id)
        }
        return ModelSelection(string: raw)
    }

    /// Records a pick everywhere a future chat looks for one: the session's own
    /// key, the server's last-used default, and the recents shortlist.
    public static func recordPick(
        _ model: ModelSelection?, sessionKey: String?, contextID: String
    ) {
        if let sessionKey { setModel(model, forKey: sessionKey) }
        setGlobalModel(model, forContextID: contextID)
        if let model { RecentModelsStore.record(model) }
    }
}

/// The last few models picked anywhere, surfaced as a "Recent" section at the
/// top of the model picker (opencode catalogs run to hundreds of models).
public enum RecentModelsStore {
    static let storageKey = "tailscode.recentModels"

    public static func all() -> [ModelSelection] {
        (UserDefaults.standard.stringArray(forKey: storageKey) ?? [])
            .compactMap(ModelSelection.init(string:))
    }

    public static func record(_ selection: ModelSelection) {
        var raw = UserDefaults.standard.stringArray(forKey: storageKey) ?? []
        raw.removeAll { $0 == selection.rawValue }
        raw.insert(selection.rawValue, at: 0)
        UserDefaults.standard.set(Array(raw.prefix(5)), forKey: storageKey)
    }
}

/// The models you starred, in the order you starred them, surfaced as a Pinned
/// section above every family and merged into every quick menu. Stars live on
/// this device: a model you pin on the phone is the one you reach for there.
public enum ModelFavoritesStore {
    static let storageKey = "tailscode.favoriteModels"
    static let limit = 24

    public static func all() -> [ModelSelection] {
        (UserDefaults.standard.stringArray(forKey: storageKey) ?? [])
            .compactMap(ModelSelection.init(string:))
    }

    public static func isFavorite(_ selection: ModelSelection) -> Bool {
        all().contains { $0 == selection }
    }

    public static func toggle(_ selection: ModelSelection) {
        var raw = UserDefaults.standard.stringArray(forKey: storageKey) ?? []
        if let index = raw.firstIndex(of: selection.rawValue) {
            raw.remove(at: index)
        } else {
            raw.insert(selection.rawValue, at: 0)
        }
        UserDefaults.standard.set(Array(raw.prefix(limit)), forKey: storageKey)
    }
}

/// Persists the chosen reasoning-effort level per session (Claude Code), plus a
/// per-server default so a new chat starts at the effort you last worked at.
public enum EffortPreferenceStore {
    static let storagePrefix = "tailscode.effort."

    public static func effort(forKey key: String) -> String? {
        UserDefaults.standard.string(forKey: storagePrefix + key)
    }

    public static func globalEffort(forContextID contextID: String) -> String? {
        effort(forKey: contextID)
    }

    public static func setGlobalEffort(_ level: String?, forContextID contextID: String) {
        setEffort(level, forKey: contextID)
    }

    public static func setEffort(_ level: String?, forKey key: String) {
        let defaults = UserDefaults.standard
        if let level {
            defaults.set(level, forKey: storagePrefix + key)
        } else {
            defaults.removeObject(forKey: storagePrefix + key)
        }
    }

    /// The effort a chat opens at, in the row's own reading order: this device's recorded pick,
    /// else what the server reports for the session, else the effort last used anywhere on that
    /// server.
    public static func initialEffort(
        sessionKey: String?, contextID: String, sessionEffort: String? = nil
    ) -> String? {
        if let picked = sessionKey.flatMap({ effort(forKey: $0) }) { return picked }
        if let sessionEffort, !sessionEffort.isEmpty { return sessionEffort }
        return globalEffort(forContextID: contextID)
    }

    public static func recordPick(_ level: String?, sessionKey: String?, contextID: String) {
        if let sessionKey { setEffort(level, forKey: sessionKey) }
        setGlobalEffort(level, forContextID: contextID)
    }
}
