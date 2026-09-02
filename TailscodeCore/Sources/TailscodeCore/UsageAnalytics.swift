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

    /// One bar in the chart over time. Empty stretches are present and zero — a gap in a month is
    /// information, not a missing bar — and a bar is a day, a week or a month depending on how
    /// much time the reader asked to see (``UsageWindow/grain``).
    public struct DayBar: Sendable, Equatable {
        public let key: String
        /// What this bar is, in words: a day as `Sun Aug 9`, a week as `Sep 8–14`, a month as
        /// `September`. Every reading of a bar — the tooltip, the peak annotation, the line a
        /// screen reader is given — says this rather than assembling one of its own.
        public let title: String
        public let costUSD: Double
        public let money: String
        /// What the day is worth in the unit the account actually has — the money, or the tokens
        /// where every model in the window ran for free. This is the string a bar is labelled
        /// with; ``money`` stays the money for anything that specifically means money.
        public let value: String
        public let tokens: Int
        public let turns: Int
        public let toolCalls: Int
        /// `0...1` against the biggest day in the window, measured the same way ``value`` is.
        public let share: Double
        public let isToday: Bool
    }

    /// One meter row: models, providers, projects, tools, machines all draw as a label, a fill
    /// and the numbers that justify it.
    public struct Meter: Sendable, Equatable {
        public let label: String
        public let detail: String
        /// The trailing value: money for a row that spent some, the word for free where a model
        /// ran on a machine the person already owns, a share for a row counted rather than priced.
        public let money: String?
        /// `0...1` against the largest row of its section.
        public let share: Double
        /// True when this row did real work and none of it cost anything. A zero here is a price,
        /// never an absence, and the row must not be drawn as an empty one.
        public let isFree: Bool

        public init(
            label: String, detail: String, money: String?, share: Double, isFree: Bool = false
        ) {
            self.label = label
            self.detail = detail
            self.money = money
            self.share = share
            self.isFree = isFree
        }
    }

    /// One thing worth saying about the window, typed by what it is about so a surface that
    /// already draws the models or the tools can leave out the line that repeats them.
    public struct Insight: Sendable, Equatable {
        public enum Topic: Sendable, Equatable {
            case model
            case cache
            case tool
            case subagents
            case streak
            case clock
        }

        public let topic: Topic
        public let text: String
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
    /// What the window comes to in the unit the account has: the money, or the work itself when
    /// every model in it ran for free. This is the number the surface leads with.
    public let headline: String
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
    /// Which provider served the work — "which model am I using" answered one level above the
    /// model name, and the only place a runtime on the server's own machine and a hosted API can
    /// be compared directly. Empty when the whole window went through one door, where a split of
    /// one says nothing.
    public let providers: [Meter]
    /// The caption under the models section: what the list left out when there were more models
    /// than it will show, and what ran at no cost because it ran on a machine the person already
    /// owns. Nil when neither is true.
    public let modelsLine: String?
    public let projects: [Meter]
    public let tools: [Meter]
    public let toolsLine: String?
    public let tiers: [SessionSpend.Tier]
    public let cacheLine: String?
    public let records: [Record]
    /// Per-server shares — empty when only one machine reported, because a split of one is noise.
    public let machines: [Meter]
    /// Everything worth saying, in the order it is worth saying it; ``insights`` is the three a
    /// surface with nothing else on it leads with.
    public let findings: [Insight]
    public var insights: [String] { findings.prefix(3).map(\.text) }
    public let source: String
    /// Servers that answered but are too old for the route, named so their absence from the
    /// numbers is a stated fact rather than a silent hole.
    public let missingServers: [String]
    /// What no contributing server could measure, said plainly. A section absent because nobody
    /// counted it must never read as one absent because it was zero, and a turn count drawn from
    /// two machines out of three has to say which.
    public let coverageNote: String?
    /// The facts every contributing server measured. A section outside it is not rendered at all.
    public let coverage: UsageAnalyticsReport.Coverage
    /// How much time this reading covers, so a surface can show which window is being read
    /// without keeping its own copy of the answer.
    public let window: UsageWindow
    /// The same fold, scored as a game: the trophy catalog with its progress, and the scores
    /// the leaderboards take. Read from this merge so the case can never disagree with the
    /// charts it sits beside.
    public let trophies: [Trophy]
    public let scores: [TrophyScore]
    private let rankedModels: [SessionSpendReport.ModelShare]
    private let priced: Bool
    private let prefix: String

    public static let defaultWindowDays = UsageWindow.fallback.days
    private static let projectLimit = 8
    private static let toolLimit = 10
    /// An account that reaches for one model has three; one that reaches for whatever is cheapest
    /// has thirty, and a list that long is a wall rather than a chart. What is cut is stated.
    private static let modelLimit = 12

    public init?(
        servers: [(name: String, report: UsageAnalyticsReport)],
        missingServers: [String] = [],
        window: UsageWindow = .fallback,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let reports = servers.filter { !$0.report.isEmpty }
        guard !reports.isEmpty || !missingServers.isEmpty else { return nil }
        self.window = window

        var dayCost: [String: Double] = [:]
        var dayTokens: [String: Int] = [:]
        var dayTurns: [String: Int] = [:]
        var dayTools: [String: Int] = [:]
        var daySessions: [String: Int] = [:]
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

        var coverage = UsageAnalyticsReport.Coverage.all
        var coarse: [String] = []
        for (name, report) in reports {
            coverage.formIntersection(report.covers)
            if !report.covers.contains(.turns) { coarse.append(name) }
            for day in report.daily
            where day.turns > 0 || day.costUSD > 0 || day.tokens.total > 0 {
                dayCost[day.day, default: 0] += day.costUSD
                dayTokens[day.day, default: 0] += day.tokens.total
                dayTurns[day.day, default: 0] += day.turns
                dayTools[day.day, default: 0] += day.toolCalls
                daySessions[day.day, default: 0] += day.sessions
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

        self.coverage = coverage
        let estimated = reports.contains { $0.report.estimated }
        let prefix = estimated ? "~" : ""
        // Money is the yardstick wherever any was spent. An account whose models all run on a
        // machine the person owns has no money to scale by, and a chart of zeroes would say the
        // month never happened, so it is measured in the work itself instead.
        let priced = totals.costUSD > 0
        let dayKeys = Self.windowKeys(window: window.days, now: now, calendar: calendar)
        let groups = Self.group(days: dayKeys, grain: window.grain, now: now, calendar: calendar)
        let weight = { (keys: [String]) -> Double in
            keys.reduce(0) {
                $0 + (priced ? (dayCost[$1] ?? 0) : Double(dayTokens[$1] ?? 0))
            }
        }
        let peakDay = groups.map { weight($0.days) }.max() ?? 0
        var bars: [DayBar] = []
        for group in groups {
            let cost = group.days.reduce(0) { $0 + (dayCost[$1] ?? 0) }
            let tokenCount = group.days.reduce(0) { $0 + (dayTokens[$1] ?? 0) }
            bars.append(
                DayBar(
                    key: group.key, title: group.title,
                    costUSD: cost, money: prefix + SessionSpend.money(cost),
                    value: priced
                        ? prefix + SessionSpend.money(cost) : StatusFacts.tokens(tokenCount),
                    tokens: tokenCount,
                    turns: group.days.reduce(0) { $0 + (dayTurns[$1] ?? 0) },
                    toolCalls: group.days.reduce(0) { $0 + (dayTools[$1] ?? 0) },
                    share: peakDay > 0 ? weight(group.days) / peakDay : 0,
                    isToday: group.holdsToday))
        }
        self.days = bars

        self.totalMoney = prefix + SessionSpend.money(totals.costUSD)
        self.headline =
            priced
            ? prefix + SessionSpend.money(totals.costUSD)
            : Localized.text("%@ tokens", StatusFacts.tokens(tokens.total))
        self.windowLabel = window.label
        let active = Double(max(1, totals.activeDays))
        var perDay = Localized.text(
            "%@ a day, over %d active days",
            priced
                ? prefix + SessionSpend.money(totals.costUSD / active)
                : StatusFacts.tokens(Int(Double(tokens.total) / active)),
            totals.activeDays)
        if let today = bars.last, today.isToday, priced ? today.costUSD > 0 : today.tokens > 0 {
            perDay += Localized.text(" · today %@", today.value)
        }
        self.perDayLine = perDay
        // Only the counts somebody actually measured. A server that keeps a running total per
        // conversation and no record of the turns inside reports zero turns, and a zero drawn as
        // a fact is the one lie this surface can tell.
        var clauses: [String] = []
        if totals.turns > 0 {
            clauses.append(Localized.text("%@ turns", Self.count(totals.turns)))
        }
        clauses.append(Localized.text("%@ conversations", Self.count(totals.sessions)))
        if totals.toolCalls > 0 {
            clauses.append(Localized.text("%@ tool calls", Self.count(totals.toolCalls)))
        }
        clauses.append(Localized.text("%@ tokens", StatusFacts.tokens(totals.tokens.total)))
        self.activityLine = clauses.joined(separator: " · ")
        (self.deltaLine, self.trend) = Self.delta(
            days: dayKeys, dayCost: dayCost, dayTokens: dayTokens, priced: priced, window: window)

        self.weekdays = Self.weekdayMeters(
            dayCost: dayCost, dayTokens: dayTokens, priced: priced, prefix: prefix,
            calendar: calendar)
        let peakHour = hourTurns.max() ?? 0
        // No server that could tell the hour means no clock — twenty-four empty columns is a
        // chart that has to be read to learn nothing.
        self.hours =
            peakHour > 0
            ? (0..<24).map { hour in
                HourBar(
                    label: String(format: "%02d", hour), turns: hourTurns[hour],
                    share: Double(hourTurns[hour]) / Double(peakHour))
            } : []
        if let busiest = hourTurns.indices.max(by: { hourTurns[$0] < hourTurns[$1] }),
            peakHour > 0
        {
            self.clockLine = Localized.text(
                "Most turns start between %02d:00 and %02d:00", busiest, (busiest + 1) % 24)
        } else {
            self.clockLine = nil
        }

        // Which model did the work is a token count, not a bill: a model on the server's own GPU
        // costs nothing and can still have done most of the month. The money stays on the row.
        let rankedModels = modelRows.values.sorted(by: Self.byWork)
        self.rankedModels = rankedModels
        self.priced = priced
        self.prefix = prefix
        let modelPeak = rankedModels.map { Double($0.tokens.fresh) }.max() ?? 0
        let modelLabels = Self.modelLabels(Array(rankedModels.prefix(Self.modelLimit)))
        self.models = rankedModels.prefix(Self.modelLimit).map { row in
            Meter(
                label: modelLabels[row.model] ?? ModelBadge.shortName(row.model),
                detail: Self.workDetail(
                    turns: row.turns, tokens: row.tokens, costUSD: row.costUSD, prefix: prefix),
                money: Self.value(costUSD: row.costUSD, tokens: row.tokens, prefix: prefix),
                share: modelPeak > 0 ? Double(row.tokens.fresh) / modelPeak : 0,
                isFree: row.costUSD <= 0 && row.tokens.total > 0)
        }
        self.providers = Self.providerMeters(models: modelRows, prefix: prefix)
        self.modelsLine = Self.modelsLine(
            ranked: rankedModels, priced: priced, prefix: prefix, shown: Self.modelLimit)

        let projectPeak = projectRows.values.map { Self.rank($0.costUSD, $0.tokens, priced) }
            .max() ?? 0
        let projectLabels = Self.projectLabels(Array(projectRows.values))
        self.projects = projectRows.values
            .sorted {
                Self.rank($0.costUSD, $0.tokens, priced) > Self.rank($1.costUSD, $1.tokens, priced)
            }
            .prefix(Self.projectLimit).map { row in
                var detail = Localized.text("%@ chats", Self.count(row.sessions))
                if row.turns > 0 {
                    detail += Localized.text(" · %@ turns", Self.count(row.turns))
                } else {
                    detail += Localized.text(" · %@ tokens", StatusFacts.tokens(row.tokens.total))
                }
                return Meter(
                    label: projectLabels[row.directory] ?? row.name, detail: detail,
                    money: Self.value(costUSD: row.costUSD, tokens: row.tokens, prefix: prefix),
                    share: projectPeak > 0
                        ? Self.rank(row.costUSD, row.tokens, priced) / projectPeak : 0,
                    isFree: row.costUSD <= 0 && row.tokens.total > 0)
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
        // A server that reports the money and the tokens but prices nothing itself leaves this at
        // zero; the saving is then implied from the same split the tier chart already trusts,
        // rather than dropping a section that is true of every cached conversation.
        if cacheSaved <= 0 {
            cacheSaved = SessionSpend.cacheSaving(tokens: tokens, costUSD: totals.costUSD)
        }
        let contextRead = tokens.cacheRead + tokens.input
        if cacheSaved >= 1, contextRead > 0 {
            let hitRate = Int(
                (Double(tokens.cacheRead) / Double(contextRead) * 100).rounded())
            self.cacheLine = Localized.text(
                "%d%% of what the model read came from cache, saving %@ against fresh-input prices",
                hitRate, "~" + SessionSpend.money(cacheSaved))
        } else if cacheSaved >= 1 {
            self.cacheLine = Localized.text(
                "Cache reads saved %@ against fresh-input prices",
                "~" + SessionSpend.money(cacheSaved))
        } else {
            self.cacheLine = nil
        }

        let busiestKey =
            priced
            ? dayCost.max(by: { $0.value < $1.value }).map(\.key)
            : dayTokens.max(by: { $0.value < $1.value }).map(\.key)
        if let busiestKey, (dayTokens[busiestKey] ?? 0) > 0 || (dayCost[busiestKey] ?? 0) > 0 {
            records.busiestDay = UsageAnalyticsReport.Records.BusiestDay(
                day: busiestKey, costUSD: dayCost[busiestKey] ?? 0,
                turns: dayTurns[busiestKey] ?? 0)
        }
        let streak = Self.streak(
            days: Set(dayTokens.keys).union(dayCost.keys), calendar: calendar)
        self.records = Self.recordRows(
            records: records, streak: streak, subagents: subagents, compactions: compactions,
            totalCostUSD: totals.costUSD, priced: priced,
            busiestTokens: busiestKey.flatMap { dayTokens[$0] } ?? 0,
            busiestSessions: busiestKey.flatMap { daySessions[$0] } ?? 0,
            prefix: prefix, calendar: calendar)

        var facts = TrophyFacts()
        facts.turns = totals.turns
        facts.tokens = tokens.total
        facts.toolCalls = totals.toolCalls
        facts.sessions = totals.sessions
        facts.streakDays = streak
        facts.subagentRuns = subagents.runs
        facts.compactions = compactions.count
        facts.cacheSavedUSD = cacheSaved
        facts.machines = reports.count
        facts.projects = projectRows.count
        facts.models = modelRows.count
        facts.nightTurns = hourTurns[0...4].reduce(0, +)
        facts.hoursCovered = hourTurns.filter { $0 > 0 }.count
        facts.longestTurnSeconds = records.longestTurn?.seconds ?? 0
        facts.peakDayCostUSD = dayCost.values.max() ?? 0
        facts.weekendTurns = Self.weekendTurns(dayTurns: dayTurns, calendar: calendar)
        self.trophies = TrophyRoom.trophies(facts: facts)
        self.scores = TrophyRoom.scores(facts: facts)

        if reports.count > 1 {
            let machineRank = { (report: UsageAnalyticsReport) -> Double in
                Self.rank(report.totals.costUSD, report.totals.tokens, priced)
            }
            let machinePeak = reports.map { machineRank($0.report) }.max() ?? 0
            self.machines = reports.sorted { machineRank($0.report) > machineRank($1.report) }
                .map { server in
                    let totals = server.report.totals
                    var detail = Localized.text("%@ chats", Self.count(totals.sessions))
                    if totals.turns > 0 {
                        detail += Localized.text(" · %@ turns", Self.count(totals.turns))
                    } else {
                        detail += Localized.text(
                            " · %@ tokens", StatusFacts.tokens(totals.tokens.total))
                    }
                    return Meter(
                        label: server.name, detail: detail,
                        money: Self.value(
                            costUSD: totals.costUSD, tokens: totals.tokens, prefix: prefix),
                        share: machinePeak > 0 ? machineRank(server.report) / machinePeak : 0,
                        isFree: totals.costUSD <= 0 && totals.tokens.total > 0)
                }
        } else {
            self.machines = []
        }

        self.findings = Self.findings(
            totals: totals, models: modelRows, tools: toolRows, hourTurns: hourTurns,
            cacheSaved: cacheSaved, streak: streak, subagents: subagents, prefix: prefix)

        self.source = reports.count > 1
            ? Localized.text(
                "Estimated from every transcript at API list prices, across %d machines",
                reports.count)
            : Localized.text("Estimated from every transcript at API list prices")
        self.missingServers = missingServers
        self.coverageNote = Self.coverageNote(
            coarse: coarse, servers: reports.count, coverage: coverage)
    }

    /// The caption under a models list that shows only its first `shown` rows: what it left out,
    /// and what ran for nothing. A card that draws four rows must not caption them with what a
    /// list of twelve left out.
    public func modelsLine(shown: Int) -> String? {
        Self.modelsLine(ranked: rankedModels, priced: priced, prefix: prefix, shown: shown)
    }

    /// The tallest bar in the daily chart, which the chart annotates along with today and
    /// nothing else. It is the tallest by whatever the chart is measuring — money, or the work
    /// itself in an account that spent none.
    public var peakDay: DayBar? {
        days.max { $0.share < $1.share }
    }

    /// Which model did the most work. Cache reads are left out of the measure: a cached prefix
    /// is counted once as a write and re-read on every turn after it, so counting the reads ranks
    /// a model by how long its conversations were rather than by how much it did. Ties break on
    /// money and then on name, so a listing never reorders itself between two reads.
    private static func byWork(
        _ lhs: SessionSpendReport.ModelShare, _ rhs: SessionSpendReport.ModelShare
    ) -> Bool {
        if lhs.tokens.fresh != rhs.tokens.fresh { return lhs.tokens.fresh > rhs.tokens.fresh }
        if lhs.costUSD != rhs.costUSD { return lhs.costUSD > rhs.costUSD }
        return lhs.model < rhs.model
    }

    /// What a row is measured by: the money wherever the account spent any, the work itself in an
    /// account that spent none.
    private static func rank(
        _ costUSD: Double, _ tokens: SessionSpendReport.Tokens, _ priced: Bool
    ) -> Double {
        priced ? costUSD : Double(tokens.fresh)
    }

    /// The trailing value on a meter: what it cost, or the word for free where it did real work
    /// and cost nothing — a row reading "$0" beside two million tokens says the model went unused,
    /// which is the opposite of what happened.
    private static func value(
        costUSD: Double, tokens: SessionSpendReport.Tokens, prefix: String
    ) -> String {
        if costUSD > 0 { return prefix + SessionSpend.money(costUSD) }
        return tokens.total > 0 ? Localized.text("Free") : SessionSpend.money(0)
    }

    private static func workDetail(
        turns: Int, tokens: SessionSpendReport.Tokens, costUSD: Double, prefix: String
    ) -> String {
        var detail = Localized.text("%@ tokens", StatusFacts.tokens(tokens.total))
        if turns > 0 {
            detail = Localized.text("%@ turns · ", Self.count(turns)) + detail
            if costUSD > 0 {
                detail += Localized.text(
                    " · %@ a turn", prefix + SessionSpend.money(costUSD / Double(turns)))
            }
        }
        return detail
    }

    /// Every model folded up by the door its tokens went through. A provider is only worth a row
    /// when there is another to compare it against.
    private static func providerMeters(
        models: [String: SessionSpendReport.ModelShare], prefix: String
    ) -> [Meter] {
        var rows: [String: (share: SessionSpendReport.ModelShare, models: Int)] = [:]
        for model in models.values {
            guard let key = ProviderIdentity.provider(ofModel: model.model) else { continue }
            var row =
                rows[key]
                ?? (
                    SessionSpendReport.ModelShare(
                        model: key, turns: 0, tokens: SessionSpendReport.Tokens(), costUSD: 0), 0
                )
            row.share.turns += model.turns
            row.share.tokens = add(row.share.tokens, model.tokens)
            row.share.costUSD += model.costUSD
            row.models += 1
            rows[key] = row
        }
        guard rows.count > 1 else { return [] }
        let ranked = rows.values.sorted { byWork($0.share, $1.share) }
        let peak = ranked.map { Double($0.share.tokens.fresh) }.max() ?? 0
        return ranked.map { row in
            var detail =
                row.models == 1
                ? Localized.text("1 model") : Localized.text("%d models", row.models)
            detail += Localized.text(" · %@ tokens", StatusFacts.tokens(row.share.tokens.total))
            if ProviderIdentity.isLocal(row.share.model) {
                detail += Localized.text(" · on your own machine")
            }
            return Meter(
                label: ProviderIdentity.displayName(row.share.model), detail: detail,
                money: value(costUSD: row.share.costUSD, tokens: row.share.tokens, prefix: prefix),
                share: peak > 0 ? Double(row.share.tokens.fresh) / peak : 0,
                isFree: row.share.costUSD <= 0 && row.share.tokens.total > 0)
        }
    }

    /// Two models can wear the same name through two different doors — the same weights served
    /// by a gateway and by its vendor — and two identical rows read as a bug rather than as a
    /// choice. Only the names that collide among the rows actually listed are qualified; a twin
    /// the list cut leaves the row it cannot be confused with short.
    private static func modelLabels(_ ranked: [SessionSpendReport.ModelShare]) -> [String: String] {
        var counts: [String: Int] = [:]
        for row in ranked { counts[ModelBadge.shortName(row.model), default: 0] += 1 }
        var labels: [String: String] = [:]
        for row in ranked {
            let short = ModelBadge.shortName(row.model)
            guard counts[short, default: 0] > 1, let key = ProviderIdentity.provider(ofModel: row.model)
            else {
                labels[row.model] = short
                continue
            }
            labels[row.model] = "\(short) · \(ProviderIdentity.displayName(key))"
        }
        return labels
    }

    /// Two checkouts of the same repository, or the same folder name under two parents, land as
    /// two rows wearing one name. Only the names that collide take the parent folder with them.
    private static func projectLabels(_ projects: [UsageAnalyticsReport.Project]) -> [String: String]
    {
        var counts: [String: Int] = [:]
        for project in projects { counts[project.name, default: 0] += 1 }
        var labels: [String: String] = [:]
        for project in projects {
            guard counts[project.name, default: 0] > 1 else {
                labels[project.directory] = project.name
                continue
            }
            let parent = URL(fileURLWithPath: project.directory).deletingLastPathComponent()
                .lastPathComponent
            labels[project.directory] =
                parent.isEmpty ? project.directory : "\(parent)/\(project.name)"
        }
        return labels
    }

    /// The caption under the models: what the list could not fit, and what the models that cost
    /// nothing actually did — the fact a column of "$0" hides.
    private static func modelsLine(
        ranked: [SessionSpendReport.ModelShare], priced: Bool, prefix: String, shown: Int
    ) -> String? {
        var parts: [String] = []
        let hidden = ranked.dropFirst(shown)
        if !hidden.isEmpty {
            let tokens = StatusFacts.tokens(hidden.reduce(0) { $0 + $1.tokens.total })
            let money = value(
                costUSD: hidden.reduce(0) { $0 + $1.costUSD },
                tokens: SessionSpendReport.Tokens(
                    output: hidden.reduce(0) { $0 + $1.tokens.total }),
                prefix: prefix)
            parts.append(
                hidden.count == 1
                    ? Localized.text("1 more model not shown · %@ tokens · %@", tokens, money)
                    : Localized.text(
                        "%d more models not shown · %@ tokens · %@", hidden.count, tokens, money))
        }
        if let free = freeLine(models: ranked, priced: priced) { parts.append(free) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What the models that cost nothing actually did, which is the fact a column of "$0" hides.
    private static func freeLine(
        models: [SessionSpendReport.ModelShare], priced: Bool
    ) -> String? {
        let free = models.filter { $0.costUSD <= 0 && $0.tokens.total > 0 }
        guard !free.isEmpty else { return nil }
        let freeTokens = free.reduce(0) { $0 + $1.tokens.fresh }
        guard freeTokens > 0 else { return nil }
        guard priced else {
            return Localized.text(
                "Every token this window ran on a machine you already own — %@ of them, at no cost",
                StatusFacts.tokens(freeTokens))
        }
        let allTokens = models.reduce(0) { $0 + $1.tokens.fresh }
        // A hundred percent is reserved for a window where nothing was paid for at all: rounding
        // a sliver of paid work away would say the month was free when it was not.
        var percent =
            allTokens > 0 ? Int((Double(freeTokens) / Double(allTokens) * 100).rounded()) : 0
        if freeTokens < allTokens { percent = min(99, percent) }
        if free.count == 1 {
            return Localized.text(
                "%@ tokens on %@ cost nothing — %d%% of the window's work ran on a machine you already own",
                StatusFacts.tokens(freeTokens), ModelBadge.shortName(free[0].model), percent)
        }
        return Localized.text(
            "%@ tokens across %d models cost nothing — %d%% of the window's work ran on a machine you already own",
            StatusFacts.tokens(freeTokens), free.count, percent)
    }

    /// What nobody counted, named. A server whose ledger is one running total per conversation
    /// knows the money and the model and nothing about the turns inside, and the difference
    /// between a count of zero and a count nobody took has to be on the screen.
    private static func coverageNote(
        coarse: [String], servers: Int, coverage: UsageAnalyticsReport.Coverage
    ) -> String? {
        guard !coarse.isEmpty else { return nil }
        let names = coarse.joined(separator: ", ")
        if coarse.count == servers {
            return coarse.count == 1
                ? Localized.text(
                    "Counted per conversation: %@ reports what each chat spent, not the turns inside it, the tools they called or the hour they ran.",
                    names)
                : Localized.text(
                    "Counted per conversation: %@ report what each chat spent, not the turns inside it, the tools they called or the hour they ran.",
                    names)
        }
        return coarse.count == 1
            ? Localized.text(
                "Turn, tool and clock counts cover %d of %d servers — %@ reports per-conversation totals only.",
                servers - coarse.count, servers, names)
            : Localized.text(
                "Turn, tool and clock counts cover %d of %d servers — %@ report per-conversation totals only.",
                servers - coarse.count, servers, names)
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

    /// One bar's worth of days, with the words that name it. A day names itself by weekday and
    /// date with its month — thirty days always straddle two, and a `Sun 9` is one of two Sundays
    /// — a week by the dates it spans, a month by its own name; a reader should never have to
    /// work out what a column is from how many there are.
    private struct Group {
        let key: String
        let title: String
        let days: [String]
        let holdsToday: Bool
    }

    private static func group(
        days: [String], grain: UsageWindow.Grain, now: Date, calendar: Calendar
    ) -> [Group] {
        let formatter = dayFormatter(calendar)
        let todayKey = formatter.string(from: now)
        guard grain != .day else {
            let display = DateFormatter()
            display.calendar = calendar
            display.timeZone = calendar.timeZone
            display.dateFormat = "MMM d"
            return days.map { key in
                let date = formatter.date(from: key)
                let title =
                    date.map { "\(weekdayName($0, calendar: calendar)) \(display.string(from: $0))" }
                    ?? key
                return Group(key: key, title: title, days: [key], holdsToday: key == todayKey)
            }
        }
        let component: Calendar.Component = grain == .week ? .weekOfYear : .month
        var order: [String] = []
        var members: [String: [String]] = [:]
        var starts: [String: Date] = [:]
        for key in days {
            guard let date = formatter.date(from: key),
                let interval = calendar.dateInterval(of: component, for: date)
            else { continue }
            let bucket = formatter.string(from: interval.start)
            if members[bucket] == nil {
                order.append(bucket)
                starts[bucket] = interval.start
            }
            members[bucket, default: []].append(key)
        }
        return order.map { bucket in
            let held = members[bucket] ?? []
            return Group(
                key: bucket,
                title: title(
                    grain: grain, start: starts[bucket], days: held, calendar: calendar),
                days: held, holdsToday: held.contains(todayKey))
        }
    }

    private static func title(
        grain: UsageWindow.Grain, start: Date?, days: [String], calendar: Calendar
    ) -> String {
        let formatter = dayFormatter(calendar)
        let display = DateFormatter()
        display.calendar = calendar
        display.timeZone = calendar.timeZone
        guard grain == .week else {
            display.dateFormat = "LLLL"
            return start.map(display.string(from:)) ?? days.first ?? ""
        }
        display.dateFormat = "MMM d"
        // A week that the window only partly holds is named by the days it actually covers, not by
        // the calendar week it belongs to: a bar cannot claim a Monday nobody counted.
        guard let first = days.first.flatMap(formatter.date(from:)),
            let last = days.last.flatMap(formatter.date(from:))
        else { return start.map(display.string(from:)) ?? "" }
        guard first != last else { return display.string(from: first) }
        let tail = DateFormatter()
        tail.calendar = calendar
        tail.timeZone = calendar.timeZone
        tail.dateFormat =
            calendar.component(.month, from: first) == calendar.component(.month, from: last)
            ? "d" : "MMM d"
        return "\(display.string(from: first))–\(tail.string(from: last))"
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
    private static func weekdayMeters(
        dayCost: [String: Double], dayTokens: [String: Int], priced: Bool, prefix: String,
        calendar: Calendar
    ) -> [Meter] {
        let formatter = dayFormatter(calendar)
        var weight = [Double](repeating: 0, count: 7)
        var cost = [Double](repeating: 0, count: 7)
        var tokens = [Int](repeating: 0, count: 7)
        // Always from the days themselves, never from the bars: a quarter drawn as thirteen weekly
        // columns still has a Tuesday in it, and folding a week's bar into one weekday would put
        // the whole quarter on whichever day each bar happened to start.
        for key in Set(dayCost.keys).union(dayTokens.keys) {
            guard let date = formatter.date(from: key) else { continue }
            let index = (calendar.component(.weekday, from: date) + 5) % 7
            cost[index] += dayCost[key] ?? 0
            tokens[index] += dayTokens[key] ?? 0
            weight[index] += priced ? (dayCost[key] ?? 0) : Double(dayTokens[key] ?? 0)
        }
        let peak = weight.max() ?? 0
        let symbols = calendar.shortWeekdaySymbols
        return (0..<7).map { index in
            let weekdayIndex = (index + 1) % 7
            let label = symbols.indices.contains(weekdayIndex) ? symbols[weekdayIndex] : ""
            return Meter(
                label: label, detail: "",
                money: priced
                    ? prefix + SessionSpend.money(cost[index])
                    : StatusFacts.tokens(tokens[index]),
                share: peak > 0 ? weight[index] / peak : 0)
        }
    }

    /// The most recent quarter of the window against the quarter before it, with a deadband so
    /// ordinary noise reads as steady. It is measured on the days rather than the bars, so the
    /// comparison is the same length of time whatever grain the chart happens to be drawn at, and
    /// it is named in days so a quarter's trend never claims to be a week's.
    private static func delta(
        days: [String], dayCost: [String: Double], dayTokens: [String: Int], priced: Bool,
        window: UsageWindow
    ) -> (String?, Trend) {
        let span = min(window.trendSpan, days.count / 2)
        guard span >= 2 else { return (nil, .flat) }
        let weigh = { (keys: ArraySlice<String>) -> Double in
            keys.reduce(0) { $0 + (priced ? (dayCost[$1] ?? 0) : Double(dayTokens[$1] ?? 0)) }
        }
        let recent = weigh(days.suffix(span))
        let before = weigh(days.dropLast(span).suffix(span))
        guard before > 0 else {
            return recent > 0
                ? (Localized.text("All of it in the last %d days", span), .up) : (nil, .flat)
        }
        let change = (recent - before) / before
        let percent = Int((abs(change) * 100).rounded())
        if abs(change) < 0.05 {
            return (Localized.text("Steady over the last %d days", span), .flat)
        }
        if change > 0 {
            return (Localized.text("Up %d%% on the %d days before", percent, span), .up)
        }
        return (Localized.text("Down %d%% on the %d days before", percent, span), .down)
    }

    private static func weekendTurns(dayTurns: [String: Int], calendar: Calendar) -> Int {
        let formatter = dayFormatter(calendar)
        return dayTurns.reduce(0) { sum, entry in
            guard let date = formatter.date(from: entry.key), calendar.isDateInWeekend(date)
            else { return sum }
            return sum + entry.value
        }
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
        compactions: UsageAnalyticsReport.Compactions, totalCostUSD: Double, priced: Bool,
        busiestTokens: Int, busiestSessions: Int, prefix: String, calendar: Calendar
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
            var detail = Localized.text(
                "%@ tokens · %@", StatusFacts.tokens(subagents.tokens.total),
                value(costUSD: subagents.costUSD, tokens: subagents.tokens, prefix: prefix))
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

    private static func findings(
        totals: UsageAnalyticsReport.Totals, models: [String: SessionSpendReport.ModelShare],
        tools: [String: Int], hourTurns: [Int], cacheSaved: Double, streak: Int,
        subagents: UsageAnalyticsReport.Subagents, prefix: String
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
                            ModelBadge.shortName(top.model), percent)))
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

    static func count(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
