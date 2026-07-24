import CodingAgentKit
import Foundation

/// Persists the merged cross-server session list so a cold launch renders the
/// last-known chats instantly instead of empty sections while every server is
/// fetched over Tailscale. Liveness is only trustworthy fresh from the
/// network, so `isActive` is stripped on load — a cached list can never show
/// phantom live sessions.
enum SessionListCache {
    private struct Entry: Codable {
        let profileID: String
        let profileName: String
        let host: String
        let backendType: AgentType
        let session: AgentSession
    }

    private static let maxEntries = 200

    private static var fileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("session-list.json")
    }

    static func load() -> [SessionEntry] {
        guard let data = try? Data(contentsOf: fileURL),
            let cached = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return cached.map { entry in
            var session = entry.session
            session.isActive = nil
            return SessionEntry(
                profileID: entry.profileID, profileName: entry.profileName,
                host: entry.host, backendType: entry.backendType, session: session)
        }
    }

    static func save(_ entries: [SessionEntry]) {
        let cached = entries.prefix(maxEntries).map {
            Entry(
                profileID: $0.profileID, profileName: $0.profileName, host: $0.host,
                backendType: $0.backendType, session: $0.session)
        }
        guard let data = try? JSONEncoder().encode(cached) else { return }
        try? data.write(
            to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
