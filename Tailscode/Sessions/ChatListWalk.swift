import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// Everything the chat list column decides by walking the whole fleet: which chats it holds under
/// the filter, the scope and the search, each one's row model (through the row cache), the sections
/// and their order, the words the list shares, the sidebar's digest and whether Mark read has
/// anything to do. The column stands beside a conversation on a phone held sideways and on every
/// iPad, and with four agents working it drew all two thousand chats on the main thread twice a
/// second — 43-72 ms a draw on an iPad Pro, worst waits past a hundred milliseconds. It is read from
/// values alone, so a draw the listing asks for works it out away from the main thread.
struct ChatListWalk: Sendable {
    struct Input: Sendable {
        let entries: [SessionEntry]
        let archived: Set<String>
        let scope: ProjectScope?
        let filter: SessionListViewController.ChatFilter
        let search: String
        let saved: Set<String>
        let savedChats: [SavedChat]
        let unreachable: Set<String>
        let pins: [String]
        let unread: @Sendable (String, Date) -> Bool
        let presence: [String: SessionPresence]
        let observedAt: [String: Date]
        let cache: SessionRowModelCache
        let boards: [String: SessionSection]
        let servers: [ConnectionProfile]
        let notices: Int
        let offersReadAll: Bool
        let now: Date
    }

    var cache: SessionRowModelCache
    let rebuilt: Set<String>?
    let sections: [(ChatListSection, [SessionRowModel])]
    let rowModels: [String: SessionRowModel]
    let keys: [[String]]
    let visible: [SessionEntry]
    let vocabulary: ChatListVocabulary
    let headings: [ChatListSection: SectionHeading]
    let boards: [String: SessionSection]
    let boardsMoved: Set<String>
    let readAll: Bool
    let digest: ChatListDigest

    /// The walk, on whatever thread asks. A draw the listing asked for calls ``away(_:)``.
    static func make(_ input: Input) -> ChatListWalk {
        var cache = input.cache
        let entries = filtered(input)
        let pins = Set(input.pins)
        cache.beginPass()
        let rows = entries.map { entry in
            let key = SessionPinStore.key(entry.profileID, entry.session.id)
            return cache.model(
                for: entry, key: key, unreachable: input.unreachable.contains(entry.profileID),
                unread: input.unread(entry.session.id, entry.session.updatedAt),
                saved: input.saved.contains(key), pinned: pins.contains(key),
                presence: presence(of: entry, in: input),
                observedAt: input.observedAt[entry.profileID], now: input.now)
        }
        cache.sweep()
        let rebuilt = cache.takeRebuilt()
        return laid(
            groupIntoListSections(rows, now: input.now), cache: cache, rebuilt: rebuilt,
            boards: input.boards, digest: digest(input, pins: pins), readAll: readAll(input))
    }

    /// The tables a draw reads, laid out from rows already grouped. The screenshot fixture, whose
    /// rows are made up rather than walked, comes straight here with no rows rebuilt to name.
    static func laid(
        _ sections: [(ChatListSection, [SessionRowModel])], cache: SessionRowModelCache,
        rebuilt: Set<String>? = nil, boards previous: [String: SessionSection], digest: ChatListDigest,
        readAll: Bool
    ) -> ChatListWalk {
        var rowModels: [String: SessionRowModel] = [:]
        var keys: [[String]] = []
        var boards: [String: SessionSection] = [:]
        var visible: [SessionEntry] = []
        var headings: [ChatListSection: SectionHeading] = [:]
        for (section, members) in sections {
            headings[section] = SectionHeading(
                section: section, rows: members.count, fresh: members.count { $0.unread })
            var sectionKeys: [String] = []
            sectionKeys.reserveCapacity(members.count)
            for row in members {
                let key = ChatSelection.key(row.entry)
                sectionKeys.append(key)
                if rowModels[key] == nil { rowModels[key] = row }
                if let board = section.board { boards[key] = board }
                visible.append(row.entry)
            }
            keys.append(sectionKeys)
        }
        var boardsMoved: Set<String> = []
        for (key, board) in boards where previous[key] != board { boardsMoved.insert(key) }
        for key in previous.keys where boards[key] == nil { boardsMoved.insert(key) }
        return ChatListWalk(
            cache: cache, rebuilt: rebuilt, sections: sections, rowModels: rowModels, keys: keys,
            visible: visible, vocabulary: ChatListVocabulary(rows: sections.flatMap(\.1)),
            headings: headings, boards: boards, boardsMoved: boardsMoved, readAll: readAll, digest: digest)
    }

    /// The walk on the cooperative pool, never on the main actor.
    @concurrent
    static func away(_ input: Input) async -> ChatListWalk {
        make(input)
    }

    /// What this device witnesses about a conversation, and otherwise what the listing says.
    private static func presence(of entry: SessionEntry, in input: Input) -> SessionPresence {
        input.presence[entry.session.id] ?? .unobserved
    }

    private static func isLive(_ entry: SessionEntry, in input: Input) -> Bool {
        ChatArchiveRule.isUnfinished(presence: presence(of: entry, in: input), session: entry.session)
    }

    private static func filtered(_ input: Input) -> [SessionEntry] {
        var list =
            input.archived.isEmpty
            ? input.entries
            : input.entries.filter {
                !input.archived.contains(ArchivedChatStore.key($0.profileID, $0.session.id))
                    || isLive($0, in: input)
            }
        if let scope = input.scope { list = list.filter(scope.matches) }
        switch input.filter {
        case .all:
            break
        case .live:
            list = list.filter { isLive($0, in: input) }
        case .profile(let id):
            list = list.filter { $0.profileID == id }
        }
        guard !input.search.isEmpty else { return list }
        let query = input.search
        return list.filter {
            $0.session.title.localizedCaseInsensitiveContains(query)
                || ($0.session.agentTask?.localizedCaseInsensitiveContains(query) ?? false)
                || ($0.session.directory?.localizedCaseInsensitiveContains(query) ?? false)
                || $0.profileName.localizedCaseInsensitiveContains(query)
        }
    }

    private static func readAll(_ input: Input) -> Bool {
        guard input.offersReadAll else { return false }
        var summary: [String: SessionPresence] = [:]
        for (id, presence) in input.presence {
            if case .running = presence { summary[id] = .running(nil) } else { summary[id] = presence }
        }
        return !ReadSweep.reading(
            entries: input.entries, saved: input.savedChats, presence: summary,
            unreachable: input.unreachable, notices: input.notices, isUnread: input.unread
        ).isEmpty
    }

    private static func digest(_ input: Input, pins: Set<String>) -> ChatListDigest {
        let live = input.entries.filter { isLive($0, in: input) }
        let ranks = Dictionary(
            input.pins.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let pinned = input.entries
            .compactMap { entry in
                ranks[SessionPinStore.key(entry.profileID, entry.session.id)].map { (rank: $0, entry: entry) }
            }
            .sorted { $0.rank < $1.rank }
            .map { pin in
                let entry = pin.entry
                let row = SessionRowModel(
                    entry: entry, unreachable: input.unreachable.contains(entry.profileID),
                    unread: input.unread(entry.session.id, entry.session.updatedAt), saved: false,
                    pinned: true, presence: presence(of: entry, in: input),
                    observedAt: input.observedAt[entry.profileID])
                return ChatListDigest.Pinned(
                    key: ChatSelection.key(entry), title: entry.session.title, backend: entry.backendType,
                    activity: row.state.activity,
                    unread: input.unread(entry.session.id, entry.session.updatedAt))
            }
        return ChatListDigest(
            servers: input.servers.map { profile in
                ChatListDigest.Server(
                    id: profile.id, name: profile.name, backend: profile.backend,
                    live: live.count { $0.profileID == profile.id },
                    unreachable: input.unreachable.contains(profile.id))
            },
            live: live.count,
            archived: input.entries.count {
                input.archived.contains(ArchivedChatStore.key($0.profileID, $0.session.id))
            },
            pinned: pinned)
    }
}
