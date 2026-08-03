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

    /// The model a chat opens with: its own recorded pick, else the last model
    /// used anywhere on that server — never a hardcoded default.
    public static func initialModel(sessionKey: String?, contextID: String) -> ModelSelection? {
        sessionKey.flatMap { model(forKey: $0) } ?? globalModel(forContextID: contextID)
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

    /// The effort a chat opens at: its own recorded pick, else the effort last
    /// used anywhere on that server.
    public static func initialEffort(sessionKey: String?, contextID: String) -> String? {
        sessionKey.flatMap { effort(forKey: $0) } ?? globalEffort(forContextID: contextID)
    }

    public static func recordPick(_ level: String?, sessionKey: String?, contextID: String) {
        if let sessionKey { setEffort(level, forKey: sessionKey) }
        setGlobalEffort(level, forContextID: contextID)
    }
}
