import CGtkShim
import Foundation
import TailscodeCore

/// Paints `AnalyticsShare.Card` into a PNG through the shim's cairo/pango path. Geometry and
/// every word are Core's; this only packs the blocks into the C call and frees the result.
enum AnalyticsCardRenderer {
    static func png(_ share: AnalyticsShare, scale: Double = 2) -> Data? {
        let source = MatrixTheme.palette
        let palette = AnalyticsShare.Palette(
            canvas: source.canvas, raised: source.canvasRaised, rule: source.rule,
            text: source.text, textDim: source.textDim, accent: source.accent,
            info: source.info, warn: source.warn, special: source.special,
            onAccent: source.onAccent)
        let card = AnalyticsShare.Card(
            blocks: share.card.blocks, palette: palette, height: share.card.height)
        return render(card, scale: scale)
    }

    private static func render(_ card: AnalyticsShare.Card, scale: Double) -> Data? {
        var kinds: [String] = []
        var a: [String] = []
        var b: [String] = []
        var c: [String] = []
        var d0: [Double] = []
        var i0: [Int32] = []
        func push(
            _ kind: String, _ first: String = "", _ second: String = "", _ third: String = "",
            number: Double = 0, flag: Int32 = 0
        ) {
            kinds.append(kind)
            a.append(first)
            b.append(second)
            c.append(third)
            d0.append(number)
            i0.append(flag)
        }

        for block in card.blocks {
            let lines = Int32(AnalyticsShare.Card.lines(block))
            switch block {
            case .brand(let text): push("brand", text)
            case .kicker(let text): push("kicker", text)
            case .hero(let text): push("hero", text)
            case .body(let text): push("body", text, flag: lines)
            case .dim(let text): push("dim", text, flag: lines)
            case .trend(let text, let tone):
                let toneFlag: Int32 = {
                    switch tone {
                    case .up: return 0
                    case .down: return 1
                    case .flat: return 2
                    }
                }()
                push("trend", text, flag: toneFlag)
            case .daily(let chart):
                push(
                    "daily",
                    chart.bars.map { String($0.share) }.joined(separator: ","),
                    chart.bars.map { $0.isToday ? "1" : "0" }.joined(separator: ","),
                    chart.bars.map { $0.isEmpty ? "1" : "0" }.joined(separator: ","))
                push("axis", chart.leading, chart.trailing)
            case .weekday(let bars):
                push(
                    "weekday",
                    bars.map { String($0.share) }.joined(separator: ","),
                    bars.map { _ in "0" }.joined(separator: ","),
                    bars.map { $0.isEmpty ? "1" : "0" }.joined(separator: ","))
            case .section(let text): push("section", text)
            case .meter(let meter):
                push(
                    "meter", meter.label, meter.detail, meter.money ?? "", number: meter.share,
                    flag: meter.hot ? 1 : 0)
            case .record(let record):
                push("record", record.glyph, record.caption, record.value)
            case .insight(let text):
                push("insight", AnalyticsShare.Card.insightPrefix + text, flag: lines)
            case .rule: push("rule")
            case .foot(let text): push("foot", text, flag: lines)
            case .spacer(let gap): push("spacer", number: gap)
            }
        }
        let count = kinds.count
        let d1 = [Double](repeating: 0, count: count)

        return kinds.withCStrings { kindPtrs in
            a.withCStrings { aPtrs in
                b.withCStrings { bPtrs in
                    c.withCStrings { cPtrs in
                        d0.withUnsafeBufferPointer { d0Buf in
                            d1.withUnsafeBufferPointer { d1Buf in
                                i0.withUnsafeBufferPointer { i0Buf in
                                    var length: gsize = 0
                                    let palette = card.palette
                                    guard
                                        let bytes = tailscode_analytics_card_png(
                                            Int32(AnalyticsShare.Card.width.rounded()),
                                            Int32(card.height.rounded()),
                                            scale,
                                            AnalyticsShare.Card.pad,
                                            palette.canvas, palette.raised, palette.rule,
                                            palette.text, palette.textDim, palette.accent,
                                            palette.info, palette.warn, palette.special,
                                            kindPtrs, aPtrs, bPtrs, cPtrs,
                                            d0Buf.baseAddress, d1Buf.baseAddress,
                                            i0Buf.baseAddress, Int32(count), &length),
                                        length > 0
                                    else { return nil }
                                    defer { g_free(bytes) }
                                    return Data(bytes: bytes, count: Int(length))
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

extension Array where Element == String {
    fileprivate func withCStrings<R>(_ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R) -> R {
        let cStrings = map { strdup($0) }
        defer { for pointer in cStrings { free(pointer) } }
        let pointers: [UnsafePointer<CChar>?] = cStrings.map { UnsafePointer($0) }
        return pointers.withUnsafeBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }
}
