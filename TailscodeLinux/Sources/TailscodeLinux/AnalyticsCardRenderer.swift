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
        let blocks = card.blocks
        let count = blocks.count
        var kinds: [String] = []
        var a: [String] = []
        var b: [String] = []
        var c: [String] = []
        var d0 = [Double](repeating: 0, count: count)
        var d1 = [Double](repeating: 0, count: count)
        var i0 = [Int32](repeating: 0, count: count)

        for (index, block) in blocks.enumerated() {
            switch block {
            case .brand(let text):
                kinds.append("brand"); a.append(text); b.append(""); c.append("")
            case .kicker(let text):
                kinds.append("kicker"); a.append(text); b.append(""); c.append("")
            case .hero(let text):
                kinds.append("hero"); a.append(text); b.append(""); c.append("")
            case .body(let text):
                kinds.append("body"); a.append(text); b.append(""); c.append("")
            case .dim(let text):
                kinds.append("dim"); a.append(text); b.append(""); c.append("")
            case .trend(let text, let tone):
                kinds.append("trend"); a.append(text); b.append(""); c.append("")
                switch tone {
                case .up: i0[index] = 0
                case .down: i0[index] = 1
                case .flat: i0[index] = 2
                }
            case .daily(let bars):
                kinds.append("daily")
                a.append(bars.map { String($0.share) }.joined(separator: ","))
                b.append(bars.map { $0.isToday ? "1" : "0" }.joined(separator: ","))
                c.append(bars.map { $0.isEmpty ? "1" : "0" }.joined(separator: ","))
            case .weekday(let bars):
                kinds.append("weekday")
                a.append(bars.map { String($0.share) }.joined(separator: ","))
                b.append(bars.map { _ in "0" }.joined(separator: ","))
                c.append(bars.map { $0.isEmpty ? "1" : "0" }.joined(separator: ","))
            case .section(let text):
                kinds.append("section"); a.append(text); b.append(""); c.append("")
            case .meter(let meter):
                kinds.append("meter")
                a.append(meter.label)
                b.append(meter.detail)
                c.append(meter.money ?? "")
                d0[index] = meter.share
                i0[index] = meter.hot ? 1 : 0
            case .record(let record):
                kinds.append("record")
                a.append(record.glyph)
                b.append(record.title)
                c.append(record.value)
            case .insight(let text):
                kinds.append("insight"); a.append(text); b.append(""); c.append("")
            case .rule:
                kinds.append("rule"); a.append(""); b.append(""); c.append("")
            case .foot(let text):
                kinds.append("foot"); a.append(text); b.append(""); c.append("")
            case .spacer(let gap):
                kinds.append("spacer"); a.append(""); b.append(""); c.append("")
                d0[index] = gap
            }
        }

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
        var pointers: [UnsafePointer<CChar>?] = cStrings.map { UnsafePointer($0) }
        return pointers.withUnsafeBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }
}
