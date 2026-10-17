import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension SelfTest {
    private static let rangeNow = Date(timeIntervalSince1970: 1_800_000_000)

    /// What the range promises that does not need a person looking: the sheet's rows from a fixture
    /// conversation and account, the wall chip the band carries while a window will not last, the
    /// tick that makes the pace bar taller than a bare one, the sheet building and closing, and the
    /// parity answer.
    static func checkRange() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("range: \(label)") }
            checks += 1
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let clock = RangeClock(calendar: calendar, locale: Locale(identifier: "en_GB"))
        let messages = RangeDemo.messages(now: rangeNow)
        let fill = RangeDemo.fill()
        let account = RangeDemo.account(now: rangeNow)
        let board = RangeBoard.read(
            messages: messages, fill: fill, quotas: [account], model: "claude-sonnet-5-5",
            now: rangeNow, clock: clock)

        try expect(
            board.rows.map(\.title) == [
                Localized.text("Context"), "5-hour session", "Weekly · all models",
            ], "the sheet holds the context and the two windows that govern the model")
        try expect(
            board.elsewhere.map(\.title) == ["Weekly · Opus"] && board.elsewhere.first?.dimmed == true,
            "the other model's window is set aside, dimmed")
        let session = board.rows.first { $0.title == "5-hour session" }
        try expect(abs((session?.tick ?? 0) - 0.4433) < 0.001, "the session row carries its tick")
        try expect(session?.news?.lead == Localized.text("Wall"), "the session row owes one line of news")
        try expect(board.cache != nil || board.footprint != nil, "the sheet reads a cache or a footprint")

        var facts = StatusFacts()
        facts.context = fill
        facts.range = RangeGlance.read(
            messages: messages, fill: fill, quotas: [account], model: "claude-sonnet-5-5",
            now: rangeNow, calendar: calendar)
        let wall = facts.segments.first { $0.id == "wall" }
        try expect(wall != nil, "the band carries a wall chip while a window will not last")
        try expect(wall?.css == "seg-warn" && wall?.text.hasPrefix(StatusMark.clock) == true, "the wall chip is amber and leads with the clock glyph")
        try expect(
            facts.segments.first { $0.id == "context" }?.action == .range
                && wall?.action == .range, "the chips open the range sheet")

        var anchor: String?
        if case .implemented(let named) = ParityManifest.evidence(for: .range) { anchor = named }
        try expect(anchor == "RangePanel", "the manifest answers the range with RangePanel")

        guard gtk_init_check() != 0 else { return checks }
        if let session {
            let withTick = PaceBar.make(session, height: 6, glance: false)
            var width: Int32 = 0
            var height: Int32 = 0
            gtk_widget_get_size_request(withTick, &width, &height)
            try expect(height == 6 + PaceBar.tickOverhang * 2, "a bar with a tick is taller than the bar by the overhang")
            let row = PaceBar.row(session)
            try expect(gtk_widget_get_visible(row) != 0, "a pace row builds")
        }
        let bare = PaceRow.balance(
            provider: "DeepSeek", slug: "deepseek",
            gauge: UsageQuota.Gauge(
                key: "balance", label: "Balance", fraction: 0, resetsAt: nil, trustedReset: false,
                usedUSD: 104.32),
            now: rangeNow)
        try expect(bare.tick == nil && bare.tailEnd == nil, "a balance has no tick and no tail")

        RangePanel.present(
            parent: nil, title: "Fix the quota parser", compact: nil, goTo: nil,
            read: { RangePanel.Reading(board: board, fill: fill) })
        try expect(RangePanel.isOpen, "the sheet builds from a board")
        RangePanel.transcriptChanged()
        RangePanel.dismiss()
        try expect(!RangePanel.isOpen, "the sheet closes")
        return checks
    }
}
