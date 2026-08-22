import CodingAgentKit
import Foundation

/// A message being held for a window, whole, on disk.
///
/// The plan alone would not survive being useful: a device that comes back after the window opened
/// has to be able to say *what* it was holding, and a record that kept only the moment would hand
/// somebody a countdown attached to nothing. So the words, what they were going to be sent with,
/// and everything clipped to them are kept together — the same rule the pending row follows in
/// memory, for the same reason.
public struct ResumeRecord: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID { plan.id }
    public var plan: ResumePlan
    public var text: String
    public var attachments: [PromptAttachment]
    public var model: ModelSelection?
    public var effort: String?

    public init(
        plan: ResumePlan, text: String, attachments: [PromptAttachment] = [],
        model: ModelSelection? = nil, effort: String? = nil
    ) {
        self.plan = plan
        self.text = text
        self.attachments = attachments
        self.model = model
        self.effort = effort
    }

    /// What a client rebuilds the row from when it finds this after a restart.
    public var queued: QueuedSend {
        QueuedSend(
            id: plan.id, text: text, model: model, effort: effort, attachments: attachments)
    }
}

/// Every message this device is holding for a window that has not opened yet, kept across
/// restarts.
///
/// A wait is measured in hours and an app's life is measured in whatever the platform feels like,
/// so a resume that lived only in a running process would work on the desk and never on the phone
/// — which is the machine this app was written for. The record is therefore written the moment a
/// plan is made and read back the moment the conversation it belongs to is opened, so a message
/// held at midnight is still held, still explained, and still sendable at eight.
///
/// It is a file rather than another defaults key for the reason ``DraftStore`` is: this is
/// something a person wrote, corelibs keys its defaults to the running executable, and a rebuilt
/// binary starting from an empty store would read as the app having eaten it.
public enum ResumeStore {
    /// How many held messages are kept. A device holding more than this many walls at once has a
    /// different problem, and the oldest are the ones whose conversation has moved on.
    public static let capacity = 64

    private static let lock = NSLock()
    private static let fileLock = NSLock()
    nonisolated(unsafe) private static var loaded: [ResumeRecord]?

    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Tailscode", isDirectory: true)
            .appendingPathComponent("resume.json")
    }

    static var unreadableURL: URL { url.appendingPathExtension("unreadable") }

    /// Everything held, newest plan first.
    public static func all() -> [ResumeRecord] {
        lock.lock()
        defer { lock.unlock() }
        return recordsLocked().sorted { $0.plan.plannedAt > $1.plan.plannedAt }
    }

    /// What is being held for one conversation, in the order it was written — which is the order
    /// it has to go back out in.
    public static func records(profileID: String, sessionID: String) -> [ResumeRecord] {
        lock.lock()
        defer { lock.unlock() }
        return recordsLocked()
            .filter { $0.plan.profileID == profileID && $0.plan.sessionID == sessionID }
            .sorted { $0.plan.plannedAt < $1.plan.plannedAt }
    }

    /// Records a plan and the words it is holding, replacing any earlier record for the same row.
    ///
    /// Written through rather than coalesced: unlike a keystroke there is exactly one of these per
    /// wall, and the process dying between the wall and the write is precisely the case the store
    /// exists for.
    public static func hold(_ record: ResumeRecord) {
        lock.lock()
        var records = recordsLocked()
        records.removeAll { $0.id == record.id }
        records.append(record)
        loaded = bounded(records)
        let snapshot = loaded ?? []
        lock.unlock()
        write(snapshot)
    }

    /// Updates the plan on a record already held — a re-plan after a window that did not open —
    /// keeping the words exactly as they were.
    public static func replan(_ plan: ResumePlan) {
        lock.lock()
        var records = recordsLocked()
        guard let index = records.firstIndex(where: { $0.id == plan.id }) else {
            lock.unlock()
            return
        }
        records[index].plan = plan
        loaded = records
        let snapshot = records
        lock.unlock()
        write(snapshot)
    }

    /// Lets go of one held message — it went, it was discarded, or the person stopped waiting.
    @discardableResult
    public static func release(_ row: UUID) -> ResumeRecord? {
        lock.lock()
        var records = recordsLocked()
        guard let index = records.firstIndex(where: { $0.id == row }) else {
            lock.unlock()
            return nil
        }
        let removed = records.remove(at: index)
        loaded = records
        let snapshot = records
        lock.unlock()
        write(snapshot)
        return removed
    }

    /// Drops everything held for one conversation — what a chat being deleted or a server being
    /// forgotten means for the messages waiting on it.
    public static func releaseAll(profileID: String, sessionID: String? = nil) {
        lock.lock()
        var records = recordsLocked()
        let before = records.count
        records.removeAll {
            $0.plan.profileID == profileID
                && (sessionID == nil || $0.plan.sessionID == sessionID)
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

    /// Forgets records whose moment passed so long ago that sending them would be a surprise, and
    /// hands back the ones it forgot so a client can say what happened rather than losing them
    /// silently. Called at launch, when the gap between the last run and this one is exactly the
    /// thing nobody watched.
    @discardableResult
    public static func sweepStale(now: Date = Date()) -> [ResumeRecord] {
        lock.lock()
        var records = recordsLocked()
        let stale = records.filter { $0.plan.isStale(at: now) }
        guard !stale.isEmpty else {
            lock.unlock()
            return []
        }
        records.removeAll { $0.plan.isStale(at: now) }
        loaded = records
        let snapshot = records
        lock.unlock()
        write(snapshot)
        return stale.sorted { $0.plan.plannedAt < $1.plan.plannedAt }
    }

    public static func removeAll() {
        lock.lock()
        loaded = []
        lock.unlock()
        write([])
    }

    /// Drops the in-memory copy so the next read comes off disk — which is what a restart is,
    /// from this store's side, and the only way a test can prove one.
    static func forgetMemo() {
        lock.lock()
        loaded = nil
        lock.unlock()
    }

    private static func recordsLocked() -> [ResumeRecord] {
        if let loaded { return loaded }
        let records = restoreFromDisk()
        loaded = records
        return records
    }

    /// A file that exists but will not decode is put aside rather than treated as absent, so the
    /// next write is not the thing that destroys what a truncated one left behind.
    private static func restoreFromDisk() -> [ResumeRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        if let decoded = try? JSONDecoder().decode([ResumeRecord].self, from: data) {
            return decoded
        }
        try? FileManager.default.removeItem(at: unreadableURL)
        try? FileManager.default.moveItem(at: url, to: unreadableURL)
        return []
    }

    /// Keeps the file bounded by how recently a plan was made. A record dropped here is one whose
    /// conversation has long since moved on.
    private static func bounded(_ records: [ResumeRecord]) -> [ResumeRecord] {
        guard records.count > capacity else { return records }
        return Array(records.sorted { $0.plan.plannedAt > $1.plan.plannedAt }.prefix(capacity))
            .sorted { $0.plan.plannedAt < $1.plan.plannedAt }
    }

    private static func write(_ records: [ResumeRecord]) {
        fileLock.lock()
        defer { fileLock.unlock() }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
