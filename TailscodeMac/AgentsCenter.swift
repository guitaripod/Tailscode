import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// The one tower of this process. It is fed whenever the sidebar's listing refreshes — the same
/// refresh that feeds the Working band, never a poll of its own — and it watches nothing until a
/// window asks it to: the tower holds the listing and nothing else while the board is closed.
@MainActor
final class AgentsCenter {
    static let shared = AgentsCenter()
    static let didChange = Notification.Name("tailscode.mac.agents.didChange")

    /// The backends the chats already hold, copied out of the directory at every listing, because
    /// the tower asks for one from its own actor and the directory is the main actor's.
    private final class Backends: @unchecked Sendable {
        private let lock = NSLock()
        private var held: [String: any CodingAgentBackend] = [:]

        func replace(_ next: [String: any CodingAgentBackend]) {
            lock.lock()
            held = next
            lock.unlock()
        }

        func backend(_ id: String) -> (any CodingAgentBackend)? {
            lock.lock()
            defer { lock.unlock() }
            return held[id]
        }
    }

    private let backends = Backends()
    private let serial = AgentsSerial()
    let tower: AgentTower
    private(set) var liveBoard: AgentBoard?

    private init() {
        let backends = backends
        tower = AgentTower(
            setup: AgentTowerSetup(
                backend: { backends.backend($0) }, catalog: { ModelCatalogStore.cached($0) }))
    }

    /// A fresh listing: every machine's sessions, which machines answered, which chats are unread.
    func listing(entries: [SessionEntry], unreachable: [String]) {
        var held: [String: any CodingAgentBackend] = [:]
        var reachability: [String: Bool] = [:]
        for entry in entries where reachability[entry.profileID] == nil {
            reachability[entry.profileID] =
                !unreachable.contains(
                    ServerLabel.display(name: entry.profileName, backend: entry.backendType))
            held[entry.profileID] = ServerDirectory.shared.backend(forProfileID: entry.profileID)
        }
        backends.replace(held)
        let isUnread = SessionSeenStore.unreadEvaluator()
        let unread = Set(
            entries.filter { isUnread($0.session.id, $0.session.updatedAt) }.map {
                $0.profileID + "/" + $0.session.id
            })
        let tower = self.tower
        let reach = reachability
        serial.run {
            await tower.update(entries: entries, reachability: reach, unread: unread)
        }
    }

    func makeFeed() -> any AgentsFeed {
        if ServerDirectory.shared.isDemoMode { return DemoFeed() }
        return TowerFeed(tower: tower, serial: serial)
    }

    /// What the open board says, for the sidebar's badge; nil while no board is open and the
    /// listing's own words are all there is.
    func note(board: AgentBoard?) {
        liveBoard = board
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
