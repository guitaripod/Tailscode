import CodingAgentKit
import Foundation

/// The month in numbers, arranged for reading rather than for accounting.
///
/// Every connected server reports its own ledger (``UsageAnalyticsReport``); this merges them
/// into one account and turns the merge into the sections a person actually wants: what the
/// window cost and which way it is heading, a bar per day, the week's rhythm and the day's
/// clock, which models and projects and tools the money went to, what caching kept in their
/// pocket, and the records worth telling someone about. Every word every client shows is
/// generated here — a client decides only how tall a bar is.
///
/// The money follows ``SessionSpend``'s rule: API-equivalent value, marked as an estimate,
/// never a bill.
public struct UsageAnalytics: Sendable, Equatable {
    public enum Trend: Sendable, Equatable {
        case up
        case down
        case flat
    }

    /// One bar in the daily chart. Days with no work are present and zero — a gap in a month is
    /// information, not a missing bar.
    public struct DayBar: Sendable, Equatable {
        public let key: String
        public let label: String
        public let weekdayLabel: String
        public let costUSD: Double
        public let money: String
        public let tokens: Int
        public let turns: Int
        public let toolCalls: Int
        /// `0...1` against the priciest day in the window.
        public let share: Double
        public let isToday: Bool
    }

    /// One meter row: models, projects, tools, machines all draw as a label, a fill and the
    /// numbers that justify it.
    public struct Meter: Sendable, Equatable {
        public let label: String
        public let detail: String
        public let money: String?
        /// `0...1` against the largest row of its section.
        public let share: Double
    }

    public struct HourBar: Sendable, Equatable {
        public let label: String
        public let turns: Int
        public let share: Double
    }

    /// One brag-worthy fact, ready to wear: an SF Symbol where the client has them, a single
    /// glyph where a column is all there is.
    public struct Record: Sendable, Equatable {
        public let id: String
        public let symbolName: String
        public let glyph: String
        public let title: String
        public let value: String
        public let detail: String?
    }

    public let totalMoney: String
    public let windowLabel: String
    public let perDayLine: String
    public let activityLine: String
    public let deltaLine: String?
    public let trend: Trend
    public let days: [DayBar]
    public let weekdays: [Meter]
    public let hours: [HourBar]
    public let clockLine: String?
    public let models: [Meter]
    public let projects: [Meter]
    public let tools: [Meter]
    public let toolsLine: String?
    public let tiers: [SessionSpend.Tier]
    public let cacheLine: String?
    public let records: [Record]
    /// Per-server shares — empty when only one machine reported, because a split of one is noise.
    public let machines: [Meter]
    public let insights: [String]
    public let source: String
    /// Servers that answered but are too old for the route, named so their absence from the
    /// numbers is a stated fact rather than a silent hole.
    public let missingServers: [String]

    public static let defaultWindowDays = 30
    private static let projectLimit = 8
    private static let toolLimit = 10

    public init?(
        servers: [(name: String, report: UsageAnalyticsReport)],
        missingServers: [String] = [],
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let reports = servers.filter { !$0.report.isEmpty }
        guard !reports.isEmpty || !missingServers.isEmpty else { return nil }
        let window = reports.map(\.report.days).max() ?? Self.defaultWindowDays

        var dayCost: [String: Double] = [:]
        var dayTokens: [String: Int] = [:]
        var dayTurns: [String: Int] = [:]
        var dayTools: [String: Int] = [:]
        var modelRows: [String: SessionSpendReport.ModelShare] = [:]
        var projectRows: [String: UsageAnalyticsReport.Project] = [:]
        var toolRows: [String: Int] = [:]
        var hourTurns = [Int](repeating: 0, count: 24)
        var totals = UsageAnalyticsReport.Totals()
        var tokens = SessionSpendReport.Tokens()
        var cacheSaved = 0.0
        var compactions = UsageAnalyticsReport.Compactions()
        var subagents = UsageAnalyticsReport.Subagents()
        var records = UsageAnalyticsReport.Records()

        for (_, report) in reports {
            for day in report.daily where day.turns > 0 || day.costUSD > 0 {
                dayCost[day.day, default: 0] += day.costUSD
                dayTokens[day.day, default: 0] += day.tokens.total
                dayTurns[day.day, default: 0] += day.turns
                dayTools[day.day, default: 0] += day.toolCalls
            }
            for share in report.models {
                var row = modelRows[share.model]
                    ?? SessionSpendReport.ModelShare(
                        model: share.model, turns: 0, tokens: .init(), costUSD: 0)
                row.turns += share.turns
                row.tokens = Self.add(row.tokens, share.tokens)
                row.costUSD += share.costUSD
                modelRows[share.model] = row
            }
            for project in report.projects {
                var row = projectRows[project.directory] ?? project
                if row.directory != project.directory || projectRows[project.directory] == nil {
                    row = project
                } else {
                    row.sessions += project.sessions
                    row.turns += project.turns
                    row.costUSD += project.costUSD
                    row.tokens = Self.add(row.tokens, project.tokens)
                }
                projectRows[project.directory] = row
            }
            for tool in report.tools {
                toolRows[tool.name, default: 0] += tool.calls
            }
            for (hour, count) in report.hourTurns.prefix(24).enumerated() {
                hourTurns[hour] += count
            }
            totals.costUSD += report.totals.costUSD
            totals.turns += report.totals.turns
            totals.toolCalls += report.totals.toolCalls
            totals.sessions += report.totals.sessions
            tokens = Self.add(tokens, report.totals.tokens)
            cacheSaved += report.cacheSavedUSD
            compactions.count += report.compactions.count
            compactions.reclaimedTokens += report.compactions.reclaimedTokens
            subagents.runs += report.subagents.runs
            subagents.tokens = Self.add(subagents.tokens, report.subagents.tokens)
            subagents.costUSD += report.subagents.costUSD
            records = Self.merge(records, report.records)
        }
        totals.activeDays = dayCost.count
        totals.tokens = tokens

        let estimated = reports.contains { $0.report.estimated }
        let prefix = estimated ? "~" : ""
        let dayKeys = Self.windowKeys(window: window, now: now, calendar: calendar)
        let peakDay = dayCost.values.max() ?? 0
        let todayKey = Self.dayFormatter(calendar).string(from: now)
        var bars: [DayBar] = []
        for key in dayKeys {
            let cost = dayCost[key] ?? 0
            let date = Self.dayFormatter(calendar).date(from: key)
            bars.append(
                DayBar(
                    key: key,
                    label: date.map { String(calendar.component(.day, from: $0)) } ?? key,
                    weekdayLabel: date.map { Self.weekdayName($0, calendar: calendar) } ?? "",
                    costUSD: cost, money: prefix + SessionSpend.money(cost),
                    tokens: dayTokens[key] ?? 0, turns: dayTurns[key] ?? 0,
                    toolCalls: dayTools[key] ?? 0,
                    share: peakDay > 0 ? cost / peakDay : 0, isToday: key == todayKey))
        }
        self.days = bars

        self.totalMoney = prefix + SessionSpend.money(totals.costUSD)
        self.windowLabel = Localized.text("Last %d days", window)
        let perActive = totals.costUSD / Double(max(1, totals.activeDays))
        self.perDayLine = Localized.text(
            "%@ a day, over %d active days", prefix + SessionSpend.money(perActive),
            totals.activeDays)
        self.activityLine = Localized.text(
            "%@ turns · %@ conversations · %@ tool calls · %@ tokens",
            Self.count(totals.turns), Self.count(totals.sessions), Self.count(totals.toolCalls),
            StatusFacts.tokens(totals.tokens.total))
        (self.deltaLine, self.trend) = Self.delta(bars: bars, prefix: prefix)

        self.weekdays = Self.weekdayMeters(bars: bars, prefix: prefix, calendar: calendar)
        let peakHour = hourTurns.max() ?? 0
        self.hours = (0..<24).map { hour in
            HourBar(
                label: String(format: "%02d", hour), turns: hourTurns[hour],
                share: peakHour > 0 ? Double(hourTurns[hour]) / Double(peakHour) : 0)
        }
        if let busiest = hourTurns.indices.max(by: { hourTurns[$0] < hourTurns[$1] }),
            peakHour > 0
        {
            self.clockLine = Localized.text(
                "Most turns start between %02d:00 and %02d:00", busiest, (busiest + 1) % 24)
        } else {
            self.clockLine = nil
        }

        let modelPeak = modelRows.values.map(\.costUSD).max() ?? 0
        self.models = modelRows.values.sorted { $0.costUSD > $1.costUSD }.map { row in
            Meter(
                label: ModelBadge.shortName(row.model),
                detail: Localized.text(
                    "%@ turns · %@ tokens", Self.count(row.turns),
                    StatusFacts.tokens(row.tokens.total)),
                money: prefix + SessionSpend.money(row.costUSD),
                share: modelPeak > 0 ? row.costUSD / modelPeak : 0)
        }

        let projectPeak = projectRows.values.map(\.costUSD).max() ?? 0
        self.projects = projectRows.values.sorted { $0.costUSD > $1.costUSD }
            .prefix(Self.projectLimit).map { row in
                Meter(
                    label: row.name,
                    detail: Localized.text(
                        "%@ chats · %@ turns", Self.count(row.sessions), Self.count(row.turns)),
                    money: prefix + SessionSpend.money(row.costUSD),
                    share: projectPeak > 0 ? row.costUSD / projectPeak : 0)
            }

        let toolPeak = toolRows.values.max() ?? 0
        let toolTotal = toolRows.values.reduce(0, +)
        self.tools = toolRows.sorted { $0.value > $1.value }.prefix(Self.toolLimit).map { row in
            Meter(
                label: row.key,
                detail: Localized.text("%@ calls", Self.count(row.value)),
                money: toolTotal > 0
                    ? "\(Int((Double(row.value) / Double(toolTotal) * 100).rounded()))%" : nil,
                share: toolPeak > 0 ? Double(row.value) / Double(toolPeak) : 0)
        }
        if let top = toolRows.max(by: { $0.value < $1.value }), toolTotal > 0 {
            let percent = Int((Double(top.value) / Double(toolTotal) * 100).rounded())
            self.toolsLine = Localized.text(
                "%@ calls in all · %@ is %d%% of them", Self.count(toolTotal), top.key, percent)
        } else {
            self.toolsLine = nil
        }

        self.tiers = SessionSpend.tierSplit(tokens: tokens, costUSD: totals.costUSD)
        if cacheSaved >= 1 {
            self.cacheLine = Localized.text(
                "Cache reads saved %@ against fresh-input prices",
                "~" + SessionSpend.money(cacheSaved))
        } else {
            self.cacheLine = nil
        }

        if let top = dayCost.max(by: { $0.value < $1.value }), top.value > 0 {
            records.busiestDay = UsageAnalyticsReport.Records.BusiestDay(
                day: top.key, costUSD: top.value, turns: dayTurns[top.key] ?? 0)
        }
        let streak = Self.streak(days: Set(dayCost.keys), calendar: calendar)
        self.records = Self.recordRows(
            records: records, streak: streak, subagents: subagents, compactions: compactions,
            prefix: prefix, calendar: calendar)

        if reports.count > 1 {
            let machinePeak = reports.map(\.report.totals.costUSD).max() ?? 0
            self.machines = reports.sorted { $0.report.totals.costUSD > $1.report.totals.costUSD }
                .map { server in
                    Meter(
                        label: server.name,
                        detail: Localized.text(
                            "%@ chats · %@ turns", Self.count(server.report.totals.sessions),
                            Self.count(server.report.totals.turns)),
                        money: prefix + SessionSpend.money(server.report.totals.costUSD),
                        share: machinePeak > 0
                            ? server.report.totals.costUSD / machinePeak : 0)
                }
        } else {
            self.machines = []
        }

        self.insights = Self.insightLines(
            totals: totals, tools: toolRows, hourTurns: hourTurns, cacheSaved: cacheSaved,
            streak: streak, subagents: subagents, prefix: prefix)

        self.source = reports.count > 1
            ? Localized.text(
                "Estimated from every transcript at API list prices, across %d machines",
                reports.count)
            : Localized.text("Estimated from every transcript at API list prices")
        self.missingServers = missingServers
    }

    /// Money at day-bar precision: the daily chart annotates its peak and its today, nothing else.
    public var peakDay: DayBar? {
        days.max { $0.costUSD < $1.costUSD }
    }

    private static func add(
        _ lhs: SessionSpendReport.Tokens, _ rhs: SessionSpendReport.Tokens
    ) -> SessionSpendReport.Tokens {
        SessionSpendReport.Tokens(
            input: lhs.input + rhs.input, output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite5m: lhs.cacheWrite5m + rhs.cacheWrite5m,
            cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h)
    }

    /// The busiest day is left out here on purpose: it is recomputed from the merged day
    /// buckets, because the peak of one machine is not the peak of the account.
    private static func merge(
        _ lhs: UsageAnalyticsReport.Records, _ rhs: UsageAnalyticsReport.Records
    ) -> UsageAnalyticsReport.Records {
        UsageAnalyticsReport.Records(
            busiestDay: nil,
            priciestSession: [lhs.priciestSession, rhs.priciestSession].compactMap { $0 }
                .max { $0.costUSD < $1.costUSD },
            priciestTurn: [lhs.priciestTurn, rhs.priciestTurn].compactMap { $0 }
                .max { $0.costUSD < $1.costUSD },
            longestTurn: [lhs.longestTurn, rhs.longestTurn].compactMap { $0 }
                .max { ($0.seconds ?? 0) < ($1.seconds ?? 0) },
            streakDays: max(lhs.streakDays, rhs.streakDays))
    }

    private static func dayFormatter(_ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private static func windowKeys(window: Int, now: Date, calendar: Calendar) -> [String] {
        let formatter = dayFormatter(calendar)
        let today = calendar.startOfDay(for: now)
        return (0..<window).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map(formatter.string(from:))
        }
    }

    private static func weekdayName(_ date: Date, calendar: Calendar) -> String {
        let index = calendar.component(.weekday, from: date) - 1
        let symbols = calendar.shortWeekdaySymbols
        guard symbols.indices.contains(index) else { return "" }
        return symbols[index]
    }

    /// Monday first regardless of locale: the chart reads as a work week, and the weekend
    /// belongs together at its end.
    private static func weekdayMeters(bars: [DayBar], prefix: String, calendar: Calendar)
        -> [Meter]
    {
        let formatter = dayFormatter(calendar)
        var cost = [Double](repeating: 0, count: 7)
        for bar in bars {
            guard let date = formatter.date(from: bar.key) else { continue }
            let index = (calendar.component(.weekday, from: date) + 5) % 7
            cost[index] += bar.costUSD
        }
        let peak = cost.max() ?? 0
        let symbols = calendar.shortWeekdaySymbols
        return (0..<7).map { index in
            let weekdayIndex = (index + 1) % 7
            let label = symbols.indices.contains(weekdayIndex) ? symbols[weekdayIndex] : ""
            return Meter(
                label: label, detail: "",
                money: prefix + SessionSpend.money(cost[index]),
                share: peak > 0 ? cost[index] / peak : 0)
        }
    }

    /// The last seven days against the seven before, with a deadband so ordinary noise reads as
    /// steady. Windows too short to hold two weeks compare their halves instead.
    private static func delta(bars: [DayBar], prefix: String) -> (String?, Trend) {
        let span = bars.count >= 14 ? 7 : bars.count / 2
        guard span >= 2 else { return (nil, .flat) }
        let recent = bars.suffix(span).reduce(0) { $0 + $1.costUSD }
        let before = bars.dropLast(span).suffix(span).reduce(0) { $0 + $1.costUSD }
        guard before > 0 else {
            return recent > 0 ? (Localized.text("All of it in the last week"), .up) : (nil, .flat)
        }
        let change = (recent - before) / before
        let percent = Int((abs(change) * 100).rounded())
        if abs(change) < 0.05 {
            return (Localized.text("Steady week over week"), .flat)
        }
        if change > 0 {
            return (Localized.text("Up %d%% on the week before", percent), .up)
        }
        return (Localized.text("Down %d%% on the week before", percent), .down)
    }

    private static func streak(days: Set<String>, calendar: Calendar) -> Int {
        let formatter = dayFormatter(calendar)
        guard let latest = days.max(), var cursor = formatter.date(from: latest) else { return 0 }
        var run = 0
        while days.contains(formatter.string(from: cursor)) {
            run += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else {
                break
            }
            cursor = previous
        }
        return run
    }

    private static func recordRows(
        records: UsageAnalyticsReport.Records, streak: Int,
        subagents: UsageAnalyticsReport.Subagents,
        compactions: UsageAnalyticsReport.Compactions, prefix: String, calendar: Calendar
    ) -> [Record] {
        var rows: [Record] = []
        if let busiest = records.busiestDay {
            let formatter = dayFormatter(calendar)
            let display = DateFormatter()
            display.calendar = calendar
            display.dateFormat = "MMM d"
            let label = formatter.date(from: busiest.day).map(display.string(from:))
                ?? busiest.day
            rows.append(
                Record(
                    id: "busiestDay", symbolName: "flame.fill", glyph: "▲",
                    title: Localized.text("Busiest day"),
                    value: "\(label) · \(prefix)\(SessionSpend.money(busiest.costUSD))",
                    detail: Localized.text("%@ turns", Self.count(busiest.turns))))
        }
        if let session = records.priciestSession {
            rows.append(
                Record(
                    id: "priciestSession", symbolName: "crown.fill", glyph: "♛",
                    title: Localized.text("Priciest conversation"),
                    value: prefix + SessionSpend.money(session.costUSD),
                    detail: session.title))
        }
        if let turn = records.priciestTurn {
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
            rows.append(
                Record(
                    id: "subagents", symbolName: "person.2.gobackward", glyph: "⑂",
                    title: Localized.text("Subagent runs"),
                    value: Self.count(subagents.runs),
                    detail: Localized.text(
                        "%@ tokens · %@", StatusFacts.tokens(subagents.tokens.total),
                        prefix + SessionSpend.money(subagents.costUSD))))
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

    private static func insightLines(
        totals: UsageAnalyticsReport.Totals, tools: [String: Int], hourTurns: [Int],
        cacheSaved: Double, streak: Int, subagents: UsageAnalyticsReport.Subagents,
        prefix: String
    ) -> [String] {
        var lines: [String] = []
        if cacheSaved > totals.costUSD, totals.costUSD > 0 {
            lines.append(
                Localized.text(
                    "Caching kept %@ off the ledger — more than the window itself cost",
                    "~" + SessionSpend.money(cacheSaved)))
        }
        if let top = tools.max(by: { $0.value < $1.value }) {
            let total = tools.values.reduce(0, +)
            let percent = total > 0 ? Int((Double(top.value) / Double(total) * 100).rounded()) : 0
            if percent >= 40 {
                lines.append(
                    Localized.text("%@ carries the work: %d%% of all tool calls", top.key, percent))
            }
        }
        if subagents.runs >= 100 {
            lines.append(
                Localized.text(
                    "%@ subagent runs did part of the work — %@ of it",
                    Self.count(subagents.runs), prefix + SessionSpend.money(subagents.costUSD)))
        }
        if streak >= 5 {
            lines.append(Localized.text("%d days without missing one", streak))
        }
        if lines.isEmpty, let peak = hourTurns.indices.max(by: { hourTurns[$0] < hourTurns[$1] }),
            hourTurns[peak] > 0
        {
            lines.append(Localized.text("The %02d:00 hour starts the most turns", peak))
        }
        return Array(lines.prefix(3))
    }

    static func count(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
