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
                    do { return (source, .success(try await source.backend.listSessions())) }
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

    static func readable(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
