import CodingAgentKit
import Foundation

enum AppCache {
    static let sessionCache: SessionCache? = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sessions", isDirectory: true)
        return try? FileSessionCache(directory: dir)
    }()
}

/// Persists the user's chosen model per session (keyed by connection + session id) so a
/// per-message model choice survives reopening the chat. Also stores a global default per
/// context (without session id) so new chats default to the last-used model.
enum ModelPreferenceStore {
    private static let prefix = "tailscode.selectedModel."

    static func model(forKey key: String) -> ModelSelection? {
        guard let raw = UserDefaults.standard.string(forKey: prefix + key) else { return nil }
        return ModelSelection(string: raw)
    }

    static func setModel(_ model: ModelSelection?, forKey key: String) {
        let defaults = UserDefaults.standard
        if let model {
            defaults.set(model.rawValue, forKey: prefix + key)
        } else {
            defaults.removeObject(forKey: prefix + key)
        }
    }

    static func globalModel(forContextID contextID: String) -> ModelSelection? {
        model(forKey: contextID)
    }

    static func setGlobalModel(_ model: ModelSelection?, forContextID contextID: String) {
        setModel(model, forKey: contextID)
    }
}

/// Persists the chosen reasoning-effort level per session (Claude Code).
enum EffortPreferenceStore {
    private static let prefix = "tailscode.effort."

    static func effort(forKey key: String) -> String? {
        UserDefaults.standard.string(forKey: prefix + key)
    }

    static func setEffort(_ level: String?, forKey key: String) {
        let defaults = UserDefaults.standard
        if let level {
            defaults.set(level, forKey: prefix + key)
        } else {
            defaults.removeObject(forKey: prefix + key)
        }
    }
}
