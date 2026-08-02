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
    private var ephemeralPasswords: [String: String] = [:]
    private let store = LinuxProfileStore()

    public func profiles() -> [ConnectionProfile] { cached }

    public func reload() {
        backends = [:]
        if let (profile, password) = Self.environmentProfile() {
            cached = [profile]
            ephemeralPasswords = password.map { [profile.id: $0] } ?? [:]
            return
        }
        ephemeralPasswords = [:]
        cached = (try? store.profiles()) ?? []
    }

    public func backend(for profile: ConnectionProfile) -> (any CodingAgentBackend)? {
        if let existing = backends[profile.id] { return existing }
        let made: (any CodingAgentBackend)?
        if let password = ephemeralPasswords[profile.id] {
            made = profile.makeBackend(password: password)
        } else {
            made = try? store.makeBackend(profile)
        }
        guard let made else { return nil }
        backends[profile.id] = made
        return made
    }

    public func save(_ profile: ConnectionProfile, password: String?) throws {
        try store.save(profile, password: password)
        reload()
    }

    public func delete(id: String) {
        try? store.delete(id: id)
        reload()
    }

    /// Every session on every configured server, as one list — the same shape the phone's list
    /// speaks, so the sidebar and a future shared view model agree on what a row is.
    public func entries() async -> (entries: [SessionEntry], unreachable: [String]) {
        var collected: [SessionEntry] = []
        var down: [String] = []
        for profile in cached {
            guard let backend = backend(for: profile) else {
                down.append(ServerLabel.display(profile))
                continue
            }
            do {
                let sessions = try await backend.listSessions()
                collected += sessions.map {
                    SessionEntry(
                        profileID: profile.id, profileName: profile.name,
                        host: profile.baseURL.host ?? profile.name,
                        backendType: profile.backend, session: $0)
                }
            } catch {
                down.append(ServerLabel.display(profile))
            }
        }
        collected.sort { $0.session.updatedAt > $1.session.updatedAt }
        return (collected, down)
    }

    private static func environmentProfile() -> (ConnectionProfile, String?)? {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["TAILSCODE_HOST"], !raw.isEmpty else { return nil }
        let backend: AgentType =
            environment["TAILSCODE_BACKEND"] == "opencode" ? .openCode : .claudeCode
        guard
            case .address(let address) = HostAddress.read(
                raw, defaultPort: HostAddress.port(for: backend))
        else { return nil }
        let profile = ConnectionProfile(
            id: "environment", name: address.displayHost, backend: backend, baseURL: address.url,
            username: backend == .claudeCode ? "claude" : "opencode")
        return (profile, environment["TAILSCODE_PASSWORD"])
    }
}
