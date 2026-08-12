import Foundation

/// Which prompt box a piece of unsent text belongs to.
///
/// Identity is the conversation, never the pane or the window: a draft follows the chat it was
/// written for across splits, across restarts, and across whichever client happens to open it
/// next. The same session id on two servers is two different chats, so every conversation-scoped
/// case carries the profile beside it — the same pairing ``SessionEntry`` uses for identity.
public enum DraftScope: Hashable, Sendable {
    /// The chat composer: the prompt being written for an existing conversation.
    case chat(profileID: String, sessionID: String)
    /// Home's composer, which has no session yet — what it is writing to is the compose target,
    /// so the draft belongs to the server and folder the next chat would start in.
    case home(profileID: String, directory: String?)
    /// The instruction handed to `/compact`: what the summary must keep.
    case compaction(profileID: String, sessionID: String)
    /// The standing goal condition — what must become true for the agent to stop.
    case goal(profileID: String, sessionID: String)
    /// A free-typed answer to an `AskUserQuestion`, which outlives a restart because the question
    /// itself does: it is derived from the transcript, not from anything in memory.
    case answer(profileID: String, sessionID: String, questionID: String)
    /// The quick-ask composer, which has no session and no folder — what it is writing to is the
    /// machine the question is aimed at, so a half-typed question comes back when the surface is
    /// summoned again rather than dying with a sheet somebody swiped away.
    case quickAsk(profileID: String)

    public var key: String {
        switch self {
        case let .chat(profileID, sessionID): return "chat:\(profileID)/\(sessionID)"
        case let .home(profileID, directory): return "home:\(profileID)#\(directory ?? "")"
        case let .compaction(profileID, sessionID): return "compact:\(profileID)/\(sessionID)"
        case let .goal(profileID, sessionID): return "goal:\(profileID)/\(sessionID)"
        case let .answer(profileID, sessionID, questionID):
            return "answer:\(profileID)/\(sessionID)#\(questionID)"
        case let .quickAsk(profileID): return "ask:\(profileID)"
        }
    }

    /// What 1.9 wrote a chat draft under before the store existed. The desktops keyed on the bare
    /// session id and iOS on `profile/session`, so the desktops' old drafts are found here and
    /// adopted under the real key the first time their chat is opened.
    var inheritedKey: String? {
        guard case let .chat(_, sessionID) = self else { return nil }
        return "chat:\(sessionID)"
    }
}

/// Every prompt box's unsent text, kept across restarts.
///
/// Typing is the most expensive thing a person does in this app and the cheapest thing for it to
/// lose, so the rule is simply that nothing typed is ever thrown away by the app closing. Text is
/// recorded as it is typed and the store writes at most once per ``quietSeconds`` — a coalescing
/// trailing write, so a burst of keystrokes costs one encode and one file write rather than one
/// per character, and the last thing typed still lands within that window without anyone having
/// to remember to save. ``flush()`` closes the window by hand where a client knows the process is
/// about to stop mattering: backgrounding, quitting, closing the pane.
///
/// It is its own file rather than another `UserDefaults` key because a draft is the one piece of
/// state that must survive a client being reinstalled at a different path — corelibs keys its
/// defaults to the running executable, and a new build starting with an empty one would read as
/// the app having eaten what you wrote. The file is also what makes the write safe to do off the
/// caller's thread: it is this store's alone, guarded by this store's own lock, and never shares
/// a page with another store's writes.
public enum DraftStore {
    /// One box's unsent text and when it was last touched. The timestamp is what orders eviction:
    /// a device that has typed into hundreds of chats keeps the ones it typed into last.
    struct Draft: Codable, Hashable, Sendable {
        var text: String
        var at: Double
    }

    /// How long the store waits for typing to stop before writing. Long enough that a fast typist
    /// costs one write, short enough that a process killed just after a thought lands keeps it.
    static let quietSeconds: TimeInterval = 1.5
    static let capacity = 240
    static let characterBudget = 2_000_000
    static let legacyPrefix = "tailscode.draft."

    private static let lock = NSLock()
    private static let fileLock = NSLock()
    nonisolated(unsafe) private static var loaded: [String: Draft]?
    nonisolated(unsafe) private static var writer: Task<Void, Never>?
    nonisolated(unsafe) private static var dirty = false
    nonisolated(unsafe) private static var revision = 0
    nonisolated(unsafe) private static var writtenRevision = 0

    /// Where the drafts live: application support rather than caches, because this is what
    /// somebody wrote and not something the app can regenerate.
    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Tailscode", isDirectory: true)
            .appendingPathComponent("drafts.json")
    }

    /// Where a file that will not decode is put instead of being overwritten.
    static var unreadableURL: URL { url.appendingPathExtension("unreadable") }

    /// Reads the file and folds in anything an older build left behind, so the first chat opened
    /// pays for neither. Clients call this once at launch; everything else is served from memory.
    ///
    /// Adopting an older build's drafts is written out here and now rather than on the next quiet
    /// moment: the launch that migrates them is also the launch that lets go of where they used to
    /// live, and a process that exits in between — a `--version`, a refused screen, a crash — would
    /// otherwise take every one of them with it.
    public static func warm() {
        lock.lock()
        _ = mapLocked()
        let pending = dirty
        lock.unlock()
        if pending { flush() }
    }

    /// What was last typed into this box, or empty. Served from memory after the first call, so
    /// opening a chat costs neither a decode nor a file touch.
    public static func text(for scope: DraftScope) -> String {
        lock.lock()
        var map = mapLocked()
        if let draft = map[scope.key] {
            lock.unlock()
            return draft.text
        }
        guard let inheritedKey = scope.inheritedKey, let inherited = map[inheritedKey] else {
            lock.unlock()
            return ""
        }
        map[inheritedKey] = nil
        map[scope.key] = inherited
        loaded = map
        dirty = true
        lock.unlock()
        schedule()
        return inherited.text
    }

    /// Records what is currently in the box. Cheap enough to call on every keystroke: it touches a
    /// dictionary in memory and, at most once per ``quietSeconds``, arms the write.
    ///
    /// Emptying the box is an edit like any other and is coalesced with the rest — only sending is
    /// a commitment, and that goes through ``clear(_:)``. A composer cleared and rewritten in the
    /// same breath, which is what a programmatic write looks like to a toolkit that reports the
    /// deletion and the insertion separately, therefore never reaches the disk halfway through.
    public static func record(_ text: String, for scope: DraftScope) {
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        lock.lock()
        var map = mapLocked()
        let held = map[scope.key]
        let inherited = scope.inheritedKey.flatMap { map[$0] }
        if empty {
            guard held != nil || inherited != nil else {
                lock.unlock()
                return
            }
            map[scope.key] = nil
        } else {
            guard held?.text != text else {
                lock.unlock()
                return
            }
            map[scope.key] = Draft(text: text, at: Date().timeIntervalSince1970)
        }
        if let inheritedKey = scope.inheritedKey { map[inheritedKey] = nil }
        loaded = bounded(map)
        dirty = true
        lock.unlock()
        schedule()
    }

    /// Forgets a box's text, and writes that out at once rather than on the next quiet moment: a
    /// prompt that has just been sent must not come back in the composer because the process died
    /// between the send and the write.
    public static func clear(_ scope: DraftScope) {
        lock.lock()
        var map = mapLocked()
        var changed = map.removeValue(forKey: scope.key) != nil
        if let inheritedKey = scope.inheritedKey {
            changed = map.removeValue(forKey: inheritedKey) != nil || changed
        }
        guard changed else {
            lock.unlock()
            return
        }
        loaded = map
        dirty = true
        lock.unlock()
        flush()
    }

    /// Writes anything outstanding now. Clients call this where they know the process is about to
    /// stop being asked: resigning active, terminating, closing the window or the pane.
    ///
    /// The file is never touched while the state lock is held — a write on a caller's thread would
    /// otherwise stall every other composer's keystroke — so two flushes can be in the air at once
    /// and the one that took its snapshot first may reach the disk last. Each snapshot carries the
    /// revision it was taken at and a later revision refuses to be overwritten by an earlier one,
    /// which is what stops a sent prompt reappearing behind a slow write.
    public static func flush() {
        lock.lock()
        writer?.cancel()
        writer = nil
        guard dirty, let map = loaded else {
            lock.unlock()
            return
        }
        dirty = false
        revision += 1
        let stamp = revision
        lock.unlock()
        fileLock.lock()
        defer { fileLock.unlock() }
        guard stamp > writtenRevision else { return }
        writtenRevision = stamp
        write(map)
    }

    /// Drops every draft. Only the "forget this device's local state" paths want this.
    public static func clearAll() {
        lock.lock()
        loaded = [:]
        dirty = true
        lock.unlock()
        flush()
    }

    private static func schedule() {
        lock.lock()
        guard writer == nil else {
            lock.unlock()
            return
        }
        writer = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: UInt64(quietSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            flush()
        }
        lock.unlock()
    }

    private static func mapLocked() -> [String: Draft] {
        if let loaded { return loaded }
        var map = restoreFromDisk()
        adoptLegacyKeys(into: &map)
        loaded = map
        return map
    }

    /// A file that exists but will not decode is put aside rather than treated as an absent one:
    /// the next keystroke writes the store back out, and starting from empty would make that
    /// keystroke the thing that destroyed everything a truncated write left behind.
    private static func restoreFromDisk() -> [String: Draft] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        if let decoded = try? JSONDecoder().decode([String: Draft].self, from: data) {
            return decoded
        }
        try? FileManager.default.removeItem(at: unreadableURL)
        try? FileManager.default.moveItem(at: url, to: unreadableURL)
        return [:]
    }

    /// 1.9 kept each draft in its own `UserDefaults` key. They are folded into the store the first
    /// time it is read and the old keys let go, so an upgrade keeps what was half-typed instead of
    /// appearing to have swallowed it.
    private static func adoptLegacyKeys(into map: inout [String: Draft]) {
        let defaults = UserDefaults.standard
        let stale = defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix(legacyPrefix)
        }
        guard !stale.isEmpty else { return }
        let at = Date().timeIntervalSince1970
        for key in stale {
            let text = defaults.string(forKey: key)
            defaults.removeObject(forKey: key)
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            let scope = "chat:" + key.dropFirst(legacyPrefix.count)
            if map[scope] == nil { map[scope] = Draft(text: text, at: at) }
        }
        dirty = true
    }

    /// Keeps the store bounded so the write never grows with how many chats a device has ever been
    /// typed into. Eviction is by recency alone and nothing else: the oldest go first, however
    /// small they are, and the draft being typed right now is never the one dropped whatever it
    /// weighs — a long prompt is exactly the one nobody could bear to retype.
    /// The budget is measured in bytes rather than in characters, because this runs on every
    /// keystroke: a grapheme count walks every draft the device is holding — a device that has been
    /// typed into all week — while the UTF-8 length is already known to a native string. The budget
    /// is a ceiling on how much is kept, so counting a little high on the way to it is honest.
    private static func bounded(_ map: [String: Draft]) -> [String: Draft] {
        var total = 0
        for draft in map.values {
            total += draft.text.utf8.count
            if total > characterBudget { return evicted(map) }
        }
        return map.count > capacity ? evicted(map) : map
    }

    private static func evicted(_ map: [String: Draft]) -> [String: Draft] {
        var total = map.values.reduce(0) { $0 + $1.text.utf8.count }
        var order = map.sorted { ($0.value.at, $0.key) > ($1.value.at, $1.key) }
        while order.count > capacity {
            total -= order.removeLast().value.text.utf8.count
        }
        while total > characterBudget, order.count > 1 {
            total -= order.removeLast().value.text.utf8.count
        }
        return Dictionary(uniqueKeysWithValues: order.map { ($0.key, $0.value) })
    }

    /// The empty store is written rather than deleted: a file that still holds yesterday's drafts
    /// would hand them all back on the next launch.
    private static func write(_ map: [String: Draft]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        let destination = url
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: destination, options: .atomic)
    }

    static func forgetMemo() {
        lock.lock()
        writer?.cancel()
        writer = nil
        loaded = nil
        dirty = false
        lock.unlock()
        fileLock.lock()
        writtenRevision = revision
        fileLock.unlock()
    }
}
