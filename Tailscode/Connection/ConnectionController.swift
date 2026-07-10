import CodingAgentKit
import CodingAgentKitApple
import Foundation

@MainActor
final class ConnectionController {
    static let shared = ConnectionController()

    private let store: ConnectionProfileStore?
    private let activeKey = "tailscode.activeProfileID"
    private(set) var activeProfileID: String?

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
        (try? store?.profiles()) ?? []
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
        let existing = profiles
        let isNew = !existing.contains { $0.id == profile.id }
        let isDebugSeed = profile.id.hasPrefix("debug")
        if isNew, !existing.isEmpty, !isDebugSeed, !ProStore.shared.isPro {
            throw ProRequired()
        }
        try store.save(profile, password: password)
        if makeActive { setActive(profile.id) }
        AppLogger.connection.info("saved profile \(profile.name) [\(profile.backend.rawValue)]")
    }

    func delete(_ id: String) throws {
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

    func password(for profile: ConnectionProfile) -> String? {
        try? store?.password(for: profile.id)
    }

    func makeBackend(policy: ConnectionPolicy = .default) -> (any CodingAgentBackend)? {
        guard let profile = activeProfile else {
            AppLogger.connection.error("makeBackend: no active profile")
            return nil
        }
        if let store, let backend = try? store.makeBackend(profile, policy: policy) {
            return backend
        }
        #if DEBUG
            if let password = overridePasswords[profile.id] {
                AppLogger.connection.info("makeBackend: using debug override password")
                return profile.makeBackend(password: password, policy: policy)
            }
        #endif
        AppLogger.connection.error("makeBackend: unable to build backend (Keychain unavailable?)")
        return nil
    }

    #if DEBUG
        private var overridePasswords: [String: String] = [:]
        func setOverridePassword(_ password: String?, for id: String) {
            overridePasswords[id] = password
        }
    #endif

    func makeBackend(for profile: ConnectionProfile, policy: ConnectionPolicy = .default)
        -> (any CodingAgentBackend)?
    {
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
