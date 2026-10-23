import CodingAgentKit
import Foundation

extension UsageAnalytics {
    static func recordRows(
        records: UsageAnalyticsReport.Records, streak: Int,
        subagents: UsageAnalyticsReport.Subagents,
        compactions: UsageAnalyticsReport.Compactions, totalCostUSD: Double, priced: Bool,
        billed: Bool, busiestTokens: Int, busiestSessions: Int, prefix: String, calendar: Calendar
    ) -> [Record] {
        var rows: [Record] = []
        if let busiest = records.busiestDay {
            let formatter = dayFormatter(calendar)
            let display = DateFormatter()
            display.calendar = calendar
            display.dateFormat = "MMM d"
            let label = formatter.date(from: busiest.day).map(display.string(from:))
                ?? busiest.day
            var detail: String
            if busiest.turns > 0 {
                detail = Localized.text("%@ turns", Self.count(busiest.turns))
            } else if busiestSessions > 0 {
                detail = Localized.text("%@ conversations", Self.count(busiestSessions))
            } else {
                detail = Localized.text("%@ tokens", StatusFacts.tokens(busiestTokens))
            }
            rows.append(
                Record(
                    id: "busiestDay", symbolName: "flame.fill", glyph: "▲",
                    title: Localized.text("Busiest day"),
                    value: priced
                        ? "\(label) · \(prefix)\(SessionSpend.money(busiest.costUSD))"
                        : "\(label) · \(StatusFacts.tokens(busiestTokens))",
                    detail: detail))
        }
        if let session = records.priciestSession, session.costUSD > 0 {
            rows.append(
                Record(
                    id: "priciestSession", symbolName: "crown.fill", glyph: "♛",
                    title: Localized.text("Priciest conversation"),
                    value: prefix + SessionSpend.money(session.costUSD),
                    detail: session.title))
        }
        if let turn = records.priciestTurn, turn.costUSD > 0 {
            rows.append(
                Record(
                    id: "priciestTurn", symbolName: "bolt.fill", glyph: "⚡",
                    title: Localized.text("Priciest turn"),
                    value: prefix + SessionSpend.money(turn.costUSD),
                    detail: turn.prompt))
        }
        if let turn = records.longestTurn, let seconds = turn.seconds {
            rows.append(
                Record(
                    id: "longestTurn", symbolName: "hourglass", glyph: "◷",
                    title: Localized.text("Longest turn"),
                    value: SessionSpend.duration(seconds),
                    detail: turn.prompt))
        }
        if streak >= 2 {
            rows.append(
                Record(
                    id: "streak", symbolName: "calendar", glyph: "≡",
                    title: Localized.text("Streak"),
                    value: Localized.text("%d days in a row", streak),
                    detail: nil))
        }
        if subagents.runs > 0 {
            var detail =
                billed && subagents.costUSD <= 0
                ? Localized.text("%@ tokens", StatusFacts.tokens(subagents.tokens.total))
                : Localized.text(
                    "%@ tokens · %@", StatusFacts.tokens(subagents.tokens.total),
                    value(
                        costUSD: subagents.costUSD, tokens: subagents.tokens, prefix: prefix,
                        door: priced || billed ? nil : .local))
            if totalCostUSD > 0, subagents.costUSD > 0 {
                let share = Int((subagents.costUSD / totalCostUSD * 100).rounded())
                detail += Localized.text(" · %d%% of the window", share)
            }
            rows.append(
                Record(
                    id: "subagents", symbolName: "person.2.gobackward", glyph: "⑂",
                    title: Localized.text("Subagent runs"),
                    value: Self.count(subagents.runs),
                    detail: detail))
        }
        if compactions.count > 0 {
            rows.append(
                Record(
                    id: "compactions", symbolName: "arrow.down.right.and.arrow.up.left",
                    glyph: "⇲",
                    title: Localized.text("Compactions"),
                    value: Self.count(compactions.count),
                    detail: Localized.text(
                        "%@ tokens reclaimed", StatusFacts.tokens(compactions.reclaimedTokens))))
        }
        return rows
    }

    static func findings(
        totals: UsageAnalyticsReport.Totals, models: [String: SessionSpendReport.ModelShare],
        tools: [String: Int], hourTurns: [Int], cacheSaved: Double, streak: Int,
        subagents: UsageAnalyticsReport.Subagents, prefix: String, names: Names
    ) -> [Insight] {
        var lines: [Insight] = []
        let work = models.values.reduce(0) { $0 + $1.tokens.fresh }
        if let top = models.values.max(by: { $0.tokens.fresh < $1.tokens.fresh }), work > 0 {
            let percent = Int((Double(top.tokens.fresh) / Double(work) * 100).rounded())
            if percent >= 60, models.count > 1 {
                lines.append(
                    Insight(
                        topic: .model,
                        text: Localized.text(
                            "%@ did most of it: %d%% of the window's tokens",
                            names(top.model), percent)))
            }
        }
        if cacheSaved > totals.costUSD, totals.costUSD > 0 {
            lines.append(
                Insight(
                    topic: .cache,
                    text: Localized.text(
                        "Caching kept %@ off the ledger — more than the window itself cost",
                        "~" + SessionSpend.money(cacheSaved))))
        }
        if let top = tools.max(by: { $0.value < $1.value }) {
            let total = tools.values.reduce(0, +)
            let percent = total > 0 ? Int((Double(top.value) / Double(total) * 100).rounded()) : 0
            if percent >= 40 {
                lines.append(
                    Insight(
                        topic: .tool,
                        text: Localized.text(
                            "%@ carries the work: %d%% of all tool calls", top.key, percent)))
            }
        }
        if subagents.runs >= 100 {
            lines.append(
                Insight(
                    topic: .subagents,
                    text: Localized.text(
                        "%@ subagent runs did part of the work — %@ of it",
                        Self.count(subagents.runs), prefix + SessionSpend.money(subagents.costUSD))))
        }
        if streak >= 5 {
            lines.append(
                Insight(
                    topic: .streak,
                    text: Localized.text("%d days without missing one", streak)))
        }
        if let peak = hourTurns.indices.max(by: { hourTurns[$0] < hourTurns[$1] }),
            hourTurns[peak] > 0
        {
            lines.append(
                Insight(
                    topic: .clock,
                    text: Localized.text("The %02d:00 hour starts the most turns", peak)))
        }
        return lines
    }
}
