import CodingAgentKit
import Foundation
import TailscodeCore

/// Every dispatcher this device talks to, held above whatever window is drawing one.
///
/// A run is minutes of another machine's model and a window is a thing people close, so the
/// boards, the streams that fold into them and the passwords that open them live here, one per
/// process — mirroring `ForgeRunner`'s shape for the same reason `MainWindow` gives for carrying
/// none of its own state on `@MainActor`: `g_application_run` never drains libdispatch's main
/// queue, so awaiting into a main-actor type from a signal handler would suspend forever with no
/// crash and no log line. `DelegateDesk` in Core is exactly this orchestration already written for
/// the Apple clients, whose run loops do pump that queue; this is its Linux twin, ported by hand
/// against the same toolkit-free `DelegateClient`/`DelegateBoard`, never against `DelegateDesk`
/// itself. Every touch from a `Task` crosses back through `Gtk.onMain`.
final class DelegateRunner: @unchecked Sendable {
    static let shared = DelegateRunner()

    private(set) var boards: [String: DelegateBoard] = [:]
    private(set) var reach: [String: DelegateReach] = [:]
    private var followers: [String: Task<Void, Never>] = [:]
    private var probes: [String: Task<Void, Never>] = [:]
    private var watchers: [ObjectIdentifier: @Sendable () -> Void] = [:]
    private let secrets: any SecretStore = FileSecretStore()

    private init() {}

    func watch(_ owner: AnyObject, _ block: @escaping @Sendable () -> Void) {
        watchers[ObjectIdentifier(owner)] = block
    }

    func unwatch(_ owner: AnyObject) {
        watchers.removeValue(forKey: ObjectIdentifier(owner))
    }

    private func changed() {
        for watcher in watchers.values { watcher() }
    }

    func board(host: String, serverName: String) -> DelegateBoard {
        if let board = boards[host] { return board }
        let board = DelegateBoard(host: host, serverName: serverName)
        boards[host] = board
        return board
    }

    func access(host: String) -> DelegateAccess {
        DelegateAccessStore.access(host: host) ?? DelegateAccess(host: host)
    }

    func password(host: String) -> String? {
        if DelegateDemo.isDemoHost(host) { return "demo" }
        return (try? secrets.value(for: DelegateAccess(host: host).secretKey)) ?? nil
    }

    /// The daemon behind a host, or the demo's scripted one — same shape, no network, no password.
    private func client(host: String) -> (any DelegateTransport)? {
        if DelegateDemo.isDemoHost(host) { return DelegateDemo.server }
        return access(host: host).config(password: password(host: host)).map(DelegateClient.init)
    }

    func isDemo(host: String) -> Bool { DelegateDemo.isDemoHost(host) }

    /// Confirms a typed password (or none) against the daemon, remembers it on success, and probes
    /// the board straight away — the same "one press is both find out and do it" shape the forge
    /// setup window uses for its own reach checks.
    func check(host: String, password: String?, serverName: String) {
        guard !DelegateDemo.isDemoHost(host) else {
            probe(host: host, serverName: serverName)
            return
        }
        reach[host] = .checking
        changed()
        guard let config = DelegateAccess(host: host).config(password: password) else {
            reach[host] = .unreachable(Localized.text("That does not read as an address"))
            changed()
            return
        }
        let client = DelegateClient(config: config)
        Task { [weak self] in
            do {
                let health = try await client.health()
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    let key = DelegateAccess(host: host).secretKey
                    if let password, !password.isEmpty {
                        try? self.secrets.setValue(password, for: key)
                    } else {
                        try? self.secrets.removeValue(for: key)
                    }
                    DelegateAccessStore.remember(DelegateAccess(host: host, enabled: true))
                    self.reach[host] = .answering(version: health.version)
                    self.changed()
                    self.probe(host: host, serverName: serverName)
                }
            } catch {
                Gtk.onMain { [weak self] in
                    self?.reach[host] = Self.reading(error)
                    self?.changed()
                }
            }
        }
    }

    /// Asks the machine what it is and what it holds. A 401 is a machine that wants its password,
    /// which is a different fact from a machine that is not there — `Self.reading` tells them apart.
    func probe(host: String, serverName: String) {
        probes[host]?.cancel()
        var board = board(host: host, serverName: serverName)
        board.phase = .checking
        boards[host] = board
        changed()
        guard let client = client(host: host) else { return }
        probes[host] = Task { [weak self] in
            do {
                let capabilities = try await client.capabilities()
                let tiers = try await client.tiers()
                guard !Task.isCancelled else { return }
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    var board = self.board(host: host, serverName: serverName)
                    board.landed(capabilities: capabilities, tiers: tiers)
                    self.boards[host] = board
                    self.reach[host] = .answering(version: capabilities.version)
                    self.changed()
                    self.refresh(host: host, serverName: serverName)
                    for runID in board.liveRunIDs { self.follow(runID: runID, host: host) }
                }
            } catch {
                guard !Task.isCancelled else { return }
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    let reading = Self.reading(error)
                    self.reach[host] = reading
                    var board = self.board(host: host, serverName: serverName)
                    board.failed(reading.line)
                    self.boards[host] = board
                    self.changed()
                }
            }
        }
    }

    /// The run listing and the pass-rate table, re-read; the live folds this device holds are kept.
    func refresh(host: String, serverName: String) {
        guard let client = client(host: host) else { return }
        Task { [weak self] in
            do {
                let runs = try await client.runs(limit: 100)
                let stats = try await client.stats(taskClass: nil)
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    var board = self.board(host: host, serverName: serverName)
                    board.filled(runs: runs)
                    board.filled(stats: stats)
                    self.boards[host] = board
                    self.changed()
                }
            } catch {
                Gtk.onMain { [weak self] in
                    self?.reach[host] = Self.reading(error)
                    self?.changed()
                }
            }
        }
    }

    /// One run's stored record and attempts, so a run opened cold has its whole past before the
    /// stream adds its present. A live fold this device already holds is kept rather than replaced.
    func load(runID: String, host: String, serverName: String) {
        guard let client = client(host: host) else { return }
        Task { [weak self] in
            guard let detail = try? await client.run(id: runID) else { return }
            Gtk.onMain { [weak self] in
                guard let self else { return }
                var board = self.board(host: host, serverName: serverName)
                if let held = board.stories[runID], held.lastSeq > 0 {
                    if detail.run.status == .running { self.follow(runID: runID, host: host) }
                    return
                }
                board.remember(DelegateRunStory(runID: runID, tiers: board.tiers, run: detail.run))
                self.boards[host] = board
                self.changed()
                if detail.run.status == .running {
                    self.follow(runID: runID, host: host)
                    return
                }
                self.replayStoredEvents(runID: runID, host: host, client: client)
            }
        }
    }

    /// A finished run's whole past, read once from its stored log — the live path never needs
    /// this, since `follow` already folds every event as it streams.
    private func replayStoredEvents(runID: String, host: String, client: any DelegateTransport) {
        Task { [weak self] in
            do {
                for try await envelope in client.events(runID: runID, after: 0) {
                    guard let self else { return }
                    Gtk.onMain { [weak self] in
                        guard let self else { return }
                        self.boards[host]?.fold(envelope)
                        self.changed()
                    }
                }
            } catch {
                let reading = Self.reading(error)
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.reach[host] = reading
                    self.changed()
                }
            }
        }
    }

    /// Follows a run from where this device last saw it until the daemon says it is over. Safe to
    /// call more than once for the same run — a second call while one is already out is a no-op —
    /// and safe to call for a run nobody is watching any more, since closing the window never stops
    /// what is already in flight here.
    func follow(runID: String, host: String) {
        guard followers[runID] == nil, let client = client(host: host) else { return }
        let after = boards[host]?.stories[runID]?.lastSeq ?? 0
        let serverName = boards[host]?.serverName ?? host
        followers[runID] = Task { [weak self] in
            do {
                for try await envelope in client.events(runID: runID, after: after) {
                    guard let self else { return }
                    Gtk.onMain { [weak self] in
                        guard let self else { return }
                        self.boards[host]?.fold(envelope)
                        self.changed()
                    }
                }
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.followers[runID] = nil
                    self.changed()
                    self.refresh(host: host, serverName: serverName)
                }
            } catch {
                let reading = Self.reading(error)
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.followers[runID] = nil
                    self.reach[host] = reading
                    self.changed()
                    self.refresh(host: host, serverName: serverName)
                }
            }
        }
    }

    func isFollowing(runID: String) -> Bool { followers[runID] != nil }

    /// Sends a packet and starts watching the run it became. The tier and ceiling ride twice — once
    /// baked into the packet by `DelegateDraft.packet()`, once as overrides — matching `DelegateDesk`
    /// exactly, since the daemon's own precedence between a packet's stored ladder and a run's
    /// override is the daemon's call, not this client's.
    func start(
        host: String, serverName: String, draft: DelegateDraft,
        completion: @escaping @Sendable (Result<String, Error>) -> Void
    ) {
        guard let packet = draft.packet() else {
            completion(.failure(DelegateDeskError.incomplete(draft.problems)))
            return
        }
        guard let client = client(host: host) else {
            completion(.failure(DelegateDeskError.noDaemon))
            return
        }
        let overrides = DelegateOverrides(tier: draft.tier, ceiling: draft.ceiling)
        Task { [weak self] in
            do {
                let runID = try await client.start(packet: packet, overrides: overrides)
                Gtk.onMain { [weak self] in
                    guard let self else { completion(.success(runID)); return }
                    var board = self.board(host: host, serverName: serverName)
                    board.expect(
                        runID: runID, packet: packet, startTier: overrides.tier,
                        ceiling: overrides.ceiling)
                    self.boards[host] = board
                    self.changed()
                    self.follow(runID: runID, host: host)
                    completion(.success(runID))
                }
            } catch {
                Gtk.onMain { completion(.failure(error)) }
            }
        }
    }

    /// The same packet, tried again on another tier — the road to qualifying a model.
    func replay(
        runID: String, host: String, tier: String?, ceiling: String?,
        completion: @escaping @Sendable (Result<String, Error>) -> Void
    ) {
        guard let client = client(host: host) else {
            completion(.failure(DelegateDeskError.noDaemon))
            return
        }
        let serverName = boards[host]?.serverName ?? host
        let packet = boards[host]?.story(for: runID)?.packet
        let overrides = DelegateOverrides(tier: tier, ceiling: ceiling)
        Task { [weak self] in
            do {
                let started = try await client.replay(runID: runID, overrides: overrides)
                Gtk.onMain { [weak self] in
                    guard let self else { completion(.success(started)); return }
                    if let packet {
                        var board = self.board(host: host, serverName: serverName)
                        board.expect(runID: started, packet: packet, startTier: tier, ceiling: ceiling)
                        self.boards[host] = board
                    }
                    self.changed()
                    self.follow(runID: started, host: host)
                    completion(.success(started))
                }
            } catch {
                Gtk.onMain { completion(.failure(error)) }
            }
        }
    }

    func approve(
        runID: String, host: String, approved: Bool,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        guard let client = client(host: host) else {
            completion(.failure(DelegateDeskError.noDaemon))
            return
        }
        Task {
            do {
                try await client.approve(runID: runID, approved: approved)
                Gtk.onMain { completion(.success(())) }
            } catch {
                Gtk.onMain { completion(.failure(error)) }
            }
        }
    }

    func cancel(
        runID: String, host: String, completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        guard let client = client(host: host) else {
            completion(.failure(DelegateDeskError.noDaemon))
            return
        }
        Task {
            do {
                try await client.cancel(runID: runID)
                Gtk.onMain { completion(.success(())) }
            } catch {
                Gtk.onMain { completion(.failure(error)) }
            }
        }
    }

    /// A 401 is a machine that wants its password and a 403 is one that refused it; everything else
    /// is unreachable, in whatever words the transport gave it. Ported from `DelegateDesk.reading`
    /// rather than shared with it, since sharing would mean calling into a `@MainActor` type.
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
