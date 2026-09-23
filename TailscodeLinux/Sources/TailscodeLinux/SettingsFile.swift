import Dispatch
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
///
/// Written only when something in it changed, and never on the main thread. The session list's
/// ten-second refresh used to write it three times a tick from the GTK thread (the divider it had
/// just read back, the split layout, the stores' keys), each time sorting and pretty-printing a
/// thousand keys and reading the whole file back to compare: about a quarter of a second of frozen
/// window every ten seconds, and a full rewrite whenever an update check stamped a new time. A
/// change now marks the file dirty and a writer queue does the encoding a moment later, once for a
/// burst of changes; `flush()` makes it synchronous where the process is about to go.
enum SettingsFile {
    private static let dataKey = "__data"

    /// Keys written by the shared stores rather than by this app's own settings — bookmarks, seen
    /// state, model choices, and the renderer the forge points at with the clips it brought back.
    /// Captured by prefix because their key space is per session.
    private static let capturedPrefixes = [
        "tailscode.saved.chats", "tailscode.saved.pending", "tailscode.seen.", "tailscode.selectedModel.",
        "tailscode.effort.", "tailscode.recentModels", "tailscode.modelCatalog.",
        "tailscode.archived.", "tailscode.activity.missed", "tailscode.watch.",
        "tailscode.quickask.", "tailscode.updates.", "tailscode.commandCatalog.",
        "tailscode.slash.recents", "tailscode.forge.", "tailscode.image.", "tailscode.usageWindow",
        "tailscode.shareCardStyle", "tailscode.quotaBoard",
    ]

    /// Long enough to take a burst of changes (a divider dragged, a pane split and resized) as one
    /// write, short enough that a crash loses nothing anybody would remember doing.
    private static let settleDelay: DispatchTimeInterval = .milliseconds(750)

    private static let lock = NSLock()
    private static let writer = DispatchQueue(label: "tailscode.settings-file", qos: .utility)
    nonisolated(unsafe) private static var state: [String: Any] = [:]
    nonisolated(unsafe) private static var dirty = false
    nonisolated(unsafe) private static var captureWanted = false
    nonisolated(unsafe) private static var writeScheduled = false
    nonisolated(unsafe) private static var lastWritten: Data?

    static var url: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
        return base.appendingPathComponent("tailscode", isDirectory: true)
            .appendingPathComponent("ui.json")
    }

    /// Reads the file into the defaults. Anything still waiting to be written goes first, so what
    /// is read back is never older than what this process already set.
    static func load() {
        flush()
        guard let data = try? Data(contentsOf: url),
            let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let defaults = UserDefaults.standard
        var restored: [String: Any] = [:]
        for (key, value) in stored {
            let value = decode(value)
            restored[key] = value
            defaults.set(value, forKey: key)
        }
        lock.withLock {
            state.merge(restored) { _, read in read }
            lastWritten = data
        }
    }

    /// The single write path for a setting: the defaults keep working for every reader, and the
    /// file learns the value at the same moment. Setting what is already there changes nothing.
    static func set(_ value: Any?, forKey key: String) {
        let defaults = UserDefaults.standard
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        let changed = lock.withLock {
            guard !same(state[key], value) else { return false }
            if let value { state[key] = value } else { state.removeValue(forKey: key) }
            dirty = true
            return true
        }
        if changed { scheduleWrite() }
    }

    /// Pulls the shared stores' own keys into the file. Empty and zero values are skipped unless
    /// the key is already known, which is what keeps a mere lookup from being recorded as a
    /// deliberate "off".
    ///
    /// Asked for from the main thread after a store writes, and done on the writer: reading every
    /// default back is tens of milliseconds on corelibs, which is a dropped frame for a question
    /// whose answer is usually "nothing changed".
    static func capture() {
        lock.withLock { captureWanted = true }
        scheduleWrite()
    }

    /// Lets go of a key space this file no longer keeps. `capture()` only ever adds, so state that
    /// has moved into a store of its own would otherwise be handed back from here forever — and a
    /// draft restored from an obsolete key is the app appearing to un-send what was sent.
    static func forget(prefix: String) {
        let defaults = UserDefaults.standard
        let stale = lock.withLock { Set(state.keys) }.union(defaults.dictionaryRepresentation().keys)
            .filter { $0.hasPrefix(prefix) }
        guard !stale.isEmpty else { return }
        for key in stale { defaults.removeObject(forKey: key) }
        lock.withLock {
            for key in stale { state.removeValue(forKey: key) }
            dirty = true
        }
        scheduleWrite()
    }

    /// Everything owed to the file, written now. For the moments the process is about to end, and
    /// for anyone about to read the file back.
    static func flush() {
        writer.sync { settle() }
    }

    private static func scheduleWrite() {
        let first = lock.withLock {
            guard !writeScheduled else { return false }
            writeScheduled = true
            return true
        }
        guard first else { return }
        writer.asyncAfter(deadline: .now() + settleDelay) { settle() }
    }

    /// Runs on the writer: folds in the stores' keys if they were asked for, then writes the file if
    /// anything in it moved.
    private static func settle() {
        let wantsCapture = lock.withLock {
            writeScheduled = false
            defer { captureWanted = false }
            return captureWanted
        }
        if wantsCapture { absorbStores() }
        let snapshot: [String: Any]? = lock.withLock {
            guard dirty else { return nil }
            dirty = false
            return state
        }
        guard let snapshot else { return }
        write(snapshot)
    }

    private static func absorbStores() {
        let captured = UserDefaults.standard.dictionaryRepresentation().filter { key, _ in
            capturedPrefixes.contains(where: { key.hasPrefix($0) })
        }
        lock.withLock {
            for (key, value) in captured {
                if state[key] == nil, isEmpty(value) { continue }
                guard !same(state[key], value) else { continue }
                state[key] = value
                dirty = true
            }
        }
    }

    private static func write(_ snapshot: [String: Any]) {
        var payload: [String: Any] = [:]
        for (key, value) in snapshot {
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
        guard lock.withLock({ lastWritten != data }) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        lock.withLock { lastWritten = data }
    }

    /// Whether two stored values say the same thing. Numbers compare by value, so a switch set to
    /// `true` over a stored `1` is not a change; anything nested compares the way the defaults
    /// themselves would hand it back.
    private static func same(_ stored: Any?, _ incoming: Any?) -> Bool {
        switch (stored, incoming) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case let (stored as Data, incoming as Data): return stored == incoming
        case let (stored as String, incoming as String): return stored == incoming
        case let (stored as NSNumber, incoming as NSNumber): return stored == incoming
        case let (stored?, incoming?):
            return NSDictionary(dictionary: ["value": stored]).isEqual(to: ["value": incoming])
        }
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
