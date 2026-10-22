import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

private let hour: TimeInterval = 3600
private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func gauge(
    _ key: String, _ label: String, used: Double, resetsIn: TimeInterval?, trusted: Bool = true
) -> UsageQuota.Gauge {
    UsageQuota.Gauge(
        key: key, label: label, fraction: used, resetsAt: resetsIn.map { now.addingTimeInterval($0) },
        trustedReset: trusted)
}

@Suite("How long a quota window is")
struct QuotaWindowSpanTests {
    @Test("The span is read from the key or the label, in every spelling the bridges use")
    func spellings() {
        #expect(QuotaWindowSpan.read(key: "session", label: "5-hour session", resetsAt: nil) == 5 * hour)
        #expect(QuotaWindowSpan.read(key: "five_hour", label: "5-hour session", resetsAt: nil) == 5 * hour)
        #expect(QuotaWindowSpan.read(key: "rolling", label: "5-hour", resetsAt: nil) == nil)
        #expect(QuotaWindowSpan.read(key: "weekly_all", label: "Weekly · all models", resetsAt: nil) == 168 * hour)
        #expect(QuotaWindowSpan.read(key: "seven_day", label: "Weekly · Opus", resetsAt: nil) == 168 * hour)
        #expect(QuotaWindowSpan.read(key: "weekly", label: "Weekly credits", resetsAt: nil) == 168 * hour)
        #expect(QuotaWindowSpan.read(key: "daily", label: "Daily", resetsAt: nil) == 24 * hour)
        #expect(QuotaWindowSpan.read(key: "extra_usage", label: "Extra usage credits", resetsAt: nil) == nil)
    }

    @Test("A month is the calendar month that ends at the reset, and needs a reset to be measured")
    func month() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let reset = calendar.date(from: DateComponents(year: 2026, month: 3, day: 1)) ?? now
        #expect(QuotaWindowSpan.read(key: "monthly", label: "Monthly", resetsAt: reset, calendar: calendar) == 28 * 24 * hour)
        #expect(QuotaWindowSpan.read(key: "monthly", label: "Monthly", resetsAt: nil, calendar: calendar) == nil)
    }
}

@Suite("Where a quota window is heading")
struct QuotaPaceTests {
    @Test("A window that states both ends is drawn flat, with no projected tail or ETA")
    func statedWindowHasNoProjection() {
        let gauge = UsageQuota.Gauge(
            key: "five_hour", label: "5-hour session", fraction: 0.4,
            resetsAt: now.addingTimeInterval(3 * hour), trustedReset: true,
            startsAt: now.addingTimeInterval(-2 * hour))
        let row = PaceRow.window(
            provider: "opencode go", slug: "opencode", gauge: gauge, now: now)

        #expect(row.tick == nil)
        #expect(row.tailEnd == nil)
        #expect(row.news == nil)
        #expect(row.detail.contains("→"))
    }

    @Test("Sixty-two percent of a five-hour window with 2h 47m left runs out in about 81 minutes")
    func sessionWillRunOut() throws {
        let pace = try #require(
            QuotaPace.read(gauge("session", "5-hour session", used: 0.62, resetsIn: 2 * hour + 47 * 60), now: now))
        #expect(abs(pace.elapsed - 0.4433) < 0.001)
        #expect(abs((pace.landing ?? 0) - 1.3985) < 0.001)
        guard case .willRunOut(let at) = pace.verdict else {
            Issue.record("expected a projected wall, got \(pace.verdict)")
            return
        }
        #expect(abs(at.timeIntervalSince(now) - 4891) < 2)
        #expect(abs((pace.slack ?? 0) - 5129) < 2)
        #expect(pace.tone == .attention)
        #expect(pace.isNews)
        #expect(pace.tailEnd == 1)
    }

    @Test("A week 62% through with 71% used lands past the limit; with 38% used it lands near 61%")
    func weeklyOnAndOffPace() throws {
        let opus = try #require(
            QuotaPace.read(gauge("seven_day", "Weekly · Opus", used: 0.71, resetsIn: 63 * hour), now: now))
        guard case .willRunOut(let at) = opus.verdict else {
            Issue.record("expected a projected wall, got \(opus.verdict)")
            return
        }
        #expect(abs(at.timeIntervalSince(now) / hour - 42.9) < 0.1)
        #expect(abs((opus.slack ?? 0) / hour - 20.1) < 0.1)

        let all = try #require(
            QuotaPace.read(gauge("weekly_all", "Weekly · all models", used: 0.38, resetsIn: 63 * hour), now: now))
        #expect(all.verdict == .onPace)
        #expect(abs((all.landing ?? 0) - 0.608) < 0.001)
        #expect(abs((all.tailEnd ?? 0) - 0.608) < 0.001)
        #expect(!all.isNews)
        #expect(all.tone == .quiet)
    }

    @Test("A window that has barely begun states no pace")
    func tooEarly() throws {
        let pace = try #require(
            QuotaPace.read(gauge("session", "5-hour session", used: 0.04, resetsIn: 4 * hour + 48 * 60), now: now))
        #expect(pace.verdict == .tooEarly)
        #expect(pace.landing == nil)
        #expect(pace.tailEnd == nil)
        #expect(abs(pace.elapsed - 0.04) < 0.001)
    }

    @Test("A full window is a wall that keeps its tick")
    func wall() throws {
        let pace = try #require(
            QuotaPace.read(gauge("session", "5-hour session", used: 1.0, resetsIn: hour + 12 * 60), now: now))
        guard case .wall(let resumes) = pace.verdict else {
            Issue.record("expected a wall, got \(pace.verdict)")
            return
        }
        #expect(resumes == now.addingTimeInterval(hour + 12 * 60))
        #expect(pace.tone == .danger)
        #expect(pace.landing == nil)
    }

    @Test("Landing near the limit is close to the line; reaching it a moment before the reset is too")
    func closeToTheLine() throws {
        let near = try #require(
            QuotaPace.read(gauge("weekly", "Weekly", used: 0.5, resetsIn: 84 * hour), now: now))
        #expect(near.verdict == .closeToTheLine)
        #expect(near.tone == .attention)
        let late = try #require(
            QuotaPace.read(gauge("weekly", "Weekly", used: 0.52, resetsIn: 84 * hour), now: now))
        #expect(late.verdict == .closeToTheLine)
        #expect(late.wallAt != nil)
        let early = try #require(
            QuotaPace.read(gauge("weekly", "Weekly", used: 0.55, resetsIn: 84 * hour), now: now))
        guard case .willRunOut = early.verdict else {
            Issue.record("expected a projected wall, got \(early.verdict)")
            return
        }
    }

    @Test("A reset the provider only estimates makes the pace approximate")
    func approximate() throws {
        let pace = try #require(
            QuotaPace.read(gauge("seven_day", "Weekly · Opus", used: 0.71, resetsIn: 63 * hour, trusted: false), now: now))
        #expect(pace.approximate)
    }

    @Test("No pace without a window length, a standing reset, or a fill to pace")
    func noPace() {
        #expect(QuotaPace.read(gauge("rolling", "5-hour", used: 0.6, resetsIn: 2 * hour), now: now) == nil)
        #expect(QuotaPace.read(gauge("session", "5-hour session", used: 0.6, resetsIn: nil), now: now) == nil)
        #expect(QuotaPace.read(gauge("session", "5-hour session", used: 0.6, resetsIn: -60), now: now) == nil)
        #expect(QuotaPace.read(gauge("session", "5-hour session", used: 0.6, resetsIn: 9 * hour), now: now) == nil)
        let balance = UsageQuota.Gauge(
            key: "balance", label: "Balance", fraction: 0, resetsAt: nil, trustedReset: false, usedUSD: 104.32)
        #expect(QuotaPace.read(balance, now: now) == nil)
    }

    @Test("A recent rate outranks the average: a bursty start that has gone quiet is on pace now")
    func recentRate() throws {
        var trail = QuotaTrail()
        let g = gauge("seven_day", "Weekly · all models", used: 0.71, resetsIn: 63 * hour)
        let id = QuotaTrail.identity(provider: "Claude", gauge: g)
        trail.note(0.70, id: id, at: now.addingTimeInterval(-30 * hour))
        trail.note(0.705, id: id, at: now.addingTimeInterval(-12 * hour))
        trail.note(0.71, id: id, at: now.addingTimeInterval(-1 * hour))
        let steady = try #require(QuotaPace.read(g, provider: "Claude", now: now, trail: trail))
        guard case .recent = steady.basis else {
            Issue.record("expected the recent rate, got \(steady.basis)")
            return
        }
        #expect(steady.verdict == .onPace)
        let averaged = try #require(QuotaPace.read(g, provider: "Claude", now: now))
        guard case .willRunOut = averaged.verdict else {
            Issue.record("the average alone would have rung, got \(averaged.verdict)")
            return
        }
    }
}

@Suite("What this device has seen each quota window do")
struct QuotaTrailTests {
    @Test("A reading is kept when it moved or when an hour has passed, and a still window leaves an anchor")
    func coalescing() {
        var trail = QuotaTrail()
        let first = trail.note(0.10, id: "a", at: now)
        let still = trail.note(0.10, id: "a", at: now.addingTimeInterval(60))
        let drift = trail.note(0.105, id: "a", at: now.addingTimeInterval(120))
        let moved = trail.note(0.12, id: "a", at: now.addingTimeInterval(180))
        let anchored = trail.note(0.12, id: "a", at: now.addingTimeInterval(180 + hour))
        #expect(first && !still && !drift && moved && anchored)
        #expect(trail.series["a"]?.count == 3)
    }

    @Test("A fall is a reset and forgets the window before it")
    func reset() {
        var trail = QuotaTrail()
        trail.note(0.80, id: "a", at: now)
        trail.note(0.90, id: "a", at: now.addingTimeInterval(600))
        trail.note(0.05, id: "a", at: now.addingTimeInterval(1200))
        #expect(trail.series["a"]?.count == 1)
        #expect(trail.series["a"]?.first?.value == 0.05)
    }

    @Test("A week is kept and no more")
    func horizon() {
        var trail = QuotaTrail()
        trail.note(0.10, id: "a", at: now)
        trail.note(0.50, id: "a", at: now.addingTimeInterval(8 * 86400))
        #expect(trail.series["a"]?.count == 1)
    }

    @Test("The recent rate is interpolated to the start of the stretch, and refuses a hole")
    func recentRate() throws {
        var trail = QuotaTrail()
        trail.note(0.10, id: "a", at: now.addingTimeInterval(-2 * hour))
        trail.note(0.30, id: "a", at: now.addingTimeInterval(-hour / 2))
        let measured = try #require(trail.recentRate(id: "a", now: now, current: 0.40, within: hour))
        #expect(abs(measured.over - hour) < 1)
        #expect(abs(measured.rate * hour - (0.40 - (0.10 + 0.20 * (1.0 / 1.5)))) < 0.001)

        var sparse = QuotaTrail()
        sparse.note(0.10, id: "a", at: now.addingTimeInterval(-10 * hour))
        sparse.note(0.30, id: "a", at: now.addingTimeInterval(-hour / 2))
        let anchored = try #require(sparse.recentRate(id: "a", now: now, current: 0.40, within: hour))
        #expect(abs(anchored.over - hour / 2) < 1)

        #expect(trail.recentRate(id: "a", now: now, current: 0.05, within: hour) == nil)
        #expect(trail.recentRate(id: "missing", now: now, current: 0.4, within: hour) == nil)
    }

    @Test("A balance's spend is read after a day, and a top-up starts it again")
    func balance() throws {
        var trail = QuotaTrail()
        trail.noteBalance(120, id: "b", at: now.addingTimeInterval(-3 * 86400))
        trail.noteBalance(104.32, id: "b", at: now)
        let spend = try #require(trail.spendPerDay(id: "b", balance: 104.32, now: now))
        #expect(abs(spend.perDay - 5.2267) < 0.001)
        #expect(trail.spendPerDay(id: "b", balance: 104.32, now: now.addingTimeInterval(-86400 * 2.5)) == nil)

        trail.noteBalance(200, id: "b", at: now.addingTimeInterval(60))
        #expect(trail.series["b"]?.count == 1)
    }
}
