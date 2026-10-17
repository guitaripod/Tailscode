import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

private let hour: TimeInterval = 3600
private let now = Date(timeIntervalSince1970: 1_800_000_000)

private let clock: RangeClock = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
    return RangeClock(calendar: calendar, locale: Locale(identifier: "en_GB"))
}()

private func user(_ id: String, at offset: TimeInterval = 0, text: String = "go") -> ChatMessage {
    ChatMessage(
        id: id, role: .user, agentType: .claudeCode,
        parts: [MessagePart(id: "t", kind: .text(text))], createdAt: now.addingTimeInterval(offset))
}

private func assistant(
    _ id: String, footprint: Int, at offset: TimeInterval = 0, duration: TimeInterval? = nil,
    lifetime: TimeInterval? = nil, model: String = "claude-sonnet-5-5",
    parts: [MessagePart]? = nil
) -> ChatMessage {
    ChatMessage(
        id: id, role: .assistant, agentType: .claudeCode,
        parts: parts ?? [MessagePart(id: "t", kind: .text("ok"))],
        createdAt: now.addingTimeInterval(offset), modelID: model,
        context: MessageUsage(
            input: 10, output: 90, cacheRead: footprint - 100, cacheLifetime: lifetime),
        duration: duration)
}

private func seam(_ id: String) -> ChatMessage {
    ChatMessage(
        id: id, role: .system, agentType: .claudeCode,
        parts: [MessagePart(id: "c", kind: .compaction(Compaction(tokensBefore: 180_000, tokensAfter: 8_000, summary: "")))],
        createdAt: now)
}

private func conversation(_ footprints: [Int]) -> [ChatMessage] {
    footprints.enumerated().flatMap { index, footprint in
        [user("u\(index)", at: Double(index) * 600), assistant("a\(index)", footprint: footprint, at: Double(index) * 600 + 5)]
    }
}

private func fill(_ used: Int, window: Int = 200_000) -> ContextFill {
    ContextFill(used: used, window: window, model: "claude-sonnet-5-5", basis: .reported)
}

private func gauge(
    _ key: String, _ label: String, used: Double, resetsIn: TimeInterval?, trusted: Bool = true
) -> UsageQuota.Gauge {
    UsageQuota.Gauge(
        key: key, label: label, fraction: used, resetsAt: resetsIn.map { now.addingTimeInterval($0) },
        trustedReset: trusted)
}

private func claude(_ gauges: [UsageQuota.Gauge]) -> UsageQuota {
    UsageQuota(
        providerName: "Claude", subtitle: "Max", source: "api · live", live: true, gauges: gauges,
        details: [])
}

private let busyAccount = claude([
    gauge("session", "5-hour session", used: 0.62, resetsIn: 2 * hour + 47 * 60),
    gauge("weekly_all", "Weekly · all models", used: 0.38, resetsIn: 63 * hour),
    gauge("weekly_scoped", "Weekly · Opus", used: 0.71, resetsIn: 63 * hour),
])

@Suite("How many more turns fit")
struct ContextBurnTests {
    @Test("The recent growth carried to the limit says how many turns are left")
    func turnsLeft() throws {
        let burn = try #require(
            ContextBurn.read(messages: conversation([100_000, 110_000, 121_000, 130_000, 142_000, 148_000]), fill: fill(148_000)))
        #expect(burn.growth == 9_600)
        #expect(burn.turnsLeft == 5)
        #expect(burn.isNews)
        #expect(burn.tone == .attention)
        #expect(RangeWords.turnsChip(5) == "~5 turns")
    }

    @Test("Nothing is said while the window is under half full, or before three turns of history")
    func gates() throws {
        let roomy = try #require(
            ContextBurn.read(messages: conversation([40_000, 50_000, 60_000, 70_000, 80_000, 90_000]), fill: fill(90_000)))
        #expect(roomy.growth == 10_000)
        #expect(roomy.turnsLeft == nil)
        let young = try #require(
            ContextBurn.read(messages: conversation([120_000, 148_000]), fill: fill(148_000)))
        #expect(young.growth == nil)
        #expect(young.turnsLeft == nil)
        let agentic = try #require(
            ContextBurn.read(messages: conversation([100_000, 120_000, 148_000]), fill: fill(148_000)))
        #expect(agentic.growth == 24_000)
        #expect(agentic.turnsLeft == 2)
    }

    @Test("A footprint that falls is a refill: nothing before it is carried into the rate")
    func refill() throws {
        let burn = try #require(
            ContextBurn.read(messages: conversation([100_000, 110_000, 120_000, 130_000, 20_000, 30_000, 40_000, 50_000, 60_000]), fill: fill(60_000, window: 100_000)))
        #expect(burn.epochTurns == 5)
        #expect(burn.growth == 10_000)
        #expect(burn.turnsLeft == 4)
    }

    @Test("A compaction seam ends the life of the window")
    func seamEndsEpoch() throws {
        var messages = conversation([100_000, 110_000, 120_000])
        messages.append(seam("s"))
        messages += [user("u9", at: 9000), assistant("a9", footprint: 20_000, at: 9005)]
        let burn = try #require(ContextBurn.read(messages: messages, fill: fill(20_000)))
        #expect(burn.turns.count == 1)
        #expect(burn.growth == nil)
    }

    @Test("The biggest single turn is named, with its share of what is left, when the whole conversation is read")
    func biggest() throws {
        let burn = try #require(
            ContextBurn.read(
                messages: conversation([100_000, 110_000, 150_000, 160_000, 170_000, 180_000]), fill: fill(180_000),
                wholeConversation: true))
        #expect(burn.biggest?.tokens == 40_000)
        #expect(burn.biggest?.messageID == "a2")
    }

    @Test("A turn of many steps is one turn, measured at its last request")
    func stepsAreOneTurn() throws {
        var messages = [user("u0"), assistant("a0", footprint: 100_000)]
        messages += [user("u1", at: 600), assistant("a1x", footprint: 105_000, at: 601), assistant("a1", footprint: 115_000, at: 700)]
        messages += [user("u2", at: 1200), assistant("a2", footprint: 130_000, at: 1201)]
        messages += [user("u3", at: 1800), assistant("a3", footprint: 145_000, at: 1801)]
        let burn = try #require(ContextBurn.read(messages: messages, fill: fill(145_000)))
        #expect(burn.turns.map(\.footprint) == [100_000, 115_000, 130_000, 145_000])
    }
}

@Suite("Whether the prompt cache is still held")
struct CacheWarmthTests {
    private func session() -> [ChatMessage] {
        [user("u1"), assistant("a1", footprint: 120_000, at: 5, duration: 120, lifetime: 3600)]
    }

    @Test("Warm counts down from the end of the last turn, which is the prompt plus how long the server timed the turn")
    func warm() throws {
        let cache = try #require(CacheWarmth.read(messages: session(), isRunning: false, now: now.addingTimeInterval(120 + 1800)))
        #expect(cache.state == .warm(remaining: 1800))
        #expect(cache.lifetime == 3600)
        #expect(cache.tokens == 119_910)
        #expect(cache.fractionLeft == 0.5)
        #expect(!cache.coldIsNews)
        #expect(!cache.needsWords)
    }

    @Test("Cold says for how long, and is news once the conversation is large enough to notice")
    func cold() throws {
        let cache = try #require(CacheWarmth.read(messages: session(), isRunning: false, now: now.addingTimeInterval(120 + 3700)))
        #expect(cache.state == .cold(for: 100))
        #expect(cache.coldIsNews)
        #expect(cache.needsWords)
    }

    @Test("A sentence is owed inside ten minutes of the end")
    func closing() throws {
        let cache = try #require(CacheWarmth.read(messages: session(), isRunning: false, now: now.addingTimeInterval(120 + 3100)))
        #expect(cache.needsWords)
        #expect(!cache.isCold)
    }

    @Test("Nothing while a turn is running, without a lifetime, or when no cache was used")
    func silent() {
        #expect(CacheWarmth.read(messages: session(), isRunning: true, now: now) == nil)
        #expect(CacheWarmth.read(messages: [user("u1"), assistant("a1", footprint: 120_000, at: 5, duration: 120)], isRunning: false, now: now) == nil)
        let uncached = ChatMessage(
            id: "a1", role: .assistant, agentType: .claudeCode, parts: [], createdAt: now,
            context: MessageUsage(input: 500, output: 40, cacheLifetime: 3600))
        #expect(CacheWarmth.read(messages: [user("u1"), uncached], isRunning: false, now: now) == nil)
    }

    @Test("A turn that only read the cache takes its lifetime from the one that wrote it")
    func lifetimeCarriesForward() throws {
        let messages = session() + [user("u2", at: 600), assistant("a2", footprint: 130_000, at: 605, duration: 60)]
        let cache = try #require(CacheWarmth.read(messages: messages, isRunning: false, now: now.addingTimeInterval(660 + 100)))
        #expect(cache.lifetime == 3600)
        #expect(cache.state == .warm(remaining: 3500))
    }
}

@Suite("What is in the window")
struct ContextCompositionTests {
    private func read(_ call: String, output: Int) -> MessagePart {
        MessagePart(
            id: call,
            kind: .tool(ToolCall(
                id: call, name: "Read", status: .completed,
                input: .object(["file_path": .string("/src/UsageAnalytics.swift")]),
                output: String(repeating: "x", count: output))))
    }

    @Test("The shares add up to exactly the measured footprint, the system prompt is what no message accounts for, and the big read is named")
    func sumsToTheMeasuredTotal() throws {
        let messages = [
            user("u0", text: String(repeating: "q", count: 400)),
            assistant("a0", footprint: 30_000, at: 5, parts: [read("r0", output: 40_000), MessagePart(id: "t", kind: .text(String(repeating: "a", count: 400)))]),
            user("u1", at: 600, text: String(repeating: "q", count: 400)),
            assistant("a1", footprint: 50_000, at: 605, parts: [read("r1", output: 4_000), MessagePart(id: "t", kind: .text(String(repeating: "a", count: 4_000)))]),
        ]
        let composition = try #require(ContextComposition.read(messages: messages, fill: fill(50_000)))
        #expect(composition.slices.reduce(0) { $0 + $1.tokens } == 50_000)
        #expect(abs(composition.slices.reduce(0) { $0 + $1.share } - 1) < 0.001)
        let system = try #require(composition.slices.first { $0.id == "system" })
        #expect(system.tokens > 15_000)
        let tools = try #require(composition.slices.first { $0.id == "tools" })
        #expect(tools.tokens > 8_000)
        let top = try #require(composition.items.first)
        #expect(top.tool == "Read")
        #expect(top.detail == "UsageAnalytics.swift")
        #expect(top.id == "a0:r0")
        #expect(top.turn == 1)
    }

    @Test("Whatever the transcript does not show is named for what it is")
    func unseenIsNamed() throws {
        let messages = [
            user("u0", text: "q"),
            assistant("a0", footprint: 90_000, at: 5, parts: [MessagePart(id: "t", kind: .text("a"))]),
        ]
        let composition = try #require(ContextComposition.read(messages: messages, fill: fill(90_000)))
        #expect(composition.slices.map(\.label) == ["System & other"])
        #expect(composition.slices.first?.share == 1)
        #expect(ContextComposition.note.contains("thinking"))
    }

    @Test("Only a measured fill is divided")
    func needsAMeasuredTotal() {
        let estimated = ContextFill(used: 50_000, window: 200_000, model: nil, basis: .estimated)
        #expect(ContextComposition.read(messages: conversation([50_000]), fill: estimated) == nil)
    }
}

@Suite("What the chat's chrome says about the range")
struct RangeGlanceTests {
    @Test("Turns left replace the share on the context chip, and open the range")
    func contextChip() throws {
        let messages = conversation([100_000, 110_000, 121_000, 130_000, 142_000, 148_000])
        let glance = RangeGlance.read(messages: messages, fill: fill(148_000), quotas: [], model: "claude-sonnet-5-5", now: now)
        var facts = StatusFacts()
        facts.context = fill(148_000)
        facts.range = glance
        let chip = try #require(facts.segments.first { $0.id == "context" })
        #expect(chip.text == "~5 turns")
        #expect(chip.css == "seg-warn")
        #expect(chip.action == .range)
        #expect(chip.meter == fill(148_000).fraction)
    }

    @Test("While there is room the chip says what it has always said")
    func quiet() throws {
        let messages = conversation([40_000, 41_000, 42_000, 43_000, 44_000, 45_000])
        let glance = RangeGlance.read(messages: messages, fill: fill(45_000), quotas: [], model: "claude-sonnet-5-5", now: now)
        var facts = StatusFacts()
        facts.context = fill(45_000)
        facts.range = glance
        #expect(facts.segments.first { $0.id == "context" }?.text == fill(45_000).badge)
        #expect(facts.segments.first { $0.id == "wall" } == nil)
        #expect(facts.segments.first { $0.id == "cache" } == nil)
    }

    @Test("A window that governs the chat's model and will run out before it resets gets a clock chip; one that governs another model does not")
    func wallChip() throws {
        let sonnet = RangeGlance.read(messages: [], fill: nil, quotas: [busyAccount], model: "claude-sonnet-5-5", now: now)
        let wall = try #require(sonnet.wall)
        #expect(wall.window == "5-hour session")
        #expect(abs(wall.wallAt.timeIntervalSince(now) - 4891) < 2)
        #expect(sonnet.wallWords(clock: clock) == "Wall 09:21")

        #expect(RangeGlance.read(messages: [], fill: nil, quotas: [busyAccount], model: nil, now: now).wall == nil)

        let opusOnly = claude([gauge("weekly_scoped", "Weekly · Opus", used: 0.71, resetsIn: 63 * hour)])
        #expect(RangeGlance.read(messages: [], fill: nil, quotas: [opusOnly], model: "claude-sonnet-5-5", now: now).wall == nil)
        let onOpus = RangeGlance.read(messages: [], fill: nil, quotas: [opusOnly], model: "claude-opus-5-5", now: now)
        #expect(onOpus.wall?.window == "Weekly · Opus")
        #expect(onOpus.wallWords(clock: clock)?.hasPrefix("Wall ") == true)
    }

    @Test("A cold cache on a large conversation is a quiet chip")
    func coldChip() throws {
        let messages = [user("u1"), assistant("a1", footprint: 120_000, at: 5, duration: 120, lifetime: 3600)]
        let glance = RangeGlance.read(messages: messages, fill: fill(120_000), quotas: [], model: nil, now: now.addingTimeInterval(5000))
        var facts = StatusFacts()
        facts.context = fill(120_000)
        facts.range = glance
        let chip = try #require(facts.segments.first { $0.id == "cache" })
        #expect(chip.text == StatusMark.cold + " Cache cold")
        #expect(chip.css == "seg-dim")
    }
}

@Suite("The sheet")
struct RangeBoardTests {
    private let messages = conversation([100_000, 110_000, 121_000, 130_000, 142_000, 148_000])

    @Test("The conversation's window leads, windows follow shortest first, and a window for another model is set aside")
    func rows() {
        let board = RangeBoard.read(
            messages: messages, fill: fill(148_000), quotas: [busyAccount], model: "claude-sonnet-5-5", now: now, clock: clock)
        #expect(board.rows.map(\.title) == ["Context", "5-hour session", "Weekly · all models"])
        #expect(board.elsewhere.map(\.title) == ["Weekly · Opus"])
        #expect(board.elsewhere.first?.dimmed == true)
        #expect(board.elsewhere.first?.news?.lead == "Wall")
        #expect(board.footprint != nil)
        #expect(board.composition != nil)
    }

    @Test("The verdict names the tank that runs out first")
    func verdict() {
        let board = RangeBoard.read(
            messages: messages, fill: fill(148_000), quotas: [busyAccount], model: "claude-sonnet-5-5", now: now, clock: clock)
        #expect(board.verdict.headline == "This chat has room for about 5 more turns.")
        #expect(board.verdict.detail == "Claude 5-hour session runs out in 1h 21m, before it resets.")
        #expect(board.verdict.tone == .attention)

        let quotaFirst = RangeBoard.read(
            messages: conversation([40_000, 41_000, 42_000, 43_000, 44_000, 45_000]), fill: fill(45_000),
            quotas: [busyAccount], model: "claude-sonnet-5-5", now: now, clock: clock)
        #expect(quotaFirst.verdict.headline == "Claude 5-hour session runs out in 1h 21m, before it resets.")
    }

    @Test("A quiet account says so, and a wall is the verdict outright")
    func quietAndWall() {
        let calm = claude([gauge("weekly_all", "Weekly · all models", used: 0.38, resetsIn: 63 * hour)])
        let board = RangeBoard.read(
            messages: conversation([40_000, 41_000, 42_000, 43_000, 44_000, 45_000]), fill: fill(45_000),
            quotas: [calm], model: "claude-sonnet-5-5", now: now, clock: clock)
        #expect(board.verdict.headline == "Room to spare.")
        #expect(board.verdict.tone == .quiet)

        let walled = claude([gauge("session", "5-hour session", used: 1.0, resetsIn: hour + 12 * 60)])
        let stopped = RangeBoard.read(messages: [], fill: nil, quotas: [walled], model: "claude-sonnet-5-5", now: now, clock: clock)
        #expect(stopped.verdict.headline == "Claude 5-hour session is used up")
        #expect(stopped.verdict.detail == nil)
        #expect(stopped.verdict.tone == .danger)
    }

    @Test("A row on pace is two lines of facts and no news; a row that will run out owes one line")
    func pacerRows() throws {
        let board = RangeBoard.read(
            messages: [], fill: nil, quotas: [busyAccount], model: "claude-sonnet-5-5", now: now, clock: clock)
        let weekly = try #require(board.rows.first { $0.title == "Weekly · all models" })
        #expect(weekly.news == nil)
        #expect(weekly.tailIsNews == false)
        #expect(weekly.tailEnd != nil)
        #expect(weekly.detail == "resets in 2d 15h")
        let session = try #require(board.rows.first { $0.title == "5-hour session" })
        #expect(session.news?.lead == "Wall")
        #expect(session.news?.body == "in 1h 21m — 1h 25m before it resets")
        #expect(session.tone == .attention)
        #expect(session.tailIsNews)
        #expect(session.amount == "62%")
        #expect(abs((session.tick ?? 0) - 0.4433) < 0.001)
    }

    @Test("A window too young to read says so and draws no tail")
    func youngWindow() throws {
        let young = claude([gauge("session", "5-hour session", used: 0.04, resetsIn: 4 * hour + 48 * 60)])
        let board = RangeBoard.read(messages: [], fill: nil, quotas: [young], model: "claude-sonnet-5-5", now: now, clock: clock)
        let row = try #require(board.rows.first)
        #expect(row.note == "Too early to tell the pace")
        #expect(row.tailEnd == nil)
        #expect(row.tick != nil)
    }

    @Test("The cache is a countdown that grows a sentence only when one is owed")
    func cacheRow() throws {
        let messages = [user("u1"), assistant("a1", footprint: 120_000, at: 5, duration: 120, lifetime: 3600)]
        let warm = RangeBoard.read(messages: messages, fill: fill(120_000), quotas: [], model: nil, now: now.addingTimeInterval(120 + 1800), clock: clock)
        #expect(warm.cache?.title == "Warm")
        #expect(warm.cache?.trailing == "30m")
        #expect(warm.cache?.sentence == nil)
        let cold = RangeBoard.read(messages: messages, fill: fill(120_000), quotas: [], model: nil, now: now.addingTimeInterval(120 + 3700), clock: clock)
        #expect(cold.cache?.isCold == true)
        #expect(cold.cache?.sentence == "The next send re-reads all 119.9k tokens at full price instead of from the cache.")
    }

    @Test("The footprint chart marks a refill and projects the next three turns")
    func footprint() throws {
        let messages = conversation([100_000, 110_000, 120_000, 130_000, 20_000, 30_000, 40_000, 50_000, 60_000])
        let board = RangeBoard.read(messages: messages, fill: fill(60_000), quotas: [], model: "claude-sonnet-5-5", now: now, clock: clock)
        let chart = try #require(board.footprint)
        #expect(chart.bars.filter { $0.kind == .refill }.count == 1)
        #expect(chart.bars.filter { $0.kind == .projected }.count == 3)
        #expect(chart.dangerLine == ContextFill.dangerAt)
    }
}

@Suite("The notification")
struct RunningLowTests {
    private func account(_ used: Double, resetsAt: Date, label: String = "5-hour session", key: String = "session") -> [UsageQuota] {
        [claude([UsageQuota.Gauge(key: key, label: label, fraction: used, resetsAt: resetsAt, trustedReset: true)])]
    }

    private let reset = now.addingTimeInterval(2 * hour + 47 * 60)

    @Test("A window on course to run out is announced once, in words that say when and how much sooner than the reset")
    func once() {
        var ledger = RunningLowLedger()
        let first = RunningLow.decide(quotas: account(0.62, resetsAt: reset), ledger: &ledger, now: now, clock: clock)
        #expect(first.count == 1)
        #expect(first.first?.title == "Claude 5-hour session is running low")
        #expect(first.first?.body == "At this pace it runs out in 1h 21m, 1h 25m before it resets.")
        let again = RunningLow.decide(quotas: account(0.63, resetsAt: reset), ledger: &ledger, now: now.addingTimeInterval(60), clock: clock)
        #expect(again.isEmpty)
    }

    @Test("A wobble does not ring twice; half an hour comfortably under the limit re-arms it")
    func rearm() {
        var ledger = RunningLowLedger()
        _ = RunningLow.decide(quotas: account(0.62, resetsAt: reset), ledger: &ledger, now: now, clock: clock)

        let calmAt = now.addingTimeInterval(600)
        #expect(RunningLow.decide(quotas: account(0.30, resetsAt: reset), ledger: &ledger, now: calmAt, clock: clock).isEmpty)
        let wobble = calmAt.addingTimeInterval(600)
        #expect(RunningLow.decide(quotas: account(0.80, resetsAt: reset), ledger: &ledger, now: wobble, clock: clock).isEmpty)

        let calmAgain = wobble.addingTimeInterval(60)
        _ = RunningLow.decide(quotas: account(0.31, resetsAt: reset), ledger: &ledger, now: calmAgain, clock: clock)
        let later = calmAgain.addingTimeInterval(RunningLow.calmFor + 60)
        _ = RunningLow.decide(quotas: account(0.33, resetsAt: reset), ledger: &ledger, now: later, clock: clock)
        let hot = later.addingTimeInterval(60)
        #expect(RunningLow.decide(quotas: account(0.80, resetsAt: reset), ledger: &ledger, now: hot, clock: clock).count == 1)
    }

    @Test("A window that resets is a different window")
    func newWindow() {
        var ledger = RunningLowLedger()
        _ = RunningLow.decide(quotas: account(0.62, resetsAt: reset), ledger: &ledger, now: now, clock: clock)
        let nextReset = reset.addingTimeInterval(5 * hour)
        let later = now.addingTimeInterval(5 * hour)
        #expect(RunningLow.decide(quotas: account(0.62, resetsAt: nextReset), ledger: &ledger, now: later, clock: clock).count == 1)
    }

    @Test("Only a window that meters the whole account is announced")
    func accountWideOnly() {
        var ledger = RunningLowLedger()
        let scoped = account(0.71, resetsAt: now.addingTimeInterval(63 * hour), label: "Weekly · Opus", key: "weekly_scoped")
        #expect(RunningLow.decide(quotas: scoped, ledger: &ledger, now: now, clock: clock).isEmpty)
    }
}

@Suite("The other surfaces that wear a pace")
struct RangeSurfacesTests {
    @Test("Home says one line, for the earliest window that will run out, and nothing otherwise")
    func homeLine() {
        #expect(
            RangeHome.line(quotas: [busyAccount], now: now, clock: clock)
                == "Claude 5-hour session runs out in 1h 21m")
        let calm = claude([gauge("weekly_all", "Weekly · all models", used: 0.38, resetsIn: 63 * hour)])
        #expect(RangeHome.line(quotas: [calm], now: now, clock: clock) == nil)
    }

    @Test("The quota strip's line for a provider is the window that is news, and carries its pace")
    func stripLine() throws {
        let glance = QuotaGlance.make(from: [("arch", busyAccount)], answeredAt: now, now: now, clock: clock)
        let line = try #require(glance.lines.first { $0.kind == .window })
        #expect(line.text.contains("5-hour session"))
        #expect(line.tone == .warn)
        #expect(line.row?.news?.lead == "Wall")
        #expect(line.row?.tailIsNews == true)
    }

    @Test("A widget row carries its tick and the wall's time, and an on-pace row stays calm")
    func widgetRows() throws {
        let busy = WidgetQuota(
            providerName: "Claude", subtitle: "Max", isLive: true,
            gauges: [
                WidgetQuota.Gauge(label: "5-hour session", fraction: 0.62, resetsAt: now.addingTimeInterval(2 * hour + 47 * 60)),
                WidgetQuota.Gauge(label: "Weekly · all models", fraction: 0.38, resetsAt: now.addingTimeInterval(63 * hour)),
            ])
        let glance = WidgetGlance.make(quotas: [busy], updatedAt: now, now: now)
        let session = try #require(glance.rows.first { $0.label == "5-hour session" })
        #expect(session.tone == .warn)
        #expect(session.wallChip != nil)
        #expect(session.pace?.tailIsNews == true)
        let weekly = try #require(glance.rows.first { $0.label == "Weekly · all models" })
        #expect(weekly.tone == .ok)
        #expect(weekly.wallChip == nil)
        #expect(weekly.pace?.tailIsNews == false)
        #expect(glance.headline.contains("Wall"))
    }

    @Test("Home's status carries the range line and speaks it")
    func homeStatus() {
        let status = HomeStatus(sentence: "All quiet", detail: "Nothing running", tone: .quiet, range: "Claude 5-hour session runs out in 1h 21m")
        #expect(status.spoken == "All quiet. Nothing running. Claude 5-hour session runs out in 1h 21m")
    }
}
