import CodingAgentKit
import Foundation

/// Several conversations held in one window at once, read as the one thing they are.
///
/// A tab is the window's *current* arrangement, never a memory of one: while chats are split
/// together the list draws them as one row, and the moment the window unsplits the rows separate
/// again, because a merged row standing for an arrangement that no longer exists is the list
/// describing a window nobody is looking at. The window's own persistence (the layout snapshot)
/// is what survives a relaunch, and this reads from exactly that value, so the row and the panes
/// can never disagree.
public struct SplitTab: Sendable, Equatable {
    public let snapshot: SplitSnapshot

    public init(snapshot: SplitSnapshot) {
        self.snapshot = snapshot
    }

    /// The conversations the arrangement holds, in the order the panes read.
    public var members: [SplitPaneSession] {
        snapshot.layout.paneIDs.compactMap { snapshot.session(for: $0) }
    }

    public var memberKeys: [String] {
        members.map { SessionPinStore.key($0.profileID, $0.sessionID) }
    }

    /// The set of conversations, spelled so two shapes of the same chats read as the same tab.
    public var identity: String {
        Set(memberKeys).sorted().joined(separator: "|")
    }

    /// Panes holding a page or a stream rather than a conversation. They are part of what the row
    /// stands for, so the row says they are there.
    public var slotCount: Int {
        snapshot.videos.count + snapshot.pages.count
    }

    public var shape: SplitArrangement {
        SplitEven.shape(of: snapshot.layout)
    }

    /// Whether the arrangement is worth a row of its own: two different conversations, at least.
    /// One chat is the plain window, and the same chat twice is one row's worth of information.
    public var isWorthShowing: Bool {
        Set(memberKeys).count >= 2
    }
}

/// The window's arrangement as the chat list draws it: one row standing for every conversation in
/// it, saying what it is made of and what state the whole of it is in.
public struct SplitTabRow: Equatable, Sendable {
    public let tab: SplitTab
    /// The member rows in the order the panes read, so the row's names are in the order the
    /// window has them.
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

    /// The left-hand fact: what the row is, the shape drawn small, how many chats are in it, and
    /// any slot open beside them.
    public var lead: String {
        var parts = [
            "\(tab.shape.glyph) \(Localized.text("Split · %@ chats", "\(members.count)"))"
        ]
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

/// What the chat list is actually a list of once the window's arrangement is in it: a
/// conversation, or the open split standing for several.
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

    /// The row the item is placed and opened by. A tab leads with its first pane.
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

/// Folding the window's arrangement into a grouped listing.
///
/// The tab replaces its members wherever the first of them would have been drawn, which puts it in
/// the highest section any of its chats earns: a split with one pane working leads LIVE NOW, the
/// same way that chat would have on its own. Nothing else about the ordering changes, and a
/// window holding one chat contributes nothing — the grouping is the identity function the moment
/// the split dissolves.
///
/// The tab is only drawn whole. If the listing is missing one of its members — filtered out,
/// archived, deleted on the server — the row cannot honestly say what the window holds, so its
/// surviving chats are drawn as the plain rows they always were.
public enum SplitTabGrouping {
    public static func apply<Label>(
        to sections: [(Label, [SessionRowModel])], tab: SplitTab?
    ) -> [(Label, [ChatListItem])] {
        guard let tab, tab.isWorthShowing else {
            return sections.map { ($0.0, $0.1.map(ChatListItem.chat)) }
        }
        var rowsByKey: [String: SessionRowModel] = [:]
        for (_, members) in sections {
            for row in members {
                rowsByKey[SessionPinStore.key(row.entry.profileID, row.entry.session.id)] = row
            }
        }
        let keys = tab.memberKeys
        guard keys.allSatisfy({ rowsByKey[$0] != nil }) else {
            return sections.map { ($0.0, $0.1.map(ChatListItem.chat)) }
        }
        var seen: Set<String> = []
        let members = keys.compactMap { key -> SessionRowModel? in
            guard seen.insert(key).inserted else { return nil }
            return rowsByKey[key]
        }
        guard members.count >= 2 else {
            return sections.map { ($0.0, $0.1.map(ChatListItem.chat)) }
        }
        let tabRow = SplitTabRow(tab: tab, members: members)
        let held = Set(keys)
        var emitted = false
        return sections.map { label, rows in
            var items: [ChatListItem] = []
            for row in rows {
                let key = SessionPinStore.key(row.entry.profileID, row.entry.session.id)
                guard held.contains(key) else {
                    items.append(.chat(row))
                    continue
                }
                if !emitted {
                    emitted = true
                    items.append(.tab(tabRow))
                }
            }
            return (label, items)
        }
    }
}
