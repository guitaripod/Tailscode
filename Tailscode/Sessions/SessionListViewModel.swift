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
    private(set) var entries: [SessionEntry] = []
    private(set) var unreachable: [String] = []

    var onChange: (() -> Void)?
    var onError: ((String) -> Void)?

    init(sources: [Source]) {
        self.sources = sources
        let profileIDs = Set(sources.map(\.profile.id))
        entries = SessionListCache.load().filter { profileIDs.contains($0.profileID) }
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

    /// Re-reads the profile list on every load so servers added or removed
    /// in Settings appear without recreating this screen.
    func load() async {
        let current = ConnectionController.shared.profiles.map(\.id)
        if current != sources.map(\.profile.id) {
            sources = ConnectionController.shared.allBackends()
                .map { Source(profile: $0.profile, backend: $0.backend) }
        }
        var collected: [SessionEntry] = []
        var failed: [String] = []

        await withTaskGroup(of: (Source, Result<[AgentSession], Error>).self) { group in
            for source in sources {
                group.addTask {
                    do { return (source, .success(try await Self.listWithDeadline(source))) }
                    catch { return (source, .failure(error)) }
                }
            }
            for await (source, result) in group {
                switch result {
                case .success(let list):
                    for session in list where session.parentID == nil {
                        collected.append(
                            SessionEntry(
                                profileID: source.profile.id,
                                profileName: source.profile.name,
                                host: source.profile.baseURL.host ?? source.profile.name,
                                backendType: source.profile.backend,
                                session: session))
                    }
                case .failure(let error):
                    failed.append(source.profile.id)
                    collected.append(contentsOf: entries.filter { $0.profileID == source.profile.id })
                    AppLogger.session.error(
                        "load failed for \(source.profile.name): \(Self.readable(error))")
                }
            }
        }

        entries = collected.sorted { $0.session.updatedAt > $1.session.updatedAt }
        unreachable = failed
        SessionListCache.save(entries)
        AppLogger.session.info("loaded \(entries.count) sessions across \(sources.count) servers")
        onChange?()
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
            onChange?()
        } catch {
            onError?(Self.readable(error))
            await load()
        }
    }

    private struct SourceTimeout: LocalizedError {
        var errorDescription: String? { "The server did not answer in time." }
    }

    /// A session list is a refresh, not a long-running turn, so it must not
    /// inherit the transport's 30s request timeout: one peer that has dropped
    /// off the tailnet would otherwise hold the whole fan-out — and the
    /// pull-to-refresh spinner — for half a minute per attempt. A source that
    /// misses this deadline is treated exactly like any other failure, so its
    /// cached entries survive and the reachable servers paint immediately.
    private static let sourceDeadline: Duration = .seconds(8)

    private static func listWithDeadline(_ source: Source) async throws -> [AgentSession] {
        try await withThrowingTaskGroup(of: [AgentSession].self) { group in
            group.addTask { try await source.backend.listSessions() }
            group.addTask {
                try await Task.sleep(for: sourceDeadline)
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
