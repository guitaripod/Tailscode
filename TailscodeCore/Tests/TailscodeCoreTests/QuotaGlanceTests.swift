import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Quota glance")
struct QuotaGlanceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func quota(
        _ provider: String, _ windows: [(String, Double)], live: Bool = true,
        source: String = "test", resetsIn: TimeInterval? = 7_200
    ) -> UsageQuota {
        UsageQuota(
            providerName: provider, subtitle: "", source: source, live: live,
            gauges: windows.map {
                UsageQuota.Gauge(
                    key: $0.0.lowercased(), label: $0.0, fraction: $0.1,
                    resetsAt: resetsIn.map { now.addingTimeInterval($0) }, trustedReset: true)
            },
            details: [])
    }

    private func balance(_ total: Double) -> UsageQuota {
        UsageQuota(
            providerName: "DeepSeek", subtitle: "", source: "api.deepseek.com", live: true,
            gauges: [
                UsageQuota.Gauge(
                    key: "balance", label: "Balance", fraction: total > 0 ? 0 : 1, resetsAt: nil,
                    trustedReset: false, usedUSD: total, limitUSD: nil, currency: "USD")
            ],
            details: [])
    }

    private func glance(_ reports: [(String, UsageQuota)], answeredAt: Date? = nil) -> QuotaGlance {
        QuotaGlance.make(from: reports, answeredAt: answeredAt ?? now, now: now)
    }

    @Test("A quiet account says so, and names the window closest to mattering")
    func quiet() {
        let strip = glance([("arch", quota("Claude", [("Weekly", 0.3), ("Session", 0.1)]))])
        #expect(strip.lines.count == 1)
        let line = try! #require(strip.lines.first)
        #expect(line.tone == .ok)
        #expect(line.text.contains("Weekly"))
        #expect(line.trailing == "30%")
        #expect(line.fraction == 0.3)
        #expect(line.slug == "claude")
    }

    @Test("Warm windows read one line each, tightest first, and the healthy stay home")
    func warm() {
        let strip = glance([
            ("arch", quota("Claude", [("Weekly", 0.85), ("Session", 0.2)])),
            ("arch", quota("Grok", [("Weekly credits", 0.72)])),
        ])
        #expect(strip.lines.count == 2)
        #expect(strip.lines[0].trailing == "85%")
        #expect(strip.lines[1].trailing == "72%")
        #expect(strip.lines.allSatisfy { $0.tone == .warn })
    }

    @Test("A wall leads, and is answered by where there is still room")
    func wall() {
        let strip = glance([
            ("arch", quota("Claude", [("Weekly", 1.0), ("Session", 0.2)])),
            ("arch", quota("Grok", [("Weekly credits", 0.4)])),
        ])
        #expect(strip.lines.count == 2)
        #expect(strip.lines[0].tone == .danger)
        #expect(strip.lines[0].trailing == Localized.text("Used up"))
        #expect(strip.lines[0].fraction == 1)
        #expect(strip.lines[1].tone == .ok)
        #expect(strip.lines[1].text.contains("Grok"))
        #expect(strip.lines[1].trailing == "40%")
    }

    @Test("A wall around one model leaves its provider open")
    func scopedWall() {
        let strip = glance([
            ("arch", quota("Claude", [("Opus weekly", 1.0), ("Weekly", 0.35)]))
        ])
        #expect(strip.lines[0].tone == .danger)
        #expect(strip.lines[1].tone == .ok)
        #expect(strip.lines[1].text.contains("Weekly"))
    }

    @Test("Nowhere left to send is a state with its own words")
    func shutOut() {
        let strip = glance([
            ("arch", quota("Claude", [("Weekly", 1.0)])),
            ("arch", quota("Grok", [("Weekly credits", 1.0)])),
        ])
        #expect(strip.lines.last?.text == Localized.text("Nothing left to send with"))
        #expect(strip.lines.last?.tone == .danger)
    }

    @Test("A prepaid balance left standing is named as the last way through")
    func onlyBalanceLeft() {
        let strip = glance([
            ("arch", quota("Claude", [("Weekly", 1.0)])),
            ("", balance(13.42)),
        ])
        #expect(strip.lines.contains { $0.text == Localized.text("Only the prepaid balance is left") })
        let money = try! #require(strip.lines.last)
        #expect(money.kind == .balance)
        #expect(money.trailing == "$13.42")
        #expect(money.fraction == nil)
    }

    @Test("An empty balance is the wall it is")
    func emptyBalance() {
        let strip = glance([("", balance(0))])
        #expect(strip.lines.count == 1)
        #expect(strip.lines[0].tone == .danger)
        #expect(strip.lines[0].trailing == Localized.text("Empty"))
    }

    @Test("Walls past the strip's room are counted, never dropped")
    func overflow() {
        let strip = glance([
            (
                "arch",
                quota("Claude", [("Weekly", 1.0), ("Session", 1.0), ("Opus weekly", 1.0)])
            ),
            ("arch", quota("Grok", [("Weekly credits", 1.0)])),
        ])
        #expect(strip.lines.filter { $0.kind == .window }.count == QuotaGlance.maxWindows)
        #expect(strip.lines.contains { $0.kind == .notice && $0.text.contains("1") })
    }

    @Test("A window whose reset has already passed is not a wall")
    func expiredWall() {
        let stale = quota("Claude", [("Weekly", 1.0)], resetsIn: -60)
        let strip = glance([("arch", stale)])
        #expect(strip.lines.allSatisfy { $0.tone != .danger })
    }

    @Test("A reading that is not live says so before it says anything else")
    func staleReading() {
        let strip = glance(
            [("arch", quota("Claude", [("Weekly", 0.4)], live: false))],
            answeredAt: now.addingTimeInterval(-1_800))
        #expect(strip.lines.first?.kind == .notice)
        #expect(strip.lines.first?.tone == .warn)
        #expect(strip.lines.first?.text.contains("30m") == true)
    }

    @Test("A live reading nobody has refreshed in a while says how long it has been")
    func agingReading() {
        let fresh = glance(
            [("arch", quota("Claude", [("Weekly", 0.4)]))],
            answeredAt: now.addingTimeInterval(-60))
        #expect(fresh.lines.allSatisfy { $0.kind != .notice })
        let old = glance(
            [("arch", quota("Claude", [("Weekly", 0.4)]))],
            answeredAt: now.addingTimeInterval(-3_600))
        #expect(old.lines.first?.kind == .notice)
        #expect(old.lines.first?.tone == .warn)
    }

    @Test("An estimate names itself rather than posing as a cache")
    func estimated() {
        let strip = glance([
            (
                "arch",
                quota(
                    "opencode go", [("Weekly", 0.5)], live: false, source: "estimated · opencode.db")
            )
        ])
        #expect(strip.lines.first?.text == Localized.text("Estimated, not live"))
        #expect(strip.lines.first?.tone == .quiet)
    }

    @Test("A first poll still out is a state; a finished one with nothing is silence")
    func pending() {
        let asking = QuotaGlance.make(from: [], answeredAt: nil, now: now)
        #expect(asking.lines.count == 1)
        #expect(asking.lines[0].tone == .quiet)
        #expect(QuotaGlance.make(from: [], answeredAt: now, now: now).isEmpty)
    }

    @Test("The whole picture rides the hover, machines and provenance included")
    func tooltip() {
        let strip = glance([
            ("arch", quota("Claude", [("Weekly", 0.9)])),
            ("macbook", quota("Claude", [("Weekly", 0.95)])),
        ])
        #expect(strip.tooltip.contains("Claude"))
        #expect(strip.tooltip.contains("95%"))
        #expect(strip.tooltip.contains("arch"))
        #expect(strip.tooltip.contains("macbook"))
    }

    @Test("Every window line carries the fraction its bar is drawn from")
    func bars() {
        let strip = glance([("arch", quota("Claude", [("Weekly", 0.85)]))])
        #expect(strip.lines.allSatisfy { $0.kind != .window || $0.fraction != nil })
    }
}
