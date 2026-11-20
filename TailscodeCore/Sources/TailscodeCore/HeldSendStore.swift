import CodingAgentKit
import Foundation

/// A send held for the connection, as it is kept on disk.
public struct HeldSend: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var profileID: String
    public var sessionID: String
    public var text: String
    public var attachments: [PromptAttachment]
    public var model: ModelSelection?
    public var effort: String?
    public var heldSince: Date
    public var reason: String
    /// How many user messages the conversation held when the words were first sent, so a
    /// restored row asks the transcript about its own words and never an older copy of them.
    public var baselineUserCount: Int

    public init(
        _ send: PendingSend, profileID: String, sessionID: String, heldSince: Date,
        reason: String
    ) {
        id = send.id
        self.profileID = profileID
        self.sessionID = sessionID
        text = send.text
        attachments = send.attachments
        model = send.model
        effort = send.effort
        self.heldSince = heldSince
        self.reason = reason
        baselineUserCount = send.baselineUserCount
    }
}

/// Every send this device is holding for the connection, kept across restarts and keyed by the
/// conversation it was written for.
///
/// A held send is words nobody else has, waiting on a network that may be gone for longer than
/// the process showing them: a phone left offline in a pocket is suspended and ended, and a send
/// that lived only in that process went with it. The record is written when a send starts
/// waiting and let go the moment it stops — sent, found in the transcript, failed, edited or
/// discarded — and whoever opens the conversation next puts the row back and goes on trying. It is
/// a file for the reason ``ResumeStore`` is: this is something a person wrote.
public enum HeldSendStore {
    public static let capacity = 64

    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded: [HeldSend]?

    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Tailscode", isDirectory: true)
            .appendingPathComponent("held-sends.json")
    }

    /// What one conversation is holding, in the order it was written, which is the order it goes.
    public static func records(profileID: String, sessionID: String) -> [HeldSend] {
        lock.withLock {
            recordsLocked().filter { $0.profileID == profileID && $0.sessionID == sessionID }
                .sorted { $0.heldSince < $1.heldSince }
        }
    }

    /// Records a held send, replacing an earlier record of the same row and keeping when it
    /// first started waiting.
    public static func hold(_ record: HeldSend) {
        let snapshot: [HeldSend] = lock.withLock {
            var records = recordsLocked()
            var kept = record
            if let earlier = records.first(where: { $0.id == record.id }) {
                kept.heldSince = min(earlier.heldSince, record.heldSince)
            }
            records.removeAll { $0.id == record.id }
            records.append(kept)
            if records.count > capacity {
                records = Array(records.sorted { $0.heldSince > $1.heldSince }.prefix(capacity))
            }
            loaded = records
            return records
        }
        write(snapshot)
    }

    /// Lets go of a row that stopped waiting. Nothing is written when there was nothing held.
    public static func release(_ id: UUID) {
        let snapshot: [HeldSend]? = lock.withLock {
            var records = recordsLocked()
            guard records.contains(where: { $0.id == id }) else { return nil }
            records.removeAll { $0.id == id }
            loaded = records
            return records
        }
        if let snapshot { write(snapshot) }
    }

    public static func removeAll() {
        lock.withLock { loaded = [] }
        write([])
    }

    /// Drops the in-memory copy so the next read comes off disk, which is what a restart is.
    static func forgetMemo() {
        lock.withLock { loaded = nil }
    }

    private static func recordsLocked() -> [HeldSend] {
        if let loaded { return loaded }
        let records =
            (try? Data(contentsOf: url)).flatMap {
                try? JSONDecoder().decode([HeldSend].self, from: $0)
            } ?? []
        loaded = records
        return records
    }

    private static func write(_ records: [HeldSend]) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

extension PendingSendLedger {
    /// Puts a held send back as the row it was, waiting, after a restart or on a reopen.
    @discardableResult
    public mutating func restore(_ held: HeldSend, userMessages: Int) -> PendingSend? {
        guard send(id: held.id) == nil else { return nil }
        begin(
            text: held.text, attachments: held.attachments, model: held.model,
            effort: held.effort, userMessages: min(held.baselineUserCount, userMessages),
            now: held.heldSince, id: held.id)
        mark(id: held.id, .waiting(reason: held.reason))
        return send(id: held.id)
    }

    /// Puts back a send the ledger let go of while its attempt was still out, for an outcome that
    /// says the server never got it. A row is retired when the account grows past it, and another
    /// device's message grows it too; the late answer that the words did not go must find them a
    /// row rather than drop them.
    @discardableResult
    public mutating func reinstate(_ sent: PendingSend, as phase: PendingSend.Phase) -> Bool {
        guard send(id: sent.id) == nil else { return false }
        begin(
            text: sent.text, attachments: sent.attachments, model: sent.model, effort: sent.effort,
            userMessages: sent.baselineUserCount, now: sent.startedAt, id: sent.id)
        mark(id: sent.id, phase)
        return true
    }
}
