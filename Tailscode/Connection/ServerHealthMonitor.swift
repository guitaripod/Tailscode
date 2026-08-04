import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// Reachability per saved server, kept alive across screens. Settings used to
/// hold this in the view controller, so every visit re-ran the whole fan-out and
/// sat on an 8-second timeout per dead peer before it could draw a single dot.
@MainActor
enum ServerHealthMonitor {
    static let didChange = Notification.Name("ServerHealthMonitor.didChange")

    struct Entry {
        let reachable: Bool
        let checkedAt: Date
    }

    private static var entries: [String: Entry] = [:]
    private static var isChecking = false

    /// Long enough that reopening Settings reuses the answer, short enough that a
    /// server brought back up reads as reachable on the next visit.
    private static let freshness: TimeInterval = 60

    static func entry(for id: String) -> Entry? { entries[id] }

    static var lastCheckedAt: Date? { entries.values.map(\.checkedAt).max() }

    static func record(_ reachable: Bool, for id: String) {
        entries[id] = Entry(reachable: reachable, checkedAt: Date())
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func forget(_ id: String) {
        entries.removeValue(forKey: id)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func clear() {
        entries.removeAll()
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Whether anything is missing or old enough to be worth re-checking.
    static func needsCheck() -> Bool {
        let profiles = ConnectionController.shared.profiles
        guard !profiles.isEmpty else { return false }
        return profiles.contains { profile in
            guard let entry = entries[profile.id] else { return true }
            return Date().timeIntervalSince(entry.checkedAt) > freshness
        }
    }

    /// Probes every saved server concurrently, publishing each answer as it
    /// lands rather than at the end — one unreachable peer must not hold the
    /// dots of the servers that answered instantly.
    static func checkAll(force: Bool = false) async {
        guard !isChecking else { return }
        guard force || needsCheck() else { return }
        isChecking = true
        defer {
            isChecking = false
            NotificationCenter.default.post(name: didChange, object: nil)
        }
        let policy = ConnectionPolicy(requestTimeout: .seconds(8), resourceTimeout: .seconds(12))
        let profiles = ConnectionController.shared.profiles
        AppLogger.connection.info("health check starting for \(profiles.count) profiles (8s timeout)")
        await withTaskGroup(of: (String, Bool).self) { group in
            for profile in profiles {
                group.addTask {
                    guard
                        let backend = await ConnectionController.shared.makeBackend(
                            for: profile, policy: policy)
                    else {
                        AppLogger.connection.info("health check \(profile.name): no backend")
                        return (profile.id, false)
                    }
                    do {
                        let health = try await backend.health()
                        return (profile.id, health.healthy)
                    } catch {
                        AppLogger.connection.info(
                            "health check \(profile.name): error \(error.localizedDescription)")
                        return (profile.id, false)
                    }
                }
            }
            for await (id, ok) in group {
                record(ok, for: id)
                AppLogger.connection.info("health check result id=\(id.prefix(8)) ok=\(ok)")
            }
        }
    }

    /// True when every saved server failed its last check. On its own that means
    /// nothing — but combined with a missing tailnet address it is almost always
    /// one cause, not several coincident ones.
    static var allUnreachable: Bool {
        let profiles = ConnectionController.shared.profiles.filter {
            !$0.id.hasPrefix(DemoWorld.profilePrefix)
        }
        guard !profiles.isEmpty else { return false }
        return profiles.allSatisfy { entries[$0.id]?.reachable == false }
    }

    /// The diagnosis Settings shows above the server list.
    enum Verdict {
        case fine
        case tailnetDown
        case serversDown
    }

    static func verdict() -> Verdict {
        guard allUnreachable else { return .fine }
        return TailnetStatus.isConnected ? .serversDown : .tailnetDown
    }
}
