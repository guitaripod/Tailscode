import CodingAgentKit
import Foundation

/// Persists the merged cross-server session list so a cold launch renders the
/// last-known chats instantly instead of empty sections while every server is
/// fetched over Tailscale. Liveness is only trustworthy fresh from the
/// network, so `isActive` is stripped on load — a cached list can never show
/// phantom live sessions.
public enum SessionListCache {
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

    public static func load() -> [SessionEntry] {
        guard let data = try? Data(contentsOf: fileURL),
            let cached = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return cached.filter { !$0.session.isSubagent }.map { entry in
            var session = entry.session
            session.isActive = nil
            return SessionEntry(
                profileID: entry.profileID, profileName: entry.profileName,
                host: entry.host, backendType: entry.backendType, session: session)
        }
    }

    public static func save(_ entries: [SessionEntry]) {
        let cached = entries.prefix(maxEntries).map {
            Entry(
                profileID: $0.profileID, profileName: $0.profileName, host: $0.host,
                backendType: $0.backendType, session: $0.session)
        }
        guard let data = try? JSONEncoder().encode(cached) else { return }
        try? data.write(
            to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    @MainActor private static var pending: [SessionEntry]?
    @MainActor private static var writer: Task<Void, Never>?

    /// Coalesces the write storm a busy turn produces — a proto-2 bridge pushes
    /// an upsert every time a status moves — into one encode+write a few seconds
    /// later, off the main actor. The cache exists for the next cold launch, not
    /// for durability, so the trailing edge is the right edge.
    @MainActor public static func scheduleSave(_ entries: [SessionEntry]) {
        pending = entries
        guard writer == nil else { return }
        writer = Task(priority: .utility) { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            writer = nil
            guard let entries = pending else { return }
            pending = nil
            await Task.detached(priority: .utility) { save(entries) }.value
        }
    }

    /// Writes whatever is still pending right now — for app backgrounding or
    /// window close, where the debounce window may never elapse.
    @MainActor public static func flushPendingSave() {
        writer?.cancel()
        writer = nil
        guard let entries = pending else { return }
        pending = nil
        save(entries)
    }
}
