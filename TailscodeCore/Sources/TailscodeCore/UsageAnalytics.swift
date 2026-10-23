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
    /// The rate over the days that had work in them, or nil when no day did: a rate over zero
    /// days is not a sentence, and one over a single day reads in the singular.
    public let perDayLine: String?
    public let activityLine: String
    public let deltaLine: String?
    public let trend: Trend
    public let days: [DayBar]
    public let weekdays: [Meter]
    /// The one-letter name of each weekday in the language of the calendar the analytics were
    /// read with, Monday first like ``weekdays``, for a chart too narrow for the short name.
    public let weekdayInitials: [String]
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
    static let modelLimit = 12
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
        let perDay = Self.perDay(
            rate: priced
                ? prefix + SessionSpend.money(totals.costUSD / active)
                : StatusFacts.tokens(Int(Double(work(tokens)) / active)),
            activeDays: totals.activeDays,
            today: bars.last.flatMap { today in
                today.isToday && (priced ? today.costUSD > 0 : today.tokens > 0) ? today.value : nil
            })
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

        self.weekdayInitials = Self.weekdayInitials(calendar: calendar)
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
}
