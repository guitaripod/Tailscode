import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// One busy afternoon, for looking at the range without an account that happens to be in it: a
/// conversation that has been filling its window turn by turn, and a Claude account whose
/// five-hour session will not last while its week is fine. The numbers are the ones in the mocks.
enum RangeDemo {
    static let model = "claude-sonnet-5-5"
    static let hour: TimeInterval = 3600

    static func messages(now: Date) -> [ChatMessage] {
        let footprints = [100_000, 110_000, 121_000, 130_000, 142_000, 148_000]
        return footprints.enumerated().flatMap { index, footprint -> [ChatMessage] in
            let offset = Double(index) * 600 - 3_600
            let ask = ChatMessage(
                id: "u\(index)", role: .user, agentType: .claudeCode,
                parts: [MessagePart(id: "t", kind: .text(String(repeating: "q", count: 400)))],
                createdAt: now.addingTimeInterval(offset))
            let answer = ChatMessage(
                id: "a\(index)", role: .assistant, agentType: .claudeCode,
                parts: [
                    read("r\(index)", file: "UsageAnalytics.swift", output: 6_000 + index * 9_000),
                    MessagePart(id: "t", kind: .text(String(repeating: "a", count: 1_200))),
                ],
                createdAt: now.addingTimeInterval(offset + 5), modelID: model,
                context: MessageUsage(
                    input: 10, output: 90, cacheRead: footprint - 100, cacheLifetime: 3_600),
                duration: 60)
            return [ask, answer]
        }
    }

    static func fill() -> ContextFill {
        ContextFill(
            used: 148_000, window: 200_000, model: model, basis: .reported,
            tiers: MessageUsage(input: 3_000, output: 2_000, cacheRead: 128_000, cacheWrite: 15_000))
    }

    static func account(now: Date) -> UsageQuota {
        func gauge(_ key: String, _ label: String, used: Double, resetsIn: TimeInterval)
            -> UsageQuota.Gauge
        {
            UsageQuota.Gauge(
                key: key, label: label, fraction: used,
                resetsAt: now.addingTimeInterval(resetsIn), trustedReset: true)
        }
        return UsageQuota(
            providerName: "Claude", subtitle: "Max 5x", source: "api · live", live: true,
            gauges: [
                gauge("session", "5-hour session", used: 0.62, resetsIn: 2 * hour + 47 * 60),
                gauge("weekly_all", "Weekly · all models", used: 0.38, resetsIn: 63 * hour),
                gauge("weekly_scoped", "Weekly · Opus", used: 0.71, resetsIn: 63 * hour),
            ], details: [])
    }

    static func balance() -> UsageQuota {
        UsageQuota(
            providerName: "DeepSeek", subtitle: "prepaid", source: "api.deepseek.com", live: true,
            gauges: [
                UsageQuota.Gauge(
                    key: "balance", label: "Balance", fraction: 0, resetsAt: nil,
                    trustedReset: false, usedUSD: 104.32, limitUSD: nil, currency: "USD")
            ], details: [])
    }

    static func reports(now: Date) -> [(String, UsageQuota)] {
        [("arch", account(now: now)), ("", balance())]
    }

    static func reading(now: Date, clock: RangeClock = .current) -> RangePanel.Reading {
        let fill = fill()
        let board = RangeBoard.read(
            messages: messages(now: now), fill: fill, quotas: [account(now: now)], model: model,
            now: now, clock: clock)
        return RangePanel.Reading(board: board, fill: fill)
    }

    private static func read(_ id: String, file: String, output: Int) -> MessagePart {
        MessagePart(
            id: id,
            kind: .tool(
                ToolCall(
                    id: id, name: "Read", status: .completed,
                    input: .object(["file_path": .string("/src/\(file)")]),
                    output: String(repeating: "x", count: output))))
    }
}

extension MainWindow {
    /// `range=sheet` opens the Range sheet on the demo afternoon, `range=usage` the usage board with
    /// the same account (and a prepaid balance), both without asking any server.
    func driveRange(_ argument: String, parent: UnsafeMutablePointer<GtkWidget>?) {
        let now = Date()
        switch argument {
        case "sheet":
            RangePanel.present(
                parent: parent, title: "Fix the quota parser", compact: {}, goTo: nil,
                read: { RangeDemo.reading(now: Date()) })
        case "usage":
            let parentBits = UInt(bitPattern: parent)
            Task {
                await UsagePanel.present(
                    parent: UnsafeMutableRawPointer(bitPattern: parentBits).map { ptr($0) },
                    initial: RangeDemo.reports(now: now),
                    refresh: { RangeDemo.reports(now: Date()) })
            }
        default:
            FileHandle.standardOutput.write(Data("RANGE unknown \(argument)\n".utf8))
        }
    }
}
