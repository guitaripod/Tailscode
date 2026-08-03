import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// The servers this Mac knows about, and the backends that talk to them.
///
/// Profiles live where the Kit already puts them — `profiles.json` in Application Support with the
/// password in the Keychain — so the desktop is a peer of the phone rather than a second store to
/// keep in step.
///
/// `TAILSCODE_HOST` / `TAILSCODE_PASSWORD` override that entirely and are never written anywhere.
/// A build loop reaches this Mac over ssh, where the Keychain has no session to prompt in and a
/// read can block forever; an environment-only path keeps the loop honest without asking the
/// login keychain for anything.
@MainActor
final class ServerDirectory {
    static let shared = ServerDirectory()

    private(set) var profiles: [ConnectionProfile] = []
    private var backends: [String: any CodingAgentBackend] = [:]
    private var ephemeralPasswords: [String: String] = [:]
    private let store: ConnectionProfileStore?

    init() {
        store = try? ConnectionProfileStore()
        reload()
    }

    func reload() {
        backends = [:]
        if let (profile, password) = Self.environmentProfile() {
            profiles = [profile]
            ephemeralPasswords = [profile.id: password].compactMapValues { $0 }
            return
        }
        ephemeralPasswords = [:]
        profiles = (try? store?.profiles()) ?? []
    }

    func backend(for profile: ConnectionProfile) -> (any CodingAgentBackend)? {
        if let existing = backends[profile.id] { return existing }
        let made: (any CodingAgentBackend)?
        if let password = ephemeralPasswords[profile.id] {
            made = profile.makeBackend(password: password)
        } else {
            made = try? store?.makeBackend(profile)
        }
        guard let made else { return nil }
        backends[profile.id] = made
        return made
    }

    func save(_ profile: ConnectionProfile, password: String?) throws {
        guard let store else { throw AgentError.unsupported("no profile store") }
        try store.save(profile, password: password)
        reload()
    }

    func delete(id: String) {
        try? store?.delete(id: id)
        reload()
    }

    /// Every session on every configured server, as one list — the same merge the Linux desktop
    /// and the phone speak, so all three clients agree on what a row is. A server that does not
    /// answer is named in `unreachable` rather than silently shortening the list.
    func entries() async -> (entries: [SessionEntry], unreachable: [String]) {
        var collected: [SessionEntry] = []
        var down: [String] = []
        for profile in profiles {
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
        let backend: AgentType = environment["TAILSCODE_BACKEND"] == "opencode" ? .openCode : .claudeCode
        guard case .address(let address) = HostAddress.read(raw, defaultPort: HostAddress.port(for: backend))
        else { return nil }
        let profile = ConnectionProfile(
            id: "environment", name: address.displayHost, backend: backend, baseURL: address.url,
            username: backend == .claudeCode ? "claude" : "opencode")
        return (profile, environment["TAILSCODE_PASSWORD"])
    }
}
