import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// The servers this machine knows about, and the backends that talk to them.
///
/// Deliberately not a global actor: on Linux the main actor's executor is libdispatch's main
/// queue, and `g_application_run` blocks inside the GLib main context without ever draining it —
/// so anything awaited from a GTK signal handler would suspend forever, silently. This is a plain
/// actor, and the UI marshals back with `onMain`.
public actor ServerDirectory {
    public static let shared = ServerDirectory()

    private var cached: [ConnectionProfile] = []
    private var backends: [String: any CodingAgentBackend] = [:]
    private var backendProfiles: [String: ConnectionProfile] = [:]
    private var ephemeralPasswords: [String: String] = [:]
    private var demoMode = false
    private let store = LinuxProfileStore()

    public func profiles() -> [ConnectionProfile] { cached }
    public func isDemoMode() -> Bool { demoMode }

    /// Re-reads the servers this machine is configured for.
    ///
    /// A server that did not change keeps the backend already talking to it. The list poll asks
    /// for this every ten seconds, and a backend is not a cheap thing to make: it carries a
    /// `URLSession`, which on Linux is a libcurl handle that nothing invalidates. Throwing them
    /// all away six times a minute meant the app was quietly accumulating one connection stack per
    /// server per poll for as long as it was open.
    public func reload() {
        if let (profile, password) = Self.environmentProfile() {
            cached = [profile]
            ephemeralPasswords = password.map { [profile.id: $0] } ?? [:]
            demoMode = false
            keepBackends(for: cached)
            return
        }
        ephemeralPasswords = [:]
        var listed = (try? store.profiles()) ?? []
        demoMode = DemoMode.isActive
        if demoMode {
            listed.append(contentsOf: DemoWorld.profiles)
        }
        cached = listed
        keepBackends(for: cached)
    }

    /// Drops the backends whose server is gone or whose address, name or agent changed, and keeps
    /// the rest exactly as they are.
    private func keepBackends(for profiles: [ConnectionProfile]) {
        var kept: [String: any CodingAgentBackend] = [:]
        var keptProfiles: [String: ConnectionProfile] = [:]
        for profile in profiles {
            guard let existing = backends[profile.id], backendProfiles[profile.id] == profile
            else { continue }
            kept[profile.id] = existing
            keptProfiles[profile.id] = profile
        }
        backends = kept
        backendProfiles = keptProfiles
    }

    /// Forgets the backend for one server, so the next ask builds a fresh one. A password is not
    /// part of a profile, so a credential that changed has to say so.
    private func forgetBackend(id: String) {
        backends[id] = nil
        backendProfiles[id] = nil
    }

    /// The password a saved server was reached with, so an edit that changes only its name or its
    /// address can hand the same one back — `save` reads a missing password as an instruction to
    /// forget the stored one, which would silently lock the app out of a server the user merely
    /// renamed.
    public func password(for profile: ConnectionProfile) -> String? {
        if let ephemeral = ephemeralPasswords[profile.id] { return ephemeral }
        return (try? store.password(for: profile.id)) ?? nil
    }

    /// The backend for a profile named by id alone — what a stored intent carries, a listing
    /// having long since gone. Nil for a server that is no longer connected.
    public func backend(forProfileID id: String) -> (any CodingAgentBackend)? {
        guard let profile = cached.first(where: { $0.id == id }) else { return nil }
        return backend(for: profile)
    }

    public func backend(for profile: ConnectionProfile) -> (any CodingAgentBackend)? {
        if profile.id.hasPrefix(DemoWorld.profilePrefix) {
            return DemoWorld.backend(for: profile.id)
        }
        if let existing = backends[profile.id] { return existing }
        let made: (any CodingAgentBackend)?
        if let password = ephemeralPasswords[profile.id] {
            made = profile.makeBackend(password: password)
        } else {
            made = try? store.makeBackend(profile)
        }
        guard let made else { return nil }
        backends[profile.id] = made
        backendProfiles[profile.id] = profile
        return made
    }

    public func enterDemoMode() {
        DemoMode.enter()
        reload()
    }

    public func leaveDemoMode() {
        DemoMode.leave()
        reload()
    }

    public func save(_ profile: ConnectionProfile, password: String?) throws {
        try store.save(profile, password: password)
        forgetBackend(id: profile.id)
        if demoMode {
            DemoMode.leave()
        }
        reload()
    }

    public func delete(id: String) {
        forgetBackend(id: id)
        if id.hasPrefix(DemoWorld.profilePrefix) {
            DemoMode.leave()
            reload()
            return
        }
        try? store.delete(id: id)
        reload()
    }

    /// Every session on every configured server, as one list — the same shape the phone's list
    /// speaks, so the sidebar and a future shared view model agree on what a row is. `knownDirectories`
    /// seed the per-project walk: a chat the list already knows lives in a place worth asking
    /// about even when the server does not report a project for it.
    ///
    /// A server that throws keeps what it last reported rather than blanking: the listing is a
    /// merge over `previous`, not a wholesale replacement, so one missed fetch (or a project
    /// dropped from the server's own list between refreshes) cannot erase the sidebar's memory
    /// of chats it has shown before.
    /// When each server was last heard from, keyed the way a row names it. A row whose server has
    /// stopped answering measures its age against this rather than against now, so the column
    /// freezes at the last reading instead of ageing a turn nobody can see any more.
    public private(set) var lastHeard: [String: Date] = [:]

    public func entries(
        knownDirectories: [String] = [], previous: [SessionEntry] = []
    ) async -> (entries: [SessionEntry], unreachable: [String]) {
        var collected: [SessionEntry] = []
        var down: [String] = []
        for profile in cached {
            guard let backend = backend(for: profile) else {
                down.append(ServerLabel.display(profile))
                collected += previous.filter { $0.profileID == profile.id }
                continue
            }
            do {
                let sessions = try await backend.listAllSessions(knownDirectories: knownDirectories)
                lastHeard[ServerLabel.display(profile)] = Date()
                collected += sessions.map {
                    SessionEntry(
                        profileID: profile.id, profileName: profile.name,
                        host: profile.baseURL.host ?? profile.name,
                        backendType: profile.backend, session: $0)
                }
            } catch {
                down.append(ServerLabel.display(profile))
                collected += previous.filter { $0.profileID == profile.id }
            }
        }
        collected.sort { $0.session.updatedAt > $1.session.updatedAt }
        return (collected, down)
    }

    private static func environmentProfile() -> (ConnectionProfile, String?)? {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["TAILSCODE_HOST"], !raw.isEmpty else { return nil }
        let backend: AgentType =
            switch environment["TAILSCODE_BACKEND"] {
            case "opencode": .openCode
            case "omp": .omp
            default: .claudeCode
            }
        guard
            case .address(let address) = HostAddress.read(
                raw, defaultPort: HostAddress.port(for: backend))
        else { return nil }
        let profile = ConnectionProfile(
            id: "environment", name: address.displayHost, backend: backend, baseURL: address.url,
            username: ProbeSweep.username(for: backend))
        return (profile, environment["TAILSCODE_PASSWORD"])
    }
}
