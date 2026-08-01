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
