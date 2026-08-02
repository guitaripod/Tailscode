import Foundation

/// Where the desktop's own state actually lives: one JSON file under `$XDG_CONFIG_HOME/tailscode`.
///
/// `UserDefaults` on Linux keys its store to the running executable, so a build installed to a new
/// path — a new release, a package instead of a local build — starts with an empty one and every
/// window size, pane, bookmark and draft appears to have been thrown away. This file is the
/// durable copy: read into the defaults at launch, written back as things change.
///
/// The file records what the app *set*, never what it merely read. Corelibs materialises a
/// zero-valued entry for a key that is only ever looked up, and a settings file that learns
/// "the file tree is hidden" from a lookup would hide it on the next launch.
enum SettingsFile {
    private static let dataKey = "__data"

    /// Keys written by the shared stores rather than by this app's own settings — bookmarks, seen
    /// state, per-session drafts and model choices. Captured by prefix because their key space is
    /// per session.
    private static let capturedPrefixes = [
        "tailscode.saved.chats", "tailscode.seen.", "tailscode.selectedModel.",
        "tailscode.effort.", "tailscode.recentModels", "tailscode.draft.",
        "tailscode.archived.",
    ]

    private nonisolated(unsafe) static var state: [String: Any] = [:]

    static var url: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
        return base.appendingPathComponent("tailscode", isDirectory: true)
            .appendingPathComponent("ui.json")
    }

    static func load() {
        guard let data = try? Data(contentsOf: url),
            let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let defaults = UserDefaults.standard
        for (key, value) in stored {
            let restored = decode(value)
            state[key] = restored
            defaults.set(restored, forKey: key)
        }
    }

    /// The single write path for a setting: the defaults keep working for every reader, and the
    /// file learns the value at the same moment.
    static func set(_ value: Any?, forKey key: String) {
        let defaults = UserDefaults.standard
        if let value {
            state[key] = value
            defaults.set(value, forKey: key)
        } else {
            state.removeValue(forKey: key)
            defaults.removeObject(forKey: key)
        }
        save()
    }

    /// Pulls the shared stores' own keys into the file. Empty and zero values are skipped unless
    /// the key is already known, which is what keeps a mere lookup from being recorded as a
    /// deliberate "off".
    static func capture() {
        let defaults = UserDefaults.standard
        for (key, value) in defaults.dictionaryRepresentation()
        where capturedPrefixes.contains(where: { key.hasPrefix($0) }) {
            if state[key] == nil, isEmpty(value) { continue }
            state[key] = value
        }
        save()
    }

    static func save() {
        var payload: [String: Any] = [:]
        for (key, value) in state {
            switch value {
            case let data as Data: payload[key] = [dataKey: data.base64EncodedString()]
            case let number as NSNumber: payload[key] = number
            case let text as String: payload[key] = text
            default:
                if JSONSerialization.isValidJSONObject([value]) { payload[key] = value }
            }
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        else { return }
        if let existing = try? Data(contentsOf: url), existing == data { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func decode(_ value: Any) -> Any {
        if let wrapper = value as? [String: String], let encoded = wrapper[dataKey],
            let data = Data(base64Encoded: encoded)
        {
            return data
        }
        return value
    }

    private static func isEmpty(_ value: Any) -> Bool {
        switch value {
        case let number as NSNumber: return number.doubleValue == 0
        case let text as String: return text.isEmpty
        case let data as Data: return data.isEmpty
        case let array as [Any]: return array.isEmpty
        case let dictionary as [String: Any]: return dictionary.isEmpty
        default: return false
        }
    }
}
