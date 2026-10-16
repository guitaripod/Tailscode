import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Home board")
struct HomeBoardTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func entry(
        _ id: String, profile: String = "one", active: Bool = false, created: TimeInterval = 0,
        updatedAgo: TimeInterval = 600, carrying: BackgroundWork? = nil, task: String? = nil
    ) -> SessionEntry {
        let updated = now.addingTimeInterval(-updatedAgo)
        return SessionEntry(
            profileID: profile, profileName: profile, host: profile, backendType: .claudeCode,
            session: AgentSession(
                id: id, agentType: .claudeCode, title: "chat \(id)", directory: "/tmp/\(id)",
                createdAt: Date(timeIntervalSince1970: created), updatedAt: updated,
                isActive: active, agentTask: task, backgroundWork: carrying))
    }

    private func row(
        _ entry: SessionEntry, presence: SessionPresence = .unobserved, unread: Bool = false,
        saved: Bool = false, pinned: Bool = false, unreachable: Bool = false
    ) -> SessionRowModel {
        SessionRowModel(
            entry: entry, unreachable: unreachable, unread: unread, saved: saved, pinned: pinned,
            presence: presence, observedAt: now)
    }

    @Test("What waits for the person leads, ahead of what is merely busy")
    func needsYouLeads() {
        let busy = row(entry("busy", active: true, created: 500))
        let asked = row(entry("asked", active: true, created: 100), presence: .awaitingApproval)
        let grouped = groupIntoSections([busy, asked, row(entry("old"))])
        #expect(grouped.map(\.0) == [.needsYou, .working, .recent])
        #expect(grouped[0].1.map(\.entry.session.id) == ["asked"])
        #expect(grouped[1].1.map(\.entry.session.id) == ["busy"])
    }

    @Test("Stuck work needs the person, because it will not speak again on its own")
    func stuckWorkNeedsYou() {
        let stuck = row(
            entry("stuck", carrying: BackgroundWork(tasks: 1, task: "sleep 9999", stalled: true)))
        #expect(stuck.state.needsYou)
        #expect(groupIntoSections([stuck]).map(\.0) == [.needsYou])
        #expect(!row(entry("quiet")).state.needsYou)
        #expect(!row(entry("run", active: true)).state.needsYou)
    }

    @Test("The longest-waiting question comes first")
    func oldestQuestionFirst() {
        let newer = row(entry("new", updatedAgo: 60), presence: .awaitingApproval)
        let older = row(entry("old", updatedAgo: 3600), presence: .awaitingApproval)
        let grouped = groupIntoSections([newer, older])
        #expect(grouped[0].1.map(\.entry.session.id) == ["old", "new"])
    }

    @Test("A pin is a fact about a row, not a place for it, while the row is busy")
    func pinnedAndBusyIsListedOnce() {
        let pinnedBusy = row(entry("a", active: true), pinned: true)
        let pinnedAsking = row(entry("b"), presence: .awaitingApproval, pinned: true)
        let pinnedQuiet = row(entry("c"), pinned: true)
        let grouped = groupIntoSections([pinnedBusy, pinnedAsking, pinnedQuiet])
        #expect(grouped.map(\.0) == [.needsYou, .working, .pinned])
        #expect(grouped[0].1.map(\.entry.session.id) == ["b"])
        #expect(grouped[1].1.map(\.entry.session.id) == ["a"])
        #expect(grouped[1].1[0].pinned, "the row still wears its pin where it is working")
        #expect(grouped[2].1.map(\.entry.session.id) == ["c"])
    }

    @Test("Section titles are the words the board draws")
    func titles() {
        #expect(SessionSection.needsYou.title == "NEEDS YOU")
        #expect(SessionSection.working.title == "WORKING")
        #expect(SessionSection.allCases.map(\.rawValue) == ["needsYou", "working", "pinned", "saved", "recent"])
    }

    @Test("The sentence says who is waiting, then who is working, then that nothing is")
    func sentence() {
        let asked = row(entry("a"), presence: .awaitingApproval)
        let busy = row(entry("b", active: true))
        let done = row(entry("c", updatedAgo: 120))

        let waiting = HomeStatus.reading(rows: [asked, busy, done], now: now, calendar: calendar)
        #expect(waiting.sentence == "1 needs you")
        #expect(waiting.tone == .attention)
        #expect(waiting.detail == "1 working · 1 finished today")

        let two = HomeStatus.reading(
            rows: [asked, row(entry("d"), presence: .awaitingApproval)], now: now, calendar: calendar)
        #expect(two.sentence == "2 need you")

        let working = HomeStatus.reading(rows: [busy, done], now: now, calendar: calendar)
        #expect(working.sentence == "1 working")
        #expect(working.tone == .live)
        #expect(working.detail == "Nothing needs you · 1 finished today")

        let quiet = HomeStatus.reading(rows: [done], now: now, calendar: calendar)
        #expect(quiet.sentence == "All quiet")
        #expect(quiet.tone == .quiet)
        #expect(quiet.detail == "Nothing running · last finished 2m ago")

        let empty = HomeStatus.reading(rows: [], now: now, calendar: calendar)
        #expect(empty.sentence == "No chats yet")
        #expect(empty.tone == .quiet)
    }

    @Test("A machine that is down is part of the reading, and a failure counts")
    func downAndFailed() {
        let busy = row(entry("b", active: true))
        let failed = row(entry("f", updatedAgo: 300), presence: .failed)
        let status = HomeStatus.reading(
            rows: [busy, failed], offline: ["studio"], now: now, calendar: calendar)
        #expect(status.sentence == "1 working")
        #expect(status.detail == "Nothing needs you · 1 failed today · studio is offline")

        let several = HomeStatus.reading(
            rows: [busy], offline: ["studio", "homelab"], now: now, calendar: calendar)
        #expect(several.detail.hasSuffix("2 servers offline"))
    }

    @Test("Yesterday's chats are not finished today")
    func yesterdayIsNotToday() {
        let old = row(entry("o", updatedAgo: 3 * 86400))
        let busy = row(entry("b", active: true))
        let status = HomeStatus.reading(rows: [busy, old], now: now, calendar: calendar)
        #expect(status.detail == "Nothing needs you")
    }

    @Test("The sentence spoken carries the detail too")
    func spoken() {
        let status = HomeStatus(sentence: "1 needs you", detail: "2 working", tone: .attention)
        #expect(status.spoken == "1 needs you. 2 working")
        #expect(HomeStatus(sentence: "All quiet", detail: "", tone: .quiet).spoken == "All quiet")
    }

    @Test("Bands hold to their limits, and what is waiting is never capped")
    func limits() {
        let waiting = (0..<5).map { row(entry("w\($0)", updatedAgo: Double($0) * 10), presence: .awaitingApproval) }
        let recents = (0..<9).map { row(entry("r\($0)", updatedAgo: 3600 + Double($0))) }
        let board = HomeBoard.make(rows: waiting + recents, limits: .phone, now: now, calendar: calendar)
        let needs = board.bands.first { $0.section == .needsYou }
        let recent = board.bands.first { $0.section == .recent }
        #expect(needs?.rows.count == 5)
        #expect(needs?.hidden == 0)
        #expect(recent?.rows.count == 6)
        #expect(recent?.hidden == 3)

        let column = HomeBoard.make(rows: waiting + recents, limits: .column, now: now, calendar: calendar)
        #expect(column.bands.map(\.section) == [.needsYou], "the column beside a chat list holds no recents")
        #expect(column.status.sentence == "5 need you", "the sentence counts what the bands do not show")
    }

    @Test("A row says only what is news")
    func news() {
        let asked = row(entry("a"), presence: .awaitingApproval)
        #expect(ChatRowNews.reading(for: asked)?.lead == "Waiting for your approval")
        let withAsk = ChatRowNews.reading(
            for: asked, ask: ApprovalAsk(lead: "Wants to run", object: "systemctl restart x"))
        #expect(withAsk == ChatRowNews(lead: "Wants to run", object: "systemctl restart x"))
        #expect(withAsk?.spoken == "Wants to run systemctl restart x")

        let working = row(entry("w", active: true, task: "Editing three files"))
        #expect(ChatRowNews.reading(for: working)?.lead == "Editing three files")
        let silent = row(entry("s", active: true))
        #expect(ChatRowNews.reading(for: silent)?.lead == "Working")

        let failed = row(entry("f"), presence: .failed)
        #expect(ChatRowNews.reading(for: failed)?.lead == "Last turn failed")

        let gone = row(entry("g", updatedAgo: 840), unreachable: true)
        #expect(ChatRowNews.reading(for: gone)?.lead == "Last heard 14m ago")

        let read = row(entry("r"))
        #expect(ChatRowNews.reading(for: read) == nil, "a settled chat that has been read has nothing to say")
        let unread = row(entry("u"), unread: true)
        #expect(ChatRowNews.reading(for: unread)?.lead == "Finished")
        #expect(ChatRowNews.reading(for: unread, missed: .turnFailed)?.lead == "Last turn failed")
        #expect(ChatRowNews.reading(for: unread, missed: .needsAnswer)?.lead == "Asked you a question")
    }

    @Test("A question speaks in its own words, and a permission in the machine's")
    func askReading() {
        let question = QuestionRequest(
            id: "q1", sessionID: "s",
            questions: [
                QuestionRequest.Item(
                    question: "Which surfaces should the experiment run on?", header: "Surfaces",
                    options: [])
            ])
        let asking = ConversationState(pendingQuestions: [question])
        #expect(ApprovalAsk.reading(in: asking)
            == ApprovalAsk(lead: "Which surfaces should the experiment run on?"))
        #expect(ApprovalAsk.reading(in: ConversationState()) == nil)
        let permission = ConversationState(
            pendingPermissions: [PermissionRequest(id: "p1", sessionID: "s")])
        #expect(ApprovalAsk.reading(in: permission) == nil, "no call in hand, nothing to say")
    }
}
