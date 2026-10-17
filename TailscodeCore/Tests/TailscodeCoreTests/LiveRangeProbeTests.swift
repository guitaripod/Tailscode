import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// Runs only against a real bridge and one of its conversations, and prints what the range reads:
/// `RANGE_PROBE_BRIDGE=http://100.91.211.44:4098 RANGE_PROBE_SESSION=<id> swift test --filter LiveRangeProbeTests`.
/// It asserts nothing; the numbers are for a person to hold against the conversation they came from.
@Suite("Live range probe")
struct LiveRangeProbeTests {
    @Test("Reads a real transcript and real quotas")
    func probe() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["RANGE_PROBE_BRIDGE"], let session = env["RANGE_PROBE_SESSION"],
            let url = URL(string: base)
        else { return }
        let backend = ClaudeCodeBackend(config: ServerConfig(baseURL: url))
        let messages = try await backend.transcript(for: session).messages
        let quota = try await backend.usageQuota()
        let now = Date()
        let model = messages.last(where: { $0.role == .assistant })?.modelID
        let fill = ContextFill.read(messages: messages, sessionModel: model, catalog: ClaudeCodeBackend.models)
        print("PROBE messages", messages.count, "model", model ?? "-")
        print("PROBE fill", fill?.badge ?? "-", "window", fill?.window ?? 0)
        let board = RangeBoard.read(
            messages: messages, fill: fill, quotas: quota.map { [$0] } ?? [], model: model, now: now)
        print("PROBE verdict:", board.verdict.headline, "|", board.verdict.detail ?? "-")
        for row in board.rows + board.elsewhere {
            print("PROBE row", row.title, row.detail, row.amount, "fill", String(format: "%.2f", row.fill),
                  "tick", row.tick.map { String(format: "%.2f", $0) } ?? "-",
                  "tail", row.tailEnd.map { String(format: "%.2f", $0) } ?? "-",
                  "news", row.news.map { "\($0.lead) \($0.body)" } ?? row.note ?? "-")
        }
        if let cache = board.cache { print("PROBE cache", cache.title, cache.trailing, cache.sentence ?? "-") } else { print("PROBE cache none") }
        if let c = board.composition {
            print("PROBE composition total", c.total, c.slices.map { "\($0.label) \($0.tokens) (\(Int($0.share * 100))%)" }.joined(separator: ", "))
            for item in c.items { print("PROBE item", item.tool, item.detail ?? "-", item.tokens, "turn", item.turn) }
        }
        if let f = board.footprint { print("PROBE footprint bars", f.bars.count, "refills", f.bars.filter { $0.kind == .refill }.count) }
        let burn = fill.flatMap { ContextBurn.read(messages: messages, fill: $0, wholeConversation: true) }
        print("PROBE burn", "epochTurns", burn?.epochTurns ?? 0, "growth", burn?.growth ?? 0, "left", burn?.turnsLeft.map(String.init) ?? "-")
        let last = messages.last(where: { $0.role == .assistant })
        print("PROBE last", last?.createdAt.timeIntervalSinceNow ?? 0, "dur", last?.duration ?? -1, "ctx", last?.context.map { "\($0.total) lifetime \($0.cacheLifetime ?? -1)" } ?? "-")
    }
}
