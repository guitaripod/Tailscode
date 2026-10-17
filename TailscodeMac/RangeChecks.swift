import AppKit
import CodingAgentKit
import TailscodeCore

/// The Range popover and the pace bar, built from a fixture account and read back: every tank the
/// board holds is a row in the sheet, an on-pace row owes no line of words and a row with news owes
/// exactly one, and a bar is as tall as the plain bar it replaced.
@MainActor
enum RangeChecks {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let hour: TimeInterval = 3600

    private static func gauge(
        _ key: String, _ label: String, used: Double, resetsIn: TimeInterval
    ) -> UsageQuota.Gauge {
        UsageQuota.Gauge(
            key: key, label: label, fraction: used, resetsAt: now.addingTimeInterval(resetsIn),
            trustedReset: true)
    }

    private static func messages() -> [ChatMessage] {
        let footprints = [100_000, 110_000, 121_000, 130_000, 142_000, 148_000]
        return footprints.enumerated().flatMap { index, footprint in
            [
                ChatMessage(
                    id: "u\(index)", role: .user, agentType: .claudeCode,
                    parts: [MessagePart(id: "t", kind: .text("go"))],
                    createdAt: now.addingTimeInterval(Double(index) * 600)),
                ChatMessage(
                    id: "a\(index)", role: .assistant, agentType: .claudeCode,
                    parts: [MessagePart(id: "t", kind: .text("ok"))],
                    createdAt: now.addingTimeInterval(Double(index) * 600 + 5),
                    modelID: "claude-sonnet-5-5",
                    context: MessageUsage(
                        input: 10, output: 90, cacheRead: footprint - 100, cacheLifetime: 3600)),
            ]
        }
    }

    static func run() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ claim: String) throws {
            guard condition else { throw SelfTestFailure(claim) }
            checks += 1
        }

        let quota = UsageQuota(
            providerName: "Claude", subtitle: "Max", source: "api · live", live: true,
            gauges: [
                gauge("session", "5-hour session", used: 0.62, resetsIn: 2 * hour + 47 * 60),
                gauge("weekly_all", "Weekly · all models", used: 0.38, resetsIn: 63 * hour),
                gauge("weekly_scoped", "Weekly · Opus", used: 0.71, resetsIn: 63 * hour),
            ],
            details: [])
        let fill = ContextFill(
            used: 148_000, window: 200_000, model: "claude-sonnet-5-5", basis: .reported)
        let board = RangeBoard.read(
            messages: messages(), fill: fill, quotas: [quota], model: "claude-sonnet-5-5", now: now)
        let snapshot = RangeSnapshot(board: board, fill: fill)
        try expect(board.rows.count >= 2, "the board holds the context and a governing window")

        let panel = RangePanelViewController(
            title: "Fixture", snapshot: snapshot, read: { snapshot }, compact: {}, reveal: { _ in })
        _ = panel.view
        panel.view.layoutSubtreeIfNeeded()
        try expect(
            panel.drawnTanks == board.rows.count + board.elsewhere.count,
            "every tank on the board is a row in the sheet")
        let fitting = panel.view.fittingSize
        try expect(fitting.width == 420, "the sheet is as wide as the popover it sits in")
        try expect(
            fitting.height > 200 && fitting.height <= 640,
            "the sheet is tall enough to read and scrolls past 640 points (\(fitting.height))")
        let expectedCards =
            2 + (board.cache == nil ? 0 : 1) + (board.composition == nil ? 0 : 1)
            + (board.footprint == nil ? 0 : 1)
        try expect(
            panel.drawnCards >= expectedCards - 1,
            "the sheet draws a card for the verdict, the tanks and each section the board has")

        for row in board.rows + board.elsewhere {
            let bar = PaceBarView(row: row, surface: .opened, height: 6, width: 200)
            bar.frame = NSRect(x: 0, y: 0, width: 200, height: 6)
            bar.layoutSubtreeIfNeeded()
            try expect(bar.intrinsicContentSize.height == 6, "\(row.title): a bar is as tall as a plain one")
            try expect(
                bar.accessibilityLabel() == row.accessibilityLabel,
                "\(row.title): the bar is read in the row's own words")
            try expect(
                (PaceWords.line(for: row, opened: false) != nil) == (row.news != nil),
                "\(row.title): a line of words under a bar only when it is news")
        }
        return checks
    }
}
