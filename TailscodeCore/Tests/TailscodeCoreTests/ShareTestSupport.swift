import Foundation
@testable import TailscodeCore

enum ShareTestSupport {
    typealias Block = AnalyticsShare.Block

    static func dump(_ block: Block) -> String {
        switch block {
        case .brand(let t): return "brand|\(t)"
        case .kicker(let t): return "kicker|\(t)"
        case .hero(let t): return "hero|\(t)"
        case .body(let t): return "body|\(t)"
        case .dim(let t): return "dim|\(t)"
        case .trend(let t, let tone): return "trend|\(t)|\(tone)"
        case .daily(let c):
            return "daily|"
                + c.bars.map { "\($0.share):\($0.isToday ? 1 : 0):\($0.isEmpty ? 1 : 0)" }
                .joined(separator: ",") + "|\(c.leading)|\(c.trailing)"
        case .weekday(let b):
            return "weekday|" + b.map { "\($0.share):\($0.isEmpty ? 1 : 0)" }.joined(separator: ",")
        case .section(let t): return "section|\(t)"
        case .meter(let m):
            return "meter|\(m.label)|\(m.detail)|\(m.money ?? "-")|\(m.share)|\(m.hot ? 1 : 0)"
        case .record(let r): return "record|\(r.glyph)|\(r.title)|\(r.value)|\(r.detail ?? "-")"
        case .insight(let t): return "insight|\(t)"
        case .rule: return "rule"
        case .foot(let t): return "foot|\(t)"
        case .spacer(let g): return "spacer|\(g)"
        case .stats(let s): return "stats|" + s.map { "\($0.value) \($0.label)" }.joined(separator: ",")
        }
    }

    static func fnv(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return hash
    }

    static func fingerprint(_ blocks: [Block]) -> (count: Int, hash: UInt64) {
        (blocks.count, fnv(blocks.map(dump).joined(separator: "\n")))
    }

    static var allSelections: [(String, [ShareModule])] {
        var out: [(String, [ShareModule])] = [("none", []), ("all", ShareModule.selectable)]
        for module in ShareModule.selectable { out.append((module.rawValue, [module])) }
        return out
    }
}
