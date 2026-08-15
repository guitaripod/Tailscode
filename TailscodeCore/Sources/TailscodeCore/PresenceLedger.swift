import Foundation

/// The last thing a witness on this device actually said about each conversation.
///
/// Opening a chat replaces one witness with another: the background watcher that kept the row alive
/// is torn down and the pane's own conversation starts knowing nothing. For a server whose listing
/// can report a running turn that gap is invisible — the listing covers it. For one whose listing
/// cannot, the gap was the only evidence there was, so a row read LIVE NOW, then RECENT, then LIVE
/// NOW again inside one round trip.
///
/// This holds the last settled reading across that gap. Only a witness that has heard the server
/// and reports nothing running settles a row; a reading with nothing to say yet leaves the memory
/// standing, and a failure may not overwrite a remembered turn — a first fetch that failed on a
/// tailnet blip knows less about the server than the watcher it replaced, not more.
public struct PresenceLedger: Sendable {
    /// How long a remembered turn stands on nothing but unsettled readings. A handover costs one
    /// round trip; a watcher that never arrives must not pin a row live all afternoon.
    public static let patience: TimeInterval = 30

    private struct Entry: Sendable {
        var presence: SessionPresence
        var unsettledSince: Date?
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    /// Files one pass of every witness on this device, keyed the way every store here is keyed. A
    /// key the pass does not mention is a key nothing is watching any more, which is an unsettled
    /// reading rather than an answer.
    public mutating func absorb(_ readings: [String: SessionPresence], at now: Date = Date()) {
        for (key, presence) in readings { record(presence, for: key, at: now) }
        for key in entries.keys where readings[key] == nil {
            record(.unsettled, for: key, at: now)
        }
        entries = entries.filter { !Self.expired($0.value, at: now) }
    }

    public mutating func record(
        _ presence: SessionPresence, for key: String, at now: Date = Date()
    ) {
        switch presence {
        case .unsettled:
            guard var entry = entries[key], entry.unsettledSince == nil else { return }
            entry.unsettledSince = now
            entries[key] = entry
        case .failed:
            guard entries[key]?.presence.isInFlight != true else { return }
            entries[key] = Entry(presence: presence, unsettledSince: nil)
        case .unobserved:
            entries[key] = nil
        case .running, .awaitingApproval:
            entries[key] = Entry(presence: presence, unsettledSince: nil)
        }
    }

    public mutating func forget(_ key: String) { entries[key] = nil }

    public func presence(for key: String, at now: Date = Date()) -> SessionPresence {
        guard let entry = entries[key], !Self.expired(entry, at: now) else { return .unobserved }
        return entry.presence
    }

    public func readings(at now: Date = Date()) -> [String: SessionPresence] {
        entries.compactMapValues { Self.expired($0, at: now) ? nil : $0.presence }
    }

    private static func expired(_ entry: Entry, at now: Date) -> Bool {
        guard let since = entry.unsettledSince else { return false }
        return now.timeIntervalSince(since) >= patience
    }
}
