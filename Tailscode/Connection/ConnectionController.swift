import CodingAgentKit
import CodingAgentKitApple
import Foundation

@MainActor
final class ConnectionController {
    static let shared = ConnectionController()

    private let store: ConnectionProfileStore?
    private let activeKey = "tailscode.activeProfileID"
    private let demoKey = "tailscode.demoMode"
    private(set) var activeProfileID: String?
    private(set) var isDemoMode: Bool

    private struct StoreUnavailable: LocalizedError {
        var errorDescription: String? { "Profile storage is unavailable on this device." }
    }

    struct ProRequired: LocalizedError {
        var errorDescription: String? {
            "Connecting more than one server requires Tailscode Pro."
        }
    }

    init() {
        store = try? ConnectionProfileStore()
        activeProfileID = UserDefaults.standard.string(forKey: activeKey)
        isDemoMode = UserDefaults.standard.bool(forKey: demoKey)
        if let store {
            AppLogger.connection.info("profile store ready at \(store.directory.lastPathComponent)")
        } else {
            AppLogger.connection.error("profile store unavailable")
        }
        if activeProfileID == nil, let first = profiles.first {
            setActive(first.id)
        }
    }

    var profiles: [ConnectionProfile] {
        var all = (try? store?.profiles()) ?? []
        #if DEBUG
            for profile in debugProfiles where !all.contains(where: { $0.id == profile.id }) {
                all.append(profile)
            }
        #endif
        if isDemoMode { all.append(contentsOf: DemoWorld.profiles) }
        return all
    }

    /// Puts the app into the scripted no-server demo world. Exits automatically
    /// the moment a real server is saved.
    func enterDemoMode() {
        UserDefaults.standard.set(true, forKey: demoKey)
        isDemoMode = true
        setActive(DemoWorld.claudeProfile.id)
        AppLogger.connection.info("entered demo mode")
    }

    func leaveDemoMode() {
        UserDefaults.standard.set(false, forKey: demoKey)
        isDemoMode = false
        let remaining = profiles.first?.id
        setActive(activeProfileID.flatMap { id in profiles.contains { $0.id == id } ? id : nil } ?? remaining)
        AppLogger.connection.info("left demo mode")
    }

    var activeProfile: ConnectionProfile? {
        let all = profiles
        return all.first { $0.id == activeProfileID } ?? all.first
    }

    var hasConnection: Bool { activeProfile != nil }

    /// Backstop for the Pro gate: the UI gates the entry points, this catches
    /// any path that slips through. First profile and re-saves are always free.
    func save(_ profile: ConnectionProfile, password: String?, makeActive: Bool = true) throws {
        guard let store else { throw StoreUnavailable() }
        var profile = profile
        let existing = profiles.filter { !$0.id.hasPrefix(DemoWorld.profilePrefix) }
        if !existing.contains(where: { $0.id == profile.id }),
            let duplicate = existing.first(where: {
                $0.backend == profile.backend
                    && $0.baseURL.scheme == profile.baseURL.scheme
                    && $0.baseURL.host == profile.baseURL.host
                    && $0.baseURL.port == profile.baseURL.port
            })
        {
            profile.id = duplicate.id
            AppLogger.connection.info("save matched existing server \(duplicate.name); updating instead of duplicating")
        }
        let isNew = !existing.contains { $0.id == profile.id }
        let isDebugSeed = profile.id.hasPrefix("debug")
        if isNew, !existing.isEmpty, !isDebugSeed, !ProStore.shared.isPro {
            throw ProRequired()
        }
        try store.save(profile, password: password)
        if isDemoMode { leaveDemoMode() }
        if makeActive { setActive(profile.id) }
        AppLogger.connection.info("saved profile \(profile.name) [\(profile.backend.rawValue)]")
    }

    func delete(_ id: String) throws {
        if id.hasPrefix(DemoWorld.profilePrefix) {
            leaveDemoMode()
            return
        }
        guard let store else { throw StoreUnavailable() }
        try store.delete(id: id)
        if activeProfileID == id {
            setActive(profiles.first { $0.id != id }?.id)
        }
    }

    func setActive(_ id: String?) {
        activeProfileID = id
        UserDefaults.standard.set(id, forKey: activeKey)
    }

    #if DEBUG
        private var overridePasswords: [String: String] = [:]
        private var debugProfiles: [ConnectionProfile] = []

        func setOverridePassword(_ password: String?, for id: String) {
            overridePasswords[id] = password
        }

        /// Keeps a seeded profile alive in memory when the simulator Keychain
        /// rejects the save (errSecMissingEntitlement flake), so DEBUG
        /// auto-connect works regardless.
        func addDebugProfile(_ profile: ConnectionProfile) {
            debugProfiles.removeAll { $0.id == profile.id }
            debugProfiles.append(profile)
        }
    #endif

    func makeBackend(for profile: ConnectionProfile, policy: ConnectionPolicy = .default)
        -> (any CodingAgentBackend)?
    {
        if profile.id.hasPrefix(DemoWorld.profilePrefix) {
            return DemoWorld.backend(for: profile.id)
        }
        if let backend = try? store?.makeBackend(profile, policy: policy) {
            return backend
        }
        #if DEBUG
            if let password = overridePasswords[profile.id] {
                return profile.makeBackend(password: password, policy: policy)
            }
        #endif
        return nil
    }

    /// A backend for every saved profile, for the unified cross-server session list.
    func allBackends(policy: ConnectionPolicy = .default)
        -> [(profile: ConnectionProfile, backend: any CodingAgentBackend)]
    {
        profiles.compactMap { profile in
            makeBackend(for: profile, policy: policy).map { (profile, $0) }
        }
    }
}

enum AgentProbe {
    static let policy = ConnectionPolicy(requestTimeout: .seconds(10), resourceTimeout: .seconds(15))

    static func username(for backend: AgentType) -> String {
        backend == .openCode ? "opencode" : "claude"
    }

    /// Retries with the other backend's Basic-auth username on .authFailed:
    /// the caller's backend may be a port guess, and claude-bridge rejects a
    /// correct password sent under the wrong username.
    static func probe(baseURL: URL, password: String?, preferring backend: AgentType) async -> ConnectionProbe.Outcome {
        guard let password else {
            return await ConnectionProbe().probe(baseURL: baseURL, credentials: nil, policy: policy)
        }
        let outcome = await ConnectionProbe().probe(
            baseURL: baseURL,
            credentials: BasicCredentials(username: username(for: backend), password: password),
            policy: policy)
        guard case .authFailed = outcome else { return outcome }
        let other: AgentType = backend == .openCode ? .claudeCode : .openCode
        return await ConnectionProbe().probe(
            baseURL: baseURL,
            credentials: BasicCredentials(username: username(for: other), password: password),
            policy: policy)
    }
}
