import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

private func entry(
    profileID: String = "one", sessionID: String, title: String = "chat",
    active: Bool? = nil, updated: Date = Date(timeIntervalSince1970: 0)
) -> SessionEntry {
    SessionEntry(
        profileID: profileID, profileName: profileID, host: profileID, backendType: .claudeCode,
        session: AgentSession(
            id: sessionID, agentType: .claudeCode, title: title, directory: "/tmp/\(profileID)",
            createdAt: updated, updatedAt: updated, isActive: active))
}

private func row(_ entry: SessionEntry, presence: SessionPresence = .unobserved) -> SessionRowModel {
    SessionRowModel(
        entry: entry, unreachable: false, unread: false, saved: false, presence: presence)
}

/// A tab is built the way a window builds one: panes minted by the layout, each bound to a chat.
private func snapshot(_ sessions: [(String, String)], as arrangement: SplitArrangement = .sideBySide)
    -> SplitSnapshot
{
    guard sessions.count > 1 else {
        let layout = SplitLayout()
        let bound = sessions.first.map {
            [layout.focusedPane.raw: SplitPaneSession(profileID: $0.0, sessionID: $0.1)]
        }
        return SplitSnapshot(layout: layout, sessions: bound ?? [:])
    }
    let layout = SplitEven.layout(count: sessions.count, as: arrangement)!
    var bound: [String: SplitPaneSession] = [:]
    for (pane, session) in zip(layout.paneIDs, sessions) {
        bound[pane.raw] = SplitPaneSession(profileID: session.0, sessionID: session.1)
    }
    return SplitSnapshot(layout: layout, sessions: bound)
}

/// The merged row is the window's arrangement and nothing else: it appears while chats are split
/// together, says what the whole of it is doing, and dissolves back into plain rows the moment
/// the window unsplits.
@Suite("Split tabs")
struct SplitTabTests {
    @Test("A tab is the set of chats it holds, whatever shape they are in")
    func identityIsTheMemberSet() {
        let sideBySide = SplitTab(snapshot: snapshot([("one", "a"), ("one", "b")]))
        let stacked = SplitTab(snapshot: snapshot([("one", "b"), ("one", "a")], as: .stacked))
        #expect(sideBySide.identity == stacked.identity)
        #expect(sideBySide.shape == .sideBySide)
        #expect(stacked.shape == .stacked)
        #expect(SplitEven.shape(of: SplitEven.layout(count: 4, as: .grid)!) == .grid)
        #expect(SplitEven.shape(of: SplitLayout()) == .sideBySide)
    }

    @Test("One chat, or the same chat twice, is not an arrangement")
    func worthShowing() {
        #expect(!SplitTab(snapshot: SplitSnapshot(layout: SplitLayout(), sessions: [:]))
            .isWorthShowing)
        #expect(!SplitTab(snapshot: snapshot([("one", "a"), ("one", "a")])).isWorthShowing)
        #expect(SplitTab(snapshot: snapshot([("one", "a"), ("two", "a")])).isWorthShowing)
    }

    @Test("The members are in the order the panes read")
    func memberOrder() {
        let tab = SplitTab(snapshot: snapshot([("one", "a"), ("one", "b"), ("one", "c")]))
        #expect(tab.memberKeys == ["one/a", "one/b", "one/c"])
    }

    @Test("The tab takes the place of its first member, in the highest section it earns")
    func placement() {
        let live = row(entry(sessionID: "b", active: true))
        let idle = row(entry(sessionID: "a"))
        let other = row(entry(sessionID: "c"))
        let tab = SplitTab(snapshot: snapshot([("one", "a"), ("one", "b")]))
        let grouped = SplitTabGrouping.apply(
            to: [("LIVE NOW", [live]), ("RECENT", [idle, other])], tab: tab)
        #expect(grouped[0].1.count == 1)
        #expect(grouped[0].1[0].isTab)
        #expect(grouped[0].1[0].key == "split:one/a|one/b")
        #expect(grouped[1].1.map(\.key) == ["one/c"])
        guard case .tab(let drawn) = grouped[0].1[0] else {
            Issue.record("the live section should carry the tab")
            return
        }
        #expect(drawn.members.map(\.entry.session.id) == ["a", "b"])
        #expect(drawn.state == .live)
        #expect(drawn.title == "chat · chat")
        #expect(drawn.lead == "▥ Split · 2 chats")
    }

    @Test("No arrangement means the grouping changes nothing — unsplit separates the rows")
    func unsplitSeparates() {
        let rows = [row(entry(sessionID: "a")), row(entry(sessionID: "b"))]
        let merged = SplitTabGrouping.apply(
            to: [("RECENT", rows)], tab: SplitTab(snapshot: snapshot([("one", "a"), ("one", "b")])))
        #expect(merged[0].1.map(\.key) == ["split:one/a|one/b"])
        let separated = SplitTabGrouping.apply(to: [("RECENT", rows)], tab: nil)
        #expect(separated[0].1.map(\.key) == ["one/a", "one/b"])
        #expect(separated[0].1.allSatisfy { !$0.isTab })
        let lone = SplitTabGrouping.apply(
            to: [("RECENT", rows)], tab: SplitTab(snapshot: snapshot([("one", "a")])))
        #expect(lone[0].1.map(\.key) == ["one/a", "one/b"])
    }

    @Test("A tab missing a member is not drawn, and its chats stay plain rows")
    func incompleteTabsAreNotDrawn() {
        let present = row(entry(sessionID: "a"))
        let tab = SplitTab(snapshot: snapshot([("one", "a"), ("one", "gone")]))
        let grouped = SplitTabGrouping.apply(to: [("RECENT", [present])], tab: tab)
        #expect(grouped[0].1.map(\.key) == ["one/a"])
        #expect(!grouped[0].1[0].isTab)
    }

    @Test("A split of two machines names them; one machine says nothing")
    func origin() {
        let across = SplitTabRow(
            tab: SplitTab(snapshot: snapshot([("one", "a"), ("two", "b")])),
            members: [row(entry(sessionID: "a")), row(entry(profileID: "two", sessionID: "b"))])
        #expect(across.origin == "one · two")
        let local = SplitTabRow(
            tab: SplitTab(snapshot: snapshot([("one", "a"), ("one", "b")])),
            members: [row(entry(sessionID: "a")), row(entry(sessionID: "b"))])
        #expect(local.origin == nil)
    }

    @Test("The loudest pane is what the whole row is doing")
    func loudestState() {
        let members = [
            row(entry(sessionID: "a")), row(entry(sessionID: "b"), presence: .running(nil)),
            row(entry(sessionID: "c"), presence: .awaitingApproval),
        ]
        let tab = SplitTab(snapshot: snapshot([("one", "a"), ("one", "b"), ("one", "c")]))
        #expect(SplitTabRow(tab: tab, members: members).state == .awaitingApproval)
        #expect(SplitTabRow(tab: tab, members: Array(members.prefix(2))).state == .live)
        #expect(SplitTabRow(tab: tab, members: [members[0]]).state == .idle)
    }

    @Test("A page open beside the chats is part of what the row stands for")
    func slotsAreNamed() {
        let base = snapshot([("one", "a"), ("one", "b")])
        let withPage = SplitSnapshot(
            layout: base.layout, sessions: base.sessions, videos: [:],
            pages: ["ghost": "example.com"])
        let tab = SplitTab(snapshot: withPage)
        #expect(tab.slotCount == 1)
        let drawn = SplitTabRow(
            tab: tab, members: [row(entry(sessionID: "a")), row(entry(sessionID: "b"))])
        #expect(drawn.lead.contains("+1"))
    }
}
