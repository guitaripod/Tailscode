import CodingAgentKit
import Foundation

/// What a saved chat needs to be drawn on a device that has never seen it: the words and the
/// place, never the conversation. Carried inside the mark that says the chat is kept.
public struct CloudChat: Codable, Sendable, Equatable {
    public var serverName: String
    public var backend: AgentType
    public var title: String
    public var directory: String?
    public var updatedAt: Double
    public var savedAt: Double

    public init(
        serverName: String, backend: AgentType, title: String, directory: String?,
        updatedAt: Double, savedAt: Double
    ) {
        self.serverName = serverName
        self.backend = backend
        self.title = title
        self.directory = directory
        self.updatedAt = updatedAt
        self.savedAt = savedAt
    }
}

/// One decision about one thing, and when it was made. A decision that took something away is kept
/// as a mark with `on` false rather than erased, because a device that has not heard of the
/// removal yet would otherwise offer the thing back as if it were new.
public struct CloudMark: Codable, Sendable, Equatable {
    public var at: Double
    public var on: Bool
    public var value: Double?
    public var chat: CloudChat?

    public init(at: Double, on: Bool, value: Double? = nil, chat: CloudChat? = nil) {
        self.at = at
        self.on = on
        self.value = value
        self.chat = chat
    }

    /// Whether this decision is the one to keep over `other`. The later decision wins; a removal
    /// wins a tie, because "gone" is the safer thing to be wrong about than "back"; and two
    /// identical-time decisions that still differ are ordered by their content, so every device
    /// picks the same one and none of them keeps overwriting the other's answer.
    func outranks(_ other: CloudMark) -> Bool {
        if at != other.at { return at > other.at }
        if on != other.on { return !on }
        if let lhs = value, let rhs = other.value, lhs != rhs { return lhs > rhs }
        return (chat?.title ?? "") > (other.chat?.title ?? "")
    }
}

/// The part of a person's state that follows them between devices, as marks keyed by what they are
/// about. Merging two ledgers is commutative, associative and idempotent, so devices that merge in
/// any order, any number of times, end up holding the same ledger.
///
/// Conversations are keyed by the server's endpoint and the session id (``CloudKeys``), never by a
/// profile id, because a profile id is minted by each device for itself and means nothing on the
/// next one. Read marks are keyed by the session id alone, as they always were.
public struct CloudLedger: Codable, Sendable, Equatable {
    public var seen: [String: CloudMark] = [:]
    public var saved: [String: CloudMark] = [:]
    public var pinned: [String: CloudMark] = [:]
    public var archived: [String: CloudMark] = [:]

    public init() {}

    public var isEmpty: Bool {
        seen.isEmpty && saved.isEmpty && pinned.isEmpty && archived.isEmpty
    }

    public static func merged(_ lhs: CloudLedger, _ rhs: CloudLedger) -> CloudLedger {
        var out = CloudLedger()
        out.seen = merge(lhs.seen, rhs.seen)
        out.saved = merge(lhs.saved, rhs.saved)
        out.pinned = merge(lhs.pinned, rhs.pinned)
        out.archived = merge(lhs.archived, rhs.archived)
        return out
    }

    private static func merge(
        _ lhs: [String: CloudMark], _ rhs: [String: CloudMark]
    ) -> [String: CloudMark] {
        lhs.merging(rhs) { mine, theirs in theirs.outranks(mine) ? theirs : mine }
    }

    static let readMarkCapacity = 300
    static let keptCapacity = 300
    static let removalCapacity = 200
    static let removalLife: TimeInterval = 60 * 24 * 3600

    /// Trims what a ledger keeps to what a key-value store can hold and a person can use. Removals
    /// outlive the news of them by weeks, long enough for a phone that was in a drawer to hear,
    /// and are then forgotten; the oldest read marks and the oldest of anything past its cap go
    /// first, because the newest decisions are the ones still being made.
    func pruned(now: Double) -> CloudLedger {
        var out = self
        out.seen = Self.keepNewest(seen, limit: Self.readMarkCapacity)
        out.saved = Self.trim(saved, now: now)
        out.pinned = Self.trim(pinned, now: now)
        out.archived = Self.trim(archived, now: now)
        return out
    }

    private static func keepNewest(
        _ marks: [String: CloudMark], limit: Int
    ) -> [String: CloudMark] {
        guard marks.count > limit else { return marks }
        let kept = marks.sorted { $0.value.at > $1.value.at }.prefix(limit)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    private static func trim(_ marks: [String: CloudMark], now: Double) -> [String: CloudMark] {
        let live = marks.filter { $0.value.on }
        let gone = marks.filter { !$0.value.on && now - $0.value.at < removalLife }
        return keepNewest(live, limit: keptCapacity)
            .merging(keepNewest(gone, limit: removalCapacity)) { first, _ in first }
    }
}

/// How a conversation is named across devices.
public enum CloudKeys {
    private static let separator = "\u{1}"

    /// A server as every device spells it alike: the host's first label, lower-cased, and the
    /// port. `arch`, `arch.tail1234.ts.net` and `ARCH.` are one machine; an address stays whole.
    public static func endpoint(host: String, port: Int?) -> String {
        var name = host.lowercased()
        while name.hasSuffix(".") { name.removeLast() }
        if !name.isEmpty, name.contains("."), !name.allSatisfy({ $0.isNumber || $0 == "." }),
            let first = name.split(separator: ".").first
        {
            name = String(first)
        }
        return "\(name):\(port ?? 0)"
    }

    public static func endpoint(of url: URL) -> String {
        let defaultPort = url.scheme == "https" ? 443 : 80
        return endpoint(host: url.host ?? "", port: url.port ?? defaultPort)
    }

    public static func conversation(endpoint: String, sessionID: String) -> String {
        endpoint + separator + sessionID
    }

    public static func split(_ key: String) -> (endpoint: String, sessionID: String)? {
        let parts = key.components(separatedBy: separator)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }
}
