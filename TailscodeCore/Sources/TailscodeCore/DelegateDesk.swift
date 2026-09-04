import CodingAgentKit
import Foundation

/// Every dispatcher this device talks to, held above whatever surface is drawing one.
///
/// A run is minutes of another machine's model and a screen is a thing people leave, so the boards,
/// the streams that fold into them and the passwords that open them live here, one per process:
/// backing out of a run and coming back finds it exactly where it was, and a board opened on a
/// second screen reads the same fold. Nothing here decides a word — every sentence is
/// `DelegateBoard`'s or `DelegateRunStory`'s — and a client only draws what it is told changed.
@MainActor
public final class DelegateDesk {
    public static let didChange = Notification.Name("tailscode.delegate.desk.didChange")

    public private(set) var boards: [String: DelegateBoard] = [:]
    public private(set) var reach: [String: DelegateReach] = [:]

    private let secrets: any SecretStore
    /// Passwords this process was handed, kept beside the secret store: a store that refuses a
    /// write (a simulator, a locked keychain) must not turn a typed password into a 401.
    private var handed: [String: String] = [:]
    private var followers: [String: Task<Void, Never>] = [:]
    private var probes: [String: Task<Void, Never>] = [:]

    public init(secrets: any SecretStore) {
        self.secrets = secrets
    }

    public func board(host: String, serverName: String) -> DelegateBoard {
        if let board = boards[host] { return board }
        let board = DelegateBoard(host: host, serverName: serverName)
        boards[host] = board
        return board
    }

    public func access(host: String) -> DelegateAccess {
        DelegateAccessStore.access(host: host) ?? DelegateAccess(host: host)
    }

    public func password(host: String) -> String? {
        handed[host] ?? ((try? secrets.value(for: DelegateAccess(host: host).secretKey)) ?? nil)
    }

    /// Remembers the daemon's password for a machine and asks it again straight away.
    public func remember(password: String, host: String, serverName: String) {
        handed[host] = password
        try? secrets.setValue(password, for: DelegateAccess(host: host).secretKey)
        DelegateAccessStore.remember(access(host: host))
        probe(host: host, serverName: serverName)
    }

    public func forget(host: String) {
        handed[host] = nil
        try? secrets.removeValue(for: DelegateAccess(host: host).secretKey)
        DelegateAccessStore.forget(host: host)
        boards[host] = nil
        reach[host] = nil
        announce()
    }

    public func client(host: String) -> DelegateClient? {
        access(host: host).config(password: password(host: host)).map(DelegateClient.init)
    }

    /// Asks the machine what it is and what it holds. A 401 is a machine that wants its password,
    /// which is a different fact from a machine that is not there.
    public func probe(host: String, serverName: String) {
        probes[host]?.cancel()
        var board = board(host: host, serverName: serverName)
        board.phase = .checking
        boards[host] = board
        reach[host] = .checking
        announce()
        probes[host] = Task { [weak self] in
            guard let self, let client = self.client(host: host) else { return }
            do {
                let capabilities = try await client.capabilities()
                let tiers = try await client.tiers()
                guard !Task.isCancelled else { return }
                var board = self.board(host: host, serverName: serverName)
                board.landed(capabilities: capabilities, tiers: tiers)
                self.boards[host] = board
                self.reach[host] = .answering(version: capabilities.version)
                self.announce()
                await self.refresh(host: host)
                for runID in self.boards[host]?.liveRunIDs ?? [] {
                    self.follow(runID: runID, host: host)
                }
            } catch {
                guard !Task.isCancelled else { return }
                let reading = Self.reading(error)
                self.reach[host] = reading
                var board = self.board(host: host, serverName: serverName)
                board.failed(reading.line)
                self.boards[host] = board
                self.announce()
            }
        }
    }

    /// The listing and the table, re-read; the live folds this device holds are kept.
    public func refresh(host: String) async {
        guard let client = client(host: host), var board = boards[host] else { return }
        do {
            let runs = try await client.runs(limit: 100)
            let stats = try await client.stats()
            board = boards[host] ?? board
            board.filled(runs: runs)
            board.filled(stats: stats)
            boards[host] = board
            announce()
        } catch {
            reach[host] = Self.reading(error)
            announce()
        }
    }

    /// Reads one run's stored record and attempts, so a run opened cold has its whole past before
    /// the stream adds its present.
    public func load(runID: String, host: String) async {
        guard let client = client(host: host), let board = boards[host] else { return }
        guard let detail = try? await client.run(id: runID) else { return }
        var story = DelegateRunStory(detail: detail, tiers: board.tiers)
        if let live = boards[host]?.stories[runID], live.lastSeq > 0 {
            story = live
        }
        boards[host]?.remember(story)
        announce()
        if detail.run.status == .running { follow(runID: runID, host: host) }
    }

    /// Follows a run from where this device last saw it until the daemon says it is over.
    public func follow(runID: String, host: String) {
        guard followers[runID] == nil, let client = client(host: host) else { return }
        let after = boards[host]?.stories[runID]?.lastSeq ?? 0
        followers[runID] = Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.followers[runID] = nil } }
            do {
                for try await envelope in client.events(runID: runID, after: after) {
                    guard let self else { return }
                    self.boards[host]?.fold(envelope)
                    self.announce()
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.reach[host] = Self.reading(error)
                self.announce()
            }
            guard let self else { return }
            await self.refresh(host: host)
        }
    }

    public func isFollowing(runID: String) -> Bool { followers[runID] != nil }

    /// Sends a packet and starts watching the run it became.
    public func start(_ draft: DelegateDraft, host: String, overrides: DelegateOverrides = DelegateOverrides()) async throws -> String {
        guard let packet = draft.packet() else { throw DelegateDeskError.incomplete(draft.problems) }
        guard let client = client(host: host) else { throw DelegateDeskError.noDaemon }
        let sent = DelegateOverrides(
            tier: overrides.tier ?? draft.tier, ceiling: overrides.ceiling ?? draft.ceiling,
            mode: overrides.mode, attempts: overrides.attempts)
        let runID = try await client.start(packet: packet, overrides: sent)
        boards[host]?.expect(runID: runID, packet: packet, startTier: sent.tier, ceiling: sent.ceiling)
        announce()
        follow(runID: runID, host: host)
        return runID
    }

    public func replay(runID: String, host: String, tier: String?, ceiling: String?) async throws -> String {
        guard let client = client(host: host) else { throw DelegateDeskError.noDaemon }
        let packet = boards[host]?.story(for: runID)?.packet
        let overrides = DelegateOverrides(tier: tier, ceiling: ceiling)
        let started = try await client.replay(runID: runID, overrides: overrides)
        if let packet {
            boards[host]?.expect(runID: started, packet: packet, startTier: tier, ceiling: ceiling)
        }
        announce()
        follow(runID: started, host: host)
        return started
    }

    public func approve(runID: String, host: String, approved: Bool) async throws {
        guard let client = client(host: host) else { throw DelegateDeskError.noDaemon }
        try await client.approve(runID: runID, approved: approved)
    }

    public func cancel(runID: String, host: String) async throws {
        guard let client = client(host: host) else { throw DelegateDeskError.noDaemon }
        try await client.cancel(runID: runID)
    }

    public func announce() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    static func reading(_ error: Error) -> DelegateReach {
        if let agentError = error as? AgentError {
            switch agentError {
            case .http(let status, _) where status == 401: return .wantsPassword
            case .http(let status, _) where status == 403: return .refused
            case .http(let status, let body): return .unreachable("HTTP \(status) \(body.prefix(80))")
            default: return .unreachable(agentError.errorDescription ?? String(describing: agentError))
            }
        }
        return .unreachable(error.localizedDescription)
    }
}

public enum DelegateDeskError: Error, LocalizedError {
    case incomplete([String])
    case noDaemon

    public var errorDescription: String? {
        switch self {
        case .incomplete(let problems): return problems.joined(separator: " ")
        case .noDaemon: return Localized.text("No dispatcher is configured for that machine.")
        }
    }
}
