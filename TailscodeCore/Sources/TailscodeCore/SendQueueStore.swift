import CodingAgentKit
import Foundation

/// One conversation's waiting messages, whole, on disk.
public struct SendQueueRecord: Sendable, Hashable, Codable {
    public var profileID: String
    public var sessionID: String
    public var items: [QueuedSend]
    public var updatedAt: Date

    public init(profileID: String, sessionID: String, items: [QueuedSend], updatedAt: Date = Date()) {
        self.profileID = profileID
        self.sessionID = sessionID
        self.items = items
        self.updatedAt = updatedAt
    }

    public var key: String { "\(profileID)/\(sessionID)" }
    public var queue: SendQueue { SendQueue(items: items) }
}

/// Every message this device is holding behind a running turn, kept across restarts and keyed
/// by the conversation it was written for.
///
/// A queue lived in whichever object happened to be showing the chat — a view model on the phone,
/// a pane on the desks — and both were the wrong owner. A pane that switched chats carried its
/// queue into the next conversation and drained it there, which is how a message written for one
/// chat was sent into another; and a process that quit took every waiting message with it, which
/// on a phone is the ordinary way a process ends. The owner is the conversation, so the store is
/// keyed the way ``DraftStore`` and ``ResumeStore`` are keyed — profile and session together —
/// and whoever shows that conversation next reads its queue back from here.
///
/// Written through rather than coalesced: a queue changes on a keystroke's worth of events per
/// minute, not per character, and the process dying between an append and the write is precisely
/// the case the store exists for. It is a file rather than a defaults key for the reason the
/// other two are: this is something a person wrote, and corelibs keys its defaults to the running
/// executable.
public enum SendQueueStore {
    public static let capacity = 64

    private static let lock = NSLock()
    private static let fileLock = NSLock()
    nonisolated(unsafe) private static var loaded: [SendQueueRecord]?

    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Tailscode", isDirectory: true)
            .appendingPathComponent("queue.json")
    }

    static var unreadableURL: URL { url.appendingPathExtension("unreadable") }

    /// Every conversation with something waiting, oldest write first.
    public static func all() -> [SendQueueRecord] {
        lock.lock()
        defer { lock.unlock() }
        return recordsLocked().sorted { $0.updatedAt < $1.updatedAt }
    }

    /// What one conversation is holding, in the order it goes out.
    public static func queue(profileID: String, sessionID: String) -> SendQueue {
        lock.lock()
        defer { lock.unlock() }
        return recordsLocked().first { $0.profileID == profileID && $0.sessionID == sessionID }?
            .queue ?? SendQueue()
    }

    /// Records what a conversation is holding now. An empty queue is a record removed rather than
    /// an empty record kept, so `all()` names only conversations with something to send.
    public static func save(_ queue: SendQueue, profileID: String, sessionID: String) {
        lock.lock()
        var records = recordsLocked()
        records.removeAll { $0.profileID == profileID && $0.sessionID == sessionID }
        if !queue.isEmpty {
            records.append(
                SendQueueRecord(profileID: profileID, sessionID: sessionID, items: queue.items))
        }
        loaded = bounded(records)
        let snapshot = loaded ?? []
        lock.unlock()
        write(snapshot)
    }

    public static func clear(profileID: String, sessionID: String? = nil) {
        lock.lock()
        var records = recordsLocked()
        let before = records.count
        records.removeAll {
            $0.profileID == profileID && (sessionID == nil || $0.sessionID == sessionID)
        }
        guard records.count != before else {
            lock.unlock()
            return
        }
        loaded = records
        let snapshot = records
        lock.unlock()
        write(snapshot)
    }

    public static func removeAll() {
        lock.lock()
        loaded = []
        lock.unlock()
        write([])
    }

    private static func recordsLocked() -> [SendQueueRecord] {
        if let loaded { return loaded }
        let records = restoreFromDisk()
        loaded = records
        return records
    }

    /// A file that exists but will not decode is put aside rather than treated as absent, so the
    /// next write is not the thing that destroys what a truncated one left behind.
    private static func restoreFromDisk() -> [SendQueueRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        if let decoded = try? JSONDecoder().decode([SendQueueRecord].self, from: data) {
            return decoded
        }
        try? FileManager.default.removeItem(at: unreadableURL)
        try? FileManager.default.moveItem(at: url, to: unreadableURL)
        return []
    }

    private static func bounded(_ records: [SendQueueRecord]) -> [SendQueueRecord] {
        guard records.count > capacity else { return records }
        return Array(records.sorted { $0.updatedAt > $1.updatedAt }.prefix(capacity))
            .sorted { $0.updatedAt < $1.updatedAt }
    }

    private static func write(_ records: [SendQueueRecord]) {
        fileLock.lock()
        defer { fileLock.unlock() }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// When a waiting message may go, decided once for every client and every watcher.
///
/// The queue drains the moment the turn yields and never while one is running, never while a
/// compaction is, never into a connection whose last send failed, and never while the composer is
/// holding one of its messages open for rewriting — sending it out from under the person editing
/// it is the one thing the queue exists to prevent. A conversation nobody is looking at follows
/// the same rule from a background watch, because a message written for a chat goes when that
/// chat's turn ends, whichever chat is on screen.
public enum SendQueueDrain {
    public static func mayDrain(_ state: ConversationState, editing: Bool = false) -> Bool {
        state.status != .running && state.compaction?.isRunning != true
            && state.lastFailure == nil && !editing
    }
}
