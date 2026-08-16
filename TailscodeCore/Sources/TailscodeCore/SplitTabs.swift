import CodingAgentKit
import Foundation

/// Several conversations held in one window at once, remembered as one thing.
///
/// A split is an arrangement somebody built on purpose — these chats, beside each other, this way
/// — and the chat list is the only place a conversation is found again. A split that lives nowhere
/// but in the window is therefore lost the moment the window moves on, and rebuilding it costs the
/// whole gesture again: mark the rows, choose the shape, wait for every pane to bind. A tab is the
/// arrangement itself kept device-locally: the members in the order the panes read, the tree that
/// put them there, and any page or stream that was open beside them.
///
/// Identity is the *set of conversations*, never the tree: splitting the same two chats again is
/// the same tab holding a new shape, not a second row saying the same names. That is what keeps
/// the list from filling with near-duplicates of one habit.
public struct SplitTab: Codable, Sendable, Equatable {
    public let id: String
    public let snapshot: SplitSnapshot
    public let updatedAt: Date

    public init(id: String = UUID().uuidString, snapshot: SplitSnapshot, updatedAt: Date = Date()) {
        self.id = id
        self.snapshot = snapshot
        self.updatedAt = updatedAt
    }

    /// The conversations the arrangement holds, in the order the panes read.
    public var members: [SplitPaneSession] {
        snapshot.layout.paneIDs.compactMap { snapshot.session(for: $0) }
    }

    public var memberKeys: [String] {
        members.map { SessionPinStore.key($0.profileID, $0.sessionID) }
    }

    /// The set of conversations, spelled so two arrangements of the same chats are one tab.
    public var identity: String {
        Set(memberKeys).sorted().joined(separator: "|")
    }

    /// Panes holding a page or a stream rather than a conversation. They are part of what clicking
    /// the tab restores, so the row says they are there rather than surprising the window with them.
    public var slotCount: Int {
        snapshot.videos.count + snapshot.pages.count
    }

    public var shape: SplitArrangement {
        SplitEven.shape(of: snapshot.layout)
    }

    /// Whether the arrangement is worth remembering at all: two different conversations, at least.
    /// One chat is the plain open, and the same chat twice is one row's worth of information.
    public var isWorthKeeping: Bool {
        Set(memberKeys).count >= 2
    }
}

/// The arrangements this device has held, newest first.
///
/// Device-local like every other list ordering here — a server has no notion of a window — and
/// deliberately small: a tab is a shortcut back to a habit, and a list of forty of them is a
/// second chat list nobody asked for. Recording is idempotent on the member set, so a morning
/// spent splitting the same two chats leaves one row, wearing the shape it ended in.
public enum SplitTabStore {
    nonisolated(unsafe) private static let defaults = UserDefaults.standard
    public static let storageKey = "tailscode.splittabs"
    public static let didChange = Notification.Name("tailscode.splittabs.didChange")

    /// Past this many, the oldest is dropped. The list is a shortcut, not an archive.
    public static let limit = 12

    public static func all() -> [SplitTab] {
        guard let raw = defaults.string(forKey: storageKey), let data = raw.data(using: .utf8),
            let tabs = try? JSONDecoder().decode([SplitTab].self, from: data)
        else { return [] }
        return tabs
    }

    /// Remembers what a window is holding, replacing whatever was remembered about the same set of
    /// conversations. An arrangement not worth keeping is not an error and does not disturb what is
    /// already stored — a window falling back to one chat has not forgotten the split it came from.
    @discardableResult
    public static func record(_ snapshot: SplitSnapshot) -> SplitTab? {
        let fresh = SplitTab(snapshot: snapshot)
        guard fresh.isWorthKeeping else { return nil }
        var current = all()
        let existing = current.first { $0.identity == fresh.identity }
        let tab = SplitTab(id: existing?.id ?? fresh.id, snapshot: snapshot)
        if let existing, existing.snapshot == snapshot, current.first?.id == existing.id {
            return existing
        }
        current.removeAll { $0.identity == fresh.identity }
        current.insert(tab, at: 0)
        write(Array(current.prefix(limit)))
        return tab
    }

    public static func forget(identity: String) {
        let current = all()
        let remaining = current.filter { $0.identity != identity }
        guard remaining.count != current.count else { return }
        write(remaining)
    }

    public static func removeAll() {
        guard !all().isEmpty else { return }
        write([])
    }

    public static func tab(identity: String) -> SplitTab? {
        all().first { $0.identity == identity }
    }

    private static func write(_ tabs: [SplitTab]) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(tabs), let raw = String(data: data, encoding: .utf8)
        else { return }
        defaults.set(raw, forKey: storageKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

/// A remembered arrangement as the chat list draws it: one row standing for every conversation in
/// it, saying what it is made of and what state the whole of it is in.
public struct SplitTabRow: Equatable, Sendable {
    public let tab: SplitTab
    /// The member rows in the order the panes read, so the row's names are in the order the
    /// window would put them.
    public let members: [SessionRowModel]

    public init(tab: SplitTab, members: [SessionRowModel]) {
        self.tab = tab
        self.members = members
    }

    /// The names, in pane order. A tab is recognised by what is in it and nothing else — a split
    /// has no name of its own, and inventing one would be a label nobody wrote.
    public var title: String {
        members.map(\.title).joined(separator: " · ")
    }

    /// The loudest thing any member is doing. A split with a question waiting in one pane is a
    /// split that needs you, whatever the other panes are up to.
    public var state: SessionRowState {
        members.max { Self.loudness($0.state) < Self.loudness($1.state) }?.state ?? .idle
    }

    public var unread: Bool {
        members.contains(where: \.unread)
    }

    public var pinned: Bool {
        members.contains(where: \.pinned)
    }

    /// The freshest member's age: the whole row moved when any pane in it did.
    public var age: String {
        members.map(\.entry.session.updatedAt).max().map(SessionRowModel.age) ?? "—"
    }

    /// The left-hand fact: the shape drawn small, how many chats are in it, and any slot that
    /// would come back with them.
    public var lead: String {
        var parts = ["\(tab.shape.glyph) \(Localized.text("%@ chats", "\(members.count)"))"]
        if tab.slotCount > 0 {
            parts.append(Localized.text("+%@ open beside them", "\(tab.slotCount)"))
        }
        return parts.joined(separator: " · ")
    }

    /// Which machines the split reaches across, named only when it reaches more than one — the
    /// point of a split is often exactly that, and it is worth nothing when every pane is local.
    public var origin: String? {
        var seen: [String] = []
        for member in members where !seen.contains(member.serverName) {
            seen.append(member.serverName)
        }
        return seen.count > 1 ? seen.joined(separator: " · ") : nil
    }

    public func facets() -> SessionRowFacets {
        SessionRowFacets(project: lead, origin: origin, age: age)
    }

    /// What a screen reader is told the row is, before it is told what is in it.
    public var accessibleLabel: String {
        Localized.text(
            "Split of %@ chats, %@: %@", "\(members.count)", tab.shape.title.lowercased(), title)
    }

    private static func loudness(_ state: SessionRowState) -> Int {
        switch state {
        case .awaitingApproval: return 4
        case .live: return 3
        case .failed: return 2
        case .offline: return 1
        case .idle: return 0
        }
    }
}

/// What the chat list is actually a list of once arrangements are in it: a conversation, or a
/// remembered split standing for several.
public enum ChatListItem: Equatable, Sendable {
    case chat(SessionRowModel)
    case tab(SplitTabRow)

    /// Every conversation the item stands for — what a mark on it holds, and what a bulk verb
    /// spends itself on.
    public var entries: [SessionEntry] {
        switch self {
        case .chat(let row): return [row.entry]
        case .tab(let row): return row.members.map(\.entry)
        }
    }

    /// The row the item is placed and opened by. A tab leads with the pane that would take focus.
    public var lead: SessionRowModel? {
        switch self {
        case .chat(let row): return row
        case .tab(let row): return row.members.first
        }
    }

    /// The item's identity in a list that re-sorts under the reader: a chat is its own key, a tab
    /// is the set it holds.
    public var key: String {
        switch self {
        case .chat(let row):
            return SessionPinStore.key(row.entry.profileID, row.entry.session.id)
        case .tab(let row):
            return "split:\(row.tab.identity)"
        }
    }

    public var isTab: Bool {
        if case .tab = self { return true }
        return false
    }

    public var state: SessionRowState {
        switch self {
        case .chat(let row): return row.state
        case .tab(let row): return row.state
        }
    }

    public var title: String {
        switch self {
        case .chat(let row): return row.title
        case .tab(let row): return row.title
        }
    }
}

/// Folding remembered arrangements into a grouped listing.
///
/// A tab replaces its members wherever the first of them would have been drawn, which puts it in
/// the highest section any of its chats earns: a split with one pane working leads LIVE NOW, the
/// same way that chat would have on its own. Nothing else about the ordering changes.
///
/// A tab is only ever drawn whole. If the listing is missing one of its members — filtered out,
/// archived, deleted on the server, on a machine that has stopped answering — the arrangement
/// cannot honestly be offered, because clicking it would deliver something other than what the row
/// named; its surviving chats are drawn as the plain rows they always were.
public enum SplitTabGrouping {
    public static func apply<Label>(
        to sections: [(Label, [SessionRowModel])], tabs: [SplitTab]
    ) -> [(Label, [ChatListItem])] {
        guard !tabs.isEmpty else {
            return sections.map { ($0.0, $0.1.map(ChatListItem.chat)) }
        }
        var rowsByKey: [String: SessionRowModel] = [:]
        for (_, members) in sections {
            for row in members {
                rowsByKey[SessionPinStore.key(row.entry.profileID, row.entry.session.id)] = row
            }
        }
        var owner: [String: String] = [:]
        var drawable: [String: SplitTabRow] = [:]
        for tab in tabs where tab.isWorthKeeping {
            let keys = tab.memberKeys
            guard keys.allSatisfy({ rowsByKey[$0] != nil && owner[$0] == nil }) else { continue }
            var seen: Set<String> = []
            let members = keys.compactMap { key -> SessionRowModel? in
                guard seen.insert(key).inserted else { return nil }
                return rowsByKey[key]
            }
            guard members.count >= 2 else { continue }
            drawable[tab.identity] = SplitTabRow(tab: tab, members: members)
            for key in keys { owner[key] = tab.identity }
        }
        guard !drawable.isEmpty else {
            return sections.map { ($0.0, $0.1.map(ChatListItem.chat)) }
        }
        var emitted: Set<String> = []
        return sections.map { label, members in
            var items: [ChatListItem] = []
            for row in members {
                let key = SessionPinStore.key(row.entry.profileID, row.entry.session.id)
                guard let identity = owner[key], let tabRow = drawable[identity] else {
                    items.append(.chat(row))
                    continue
                }
                guard emitted.insert(identity).inserted else { continue }
                items.append(.tab(tabRow))
            }
            return (label, items)
        }
    }
}
