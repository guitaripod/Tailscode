import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Chat list sections and row ink")
struct ChatListSectionsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Saturday 14 November 2026, 22:48 UTC.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 22, minute: 48))!
    }

    private func entry(
        _ id: String, ago: TimeInterval = 600, active: Bool = false, said: String? = nil,
        scheduled: Bool? = nil
    ) -> SessionEntry {
        SessionEntry(
            profileID: "one", profileName: "one", host: "one", backendType: .claudeCode,
            session: AgentSession(
                id: id, agentType: .claudeCode, title: "chat \(id)", directory: "/tmp/\(id)",
                createdAt: now.addingTimeInterval(-ago - 60), updatedAt: now.addingTimeInterval(-ago),
                isActive: active, isScheduled: scheduled, lastWords: said))
    }

    private func row(
        _ entry: SessionEntry, presence: SessionPresence = .unobserved, unread: Bool = false,
        saved: Bool = false, pinned: Bool = false, unreachable: Bool = false
    ) -> SessionRowModel {
        SessionRowModel(
            entry: entry, unreachable: unreachable, unread: unread, saved: saved, pinned: pinned,
            presence: presence, observedAt: now, now: now)
    }

    private let hour: TimeInterval = 3600
    private let day: TimeInterval = 86_400

    @Test("A chat is filed under the landmark it last moved in")
    func bucketsByCalendarDay() {
        func bucket(_ ago: TimeInterval) -> RecentBucket {
            RecentBucket.of(now.addingTimeInterval(-ago), now: now, calendar: calendar)
        }
        #expect(bucket(60) == .today)
        #expect(bucket(22 * hour) == .today)
        #expect(bucket(23 * hour) == .yesterday)
        #expect(bucket(46 * hour) == .yesterday)
        #expect(bucket(47 * hour) == .week)
        #expect(bucket(7 * day) == .week)
        #expect(bucket(8 * day) == .month)
        #expect(bucket(30 * day) == .month)
        #expect(bucket(31 * day) == .named(year: 2026, month: 10))
        #expect(bucket(200 * day) == .named(year: 2026, month: 4))
        #expect(bucket(400 * day) == .year(2025))
        #expect(bucket(-5 * hour) == .today, "a chat stamped into this device's future reads as today")
    }

    @Test("Landmarks read newest first, months by name and earlier years by number")
    func landmarksInOrder() {
        let buckets: [RecentBucket] = [
            .year(2024), .named(year: 2026, month: 3), .month, .today, .year(2025),
            .named(year: 2026, month: 10), .week, .yesterday,
        ]
        #expect(
            buckets.sorted { $0.rank < $1.rank } == [
                .today, .yesterday, .week, .month, .named(year: 2026, month: 10),
                .named(year: 2026, month: 3), .year(2025), .year(2024),
            ])
        let english = Locale(identifier: "en_US")
        #expect(
            RecentBucket.named(year: 2026, month: 10).title(calendar: calendar, locale: english)
                == "OCTOBER")
        #expect(RecentBucket.year(2025).title(calendar: calendar, locale: english) == "2025")
    }

    @Test("The full list is the board with RECENT filed by when, each landmark newest first")
    func listSections() {
        let rows = [
            row(entry("live", ago: 5, active: true)),
            row(entry("pin", ago: 3 * day), pinned: true),
            row(entry("a", ago: 600)),
            row(entry("b", ago: 2 * hour)),
            row(entry("c", ago: 30 * hour)),
            row(entry("d", ago: 5 * day)),
            row(entry("e", ago: 90 * day)),
        ]
        let grouped = groupIntoListSections(rows, now: now, calendar: calendar)
        #expect(
            grouped.map(\.0) == [
                .working, .pinned, .recent(.today), .recent(.yesterday), .recent(.week),
                .recent(.named(year: 2026, month: 8)),
            ])
        #expect(grouped[2].1.map(\.entry.session.id) == ["a", "b"])
        #expect(Set(grouped.map(\.0.key)).count == grouped.count)
    }

    @Test("A heading counts what is acted on: totals for the fleet, new rows everywhere else")
    func headings() {
        let waiting = SectionHeading(section: .needsYou, rows: 2, fresh: 2)
        #expect(waiting.total == 2)
        #expect(waiting.freshLabel == nil)
        #expect(waiting.needsYou)
        let today = SectionHeading(
            section: .recent(.today),
            items: [
                .chat(row(entry("a"), unread: true)), .chat(row(entry("b"))),
                .chat(row(entry("c"), unread: true)),
            ])
        #expect(today.total == nil)
        #expect(today.fresh == 2)
        #expect(today.freshLabel == "2 new")
        #expect(SectionHeading(section: .saved, rows: 4, fresh: 0).freshLabel == nil)
        let one = row(entry("s1", active: true))
        let two = row(entry("s2", active: true), unread: true)
        let layout = SplitEven.layout(count: 2, as: .sideBySide)!
        var bound: [String: SplitPaneSession] = [:]
        for (pane, member) in zip(layout.paneIDs, [one, two]) {
            bound[pane.raw] = SplitPaneSession(
                profileID: member.entry.profileID, sessionID: member.entry.session.id)
        }
        let split = SplitTab(snapshot: SplitSnapshot(layout: layout, sessions: bound))
        let merged = SectionHeading(
            section: .working, items: [.tab(SplitTabRow(tab: split, members: [one, two]))])
        #expect(merged.total == 2, "a split is counted by the chats it stands for")
    }

    @Test("Waiting and unread are pressed hardest, busy is plain, settled and read steps back")
    func emphasis() {
        #expect(row(entry("a"), presence: .awaitingApproval).emphasis == .strong)
        #expect(row(entry("b"), unread: true).emphasis == .strong)
        #expect(row(entry("c", active: true)).emphasis == .plain)
        #expect(
            row(entry("c2", active: true), unread: true).emphasis == .plain,
            "a turn in flight is unread for as long as it runs, and is not weighted for it")
        #expect(row(entry("c3"), presence: .failed, unread: true).emphasis == .strong)
        #expect(row(entry("d"), presence: .failed).emphasis == .plain)
        #expect(row(entry("e"), unreachable: true).emphasis == .plain)
        #expect(row(entry("f")).emphasis == .receded)
        #expect(ChatRowInk.titleOpacity(.receded) < 1)
        #expect(ChatRowInk.titleOpacity(.plain) == 1)
        #expect(ChatRowInk.chipOpacity(.receded) < ChatRowInk.titleOpacity(.receded))
    }

    @Test("A mark in the state column always means something")
    func columnMark() {
        #expect(row(entry("a")).columnMark == .none)
        #expect(row(entry("b"), unread: true).columnMark == .unread)
        #expect(row(entry("c", active: true), unread: true).columnMark == .activity(.working))
        #expect(row(entry("d"), presence: .failed, unread: true).columnMark == .activity(.failed))
    }

    @Test("A row does not repeat the mark its own heading already says")
    func titleMarks() {
        let both = row(entry("a", scheduled: true), saved: true, pinned: true)
        #expect(both.titleMarks(under: .working) == [.pinned, .saved, .scheduled])
        #expect(both.titleMarks(under: .pinned) == [.saved, .scheduled])
        #expect(both.titleMarks(under: .saved) == [.pinned, .scheduled])
        #expect(row(entry("b")).titleMarks(under: .recent).isEmpty)
    }

    @Test("An unread finish quotes the answer, and a read one says nothing")
    func quotedNews() {
        let said = "Uploaded 1.84 (222); App Store Connect reports it VALID."
        let unread = row(entry("a", said: said), unread: true)
        #expect(ChatRowNews.reading(for: unread) == ChatRowNews(lead: said, voice: .said))
        #expect(ChatRowNews.reading(for: row(entry("b", said: said))) == nil)
        let mute = ChatRowNews.reading(for: row(entry("c"), unread: true))
        #expect(mute == ChatRowNews(lead: "Finished", voice: .settled))
        let failed = ChatRowNews.reading(for: unread, missed: .turnFailed)
        #expect(failed?.voice == .failed, "why it was missed outranks what it said")
        let working = ChatRowNews.reading(for: row(entry("d", active: true, said: said), unread: true))
        #expect(working?.voice == .working, "a turn in flight is the louder fact")
        #expect(ChatRowInk.newsLines(.said, roomy: false) == 2)
        #expect(ChatRowInk.newsLines(.working, roomy: false) == 1)
        #expect(ChatRowInk.newsLines(.working, roomy: true) == 2)
    }
}
