import Foundation

/// `keybindings.json` as a file: read into overrides, and edited without losing anything a person
/// wrote there by hand. The rebinding screens and a text editor share this one file, so a screen's
/// edit changes only the ids it was about — notes, `_defaults`, and ids from a newer build all come
/// back out exactly as they went in.
public enum ShortcutFile {
    public enum Change: Equatable, Sendable {
        case bind([String])
        case restoreDefault
    }

    public enum Failure: Error, Equatable, Sendable {
        /// The file exists and is not a JSON object. Writing over it would destroy what somebody
        /// typed, so the edit is refused and the screen says why.
        case unreadable
    }

    /// What the file says, and what is wrong with it.
    public static func parse(_ data: Data) -> (overrides: [String: [String]], issues: [String]) {
        var overrides: [String: [String]] = [:]
        var issues: [String] = []
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([:], [Localized.text("keybindings.json is not valid JSON")])
        }
        let known = Set(ShortcutRegistry.all.map(\.id))
        for (key, value) in parsed where !key.hasPrefix("_") {
            guard known.contains(key) else {
                issues.append(Localized.text("unknown shortcut id \"%@\"", key))
                continue
            }
            switch value {
            case let spec as String:
                overrides[key] = spec.isEmpty ? [] : [spec]
            case let specs as [String]:
                overrides[key] = specs
            case is NSNull:
                overrides[key] = []
            default:
                issues.append(Localized.text("\"%@\" must be a string, a list or null", key))
            }
        }
        return (overrides, issues)
    }

    /// The file a person who never edited anything gets: notes and the shipped table, nothing
    /// bound. Only `_` keys are written, so it starts as documentation and upgrades keep shipping
    /// new defaults to people who never rebound anything.
    static func starter() -> [String: Any] {
        var defaults: [String: Any] = [:]
        for definition in ShortcutRegistry.all {
            defaults[definition.id] =
                definition.defaults.count == 1 ? definition.defaults[0] : definition.defaults
        }
        return [
            "_readme": [
                "Settings → Keyboard rebinds by pressing keys; this file is the same thing as text.",
                "Rebind by id: \"chat.archive\": \"e\", a list for several keys, null to unbind.",
                "Modifiers ctrl+ shift+ alt+ · sequences as two keys with a space: \"g g\".",
                "Named keys: enter escape tab space backspace delete home end pageup pagedown up down left right minus plus equal comma period f1…f12.",
                "Limit a binding: \"normal:f\" or \"normal,insert:ctrl+b\" (normal, insert, terminal).",
                "Keys starting with _ are ignored. _defaults shows every id as shipped.",
                "Apply with Settings → Keyboard → Reload, or restart.",
            ],
            "_defaults": defaults,
        ]
    }

    private static func serialized(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    /// The bytes the file should hold after `changes`: `existing` with each named id rewritten
    /// and everything else untouched. A binding is written the way a person would — a bare string
    /// for one key, a list for several, `null` for none — and restoring a default removes the id
    /// altogether, so the file never pins a value the shipped table already says.
    public static func applying(_ changes: [String: Change], to existing: Data?) throws -> Data {
        var object: [String: Any]
        if let existing, !existing.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any]
            else { throw Failure.unreadable }
            object = parsed
        } else {
            object = starter()
        }
        for (id, change) in changes {
            switch change {
            case .restoreDefault:
                object[id] = nil
            case .bind(let specs):
                switch specs.count {
                case 0: object[id] = NSNull()
                case 1: object[id] = specs[0]
                default: object[id] = specs
                }
            }
        }
        guard let data = serialized(object) else { throw Failure.unreadable }
        return data
    }

    public static func write(_ changes: [String: Change]) throws {
        guard !changes.isEmpty else { return }
        let url = ShortcutSet.configURL
        let data = try applying(changes, to: try? Data(contentsOf: url))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Whether `keybindings.json` exists and is not a JSON object: the one state in which no edit
    /// can be made, because writing over it would destroy what somebody typed.
    public static var isUnreadable: Bool {
        guard let data = try? Data(contentsOf: ShortcutSet.configURL), !data.isEmpty else {
            return false
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] == nil
    }

    /// Every id back to its shipped keys, with the notes and anything unknown left alone. A file
    /// that cannot be read at all is the one case an edit refuses, and the one reset is for: what
    /// was there is kept beside it as `keybindings.json.broken` and the starter takes its place.
    public static func resetAll() throws {
        let known = ShortcutRegistry.all.map(\.id)
        do {
            try write(Dictionary(uniqueKeysWithValues: known.map { ($0, Change.restoreDefault) }))
        } catch Failure.unreadable {
            try replaceWithStarter()
        }
    }

    private static func replaceWithStarter() throws {
        let url = ShortcutSet.configURL
        let kept = url.appendingPathExtension("broken")
        let manager = FileManager.default
        try? manager.removeItem(at: kept)
        try manager.moveItem(at: url, to: kept)
        guard let data = serialized(starter()) else { throw Failure.unreadable }
        try data.write(to: url, options: .atomic)
    }

    /// Writes the starter file if none exists, so "edit the shortcuts" always has a file to open.
    public static func ensureStarter() {
        let url = ShortcutSet.configURL
        guard !FileManager.default.fileExists(atPath: url.path), let data = serialized(starter())
        else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
