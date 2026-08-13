import TailscodeCore
import CodingAgentKit
import CodingAgentKitApple
import Foundation

/// Each section in the session list represents one backend server.
@MainActor
final class SessionListViewModel {
    struct Source {
        let profile: ConnectionProfile
        let backend: any CodingAgentBackend
    }

    private var sources: [Source]
    private var sourcesRevision: Int
    private(set) var entries: [SessionEntry] = []
    private(set) var unreachable: [String] = []

    var onChange: (() -> Void)?
    var onError: ((String) -> Void)?
    private var streamTasks: [Task<Void, Never>] = []

    init(sources: [Source]) {
        self.sources = sources
        self.sourcesRevision = ConnectionController.shared.revision
        let profileIDs = Set(sources.map(\.profile.id))
        entries = SessionListCache.load().filter { profileIDs.contains($0.profileID) }
        startStreams()
    }

    deinit {
        for task in streamTasks { task.cancel() }
    }

    /// A proto-2 bridge pushes every list change the moment it happens: a row updates, moves, or
    /// appears without a single poll. The load() path survives as the hydrate and as the whole
    /// story for servers that cannot push.
    private func startStreams() {
        for task in streamTasks { task.cancel() }
        streamTasks = []
        for source in sources {
            guard let streaming = source.backend as? SessionListStreaming else { continue }
            let profile = source.profile
            let task = Task { [weak self] in
                guard let changes = await streaming.sessionListChanges() else { return }
                for await change in changes {
                    guard let self, !Task.isCancelled else { return }
                    self.apply(change, profile: profile)
                }
            }
            streamTasks.append(task)
        }
    }

    private func apply(_ change: SessionListChange, profile: ConnectionProfile) {
        switch change {
        case .upsert(let session):
            let entry = SessionEntry(
                profileID: profile.id, profileName: profile.name,
                host: profile.baseURL.host ?? profile.name,
                backendType: profile.backend, session: session)
            entries.removeAll { $0.profileID == profile.id && $0.session.id == session.id }
            entries.append(entry)
            entries.sort { $0.session.updatedAt > $1.session.updatedAt }
            SessionListCache.scheduleSave(entries)
            onChange?()
        case .remove(let id):
            entries.removeAll { $0.profileID == profile.id && $0.session.id == id }
            onChange?()
        case .invalidated:
            Task { [weak self] in await self?.load() }
        }
    }

    /// Rebuilds the backends from the saved profiles, dropping entries whose
    /// server is gone. Called when Settings edits connections, so the list
    /// follows an add, a removal, a rename, or a new address without the screen
    /// being recreated. Every verdict is torn up with them: the user just
    /// changed what these servers are, so what the old ones failed to answer
    /// says nothing about the new ones.
    func refreshSources() {
        sourcesRevision = ConnectionController.shared.revision
        sources = ConnectionController.shared.allBackends()
            .map { Source(profile: $0.profile, backend: $0.backend) }
        let live = Set(sources.map(\.profile.id))
        entries.removeAll { !live.contains($0.profileID) }
        unreachable = []
        failureStreaks = [:]
        confirmationTask?.cancel()
        confirmationTask = nil
        startStreams()
        onChange?()
    }

    var servers: [ConnectionProfile] { sources.map(\.profile) }
    var isEmptyOfServers: Bool { sources.isEmpty }

    func backend(for entry: SessionEntry) -> (any CodingAgentBackend)? {
        backend(forProfileID: entry.profileID)
    }

    func backend(forProfileID profileID: String) -> (any CodingAgentBackend)? {
        sources.first { $0.profile.id == profileID }?.backend
    }

    func supportsMultipleSessions(_ entry: SessionEntry) -> Bool {
        backend(for: entry)?.capabilities.supportsMultipleSessions ?? false
    }

    func supportsRenaming(_ entry: SessionEntry) -> Bool {
        backend(for: entry)?.capabilities.supportsRenaming ?? false
    }

    func supportsForking(_ entry: SessionEntry) -> Bool {
        backend(for: entry)?.capabilities.supportsForking ?? false
    }

    /// Forks server-side and returns the copy as a listable entry, so the caller can open it
    /// the same way a tapped row opens.
    func fork(_ entry: SessionEntry) async -> SessionEntry? {
        guard let backend = backend(for: entry) else { return nil }
        do {
            let forked = try await backend.forkSession(entry.session.id)
            let new = SessionEntry(
                profileID: entry.profileID, profileName: entry.profileName,
                host: entry.host, backendType: entry.backendType, session: forked)
            entries.insert(new, at: 0)
            onChange?()
            Task { await load() }
            return new
        } catch {
            onError?(Self.readable(error))
            return nil
        }
    }

    func rename(_ entry: SessionEntry, to title: String) async {
        guard let backend = backend(for: entry) else { return }
        do {
            try await backend.renameSession(entry.session.id, title: title)
            await load()
        } catch {
            onError?(Self.readable(error))
        }
    }

    /// A server is only called unreachable once a second attempt agrees. The
    /// first fan-out after the app comes back from a long pause fails on servers
    /// that were up the whole time — the tailnet tunnel has to re-handshake and
    /// the sockets the app left open died while it was away — so publishing that
    /// first answer accused a healthy machine of being down every single time
    /// the app was reopened.
    private var failureStreaks: [String: Int] = [:]
    private var confirmationTask: Task<Void, Never>?

    private static let failuresBeforeVerdict = 2
    private static let confirmationDelay: Duration = .seconds(2)

    /// Re-reads the profile list on every load so servers added or removed
    /// in Settings appear without recreating this screen.
    func load() async {
        if ConnectionController.shared.revision != sourcesRevision {
            sourcesRevision = ConnectionController.shared.revision
            sources = ConnectionController.shared.allBackends()
                .map { Source(profile: $0.profile, backend: $0.backend) }
            startStreams()
        }
        await refresh(sources, deadline: Self.sourceDeadline)
    }

    /// Lists `targets` concurrently and merges their answers into what is
    /// already on screen, so a server that stayed silent keeps the sessions it
    /// last reported rather than blanking. Servers outside `targets` are left
    /// untouched, which is what lets a doubted server be re-checked on its own.
    private func refresh(_ targets: [Source], deadline: Duration) async {
        var fresh: [String: [SessionEntry]] = [:]
        var known = Set(entries.compactMap(\.session.directory))
        known.formUnion(SessionListCache.load().compactMap(\.session.directory))
        let directories = known
        await withTaskGroup(of: (Source, Result<[AgentSession], Error>).self) { group in
            for source in targets {
                group.addTask {
                    do {
                        return (
                            source,
                            .success(
                                try await Self.listWithDeadline(
                                    source, knownDirectories: directories, deadline: deadline))
                        )
                    } catch {
                        return (source, .failure(error))
                    }
                }
            }
            for await (source, result) in group {
                switch result {
                case .success(let list):
                    failureStreaks[source.profile.id] = 0
                    healthilySlow.remove(source.profile.id)
                    fresh[source.profile.id] = list.map {
                        SessionEntry(
                            profileID: source.profile.id,
                            profileName: source.profile.name,
                            host: source.profile.baseURL.host ?? source.profile.name,
                            backendType: source.profile.backend,
                            session: $0)
                    }
                case .failure(let error):
                    let streak = (failureStreaks[source.profile.id] ?? 0) + 1
                    failureStreaks[source.profile.id] = streak
                    AppLogger.session.error(
                        "load failed for \(source.profile.name) (attempt \(streak)): "
                            + Self.readable(error))
                }
            }
        }
        await publish(fresh)
    }

    /// Servers whose listing keeps missing the deadline while their `/status` answers instantly:
    /// busy, not down. They keep their last-known sessions and never raise the banner.
    private var healthilySlow: Set<String> = []

    /// The listing route can take longer than any reasonable deadline while the bridge folds a
    /// live turn — and a slow answer is not a dead server. Before a server is pronounced
    /// unreachable, it gets asked the cheap question directly; only silence there too earns the
    /// banner.
    private func confirmedDown(_ ids: [String]) async -> Set<String> {
        guard !ids.isEmpty else { return [] }
        return await withTaskGroup(of: (String, Bool).self) { group in
            for id in ids {
                guard let source = sources.first(where: { $0.profile.id == id }) else { continue }
                group.addTask {
                    let healthy: Bool = await {
                        do {
                            return try await withThrowingTaskGroup(of: Bool.self) { probe in
                                probe.addTask { try await source.backend.health().healthy }
                                probe.addTask {
                                    try await Task.sleep(for: .seconds(4))
                                    throw SourceTimeout()
                                }
                                guard let first = try await probe.next() else { return false }
                                probe.cancelAll()
                                return first
                            }
                        } catch {
                            return false
                        }
                    }()
                    return (id, healthy)
                }
            }
            var down = Set(ids)
            for await (id, healthy) in group where healthy { down.remove(id) }
            return down
        }
    }

    /// Merged onto whatever is on screen at this moment rather than onto a
    /// snapshot taken before the fan-out: the confirmation pass and the cadence
    /// can be in flight together, and neither may republish the other's servers
    /// from a list it read minutes ago.
    private func publish(_ fresh: [String: [SessionEntry]]) async {
        let byProfile = Dictionary(grouping: entries, by: \.profileID)
            .merging(fresh) { _, new in new }
        let live = sources.map(\.profile.id)
        let collected = live.flatMap { byProfile[$0] ?? [] }
        let candidates = live.filter { (failureStreaks[$0] ?? 0) >= Self.failuresBeforeVerdict }
        let down = await confirmedDown(candidates.filter { !healthilySlow.contains($0) })
        for id in candidates where !down.contains(id) { healthilySlow.insert(id) }
        let verdicts = candidates.filter { down.contains($0) || !healthilySlow.contains($0) }
        let changed = collected.count != entries.count || verdicts != unreachable
        entries = collected.sorted { $0.session.updatedAt > $1.session.updatedAt }
        unreachable = verdicts
        SessionListCache.scheduleSave(entries)
        SavedChatStore.reconcile(with: entries)
        ActivityInbox.reconcile(
            entries.map {
                ActivityObservation(
                    profileID: $0.profileID, sessionID: $0.session.id, title: $0.session.title,
                    isActive: $0.session.isActive == true)
            },
            authoritativeProfileIDs: Set(fresh.keys))
        if changed {
            AppLogger.session.info(
                "loaded \(entries.count) sessions across \(sources.count) servers")
        }
        onChange?()
        scheduleConfirmation(live.filter { failureStreaks[$0] == 1 })
    }

    /// A server that has missed once is re-checked on its own a moment later
    /// instead of waiting for the next cadence tick or a pull: the verdict has
    /// to settle by itself, and a tunnel that was still coming up gets the
    /// seconds it needs. The second look is generous with time where the first
    /// is deliberately short — nothing is waiting on it, the list is already
    /// painted, and the only thing it decides is whether to raise an alarm.
    private func scheduleConfirmation(_ ids: [String]) {
        confirmationTask?.cancel()
        confirmationTask = nil
        guard !ids.isEmpty else { return }
        confirmationTask = Task { [weak self] in
            try? await Task.sleep(for: Self.confirmationDelay)
            guard !Task.isCancelled, let self else { return }
            self.confirmationTask = nil
            await self.refresh(
                self.sources.filter { ids.contains($0.profile.id) },
                deadline: Self.confirmationDeadline)
        }
    }

    /// The same mint, with the reason kept instead of thrown away. A new chat is the one place a
    /// silent failure is unforgivable — the person asked for a conversation and got a closed
    /// sheet — so the caller is handed the diagnosis to show where the asking happened.
    func createSession(on profile: ConnectionProfile, directory: String?) async
        -> Result<SessionEntry, NewChatFailure>
    {
        let server = NewChatServer(
            profileID: profile.id, name: profile.name, backend: profile.backend,
            address: ServerLabel.address(profile))
        guard let source = sources.first(where: { $0.profile.id == profile.id }) else {
            return .failure(NewChatDiagnosis.noCredentials(server: server))
        }
        let minted = await NewChatAttempt.mint(
            using: source.backend, server: server, baseURL: profile.baseURL,
            password: ConnectionController.shared.password(for: profile.id), directory: directory)
        guard case .success(let session) = minted else {
            return .failure(minted.failureValue ?? NewChatDiagnosis.noSuchServer())
        }
        let entry = SessionEntry(
            profileID: source.profile.id, profileName: source.profile.name,
            host: source.profile.baseURL.host ?? source.profile.name,
            backendType: source.profile.backend, session: session)
        entries.insert(entry, at: 0)
        onChange?()
        Task { await load() }
        return .success(entry)
    }

    func newSession(on profile: ConnectionProfile, directory: String? = nil) async -> SessionEntry? {
        guard let source = sources.first(where: { $0.profile.id == profile.id }) else { return nil }
        do {
            let session = try await source.backend.createSession(title: nil, directory: directory)
            let entry = SessionEntry(
                profileID: source.profile.id, profileName: source.profile.name,
                host: source.profile.baseURL.host ?? source.profile.name,
                backendType: source.profile.backend, session: session)
            entries.insert(entry, at: 0)
            onChange?()
            Task { await load() }
            return entry
        } catch {
            onError?(Self.readable(error))
            return nil
        }
    }

    /// Takes the row off the list first and tells the server after, because a delete that waits on
    /// a tailnet round trip reads as a tap that did nothing. A refusal reloads the listing, which
    /// resurfaces the conversation the server still holds — a deleted row must never sit on screen
    /// waiting, and a failed delete must never leave the list pretending it worked.
    func delete(_ entry: SessionEntry) async {
        guard let backend = backend(for: entry) else { return }
        entries.removeAll { $0 == entry }
        forgetLocally(entry)
        SessionListCache.scheduleSave(entries)
        onChange?()
        do {
            try await backend.deleteSession(entry.session.id)
        } catch {
            onError?(Self.readable(error))
            await load()
        }
    }

    /// Deletes a whole selection, fanning the requests out concurrently rather than queueing one
    /// round trip per chat: every row leaves at once and the servers are told in parallel, so
    /// clearing a week of dead conversations costs one wait instead of thirty. The answer counts
    /// what survived and carries the first failure's reason, since a fan-out that fails usually
    /// fails the same way for every row; a partial failure is never reported as a clean run.
    func delete(_ targets: [SessionEntry]) async -> BulkChatOutcome {
        let deletable = targets.filter { backend(for: $0) != nil }
        guard !deletable.isEmpty else { return BulkChatOutcome(deleted: 0, failed: 0, reason: nil) }
        let doomed = Set(deletable)
        entries.removeAll { doomed.contains($0) }
        for entry in deletable { forgetLocally(entry) }
        SessionListCache.scheduleSave(entries)
        onChange?()
        let results = await withTaskGroup(of: (Int, String?).self) { group in
            for (index, entry) in deletable.enumerated() {
                guard let backend = backend(for: entry) else { continue }
                let sessionID = entry.session.id
                group.addTask {
                    do {
                        try await backend.deleteSession(sessionID)
                        return (index, nil)
                    } catch {
                        return (index, Self.readable(error))
                    }
                }
            }
            var collected: [(Int, String?)] = []
            for await result in group { collected.append(result) }
            return collected.sorted { $0.0 < $1.0 }
        }
        let failures = results.compactMap(\.1)
        if !failures.isEmpty { await load() }
        AppLogger.session.info(
            "bulk delete: \(results.count - failures.count) removed, \(failures.count) failed")
        return BulkChatOutcome(
            deleted: results.count - failures.count, failed: failures.count, reason: failures.first)
    }

    /// Everything this device kept about a deleted conversation goes with it: a bookmark, an
    /// archive entry or a pin left behind would keep listing, hiding or reserving a place at the
    /// top of the list for a session no server has any more. Never leaves a local store pointing
    /// at a chat that is gone.
    private func forgetLocally(_ entry: SessionEntry) {
        SavedChatStore.remove(profileID: entry.profileID, sessionID: entry.session.id)
        if ArchivedChatStore.contains(profileID: entry.profileID, sessionID: entry.session.id) {
            ArchivedChatStore.toggle(profileID: entry.profileID, sessionID: entry.session.id)
        }
        if SessionPinStore.contains(profileID: entry.profileID, sessionID: entry.session.id) {
            SessionPinStore.toggle(profileID: entry.profileID, sessionID: entry.session.id)
        }
    }

    private struct SourceTimeout: LocalizedError {
        var errorDescription: String? { String(localized: "The server did not answer in time.") }
    }

    /// A session list is a refresh, not a long-running turn, so it must not
    /// inherit the transport's 30s request timeout: one peer that has dropped
    /// off the tailnet would otherwise hold the whole fan-out — and the
    /// pull-to-refresh spinner — for half a minute per attempt. A source that
    /// misses this deadline is treated exactly like any other failure, so its
    /// cached entries survive and the reachable servers paint immediately.
    private static let sourceDeadline: Duration = .seconds(8)

    /// The confirmation pass runs off-screen with the list already painted, so
    /// it can afford to wait out a tailnet that is still re-establishing itself
    /// rather than inheriting a deadline sized for a spinner.
    private static let confirmationDeadline: Duration = .seconds(20)

    private static func listWithDeadline(
        _ source: Source, knownDirectories: Set<String>, deadline: Duration
    ) async throws -> [AgentSession] {
        try await withThrowingTaskGroup(of: [AgentSession].self) { group in
            group.addTask {
                try await source.backend.listAllSessions(knownDirectories: Array(knownDirectories))
            }
            group.addTask {
                try await Task.sleep(for: deadline)
                throw SourceTimeout()
            }
            guard let first = try await group.next() else { throw SourceTimeout() }
            group.cancelAll()
            return first
        }
    }

    nonisolated static func readable(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
