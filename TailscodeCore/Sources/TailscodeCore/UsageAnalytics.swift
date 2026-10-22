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
        /// The trailing value: money for a row that spent some, otherwise the word for what a
        /// zero there means — read from ``door`` — and a share for a row counted rather than priced.
        public let money: String?
        /// `0...1` against the largest row of its section.
        public let share: Double
        /// True when this row did real work and nothing was billed for it at all. A zero here is
        /// a price, never an absence, and the row must not be drawn as an empty one. A plan's
        /// tokens are not free: the month was paid for, this ledger simply cannot divide it.
        public let isFree: Bool
        /// Which kind of door the row's tokens went through, where the row is a model, a provider
        /// or a machine. It is what makes a cost of nothing legible: hardware the person owns, a
        /// plan they already pay for, or a rate the server does not have.
        public let door: ModelDoorKind?
        /// How fast the model has run on this device, where the speed ledger has watched enough
        /// turns to say ("74 tok/s"). Only a model on the person's own machine carries one: its
        /// speed is a property of their hardware, where a hosted model's belongs to the provider's
        /// load that hour.
        public let speed: String?

        public init(
            label: String, detail: String, money: String?, share: Double, isFree: Bool = false,
            door: ModelDoorKind? = nil, speed: String? = nil
        ) {
            self.label = label
            self.detail = detail
            self.money = money
            self.share = share
            self.isFree = isFree
            self.door = door
            self.speed = speed
        }

        /// What a row wears at its trailing edge: the speed where there is one, then the money
        /// word. A client draws this and composes nothing of its own.
        public var trailing: String? {
            let parts = [speed, money].compactMap { $0 }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    /// What ran on the person's own hardware, arranged to lead the page for an account that does
    /// most of its work there. The money cannot say any of it: a local model costs nothing, so the
    /// facts that matter are how much it did, how that divides between reading and writing, which
    /// model did it, how fast, and how much room its window has.
    public struct LocalWork: Sendable, Equatable {
        /// One tile in the stats row: a label, the number, and a dim line that qualifies it.
        public struct Stat: Sendable, Equatable {
            public let label: String
            public let value: String
            public let detail: String?
        }

        public let title: String
        public let headline: String
        /// The work: fresh tokens, cache reads left out, summed over every model on a local door.
        public let tokens: Int
        /// `0...1` of the window's fresh tokens across every door.
        public let share: Double
        /// What the models wrote and what they read, where the ledger separates the two. Nil when
        /// it cannot, so a surface says nothing rather than splitting a number it never had.
        public let generated: Int?
        public let read: Int?
        /// Turns on a local door, where the servers counted them; nil is not zero.
        public let turns: Int?
        /// Days with local work in them, where every machine that ran a local model ran nothing
        /// else, so the daily buckets are the local model's alone; nil when they are shared.
        public let activeDays: Int?
        public let stats: [Stat]
        public let models: [Meter]
        /// What the list left out when there were more local models than it will show.
        public let caption: String?
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
    /// What the account spent on hosted models, said once under a headline that is tokens: an
    /// account whose work mostly ran on its own machine leads with the work, and the bill it did
    /// run up is a dim line beneath rather than the number. Nil when the headline is the money
    /// or when nothing was spent.
    public let hostedLine: String?
    /// What ran on the person's own hardware, or nil when nothing did.
    public let localWork: LocalWork?
    /// Whether at least half the window's work ran on the person's own hardware. Such an account
    /// is measured in tokens everywhere — the headline, the bars, the rankings — and its page
    /// leads with ``localWork`` and the models.
    public let isLocalLed: Bool
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
    private let modelNames: [String: String]
    private let prefix: String

    public static let defaultWindowDays = UsageWindow.fallback.days
    private static let projectLimit = 8
    private static let toolLimit = 10
    /// An account that reaches for one model has three; one that reaches for whatever is cheapest
    /// has thirty, and a list that long is a wall rather than a chart. What is cut is stated.
    private static let modelLimit = 12
    /// The share of the window's work at or above which an account is called local-led and is
    /// measured by its work instead of by its bill.
    static let localLedShare = 0.5

    public init?(
        servers: [(name: String, report: UsageAnalyticsReport)],
        missingServers: [String] = [],
        window: UsageWindow = .fallback,
        now: Date = Date(),
        calendar: Calendar = .current,
        modelNames: [String: String] = [:],
        contextWindows: [String: Int] = [:],
        speeds: ModelSpeedLedger = .shared
    ) {
        let reports = servers.filter { !$0.report.isEmpty }
        guard !reports.isEmpty || !missingServers.isEmpty else { return nil }
        self.window = window

        var dayCost: [String: Double] = [:]
        var dayTotals: [String: Int] = [:]
        var dayFresh: [String: Int] = [:]
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
        var localDays = Set<String>()
        var localDaysAreKnown = true
        for (name, report) in reports {
            coverage.formIntersection(report.covers)
            if !report.covers.contains(.turns) { coarse.append(name) }
            switch Self.door(ofServing: report.models) {
            case .local:
                localDays.formUnion(
                    report.daily.filter { $0.turns > 0 || $0.tokens.total > 0 }.map(\.day))
            case .mixed: localDaysAreKnown = false
            case .none: break
            }
            for day in report.daily
            where day.turns > 0 || day.costUSD > 0 || day.tokens.total > 0 {
                dayCost[day.day, default: 0] += day.costUSD
                dayTotals[day.day, default: 0] += day.tokens.total
                dayFresh[day.day, default: 0] += day.tokens.fresh
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
        modelRows = Self.adoptDoors(modelRows)
        let names = Names(table: modelNames)
        let allWork = max(
            totals.tokens.fresh, modelRows.values.reduce(0) { $0 + $1.tokens.fresh })
        let localRows = Self.localRows(modelRows)
        let localWorkTokens = localRows.reduce(0) { $0 + $1.tokens.fresh }
        let localLed = Self.isLocalLed(localTokens: localWorkTokens, allTokens: allWork)
        self.isLocalLed = localLed
        let priced = Self.measuresMoney(costUSD: totals.costUSD, localLed: localLed)
        let tokenYardstickWithBill = totals.costUSD > 0 && localLed
        let dayTokens = localLed ? dayFresh : dayTotals
        let work: (SessionSpendReport.Tokens) -> Int = { localLed ? $0.fresh : $0.total }
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
            : Localized.text("%@ tokens", StatusFacts.tokens(work(tokens)))
        self.hostedLine =
            tokenYardstickWithBill
            ? Self.hostedLine(costUSD: totals.costUSD, prefix: prefix, estimated: estimated)
            : nil
        self.windowLabel = window.label
        let active = Double(max(1, totals.activeDays))
        var perDay = Localized.text(
            "%@ a day, over %d active days",
            priced
                ? prefix + SessionSpend.money(totals.costUSD / active)
                : StatusFacts.tokens(Int(Double(work(tokens)) / active)),
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
        clauses.append(Localized.text("%@ tokens", StatusFacts.tokens(work(totals.tokens))))
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
        self.modelNames = modelNames
        self.prefix = prefix
        let modelPeak = rankedModels.map { Double($0.tokens.fresh) }.max() ?? 0
        let modelLabels = Self.modelLabels(Array(rankedModels.prefix(Self.modelLimit)), names: names)
        self.models = rankedModels.prefix(Self.modelLimit).map { row in
            let short = names(row.model)
            let label = modelLabels[row.model] ?? short
            let provider = ProviderIdentity.provider(ofModel: row.model)
            let door = provider.map(ModelDoorKind.classify)
            return Meter(
                label: label,
                detail: Self.workDetail(
                    turns: row.turns, counted: work(row.tokens), costUSD: row.costUSD,
                    prefix: prefix,
                    through: label == short ? provider : nil),
                money: Self.value(
                    costUSD: row.costUSD, tokens: row.tokens, prefix: prefix, door: door),
                share: modelPeak > 0 ? Double(row.tokens.fresh) / modelPeak : 0,
                isFree: Self.isFree(costUSD: row.costUSD, tokens: row.tokens, door: door),
                door: door)
        }
        self.providers = Self.providerMeters(models: modelRows, prefix: prefix, localLed: localLed)
        self.modelsLine = Self.modelsLine(
            ranked: rankedModels, prefix: prefix, shown: Self.modelLimit, names: names)
        self.localWork = Self.localWork(
            rows: localRows, allTokens: allWork, led: localLed,
            activeDays: localDaysAreKnown && !localDays.isEmpty ? localDays.count : nil,
            prefix: prefix, names: names, contextWindows: contextWindows, speeds: speeds)

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
                } else if !tokenYardstickWithBill {
                    detail += Localized.text(" · %@ tokens", StatusFacts.tokens(work(row.tokens)))
                }
                let trailing = Self.unpricedRow(
                    costUSD: row.costUSD, tokens: row.tokens, prefix: prefix, priced: priced,
                    byWork: tokenYardstickWithBill)
                return Meter(
                    label: projectLabels[row.directory] ?? row.name, detail: detail,
                    money: trailing.value,
                    share: projectPeak > 0
                        ? Self.rank(row.costUSD, row.tokens, priced) / projectPeak : 0,
                    isFree: trailing.isFree)
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
            days: Set(dayTotals.keys).union(dayCost.keys), calendar: calendar)
        self.records = Self.recordRows(
            records: records, streak: streak, subagents: subagents, compactions: compactions,
            totalCostUSD: totals.costUSD, priced: priced, billed: tokenYardstickWithBill,
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
                    } else if !tokenYardstickWithBill {
                        detail += Localized.text(
                            " · %@ tokens", StatusFacts.tokens(work(totals.tokens)))
                    }
                    let door =
                        Self.door(ofModels: server.report.models)
                        ?? (priced || tokenYardstickWithBill ? nil : .local)
                    let trailing =
                        tokenYardstickWithBill && door == nil
                        ? Self.unpricedRow(
                            costUSD: totals.costUSD, tokens: totals.tokens, prefix: prefix,
                            priced: priced, byWork: true)
                        : (
                            value: Self.value(
                                costUSD: totals.costUSD, tokens: totals.tokens, prefix: prefix,
                                door: door),
                            isFree: Self.isFree(
                                costUSD: totals.costUSD, tokens: totals.tokens, door: door)
                        )
                    return Meter(
                        label: server.name, detail: detail,
                        money: trailing.value,
                        share: machinePeak > 0 ? machineRank(server.report) / machinePeak : 0,
                        isFree: trailing.isFree,
                        door: door)
                }
        } else {
            self.machines = []
        }

        self.findings = Self.findings(
            totals: totals, models: modelRows, tools: toolRows, hourTurns: hourTurns,
            cacheSaved: cacheSaved, streak: streak, subagents: subagents, prefix: prefix,
            names: names)

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
        Self.modelsLine(
            ranked: rankedModels, prefix: prefix, shown: shown, names: Names(table: modelNames))
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

    /// The trailing value on a meter: what it cost, or — where it did real work and the server
    /// priced none of it — the word for the door rather than a verdict on the bill. A row reading
    /// "$0" beside two million tokens says the model went unused, which is the opposite of what
    /// happened, and *free* says the same of a plan somebody pays for every month. So each zero
    /// names what it is: *Local* for hardware the person already owns, *Plan* for a subscription
    /// billed a flat month (Ollama Cloud, a coding plan), *Free tier* for models a provider gives
    /// away, *Unpriced* for a hosted rate this ledger simply does not have.
    private static func value(
        costUSD: Double, tokens: SessionSpendReport.Tokens, prefix: String, door: ModelDoorKind?
    ) -> String {
        if costUSD > 0 { return prefix + SessionSpend.money(costUSD) }
        guard tokens.total > 0 else { return SessionSpend.money(0) }
        switch door {
        case .local: return Localized.text("Local")
        case .subscription: return Localized.text("Plan")
        case .free: return Localized.text("Free tier")
        case .gateway, .key, .none: return Localized.text("Unpriced")
        }
    }

    /// Whether a row's work was billed to nobody at all. A plan's tokens are excluded on purpose:
    /// the money was spent, it just cannot be divided per token.
    private static func isFree(
        costUSD: Double, tokens: SessionSpendReport.Tokens, door: ModelDoorKind?
    ) -> Bool {
        guard costUSD <= 0, tokens.total > 0 else { return false }
        return door == .local || door == .free
    }

    /// The numbers under a model's name, led by the door its tokens went through where the name
    /// itself does not already carry it — which is how the list answers *what am I actually
    /// running* rather than only *what did it cost*.
    private static func workDetail(
        turns: Int, counted: Int, costUSD: Double, prefix: String, through: String? = nil
    ) -> String {
        var detail = Localized.text("%@ tokens", StatusFacts.tokens(counted))
        if turns > 0 {
            detail = Localized.text("%@ turns · ", Self.count(turns)) + detail
            if costUSD > 0 {
                detail += Localized.text(
                    " · %@ a turn", prefix + SessionSpend.money(costUSD / Double(turns)))
            }
        }
        if let through {
            detail = ProviderIdentity.displayName(through) + " · " + detail
        }
        return detail
    }

    /// Every model folded up by the door its tokens went through. A provider is only worth a row
    /// when there is another to compare it against.
    private static func providerMeters(
        models: [String: SessionSpendReport.ModelShare], prefix: String, localLed: Bool
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
        guard !(localLed && rows.keys.allSatisfy(ProviderIdentity.isLocal)) else { return [] }
        let ranked = rows.values.sorted { byWork($0.share, $1.share) }
        let peak = ranked.map { Double($0.share.tokens.fresh) }.max() ?? 0
        return ranked.map { row in
            var detail =
                row.models == 1
                ? Localized.text("1 model") : Localized.text("%d models", row.models)
            detail += Localized.text(
                " · %@ tokens",
                StatusFacts.tokens(localLed ? row.share.tokens.fresh : row.share.tokens.total))
            let door = ModelDoorKind.classify(row.share.model)
            switch door {
            case .local: detail += Localized.text(" · on your own machine")
            case .subscription: detail += Localized.text(" · on a plan you already pay for")
            case .free, .gateway, .key: break
            }
            return Meter(
                label: ProviderIdentity.displayName(row.share.model), detail: detail,
                money: value(
                    costUSD: row.share.costUSD, tokens: row.share.tokens, prefix: prefix,
                    door: door),
                share: peak > 0 ? Double(row.share.tokens.fresh) / peak : 0,
                isFree: isFree(
                    costUSD: row.share.costUSD, tokens: row.share.tokens, door: door),
                door: door)
        }
    }

    /// Two models can wear the same name through two different doors — the same weights served
    /// by a gateway and by its vendor — and two identical rows read as a bug rather than as a
    /// choice. Only the names that collide among the rows actually listed are qualified; a twin
    /// the list cut leaves the row it cannot be confused with short.
    private static func modelLabels(
        _ ranked: [SessionSpendReport.ModelShare], names: Names
    ) -> [String: String] {
        var counts: [String: Int] = [:]
        for row in ranked { counts[names(row.model), default: 0] += 1 }
        var labels: [String: String] = [:]
        for row in ranked {
            let short = names(row.model)
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
            let parent = URL(fileURLWithPath: project.directory, isDirectory: true)
                .deletingLastPathComponent()
                .lastPathComponent
            labels[project.directory] =
                parent.isEmpty ? project.directory : "\(parent)/\(project.name)"
        }
        return labels
    }

    /// The caption under the models: what the list could not fit, and what ran through a plan or
    /// through a door with no rate — the facts a column of "$0" hides. What ran on the person's
    /// own hardware is ``localWork``'s to say.
    private static func modelsLine(
        ranked: [SessionSpendReport.ModelShare], prefix: String, shown: Int, names: Names
    ) -> String? {
        var parts: [String] = []
        let hidden = ranked.dropFirst(shown)
        if !hidden.isEmpty {
            let tokens = StatusFacts.tokens(hidden.reduce(0) { $0 + $1.tokens.total })
            let hiddenCost = hidden.reduce(0) { $0 + $1.costUSD }
            let money =
                hiddenCost > 0
                ? prefix + SessionSpend.money(hiddenCost)
                : Localized.text("no price")
            parts.append(
                hidden.count == 1
                    ? Localized.text("1 more model not shown · %@ tokens · %@", tokens, money)
                    : Localized.text(
                        "%d more models not shown · %@ tokens · %@", hidden.count, tokens, money))
        }
        if let plan = planLine(models: ranked, names: names) { parts.append(plan) }
        if let unpriced = unpricedLine(models: ranked, names: names) { parts.append(unpriced) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The same model reported by two servers under two names is one model. A bridge that serves
    /// a single engine names the model alone (`glm-5.3-flash`) while an opencode server names the
    /// door with it (`ollama-cloud/glm-5.3-flash`), and split in two the account reads as two
    /// models — one of them filed under a vendor nobody holds an account with, its tokens
    /// *unpriced* beside the very same tokens on a plan. So where exactly one qualified row wears
    /// a bare row's name, the bare row joins it: a door a server actually reported outranks one
    /// read off the model's family.
    private static func adoptDoors(
        _ rows: [String: SessionSpendReport.ModelShare]
    ) -> [String: SessionSpendReport.ModelShare] {
        var hosts: [String: Set<String>] = [:]
        for key in rows.keys where key.contains("/") {
            hosts[ModelBadge.shortName(key), default: []].insert(key)
        }
        var out: [String: SessionSpendReport.ModelShare] = [:]
        for (key, row) in rows {
            let twins = key.contains("/") ? nil : hosts[ModelBadge.shortName(key)]
            let target = twins?.count == 1 ? twins?.first ?? key : key
            var merged =
                out[target]
                ?? SessionSpendReport.ModelShare(
                    model: target, turns: 0, tokens: .init(), costUSD: 0)
            merged.turns += row.turns
            merged.tokens = add(merged.tokens, row.tokens)
            merged.costUSD += row.costUSD
            out[target] = merged
        }
        return out
    }

    /// Which door a model's tokens went through, where the model key names one at all.
    private static func door(of model: SessionSpendReport.ModelShare) -> ModelDoorKind? {
        ProviderIdentity.provider(ofModel: model.model).map(ModelDoorKind.classify)
    }

    /// The one door a whole machine's work went through, where its models agree on one — which
    /// is what lets a server running nothing but Ollama read as local inside an account that
    /// spent money elsewhere. A machine with two kinds of door has no single answer.
    private static func door(ofModels models: [SessionSpendReport.ModelShare]) -> ModelDoorKind? {
        let doors = Set(models.filter { $0.tokens.total > 0 }.compactMap(door(of:)))
        return doors.count == 1 ? doors.first : nil
    }

    /// The models a clause is about: the ones that did real work and were billed nothing per
    /// token, through the doors this clause speaks for.
    private static func unbilled(
        _ models: [SessionSpendReport.ModelShare], through doors: Set<ModelDoorKind>
    ) -> [SessionSpendReport.ModelShare] {
        models.filter {
            $0.costUSD <= 0 && $0.tokens.total > 0 && door(of: $0).map(doors.contains) == true
        }
    }

    /// The doors a clause ran through, named as brands.
    private static func doorNames(_ models: [SessionSpendReport.ModelShare]) -> String {
        let doors = Set(models.compactMap { ProviderIdentity.provider(ofModel: $0.model) })
            .map(ProviderIdentity.displayName).sorted()
        return doors.isEmpty ? "" : " " + Localized.text("through %@", doors.joined(separator: ", "))
    }

    /// What went through a plan rather than a meter. A subscription buys a flat month, so its
    /// tokens are neither free nor unpriced — the money was spent and this ledger cannot divide
    /// it — and saying so is the difference between a plan and a hole in the numbers.
    private static func planLine(
        models: [SessionSpendReport.ModelShare], names: Names
    ) -> String? {
        let plan = unbilled(models, through: [.subscription])
        guard !plan.isEmpty else { return nil }
        let tokens = StatusFacts.tokens(plan.reduce(0) { $0 + $1.tokens.total })
        let through = doorNames(plan)
        return plan.count == 1
            ? Localized.text(
                "%@ tokens on %@%@ ran on a plan — billed by the month, not per token",
                tokens, names(plan[0].model), through)
            : Localized.text(
                "%@ tokens across %d models%@ ran on a plan — billed by the month, not per token",
                tokens, plan.count, through)
    }

    /// What ran through a hosted door the server has no rate for. A gateway's free tier is
    /// somebody's money; a card that called it free would be claiming a bill that exists is zero.
    private static func unpricedLine(
        models: [SessionSpendReport.ModelShare], names: Names
    ) -> String? {
        let unpriced = unbilled(models, through: [.key, .gateway, .free])
        guard !unpriced.isEmpty else { return nil }
        let tokens = StatusFacts.tokens(unpriced.reduce(0) { $0 + $1.tokens.total })
        let through = doorNames(unpriced)
        return unpriced.count == 1
            ? Localized.text(
                "%@ tokens on %@%@ are unpriced — the server reports no rate for it",
                tokens, names(unpriced[0].model), through)
            : Localized.text(
                "%@ tokens across %d models%@ are unpriced — the server reports no rate for them",
                tokens, unpriced.count, through)
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

    private static func findings(
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

    /// A model as every row names it: the codename the catalog gives it where a client had one
    /// to hand, which is what the person's own picker shows, and the id cleaned of its packaging
    /// otherwise. The rule for what a catalog name is worth wearing is ``ModelBadge``'s, applied
    /// once by ``modelNames(from:)``; this only looks the result up.
    private struct Names: Sendable, Equatable {
        let table: [String: String]

        func callAsFunction(_ model: String) -> String {
            table[model] ?? ModelBadge.shortName(model)
        }
    }

    /// The names a catalog gives its models, keyed the way a ledger keys them — `provider/id`,
    /// and the bare id too where no two providers disagree about it, because a Claude bridge
    /// names its models without a door. A name is whatever ``ModelBadge`` would put on a session
    /// row, so a codename shows here the way it does in the picker.
    public static func modelNames(from catalog: [ModelInfo]) -> [String: String] {
        catalogTable(catalog) {
            ModelBadge.shortName($0.id, catalogName: $0.name, providerID: $0.providerID)
        }
    }

    /// The context windows a catalog states, keyed like ``modelNames(from:)``. A model whose
    /// catalog entry says nothing has no entry, so no row claims a window nobody reported.
    public static func contextWindows(from catalog: [ModelInfo]) -> [String: Int] {
        catalogTable(catalog) { ($0.contextWindow ?? 0) > 0 ? $0.contextWindow : nil }
    }

    /// The same names from what each server last told this device about its models.
    public static func modelNames(profileIDs: [String]) -> [String: String] {
        modelNames(from: profileIDs.flatMap(ModelCatalogStore.cached))
    }

    public static func contextWindows(profileIDs: [String]) -> [String: Int] {
        contextWindows(from: profileIDs.flatMap(ModelCatalogStore.cached))
    }

    /// Makes sure the names exist to be read. A catalog is remembered whenever a chat or a chooser
    /// asked a server for it, so a device that has only ever opened the month has none, and the
    /// models would wear their ids. A server that has just answered the ledger can be asked once
    /// more; one whose catalog is already remembered is left alone.
    public static func rememberModels(profileID: String, backend: any CodingAgentBackend) async {
        guard ModelCatalogStore.cached(profileID).isEmpty else { return }
        await ModelCatalogStore.refresh(profileID: profileID, backend: backend)
    }

    private static func catalogTable<Value: Equatable>(
        _ catalog: [ModelInfo], _ value: (ModelInfo) -> Value?
    ) -> [String: Value] {
        var table: [String: Value] = [:]
        var bare: [String: Value] = [:]
        var contested = Set<String>()
        for model in catalog {
            guard let known = value(model) else { continue }
            table["\(model.providerID)/\(model.id)"] = known
            if let seen = bare[model.id], seen != known { contested.insert(model.id) }
            bare[model.id] = known
        }
        for (id, known) in bare where !contested.contains(id) && table[id] == nil {
            table[id] = known
        }
        return table
    }

    /// Money is the yardstick wherever any was spent and the work did not mostly run for free. An
    /// account whose models all run on a machine the person owns has no money to scale by, and a
    /// chart of zeroes would say the month never happened; one that did most of its work there
    /// and paid a little for the rest is about the work, with the bill a line beneath. Either way
    /// it is measured in the work itself.
    private static func measuresMoney(costUSD: Double, localLed: Bool) -> Bool {
        costUSD > 0 && !localLed
    }

    /// Whether the work mostly ran on the person's own hardware. Compared as tokens rather than
    /// as a rounded percentage, so a window at 49.6% is not called led by the rounding.
    static func isLocalLed(localTokens: Int, allTokens: Int) -> Bool {
        localTokens > 0 && allTokens > 0
            && Double(localTokens) >= Double(allTokens) * localLedShare
    }

    /// The models that did work through a door on the person's own machine, busiest first.
    private static func localRows(
        _ models: [String: SessionSpendReport.ModelShare]
    ) -> [SessionSpendReport.ModelShare] {
        models.values.filter { door(of: $0) == .local && $0.tokens.fresh > 0 }.sorted(by: byWork)
    }

    /// What one machine's models went through: all on the person's own hardware, some of them,
    /// or none of them. It is what says whether that machine's daily buckets are a local
    /// model's alone.
    private enum Serving {
        case local
        case mixed
        case none
    }

    private static func door(ofServing models: [SessionSpendReport.ModelShare]) -> Serving {
        var rows: [String: SessionSpendReport.ModelShare] = [:]
        for model in models {
            var row = rows[model.model] ?? SessionSpendReport.ModelShare(
                model: model.model, turns: 0, tokens: .init(), costUSD: 0)
            row.tokens = add(row.tokens, model.tokens)
            rows[model.model] = row
        }
        let doors = adoptDoors(rows).values.filter { $0.tokens.fresh > 0 }.map(door(of:))
        let local = doors.filter { $0 == .local }.count
        if local == 0 { return .none }
        return local == doors.count ? .local : .mixed
    }

    /// The bill an account that leads with its work still ran up, as a dim line under the number.
    private static func hostedLine(costUSD: Double, prefix: String, estimated: Bool) -> String {
        let money = SessionSpend.money(costUSD)
        return estimated
            ? Localized.text("%@ of hosted spend, an estimate", money)
            : Localized.text("%@ of hosted spend", money)
    }

    /// The trailing value of a project, machine or record whose door is not known. In an account
    /// measured by its money it is the money; in one that spent nothing it is the word for what a
    /// zero means on a machine the person owns; in one that leads with its work but paid a little
    /// it is the work, because a zero there could be a plan or a local model and nothing says.
    private static func unpricedRow(
        costUSD: Double, tokens: SessionSpendReport.Tokens, prefix: String, priced: Bool,
        byWork: Bool
    ) -> (value: String, isFree: Bool) {
        if byWork { return (StatusFacts.tokens(tokens.fresh), false) }
        let door: ModelDoorKind? = priced ? nil : .local
        return (
            value(costUSD: costUSD, tokens: tokens, prefix: prefix, door: door),
            isFree(costUSD: costUSD, tokens: tokens, door: door)
        )
    }

    /// A window as a person says it: 262k, 1M. Never a decimal on a thousand, because a context
    /// window is a size class and 262.1k reads as a measurement.
    static func contextLabel(_ window: Int) -> String {
        if window >= 1_000_000 {
            let tenths = Int((Double(window) / 100_000).rounded())
            return tenths % 10 == 0 ? "\(tenths / 10)M" : "\(tenths / 10).\(tenths % 10)M"
        }
        if window >= 1000 { return "\(Int((Double(window) / 1000).rounded()))k" }
        return "\(window)"
    }

    /// What the speed ledger remembers of a model. The ledger is keyed by the id a turn carries,
    /// which has no door in front of it, and a ledger row is keyed by the door and the id.
    private static func speed(
        of model: String, in ledger: ModelSpeedLedger
    ) -> ModelSpeedLedger.Reading? {
        let bare = model.firstIndex(of: "/").map { String(model[model.index(after: $0)...]) }
        return bare.flatMap { ledger.reading(model: $0) } ?? ledger.reading(model: model)
    }

    private static func speedWord(_ reading: ModelSpeedLedger.Reading) -> String {
        Localized.text("%@ tok/s", ResponseStats.rate(reading.tokensPerSecond))
    }

    /// The share of the window the local work is, as a person reads a percentage: never zero for
    /// something, never a hundred while anything else ran, and never half for an account that is
    /// not led by it.
    private static func shareWord(
        _ share: Double, led: Bool, everything: Bool
    ) -> String {
        var points = Int((share * 100).rounded())
        if !led { points = min(points, 49) }
        if !everything { points = min(points, 99) }
        return points == 0 ? "<1%" : "\(points)%"
    }

    private static func localWork(
        rows: [SessionSpendReport.ModelShare], allTokens: Int, led: Bool, activeDays: Int?,
        prefix: String, names: Names, contextWindows: [String: Int], speeds: ModelSpeedLedger
    ) -> LocalWork? {
        guard !rows.isEmpty else { return nil }
        let tokens = rows.reduce(0) { $0 + $1.tokens.fresh }
        let share = min(1, Double(tokens) / Double(max(allTokens, tokens)))
        let generated = rows.reduce(0) { $0 + $1.tokens.output }
        let read = tokens - generated
        let separates = generated > 0 && read > 0
        let turns = rows.reduce(0) { $0 + $1.turns }
        let shown = rows.prefix(modelLimit)
        let labels = modelLabels(Array(shown), names: names)
        let providers = Set(rows.compactMap { ProviderIdentity.provider(ofModel: $0.model) })
        let peak = Double(rows.first?.tokens.fresh ?? 0)
        let meters = shown.map { row -> Meter in
            let short = names(row.model)
            let label = labels[row.model] ?? short
            let provider = ProviderIdentity.provider(ofModel: row.model)
            var detail = workDetail(
                turns: row.turns, counted: row.tokens.fresh, costUSD: row.costUSD,
                prefix: prefix,
                through: providers.count > 1 && label == short ? provider : nil)
            if let window = contextWindows[row.model], window > 0 {
                detail += " · " + Localized.text("%@ context", contextLabel(window))
            }
            return Meter(
                label: label, detail: detail,
                money: value(
                    costUSD: row.costUSD, tokens: row.tokens, prefix: prefix, door: .local),
                share: peak > 0 ? Double(row.tokens.fresh) / peak : 0,
                isFree: isFree(costUSD: row.costUSD, tokens: row.tokens, door: .local),
                door: .local,
                speed: speed(of: row.model, in: speeds).map(speedWord))
        }

        var stats = [
            LocalWork.Stat(
                label: Localized.text("Work"), value: StatusFacts.tokens(tokens),
                detail: Localized.text("tokens")),
            LocalWork.Stat(
                label: Localized.text("Share of work"),
                value: shareWord(share, led: led, everything: tokens >= allTokens),
                detail: Localized.text("of the window")),
        ]
        if separates {
            stats.append(
                LocalWork.Stat(
                    label: Localized.text("Wrote"), value: StatusFacts.tokens(generated),
                    detail: Localized.text("read %@", StatusFacts.tokens(read))))
        }
        if let fastest = rows.first(where: { speed(of: $0.model, in: speeds) != nil }),
            let reading = speed(of: fastest.model, in: speeds)
        {
            stats.append(
                LocalWork.Stat(
                    label: Localized.text("Speed"), value: speedWord(reading),
                    detail: labels[fastest.model] ?? names(fastest.model)))
        }
        if stats.count < 4, turns > 0 {
            stats.append(
                LocalWork.Stat(
                    label: Localized.text("Turns"), value: count(turns),
                    detail: activeDays.map { Localized.text("%d active days", $0) }))
        }

        let hidden = rows.dropFirst(modelLimit)
        let caption: String? =
            hidden.isEmpty
            ? nil
            : hidden.count == 1
                ? Localized.text(
                    "1 more local model not shown · %@ tokens",
                    StatusFacts.tokens(hidden.reduce(0) { $0 + $1.tokens.fresh }))
                : Localized.text(
                    "%d more local models not shown · %@ tokens", hidden.count,
                    StatusFacts.tokens(hidden.reduce(0) { $0 + $1.tokens.fresh }))
        return LocalWork(
            title: Localized.text("On your own machine"),
            headline: Localized.text("%@ tokens on your own hardware", StatusFacts.tokens(tokens)),
            tokens: tokens, share: share, generated: separates ? generated : nil,
            read: separates ? read : nil, turns: turns > 0 ? turns : nil, activeDays: activeDays,
            stats: stats, models: meters, caption: caption)
    }

    static func count(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
