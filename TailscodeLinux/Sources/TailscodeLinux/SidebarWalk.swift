import CodingAgentKit
import Foundation
import TailscodeCore

/// Everything the chat list decides by walking the whole fleet: a row for every chat, what the orb
/// and the Agents entry read, the sections the list is filed into, the words it shares and the
/// digest of the drawn order. A fleet that has been used for months lists two thousand chats, and
/// with a few agents at work the list was asked to draw most seconds; walking them was twelve to
/// fourteen milliseconds of the GTK thread each time, before a widget was touched. It is read from
/// values alone, so a draw the listing or a store asked for works it out on a dispatch worker and
/// the GTK thread only patches the rows it found moved.
struct SidebarWalk: Sendable {
    struct Input: Sendable {
        let entries: [SessionEntry]
        let pendingDeletes: Set<String>
        let unreachable: [String]
        let lastHeard: [String: Date]
        let savedChats: [SavedChat]
        let saved: Set<String>
        let pins: Set<String>
        let archived: Set<ArchivedChatStore.ChatKey>
        let unread: @Sendable (String, Date) -> Bool
        let presence: [String: SessionPresence]
        let needle: String
        let projectScope: ProjectScope?
        let showingArchive: Bool
        let splitTab: SplitTab?
        let observe: Bool
        let now: Date
    }

    struct Server: Sendable, Hashable {
        let profileID: String
        let name: String
    }

    let rows: [SessionRowModel]
    let servers: [Server]
    let rebuilt: Set<String>
    let orphanKeys: [String]
    let orbTarget: SessionEntry?
    let orbKinds: [ActivityKind?]
    let observations: [ActivityObservation]?
    let sections: [(ChatListSection, [ChatListItem])]
    let visible: [ChatListItem]
    let boardOfKey: [String: SessionSection]
    let archivedTotal: Int
    let vocabulary: ChatListVocabulary
    let order: Int

    /// The walk, on whatever thread asks, with the row cache it reads and writes handed in and out.
    static func make(_ input: Input, cache: inout SessionRowModelCache) -> SidebarWalk {
        cache.beginPass()
        var known: [Server: (unreachable: Bool, observedAt: Date?)] = [:]
        var servers: [Server] = []
        var rows: [SessionRowModel] = []
        rows.reserveCapacity(input.entries.count)
        for entry in input.entries {
            let key = SessionPinStore.key(entry.profileID, entry.session.id)
            if !input.pendingDeletes.isEmpty, input.pendingDeletes.contains(key) { continue }
            let named = Server(profileID: entry.profileID, name: entry.profileName)
            let server: (unreachable: Bool, observedAt: Date?)
            if let found = known[named] {
                server = found
            } else {
                let label = ServerLabel.display(name: entry.profileName, backend: entry.backendType)
                server = (input.unreachable.contains(label), input.lastHeard[label])
                known[named] = server
                servers.append(named)
            }
            rows.append(
                cache.model(
                    for: entry, key: key, unreachable: server.unreachable,
                    unread: input.unread(entry.session.id, entry.session.updatedAt),
                    saved: input.saved.contains(entry.session.id),
                    pinned: input.pins.contains(key),
                    presence: input.presence[key] ?? .unobserved, observedAt: server.observedAt,
                    now: input.now))
        }
        cache.sweep()
        let rebuilt = cache.takeRebuilt()
        let listedCount = rows.count
        rows += MainWindow.orphanedSavedRows(input.savedChats, listed: input.entries)
        var orphanKeys: [String] = []
        for orphan in rows[listedCount...] {
            servers.append(Server(profileID: orphan.entry.profileID, name: orphan.entry.profileName))
            orphanKeys.append(SessionPinStore.key(orphan.entry.profileID, orphan.entry.session.id))
        }
        let orbTarget =
            rows.first { $0.state == .awaitingApproval }?.entry ?? rows.first { $0.state == .live }?.entry
        let observations =
            input.observe
            ? rows.map {
                ActivityObservation(profileID: $0.entry.profileID, session: $0.entry.session, title: $0.title)
            } : nil
        let candidates: [(row: SessionRowModel, archived: Bool)] = rows.map {
            (
                $0,
                input.archived.contains(
                    ArchivedChatStore.ChatKey(profileID: $0.entry.profileID, sessionID: $0.entry.session.id))
            )
        }
        let scoped =
            input.projectScope.map { scope in candidates.filter { scope.matches($0.row.entry) } } ?? candidates
        let archivedTotal = scoped.count { $0.archived }
        let matching =
            input.needle.isEmpty
            ? scoped
            : scoped.filter {
                $0.row.title.lowercased().contains(input.needle)
                    || $0.row.detail.lowercased().contains(input.needle)
                    || ($0.row.snippet?.lowercased().contains(input.needle) ?? false)
            }
        let grouped: [(ChatListSection, [SessionRowModel])] =
            input.showingArchive
            ? [(ChatListSection.archived, matching.filter { $0.archived }.map { $0.row })].filter { !$0.1.isEmpty }
            : groupIntoListSections(
                matching.filter { !$0.archived || $0.row.isUnfinished }.map { $0.row }, now: input.now)
        let sections = SplitTabGrouping.apply(to: grouped, tab: input.splitTab)
        let visible = sections.flatMap(\.1)
        var boardOfKey: [String: SessionSection] = [:]
        for (section, members) in sections {
            guard let board = section.board else { continue }
            for item in members { boardOfKey[item.key] = board }
        }
        return SidebarWalk(
            rows: rows, servers: servers, rebuilt: rebuilt, orphanKeys: orphanKeys, orbTarget: orbTarget,
            orbKinds: rows.map { $0.state.activity }, observations: observations, sections: sections,
            visible: visible, boardOfKey: boardOfKey, archivedTotal: archivedTotal,
            vocabulary: ChatListVocabulary(rows: rows), order: order(of: visible))
    }

    /// A 64-bit digest of the drawn order, hashed from the profile and session ids with no
    /// strings built.
    private static func order(of visible: [ChatListItem]) -> Int {
        var order = Hasher()
        order.combine(visible.count)
        for item in visible {
            switch item {
            case .chat(let row):
                order.combine(row.entry.profileID)
                order.combine(row.entry.session.id)
            case .tab(let row):
                order.combine(row.members.count)
                for member in row.members {
                    order.combine(member.entry.profileID)
                    order.combine(member.entry.session.id)
                }
            }
        }
        return order.finalize()
    }

    /// The CPU time the calling thread has used, so a walk on a worker can say what it cost.
    static func threadTime() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return Double(time.tv_sec) * 1000 + Double(time.tv_nsec) / 1_000_000
    }
}
