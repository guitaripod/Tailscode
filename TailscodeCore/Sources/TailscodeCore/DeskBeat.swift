import CodingAgentKit
import Foundation

/// What a computer knows about the person in front of it right now.
public struct DeskReading: Sendable, Equatable {
    /// Seconds since the last keyboard or pointer input anywhere on the desktop; nil when the
    /// desktop gives no way to know, which never counts as anyone being there.
    public var idle: TimeInterval?
    public var locked: Bool

    public init(idle: TimeInterval?, locked: Bool = false) {
        self.idle = idle
        self.locked = locked
    }
}

/// A server a desk reports to, by a key that stays the same while the server does.
public struct DeskServer: Sendable {
    public var key: String
    public var backend: any CodingAgentBackend

    public init(key: String, backend: any CodingAgentBackend) {
        self.key = key
        self.backend = backend
    }
}

/// A computer's half of being quiet at the desk: every `DeskReport.interval` it tells every server
/// it holds whether its person is in front of it, which conversations they had on screen, and —
/// the moment it happens — that the screen locked or the machine is going away. A phone that asked
/// to stay quiet while they are here reads it from any of those servers.
///
/// Runs on its own, never on a main queue (GTK's loop does not drain one), and asks the client
/// only for a reading and the servers it holds. A server that keeps no desks is asked again after
/// `refusalPause`, since it may be updated meanwhile.
public actor DeskBeat {
    public struct Status: Sendable, Equatable {
        public var enabled: Bool
        public var reading: DeskReading?
        /// How many servers took the last report, how many were asked, and how many of those
        /// said they keep no desks (the rest could not be reached).
        public var heard: Int
        public var asked: Int
        public var refused: Int
        public var reportedAt: Date?

        public init(
            enabled: Bool, reading: DeskReading? = nil, heard: Int = 0, asked: Int = 0,
            refused: Int = 0, reportedAt: Date? = nil
        ) {
            self.enabled = enabled
            self.reading = reading
            self.heard = heard
            self.asked = asked
            self.refused = refused
            self.reportedAt = reportedAt
        }
    }

    public static let refusalPause: TimeInterval = 600
    public static let reportTimeout: TimeInterval = 8
    public static let didChange = Notification.Name("tailscode.desk.didChange")

    private let desk: String
    private let name: String
    private let interval: TimeInterval
    private let sense: @Sendable () async -> DeskReading
    private let servers: @Sendable () async -> [DeskServer]
    private var looked: [String: Date] = [:]
    /// Moves on every leave and every switch-off, so a report that started before one is not sent
    /// after it.
    private var epoch = 0
    private var refusedAt: [String: Date] = [:]
    /// The servers that took the last report, which a desk leaving tells without asking the
    /// client for its servers again: a quitting app may be holding the very thread that would
    /// answer.
    private var listening: [DeskServer] = []
    private var loop: Task<Void, Never>?
    public private(set) var status: Status

    public init(
        desk: String, name: String, enabled: Bool, interval: TimeInterval = DeskReport.interval,
        sense: @escaping @Sendable () async -> DeskReading,
        servers: @escaping @Sendable () async -> [DeskServer]
    ) {
        self.desk = desk
        self.name = name
        self.interval = interval
        self.sense = sense
        self.servers = servers
        self.status = Status(enabled: enabled)
    }

    /// Starts reporting on the clock, if reporting is on. Starting twice changes nothing.
    public func start() {
        guard status.enabled, loop == nil else { return }
        DeskLooks.listen()
        let interval = interval
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.report()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Turns reporting on or off. Off tells every server this desk is leaving, so a phone waiting
    /// for its person to go hears at once rather than after the desk falls silent.
    public func setEnabled(_ on: Bool) async {
        guard on != status.enabled else { return }
        status.enabled = on
        if on {
            start()
        } else {
            loop?.cancel()
            loop = nil
            epoch += 1
            await report(leaving: true)
            guard !status.enabled else { return }
            status = Status(enabled: false)
            announce()
        }
    }

    /// A conversation the person has in front of them in a focused window.
    public func look(_ sessionID: String, at moment: Date = Date()) {
        guard status.enabled, !sessionID.isEmpty else { return }
        looked[sessionID] = max(looked[sessionID] ?? .distantPast, moment)
    }

    /// Something a phone would act on changed — the screen locked or unlocked — so the servers
    /// hear now rather than at the next beat.
    public func poke() async {
        guard status.enabled else { return }
        await report()
    }

    /// The app is quitting or the machine is going to sleep: this desk's last word.
    public func leave() async {
        guard status.enabled else { return }
        epoch += 1
        await report(leaving: true)
    }

    /// Reads the desk and tells every server that keeps desks. A lock change found on the clock
    /// is reported like any other beat; one the client noticed first came through `poke`.
    public func report(leaving: Bool = false, now: Date = Date()) async {
        guard status.enabled || leaving else { return }
        let started = epoch
        let reading = leaving ? DeskReading(idle: nil, locked: true) : await sense()
        let looks = looked.merging(DeskLooks.take()) { max($0, $1) }
        looked.removeAll()
        let sent = DeskReport(
            desk: desk, name: name, idle: reading.idle.map { Int($0.rounded(.down)) },
            locked: reading.locked, leaving: leaving, looked: looks.keys.sorted(),
            lookedAgo: looks.mapValues { max(0, Int(now.timeIntervalSince($0).rounded())) })
        let targets =
            leaving
            ? listening
            : await servers().filter { server in
                guard let refused = refusedAt[server.key] else { return true }
                return now.timeIntervalSince(refused) >= Self.refusalPause
            }
        guard leaving || (status.enabled && epoch == started) else {
            looked.merge(looks) { max($0, $1) }
            return
        }
        var answers: [(String, Bool?)] = []
        await withTaskGroup(of: (String, Bool?).self) { group in
            for server in targets {
                group.addTask {
                    (server.key, await Self.send(sent, to: server.backend))
                }
            }
            for await answer in group { answers.append(answer) }
        }
        for (key, took) in answers {
            switch took {
            case true?: refusedAt[key] = nil
            case false?: refusedAt[key] = now
            case nil: break
            }
        }
        guard !leaving else {
            listening = []
            return
        }
        let took = Set(answers.filter { $0.1 == true }.map(\.0))
        let refused = Set(answers.filter { $0.1 == false }.map(\.0))
        if took.isEmpty { looked.merge(looks) { max($0, $1) } }
        var keep = listening.filter { !refused.contains($0.key) && !took.contains($0.key) }
        keep += targets.filter { took.contains($0.key) }
        listening = keep
        status.reading = reading
        status.asked = targets.count
        status.heard = took.count
        status.refused = refused.count
        status.reportedAt = now
        announce()
    }

    /// True when the server took the report, false when it keeps no desks, nil when it could not
    /// be reached in time — which says nothing about whether it would have.
    private static func send(_ report: DeskReport, to backend: any CodingAgentBackend) async -> Bool? {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask { try? await backend.reportDesk(report) }
            group.addTask {
                try? await Task.sleep(for: .seconds(reportTimeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private nonisolated func announce() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

/// The conversations the person looked at on this computer since its desk last reported: every
/// chat marked seen here, which is a chat opened, read as it grew, or marked read by hand. Only a
/// computer whose desk is reporting listens, so a phone gathers nothing.
public enum DeskLooks {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var listening = false
    nonisolated(unsafe) private static var pending: [String: Date] = [:]
    private static let limit = 64

    public static func listen() {
        lock.withLock { listening = true }
    }

    public static func note(_ sessionID: String) {
        guard !sessionID.isEmpty else { return }
        let now = Date()
        lock.withLock {
            guard listening, pending.count < limit || pending[sessionID] != nil else { return }
            pending[sessionID] = now
        }
    }

    public static func take() -> [String: Date] {
        lock.withLock {
            defer { pending.removeAll() }
            return pending
        }
    }
}

/// Where a computer keeps its own desk identity and whether it reports at all, under keys every
/// desktop client reads through its own store.
public enum DeskKeys {
    public static let id = "tailscode.desk.id"
    public static let reports = "tailscode.desk.reports"

    /// This computer's id, made once and kept.
    public static func id(_ value: (String) -> Any?, _ store: (String, Any?) -> Void) -> String {
        if let known = value(id) as? String, !known.isEmpty { return known }
        let made = UUID().uuidString
        store(id, made)
        return made
    }

    public static func reports(_ value: (String) -> Any?) -> Bool {
        value(reports) as? Bool ?? true
    }
}

/// A phone's half: asks every server it holds what they know about desks, and keeps the one it
/// can wait on for its person to leave.
public enum DeskLookout {
    public struct Answer: Sendable {
        public var presence: DeskPresence
        /// A server that keeps desks, to hold a wait on, by the key the caller gave it.
        public var waiter: DeskServer?

        public init(presence: DeskPresence, waiter: DeskServer?) {
            self.presence = presence
            self.waiter = waiter
        }
    }

    public static let timeout: TimeInterval = 4

    /// What the servers that keep desks know, merged; nil when none of them keeps any, or none
    /// answered in time. The waiter is a server that itself sees the person at a desk by
    /// `awayAfter`, so a wait held on it cannot answer "away" only because the desk never
    /// reported there.
    public static func ask(_ servers: [DeskServer], awayAfter: TimeInterval? = nil) async -> Answer? {
        var answers: [(DeskServer, DeskPresence)] = []
        await withTaskGroup(of: (Int, DeskPresence?).self) { group in
            for (index, server) in servers.enumerated() {
                group.addTask {
                    await withTaskGroup(of: DeskPresence?.self) { inner in
                        inner.addTask { try? await server.backend.deskPresence() }
                        inner.addTask {
                            try? await Task.sleep(for: .seconds(timeout))
                            return nil
                        }
                        let first = await inner.next() ?? nil
                        inner.cancelAll()
                        return (index, first)
                    }
                }
            }
            for await (index, presence) in group {
                if let presence { answers.append((servers[index], presence)) }
            }
        }
        guard !answers.isEmpty else { return nil }
        let ordered = answers.sorted { $0.0.key < $1.0.key }
        let seeing = awayAfter.flatMap { patience in
            ordered.first { $0.1.occupied(awayAfter: patience) != nil }?.0
        }
        return Answer(
            presence: DeskPresence.merged(answers.map(\.1)), waiter: seeing ?? ordered.first?.0)
    }
}
