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
    let layout = SplitEven.layout(count: sessions.count, as: arrangement)!
    var bound: [String: SplitPaneSession] = [:]
    for (pane, session) in zip(layout.paneIDs, sessions) {
        bound[pane.raw] = SplitPaneSession(profileID: session.0, sessionID: session.1)
    }
    return SplitSnapshot(layout: layout, sessions: bound)
}

/// What a remembered arrangement is allowed to claim about itself, and where the list puts it.
@Suite("Split tabs")
struct SplitTabTests {
    @Test("A tab is the set of chats it holds, whatever shape they were in")
    func identityIsTheMemberSet() {
        let sideBySide = SplitTab(snapshot: snapshot([("one", "a"), ("one", "b")]))
        let stacked = SplitTab(
            snapshot: snapshot([("one", "b"), ("one", "a")], as: .stacked))
        #expect(sideBySide.identity == stacked.identity)
        #expect(sideBySide.shape == .sideBySide)
        #expect(stacked.shape == .stacked)
        #expect(SplitEven.shape(of: SplitEven.layout(count: 4, as: .grid)!) == .grid)
        #expect(SplitEven.shape(of: SplitLayout()) == .sideBySide)
    }

    @Test("One chat, or the same chat twice, is not an arrangement")
    func worthKeeping() {
        #expect(!SplitTab(snapshot: SplitSnapshot(layout: SplitLayout(), sessions: [:]))
            .isWorthKeeping)
        #expect(!SplitTab(snapshot: snapshot([("one", "a"), ("one", "a")])).isWorthKeeping)
        #expect(SplitTab(snapshot: snapshot([("one", "a"), ("two", "a")])).isWorthKeeping)
    }

    @Test("The members are in the order the panes read")
    func memberOrder() {
        let tab = SplitTab(snapshot: snapshot([("one", "a"), ("one", "b"), ("one", "c")]))
        #expect(tab.memberKeys == ["one/a", "one/b", "one/c"])
    }

    @Test("A tab takes the place of its first member, in the highest section it earns")
    func placement() {
        let live = row(entry(sessionID: "b", active: true))
        let idle = row(entry(sessionID: "a"))
        let other = row(entry(sessionID: "c"))
        let tab = SplitTab(snapshot: snapshot([("one", "a"), ("one", "b")]))
        let grouped = SplitTabGrouping.apply(
            to: [("LIVE NOW", [live]), ("RECENT", [idle, other])], tabs: [tab])
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
        #expect(drawn.lead == "▥ 2 chats")
    }

    @Test("A tab missing a member is not drawn, and its chats stay plain rows")
    func incompleteTabsAreNotDrawn() {
        let present = row(entry(sessionID: "a"))
        let tab = SplitTab(snapshot: snapshot([("one", "a"), ("one", "gone")]))
        let grouped = SplitTabGrouping.apply(to: [("RECENT", [present])], tabs: [tab])
        #expect(grouped[0].1.map(\.key) == ["one/a"])
        #expect(!grouped[0].1[0].isTab)
    }

    @Test("A chat belongs to one tab, so the newest arrangement wins the row")
    func oneTabPerChat() {
        let rows = ["a", "b", "c"].map { row(entry(sessionID: $0)) }
        let newest = SplitTab(snapshot: snapshot([("one", "a"), ("one", "b")]))
        let older = SplitTab(snapshot: snapshot([("one", "b"), ("one", "c")]))
        let grouped = SplitTabGrouping.apply(to: [("RECENT", rows)], tabs: [newest, older])
        #expect(grouped[0].1.map(\.key) == ["split:one/a|one/b", "one/c"])
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
        let tab = SplitTab(
            snapshot: snapshot([("one", "a"), ("one", "b"), ("one", "c")]))
        #expect(SplitTabRow(tab: tab, members: members).state == .awaitingApproval)
        #expect(SplitTabRow(tab: tab, members: Array(members.prefix(2))).state == .live)
        #expect(SplitTabRow(tab: tab, members: [members[0]]).state == .idle)
    }

    @Test("A page open beside the chats is part of what comes back")
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

/// The store shares one `UserDefaults` with every other device-local store here.
extension DeviceStores {
    @Suite("Split tab store")
    struct SplitTabStoreTests {
        private func fresh() {
            SplitTabStore.removeAll()
        }

        @Test("Splitting the same chats again keeps one row, wearing the newest shape")
        func recordingIsIdempotentOnTheMemberSet() {
            fresh()
            SplitTabStore.record(snapshot([("one", "a"), ("one", "b")]))
            let first = SplitTabStore.all()
            #expect(first.count == 1)
            SplitTabStore.record(snapshot([("one", "b"), ("one", "a")], as: .stacked))
            let second = SplitTabStore.all()
            #expect(second.count == 1)
            #expect(second[0].id == first[0].id)
            #expect(second[0].shape == .stacked)
            fresh()
        }

        @Test("A window holding one chat forgets nothing")
        func aLoneChatIsNotRecorded() {
            fresh()
            SplitTabStore.record(snapshot([("one", "a"), ("one", "b")]))
            #expect(SplitTabStore.record(SplitSnapshot(layout: SplitLayout(), sessions: [:])) == nil)
            #expect(SplitTabStore.all().count == 1)
            fresh()
        }

        @Test("The newest arrangement leads, and the list stays short")
        func orderAndLimit() {
            fresh()
            for index in 0..<(SplitTabStore.limit + 3) {
                SplitTabStore.record(snapshot([("one", "a\(index)"), ("one", "b\(index)")]))
            }
            let all = SplitTabStore.all()
            #expect(all.count == SplitTabStore.limit)
            #expect(all[0].memberKeys.contains("one/a\(SplitTabStore.limit + 2)"))
            fresh()
        }

        @Test("An arrangement can be let go of by hand")
        func forget() {
            fresh()
            SplitTabStore.record(snapshot([("one", "a"), ("one", "b")]))
            SplitTabStore.record(snapshot([("one", "c"), ("one", "d")]))
            SplitTabStore.forget(identity: "one/a|one/b")
            #expect(SplitTabStore.all().map(\.identity) == ["one/c|one/d"])
            fresh()
            #expect(SplitTabStore.all().isEmpty)
        }
    }
}
