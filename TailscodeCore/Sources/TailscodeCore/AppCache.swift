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
}
