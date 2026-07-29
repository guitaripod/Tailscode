import CodingAgentKit
import CodingAgentKitApple
import Foundation

struct SessionEntry: Hashable {
    let profileID: String
    let profileName: String
    let host: String
    let backendType: AgentType
    let session: AgentSession

    static func == (lhs: SessionEntry, rhs: SessionEntry) -> Bool {
        lhs.profileID == rhs.profileID && lhs.session.id == rhs.session.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(profileID)
        hasher.combine(session.id)
    }
}

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

    init(sources: [Source]) {
        self.sources = sources
        self.sourcesRevision = ConnectionController.shared.revision
        let profileIDs = Set(sources.map(\.profile.id))
        entries = SessionListCache.load().filter { profileIDs.contains($0.profileID) }
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
        }
        await refresh(sources, deadline: Self.sourceDeadline)
    }

    /// Lists `targets` concurrently and merges their answers into what is
    /// already on screen, so a server that stayed silent keeps the sessions it
    /// last reported rather than blanking. Servers outside `targets` are left
    /// untouched, which is what lets a doubted server be re-checked on its own.
    private func refresh(_ targets: [Source], deadline: Duration) async {
        var fresh: [String: [SessionEntry]] = [:]
        await withTaskGroup(of: (Source, Result<[AgentSession], Error>).self) { group in
            for source in targets {
                group.addTask {
                    do {
                        return (
                            source,
                            .success(try await Self.listWithDeadline(source, deadline: deadline))
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
                    fresh[source.profile.id] = list.filter { $0.parentID == nil }.map {
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
        publish(fresh)
    }

    /// Merged onto whatever is on screen at this moment rather than onto a
    /// snapshot taken before the fan-out: the confirmation pass and the cadence
    /// can be in flight together, and neither may republish the other's servers
    /// from a list it read minutes ago.
    private func publish(_ fresh: [String: [SessionEntry]]) {
        let byProfile = Dictionary(grouping: entries, by: \.profileID)
            .merging(fresh) { _, new in new }
        let live = sources.map(\.profile.id)
        let collected = live.flatMap { byProfile[$0] ?? [] }
        let verdicts = live.filter { (failureStreaks[$0] ?? 0) >= Self.failuresBeforeVerdict }
        let changed = collected.count != entries.count || verdicts != unreachable
        entries = collected.sorted { $0.session.updatedAt > $1.session.updatedAt }
        unreachable = verdicts
        SessionListCache.save(entries)
        SavedChatStore.reconcile(with: entries)
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

    func delete(_ entry: SessionEntry) async {
        guard let backend = backend(for: entry) else { return }
        do {
            try await backend.deleteSession(entry.session.id)
            entries.removeAll { $0 == entry }
            SavedChatStore.remove(profileID: entry.profileID, sessionID: entry.session.id)
            onChange?()
        } catch {
            onError?(Self.readable(error))
            await load()
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
        _ source: Source, deadline: Duration
    ) async throws -> [AgentSession] {
        try await withThrowingTaskGroup(of: [AgentSession].self) { group in
            group.addTask { try await source.backend.listSessions() }
            group.addTask {
                try await Task.sleep(for: deadline)
                throw SourceTimeout()
            }
            guard let first = try await group.next() else { throw SourceTimeout() }
            group.cancelAll()
            return first
        }
    }

    static func readable(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
