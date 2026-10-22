import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Usage analytics: work on the person's own machine")
struct UsageLocalWorkTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Helsinki") ?? .current
        return calendar
    }

    private var now: Date {
        ISO8601DateFormatter().date(from: "2026-08-07T15:00:00+03:00") ?? Date()
    }

    private func key(daysAgo: Int) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(
            from: calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))
                ?? now)
    }

    private func tokens(
        input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0
    ) -> SessionSpendReport.Tokens {
        SessionSpendReport.Tokens(
            input: input, output: output, cacheRead: cacheRead, cacheWrite5m: cacheWrite)
    }

    private func share(
        _ model: String, turns: Int = 0, input: Int = 0, output: Int = 0, cacheRead: Int = 0,
        cost: Double = 0
    ) -> SessionSpendReport.ModelShare {
        SessionSpendReport.ModelShare(
            model: model, turns: turns,
            tokens: tokens(input: input, output: output, cacheRead: cacheRead), costUSD: cost)
    }

    private func report(
        models: [SessionSpendReport.ModelShare], dailyDays: [Int] = [1, 2],
        turns: Int = 0, toolCalls: Int = 0, sessions: Int = 4,
        projects: [UsageAnalyticsReport.Project] = [], tools: [UsageAnalyticsReport.Tool] = [],
        hourTurns: [Int] = [], coverage: UsageAnalyticsReport.Coverage? = nil
    ) -> UsageAnalyticsReport {
        var total = SessionSpendReport.Tokens()
        for model in models {
            total = SessionSpendReport.Tokens(
                input: total.input + model.tokens.input,
                output: total.output + model.tokens.output,
                cacheRead: total.cacheRead + model.tokens.cacheRead,
                cacheWrite5m: total.cacheWrite5m + model.tokens.cacheWrite5m)
        }
        let cost = models.reduce(0) { $0 + $1.costUSD }
        let perDay = dailyDays.isEmpty ? 0 : total.output / dailyDays.count
        let daily = dailyDays.map {
            UsageAnalyticsReport.Day(
                day: key(daysAgo: $0), costUSD: cost / Double(dailyDays.count),
                tokens: tokens(output: perDay), turns: turns / max(1, dailyDays.count),
                sessions: 1)
        }
        return UsageAnalyticsReport(
            since: now.addingTimeInterval(-30 * 86_400), generatedAt: now, days: 30,
            totals: UsageAnalyticsReport.Totals(
                costUSD: cost, tokens: total, turns: turns, toolCalls: toolCalls,
                sessions: sessions, activeDays: daily.count),
            daily: daily, models: models, projects: projects, tools: tools,
            hourTurns: hourTurns, coverage: coverage)
    }

    private func analytics(
        _ servers: [(name: String, report: UsageAnalyticsReport)],
        names: [String: String] = [:], contexts: [Int] = [],
        speeds: ModelSpeedLedger? = nil
    ) throws -> UsageAnalytics {
        try #require(
            UsageAnalytics(
                servers: servers, now: now, calendar: calendar, modelNames: names,
                speeds: speeds ?? quietLedger()))
    }

    private func quietLedger() -> ModelSpeedLedger {
        ModelSpeedLedger(defaults: UserDefaults(suiteName: "usage-local-\(UUID())") ?? .standard)
    }

    private var hostedOnly: UsageAnalyticsReport {
        report(
            models: [
                share("claude-opus-5", turns: 40, input: 2000, output: 90000, cost: 20),
                share("claude-sonnet-5", turns: 12, input: 1000, output: 30000, cost: 4),
                share("ollama-cloud/glm-5.3-flash", turns: 8, input: 500, output: 9000),
            ],
            turns: 60, toolCalls: 300, sessions: 5,
            projects: [
                UsageAnalyticsReport.Project(
                    directory: "/w/app", name: "app", sessions: 3, turns: 40, costUSD: 20,
                    tokens: tokens(output: 90000)),
                UsageAnalyticsReport.Project(
                    directory: "/w/lib", name: "lib", sessions: 2, turns: 20, costUSD: 4,
                    tokens: tokens(output: 30000)),
            ],
            tools: [UsageAnalyticsReport.Tool(name: "Bash", calls: 200)],
            hourTurns: [Int](repeating: 0, count: 13) + [40] + [Int](repeating: 0, count: 10))
    }

    private func dump(_ analytics: UsageAnalytics) -> String {
        var lines: [String] = [
            analytics.headline, analytics.totalMoney, analytics.windowLabel, analytics.perDayLine,
            analytics.activityLine, analytics.deltaLine ?? "-", analytics.modelsLine ?? "-",
            analytics.clockLine ?? "-", analytics.toolsLine ?? "-", analytics.cacheLine ?? "-",
            analytics.source, analytics.coverageNote ?? "-",
            analytics.peakDay.map { "\($0.title) \($0.value)" } ?? "-",
        ]
        for meter in analytics.models + analytics.providers + analytics.projects + analytics.machines
            + analytics.weekdays
        {
            lines.append(
                "\(meter.label)|\(meter.detail)|\(meter.money ?? "-")|\(meter.isFree)|\(meter.share)"
            )
        }
        lines += analytics.days.filter { $0.share > 0 }.map { "\($0.title)|\($0.value)|\($0.share)" }
        lines += analytics.records.filter { $0.id != "busiestDay" }.map {
            "\($0.title)|\($0.value)|\($0.detail ?? "-")"
        }
        lines += analytics.findings.map(\.text)
        return lines.joined(separator: "\n")
    }

    @Test("A hosted-only account reads exactly as it did before local work had a section")
    func hostedOnlyIsUnchanged() throws {
        let result = try analytics([("studio", hostedOnly)])
        #expect(result.localWork == nil)
        #expect(result.isLocalLed == false)
        #expect(result.hostedLine == nil)
        #expect(dump(result) == hostedOnlyReading)
    }

    private var localLedReport: UsageAnalyticsReport {
        report(
            models: [
                share("llama-server/bolt", turns: 10, input: 30_000, output: 5_000, cacheRead: 900_000),
                share("llama-server/pennyroyal", turns: 4, input: 10_000, output: 5_000),
                share("claude-opus-5", turns: 3, input: 2_000, output: 1_000, cost: 3.2),
            ],
            turns: 17, sessions: 6, coverage: nil)
    }

    private var names: [String: String] {
        ["llama-server/bolt": "Bolt", "llama-server/pennyroyal": "Pennyroyal"]
    }

    private func ledger(_ model: String, turns: Int, tokens: Int, seconds: Double) -> ModelSpeedLedger {
        let ledger = quietLedger()
        for index in 0..<turns {
            ledger.record(turnID: "\(model)-\(index)", model: model, tokens: tokens, seconds: seconds)
        }
        return ledger
    }

    @Test("A local-led account leads with its tokens and demotes the bill to a line")
    func localLedLeadsWithTokens() throws {
        let result = try analytics([("arch", localLedReport)], names: names)
        #expect(result.isLocalLed)
        #expect(result.headline == "53.0k tokens")
        #expect(result.hostedLine == "$3.20 of hosted spend, an estimate")
        #expect(result.perDayLine.contains("$") == false)
        #expect(result.days.filter { $0.share > 0 }.allSatisfy { $0.value.hasSuffix("k") || !$0.value.contains("$") })
        #expect(result.weekdays.allSatisfy { $0.money?.contains("$") == false })
        #expect(result.peakDay?.value.contains("$") == false)
        #expect(result.projects.allSatisfy { $0.money?.contains("$") != true })
        let work = try #require(result.localWork)
        #expect(work.tokens == 50_000)
        #expect(work.headline == "50.0k tokens on your own hardware")
        #expect(work.title == "On your own machine")
        #expect(work.models.map(\.label) == ["Bolt", "Pennyroyal"])
        #expect(work.models.first?.money == "Local")
        #expect(work.models.first?.isFree == true)
        #expect(work.models.first?.detail == "10 turns · 35.0k tokens")
    }

    @Test("An account with no hosted spend at all has no bill line and no money tile")
    func localOnlyHasNoMoney() throws {
        let only = report(
            models: [share("llama-server/bolt", turns: 10, input: 30_000, output: 5_000)],
            turns: 10, sessions: 3)
        let result = try analytics([("arch", only)], names: names)
        #expect(result.isLocalLed)
        #expect(result.hostedLine == nil)
        #expect(result.headline == "35.0k tokens")
        let work = try #require(result.localWork)
        #expect(work.stats.map(\.label) == ["Work", "Share of work", "Wrote", "Turns"])
        #expect(work.stats.allSatisfy { !$0.value.contains("$") && !($0.detail ?? "").contains("$") })
        #expect(work.stats[0].value == "35.0k")
        #expect(work.stats[1].value == "100%")
        #expect(work.stats[2].value == "5.0k")
        #expect(work.stats[2].detail == "read 30.0k")
        #expect(work.stats[3].value == "10")
        #expect(work.share == 1)
    }

    @Test("The yardstick flips at half: 49% stays money, 50% and 51% become tokens")
    func yardstickThreshold() throws {
        for (local, led) in [(49, false), (50, true), (51, true)] {
            let mixed = report(
                models: [
                    share("llama-server/bolt", turns: 1, input: 0, output: local * 1000),
                    share("claude-opus-5", turns: 1, input: 0, output: (100 - local) * 1000, cost: 8),
                ], turns: 2)
            let result = try analytics([("arch", mixed)], names: names)
            #expect(result.isLocalLed == led, "local share \(local)%")
            #expect(result.headline.contains("$") == !led, "local share \(local)%")
            #expect((result.hostedLine != nil) == led)
            #expect(result.localWork != nil)
            #expect(result.days.filter { $0.share > 0 }.allSatisfy { $0.value.contains("$") == !led })
        }
        #expect(UsageAnalytics.isLocalLed(localTokens: 49, allTokens: 100) == false)
        #expect(UsageAnalytics.isLocalLed(localTokens: 50, allTokens: 100))
        #expect(UsageAnalytics.isLocalLed(localTokens: 51, allTokens: 100))
        #expect(UsageAnalytics.isLocalLed(localTokens: 0, allTokens: 0) == false)
    }

    @Test("A hosted-led account keeps the money headline and gains the local section")
    func hostedLedGainsTheSection() throws {
        let mixed = report(
            models: [
                share("llama-server/bolt", turns: 2, input: 0, output: 20_000),
                share("claude-opus-5", turns: 8, input: 0, output: 80_000, cost: 12),
            ], turns: 10)
        let result = try analytics([("arch", mixed)], names: names)
        #expect(result.isLocalLed == false)
        #expect(result.headline == "~$12.00")
        #expect(result.hostedLine == nil)
        let work = try #require(result.localWork)
        #expect(work.stats[1].value == "20%")
        #expect(result.modelsLine == nil)
    }

    @Test("Only 49.6 percent local never reads as half, and almost-all never reads as all")
    func shareRounding() throws {
        let nearHalf = report(
            models: [
                share("llama-server/bolt", output: 496),
                share("claude-opus-5", output: 504, cost: 1),
            ], turns: 2)
        #expect(try #require(analytics([("a", nearHalf)]).localWork).stats[1].value == "49%")
        let nearAll = report(
            models: [
                share("llama-server/bolt", output: 99_600),
                share("claude-opus-5", output: 400, cost: 1),
            ], turns: 2)
        #expect(try #require(analytics([("a", nearAll)]).localWork).stats[1].value == "99%")
        let sliver = report(
            models: [
                share("llama-server/bolt", output: 100),
                share("claude-opus-5", output: 99_900, cost: 1),
            ], turns: 2)
        #expect(try #require(analytics([("a", sliver)]).localWork).stats[1].value == "<1%")
    }

    @Test("A local model the catalog never named wears its cleaned id, and a codename wears the codename")
    func codenames() throws {
        let result = try analytics(
            [("arch", localLedReport)], names: ["llama-server/bolt": "Bolt"])
        let work = try #require(result.localWork)
        #expect(work.models.map(\.label) == ["Bolt", "pennyroyal"])
        #expect(result.models.map(\.label).contains("Bolt"))
        let hosted = try analytics(
            [("studio", hostedOnly)], names: ["claude-opus-5": "Opus", "claude-sonnet-5": "Daily Driver"])
        #expect(hosted.models.map(\.label).contains("Daily Driver"))
        #expect(hosted.findings.contains { $0.text.hasPrefix("Opus did most of it") })
    }

    @Test("A catalog's names and windows are keyed the way a ledger is")
    func catalogTables() {
        let catalog = [
            ModelInfo(
                id: "qwen3-coder-30b-q8", name: "Qwen Daily", providerID: "llama-server",
                contextWindow: 262_144),
            ModelInfo(
                id: "gpt-oss:120b", name: "gpt-oss:120b", providerID: "ollama",
                contextWindow: nil),
            ModelInfo(
                id: "bolt-moe", name: "Bolt", providerID: "llama-server", contextWindow: 131_072),
            ModelInfo(id: "bolt-moe", name: "Bolt", providerID: "ollama", contextWindow: 65_536),
        ]
        let names = UsageAnalytics.modelNames(from: catalog)
        #expect(names["llama-server/qwen3-coder-30b-q8"] == "Qwen Daily")
        #expect(names["qwen3-coder-30b-q8"] == "Qwen Daily")
        #expect(names["ollama/gpt-oss:120b"] == "gpt-oss-120b")
        let windows = UsageAnalytics.contextWindows(from: catalog)
        #expect(windows["llama-server/qwen3-coder-30b-q8"] == 262_144)
        #expect(windows["ollama/gpt-oss:120b"] == nil)
        #expect(windows["llama-server/bolt-moe"] == 131_072)
        #expect(windows["ollama/bolt-moe"] == 65_536)
        #expect(windows["bolt-moe"] == nil)
        #expect(names["bolt-moe"] == "Bolt")
    }

    @Test("Two doors to one model are told apart, and the runtime is named when there are two")
    func twoLocalDoorsOfOneModel() throws {
        let both = report(
            models: [
                share("llama-server/bolt", turns: 4, input: 8_000, output: 2_000),
                share("ollama/bolt", turns: 2, input: 3_000, output: 1_000),
            ], turns: 6)
        let result = try analytics(
            [("arch", both)], names: ["llama-server/bolt": "Bolt", "ollama/bolt": "Bolt"])
        let work = try #require(result.localWork)
        #expect(work.models.map(\.label) == ["Bolt · llama.cpp", "Bolt · Ollama"])
        #expect(work.tokens == 14_000)
        #expect(result.providers.isEmpty)
    }

    @Test("Two local runtimes with different models name the runtime in each row")
    func runtimeNamedWhenThereAreTwo() throws {
        let both = report(
            models: [
                share("llama-server/bolt", turns: 4, input: 8_000, output: 2_000),
                share("ollama/qwen3:14b", turns: 2, input: 3_000, output: 1_000),
            ], turns: 6)
        let result = try analytics([("arch", both)], names: ["llama-server/bolt": "Bolt"])
        let work = try #require(result.localWork)
        #expect(work.models.map(\.detail) == [
            "llama.cpp · 4 turns · 10.0k tokens", "Ollama · 2 turns · 4.0k tokens",
        ])
        #expect(result.providers.isEmpty)
    }

    @Test("A report that cannot tell reading from writing shows the work and no split")
    func noSeparation() throws {
        let lumped = report(
            models: [share("llama-server/bolt", turns: 3, input: 40_000, output: 0)], turns: 3)
        let work = try #require(analytics([("arch", lumped)]).localWork)
        #expect(work.generated == nil)
        #expect(work.read == nil)
        #expect(work.stats.contains { $0.label == "Wrote" } == false)
        #expect(work.stats.first?.value == "40.0k")
        let outputOnly = report(
            models: [share("llama-server/bolt", turns: 3, input: 0, output: 9_000)], turns: 3)
        let second = try #require(analytics([("arch", outputOnly)]).localWork)
        #expect(second.generated == nil)
    }

    @Test("Turns nobody counted are not a zero, and the server says so")
    func turnsNotMeasured() throws {
        let coarse = report(
            models: [share("llama-server/bolt", turns: 0, input: 8_000, output: 2_000)],
            turns: 0, coverage: .sessionTotals)
        let result = try analytics([("arch", coarse)])
        let work = try #require(result.localWork)
        #expect(work.turns == nil)
        #expect(work.stats.contains { $0.label == "Turns" } == false)
        #expect(work.models.first?.detail == "10.0k tokens")
        #expect(result.coverageNote?.contains("arch") == true)
    }

    @Test("Speed and context appear only where they are true")
    func speedAndContext() throws {
        let one = report(
            models: [
                share("llama-server/bolt", turns: 5, input: 8_000, output: 2_000),
                share("llama-server/pennyroyal", turns: 2, input: 3_000, output: 1_000),
            ], turns: 7)
        let bare = try #require(analytics([("arch", one)], names: names).localWork)
        #expect(bare.models.allSatisfy { $0.speed == nil })
        #expect(bare.models.allSatisfy { !$0.detail.contains("context") })
        #expect(bare.stats.contains { $0.label == "Speed" } == false)

        let twoTurns = ledger("bolt", turns: 2, tokens: 740, seconds: 10)
        #expect(
            try #require(analytics([("arch", one)], names: names, speeds: twoTurns).localWork)
                .models.first?.speed == nil)

        let measured = ledger("bolt", turns: 3, tokens: 740, seconds: 10)
        let result = try #require(
            UsageAnalytics(
                servers: [("arch", one)], now: now, calendar: calendar, modelNames: names,
                contextWindows: ["llama-server/bolt": 262_144], speeds: measured))
        let work = try #require(result.localWork)
        #expect(work.models[0].speed == "74 tok/s")
        #expect(work.models[0].trailing == "74 tok/s · Local")
        #expect(work.models[0].detail == "5 turns · 10.0k tokens · 262k context")
        #expect(work.models[1].speed == nil)
        #expect(work.models[1].trailing == "Local")
        #expect(work.models[1].detail == "2 turns · 4.0k tokens")
        let speed = try #require(work.stats.first { $0.label == "Speed" })
        #expect(speed.value == "74 tok/s")
        #expect(speed.detail == "Bolt")
    }

    @Test("A context window reads as a size class")
    func contextLabels() {
        #expect(UsageAnalytics.contextLabel(262_144) == "262k")
        #expect(UsageAnalytics.contextLabel(131_072) == "131k")
        #expect(UsageAnalytics.contextLabel(200_000) == "200k")
        #expect(UsageAnalytics.contextLabel(1_000_000) == "1M")
        #expect(UsageAnalytics.contextLabel(1_048_576) == "1M")
        #expect(UsageAnalytics.contextLabel(1_500_000) == "1.5M")
        #expect(UsageAnalytics.contextLabel(4096) == "4k")
        #expect(UsageAnalytics.contextLabel(512) == "512")
    }

    @Test("Active days are claimed only where the daily buckets are a local model's alone")
    func activeDays() throws {
        let alone = report(
            models: [share("llama-server/bolt", turns: 4, input: 8_000, output: 2_000)],
            dailyDays: [1, 2, 5], turns: 4)
        #expect(try #require(analytics([("arch", alone)]).localWork).activeDays == 3)
        #expect(try #require(analytics([("arch", localLedReport)]).localWork).activeDays == nil)
        let beside = try #require(
            analytics([("arch", alone), ("studio", hostedOnly)]).localWork)
        #expect(beside.activeDays == 3)
    }

    @Test("Local models beyond the list are counted in a caption, never dropped silently")
    func longList() throws {
        let many = (0..<14).map {
            share("llama-server/model-\($0)", turns: 1, input: 1_000 * (20 - $0), output: 100)
        }
        let work = try #require(analytics([("arch", report(models: many, turns: 14))]).localWork)
        #expect(work.models.count == 12)
        #expect(work.caption?.hasPrefix("2 more local models not shown · ") == true)
        let one = Array(many.prefix(13))
        let single = try #require(analytics([("arch", report(models: one, turns: 13))]).localWork)
        #expect(single.caption?.hasPrefix("1 more local model not shown · ") == true)
    }

    @Test("A local-led account drops a provider split that only says where its models ran")
    func providersDropped() throws {
        let led = try analytics([("arch", localLedReport)])
        #expect(led.providers.map(\.label).contains("Anthropic"))
        let local = report(
            models: [
                share("llama-server/bolt", turns: 4, input: 8_000, output: 2_000),
                share("ollama/qwen3:14b", turns: 2, input: 3_000, output: 1_000),
            ], turns: 6)
        #expect(try analytics([("arch", local)]).providers.isEmpty)
        let hostedLead = report(
            models: [
                share("llama-server/bolt", output: 1_000),
                share("ollama/qwen3:14b", output: 1_000),
                share("claude-opus-5", output: 90_000, cost: 9),
            ], turns: 6)
        #expect(try analytics([("arch", hostedLead)]).providers.count == 3)
    }

    @Test("No local door, no local section")
    func noLocal() throws {
        let hosted = report(
            models: [
                share("claude-opus-5", turns: 1, output: 1_000, cost: 1),
                share("ollama-cloud/glm-5.3-flash", turns: 1, output: 1_000),
                share("some-bare-model", turns: 1, output: 1_000),
            ], turns: 3)
        let result = try analytics([("studio", hosted)])
        #expect(result.localWork == nil)
        #expect(result.isLocalLed == false)
    }

    @Test("The plain text and the markdown carry the local block, led or not")
    func exports() throws {
        let led = try analytics([("arch", localLedReport)], names: names)
        let plain = AnalyticsShare(led, now: now).plainText
        #expect(plain.contains("On your own machine"))
        #expect(plain.contains("50.0k tokens on your own hardware"))
        #expect(plain.contains("Work 50.0k tokens · Share of work 94% of the window"))
        #expect(plain.contains("Bolt · Local · 10 turns · 35.0k tokens"))
        #expect(plain.contains("$3.20 of hosted spend, an estimate"))
        #expect(plain.range(of: "On your own machine")!.lowerBound < plain.range(of: "\nModels\n")!.lowerBound)
        let markdown = AnalyticsShare(led, now: now).markdown
        #expect(markdown.contains("## On your own machine"))
        #expect(markdown.contains("- **Bolt** · Local · 10 turns · 35.0k tokens"))

        let hostedLead = report(
            models: [
                share("llama-server/bolt", turns: 2, input: 0, output: 20_000),
                share("claude-opus-5", turns: 8, input: 0, output: 80_000, cost: 12),
            ], turns: 10)
        let mixed = try analytics([("arch", hostedLead)], names: names)
        let mixedPlain = AnalyticsShare(mixed, now: now).plainText
        #expect(mixedPlain.range(of: "\nModels\n")!.lowerBound < mixedPlain.range(of: "On your own machine")!.lowerBound)

        let hosted = AnalyticsShare(try analytics([("studio", hostedOnly)]), now: now)
        #expect(hosted.plainText.contains("On your own machine") == false)
        #expect(hosted.markdown.contains("On your own machine") == false)
    }

    private var hostedOnlyReading: String {
        """
~$24.00
~$24.00
Last 30 days
~$12.00 a day, over 2 active days
60 turns · 5 conversations · 300 tool calls · 132.5k tokens
All of it in the last 7 days
9.5k tokens on glm-5.3-flash through Ollama Cloud ran on a plan — billed by the month, not per token
Most turns start between 13:00 and 14:00
200 calls in all · Bash is 100% of them
-
Estimated from every transcript at API list prices
-
Wed Aug 5 ~$12.00
Opus|Anthropic · 40 turns · 92.0k tokens · ~$0.50 a turn|~$20.00|false|1.0
Sonnet|Anthropic · 12 turns · 31.0k tokens · ~$0.33 a turn|~$4.00|false|0.33695652173913043
glm-5.3-flash|Ollama Cloud · 8 turns · 9.5k tokens|Plan|false|0.10326086956521739
Anthropic|2 models · 123.0k tokens|~$24.00|false|1.0
Ollama Cloud|1 model · 9.5k tokens · on a plan you already pay for|Plan|false|0.07723577235772358
app|3 chats · 40 turns|~$20.00|false|1.0
lib|2 chats · 20 turns|~$4.00|false|0.2
Mon||~$0|false|0.0
Tue||~$0|false|0.0
Wed||~$12.00|false|1.0
Thu||~$12.00|false|1.0
Fri||~$0|false|0.0
Sat||~$0|false|0.0
Sun||~$0|false|0.0
Wed Aug 5|~$12.00|1.0
Thu Aug 6|~$12.00|1.0
Streak|2 days in a row|-
Opus did most of it: 69% of the window's tokens
Bash carries the work: 100% of all tool calls
The 13:00 hour starts the most turns
"""
    }
}
