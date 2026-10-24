import CodingAgentKit
import CodingAgentKitApple
import Foundation
import Synchronization
import TailscodeCore

/// What the chat list last said, in the shape the tower is told: the sessions of every machine,
/// which machines answered, which chats are unread, and when each machine was last heard.
struct AgentsListing: Sendable {
    var entries: [SessionEntry]
    var reachability: [String: Bool]
    var unread: Set<String>
    var lastSeen: [String: Date]
}

/// The backends the chat list has reached, by profile, for the tower to ask for without waiting.
final class BackendBook: @unchecked Sendable {
    private let held = Mutex<[String: any CodingAgentBackend]>([:])

    func backend(_ id: String) -> (any CodingAgentBackend)? { held.withLock { $0[id] } }

    func keep(_ backend: any CodingAgentBackend, for id: String) {
        held.withLock { $0[id] = backend }
    }
}

/// The one `AgentTower` of the app, and the road the chat list's refreshes take to it. The tower is
/// an actor and the list is the main window's, so the listing is handed over by a coalescing
/// feeder: the newest listing wins, one task drains it, and the backends the tower is asked for are
/// the ones the chats already hold, never a second connection.
final class AgentsRuntime: @unchecked Sendable {
    static let shared = AgentsRuntime()

    let tower: AgentTower
    private let backends = BackendBook()
    private let feeder = Mutex(Feeder())
    private let seen = Mutex<[String: Date]>([:])

    private struct Feeder {
        var pending: AgentsListing?
        var pushing = false
    }

    private let held = Mutex<AgentBoard.Headline?>(nil)
    private let shown = Mutex(false)

    private init() {
        let backends = backends
        tower = AgentTower(
            setup: AgentTowerSetup(
                backend: { id in backends.backend(id) },
                catalog: { ModelCatalogStore.cached($0) }))
    }

    var source: any AgentsSource {
        DemoMode.isActive ? DemoAgentsSource() : TowerSource(tower: tower)
    }

    /// When a machine was last heard from, for the line a dimmed card says.
    func lastSeen(_ profileID: String) -> Date? { seen.withLock { $0[profileID] } }

    /// Whether a board is open and so worth feeding. Nothing is handed to the tower while it is not.
    var watching: Bool {
        get { shown.withLock { $0 } }
        set { shown.withLock { $0 = newValue } }
    }

    /// The headline of the board while it is open, so the sidebar's chip says what the board says
    /// rather than what the list could guess.
    var openHeadline: AgentBoard.Headline? {
        get { held.withLock { $0 } }
        set { held.withLock { $0 = newValue } }
    }

    /// A fresh listing from the chat list. Nothing is sent in demo mode, whose board is not built
    /// from machines.
    func feed(_ listing: AgentsListing) {
        seen.withLock { $0 = listing.lastSeen }
        guard !DemoMode.isActive else { return }
        let start = feeder.withLock { state -> Bool in
            state.pending = listing
            if state.pushing { return false }
            state.pushing = true
            return true
        }
        guard start else { return }
        Task { await drain() }
    }

    private func drain() async {
        while let listing = take() {
            for id in Set(listing.entries.map(\.profileID)) {
                if let backend = await ServerDirectory.shared.backend(forProfileID: id) {
                    backends.keep(backend, for: id)
                }
            }
            await tower.update(
                entries: listing.entries, reachability: listing.reachability, unread: listing.unread)
        }
    }

    private func take() -> AgentsListing? {
        feeder.withLock { state in
            if let next = state.pending {
                state.pending = nil
                return next
            }
            state.pushing = false
            return nil
        }
    }

    /// The listing a main window hands over: the session keys the person has not read, and which
    /// machines answered the last sweep (a machine's label is how `unreachable` names it).
    static func listing(
        entries: [SessionEntry], unreachable: [String], lastHeard: [String: Date],
        listedFromNetwork: Bool
    ) -> AgentsListing {
        let isUnread = SessionSeenStore.unreadEvaluator()
        var reachability: [String: Bool] = [:]
        var lastSeen: [String: Date] = [:]
        for entry in entries where reachability[entry.profileID] == nil {
            let label = ServerLabel.display(name: entry.profileName, backend: entry.backendType)
            if listedFromNetwork { reachability[entry.profileID] = !unreachable.contains(label) }
            if let heard = lastHeard[label] { lastSeen[entry.profileID] = heard }
        }
        let unread = Set(
            entries.filter { isUnread($0.session.id, $0.session.updatedAt) }.map {
                $0.profileID + "/" + $0.session.id
            })
        return AgentsListing(
            entries: entries, reachability: reachability, unread: unread, lastSeen: lastSeen)
    }
}

/// What the sidebar's Agents row says: the chip that leads, in words a screen reader reads too.
struct AgentsChip: Equatable, Sendable {
    let needsYou: Int
    let working: Int

    var isEmpty: Bool { needsYou == 0 && working == 0 }

    var isUrgent: Bool { needsYou > 0 }

    var text: String { isUrgent ? "\(needsYou)" : working > 0 ? "\(working)" : "" }

    var spoken: String {
        var parts = [Localized.text("Agents")]
        if needsYou > 0 { parts.append(Localized.text("%d needs you", needsYou)) }
        if working > 0 { parts.append(Localized.text("%d working", working)) }
        return parts.joined(separator: ", ")
    }

    init(needsYou: Int, working: Int) {
        self.needsYou = needsYou
        self.working = working
    }

    init(headline: AgentBoard.Headline) {
        self.init(needsYou: headline.needsYou, working: headline.working)
    }

    /// The same count from the chat list's rows, for when the board is shut and nothing is watched:
    /// what the list knows is a turn that is open and a turn that is waiting on an approval.
    init(rows: [SessionRowState]) {
        self.init(
            needsYou: rows.count { $0 == .awaitingApproval }, working: rows.count { $0 == .live })
    }
}
