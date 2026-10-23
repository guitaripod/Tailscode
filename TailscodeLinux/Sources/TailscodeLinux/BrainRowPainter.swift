import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// How one row of the step list is drawn, written once for every canvas that draws step rows: the
/// list beside the head and the rows a work line of the account unfolds into are the same pixels,
/// because they are this one painter given a row, a width and what the pointer is doing.
struct BrainRowPainter {
    /// What the pointer and the clipboard are doing to the rows, which a row paints.
    struct Touch {
        /// The row that said Copied a moment ago.
        var copiedID: String?
        /// The row whose Copy button the pointer is on.
        var copyHotID: String?
    }

    let fonts: BrainListFonts
    let input: ChatInput

    init(fonts: BrainListFonts, input: ChatInput = .pointer) {
        self.fonts = fonts
        self.input = input
    }

    /// The widest a step's title is drawn: a sentence, cut with an ellipsis beyond this.
    static let titleMax = 168.0

    var rowHeight: Double { NeuralStageMetrics.listRowHeight(input: input) }

    func copyRect(for row: NeuralStepList.Row, width: Double, touch: Touch) -> NeuralRect {
        let label = touch.copiedID == row.id ? BrainWords.copied : BrainWords.copy
        let size = BrainDraw.measure(label, fonts.status) + 18
        return NeuralRect(x: width - 6 - size, y: (row.height(input: input) - 24) / 2, width: size, height: 24)
    }

    func paintRow(
        _ cr: OpaquePointer, row: NeuralStepList.Row, previous: NeuralStepList.Row?,
        next: NeuralStepList.Row?, y: Double, height rowH: Double, width: Double, inks: BrainInks,
        isCursor: Bool, isHovered: Bool, pointerHere: Bool, alpha: Double, query: String, touch: Touch
    ) {
        let zone = inks.corrected(row.zone)
        cairo_save(cr)
        if row.status == .failed {
            BrainDraw.fill(cr, inks.cDanger, 0.08 * alpha)
            cairo_rectangle(cr, 0, y, width, rowH)
            cairo_fill(cr)
        }
        if isCursor {
            BrainDraw.fill(cr, inks.accent, 0.14 * alpha)
            cairo_rectangle(cr, 0, y, width, rowH)
            cairo_fill(cr)
        } else if isHovered {
            BrainDraw.fill(cr, inks.ink, 0.06 * alpha)
            cairo_rectangle(cr, 0, y, width, rowH)
            cairo_fill(cr)
        }
        BrainDraw.fill(cr, zone, alpha)
        cairo_rectangle(cr, 0, y, 3, rowH)
        cairo_fill(cr)
        if isCursor {
            BrainDraw.fill(cr, inks.accent, alpha)
            cairo_rectangle(cr, 3, y, 2, rowH)
            cairo_fill(cr)
            cairo_set_line_width(cr, 1)
            BrainDraw.roundedRect(cr, 0.5, y + 0.5, width - 1, rowH - 1, 2)
            BrainDraw.fill(cr, inks.accent, 0.9 * alpha)
            cairo_stroke(cr)
        }
        paintBracket(cr, row: row, previous: previous, next: next, y: y, height: rowH, inks: inks, alpha: alpha)
        let said = row.isSaid
        let lineBand = said ? 28.0 : rowH
        let mid = y + lineBand / 2
        if said {
            BrainDraw.quoteGlyph(cr, cx: 34, cy: y + 14, color: inks.accent, alpha: alpha, font: fonts.title)
        } else {
            BrainDraw.zoneGlyph(cr, zone: row.zone, cx: 34, cy: mid, color: zone, alpha: alpha)
        }
        BrainDraw.line(
            cr, "\(row.number)", font: fonts.number, lineHeight: fonts.lineHeight, x: 51, top: y,
            height: lineBand, width: 24, align: 2, color: inks.dim, alpha: alpha)
        let statusLeft = paintStatus(
            cr, row: row, y: y, height: rowH, width: width, inks: inks, alpha: alpha,
            showCopy: pointerHere || touch.copiedID == row.id, touch: touch)
        let textLimit = statusLeft - 12
        if row.kind == .tool {
            let titleWidth = min(BrainDraw.measure(row.title, fonts.title), Self.titleMax)
            BrainDraw.line(
                cr, row.title, font: fonts.title, lineHeight: fonts.lineHeight, x: 83, top: y, height: rowH,
                width: titleWidth, color: inks.ink, alpha: alpha)
            let argumentX = 83 + titleWidth + 10
            let room = max(0, textLimit - argumentX)
            let chars = max(0, Int(room / fonts.monoWidth))
            let shown = row.argument(fittingChars: chars)
            if !query.isEmpty {
                highlight(cr, text: shown, x: argumentX, y: y, query: query, inks: inks, alpha: alpha)
            }
            BrainDraw.line(
                cr, shown, font: fonts.argument, lineHeight: fonts.lineHeight, x: argumentX, top: y,
                height: rowH, width: room, color: inks.dim, alpha: alpha)
        } else if said {
            let room = max(0, textLimit - 83)
            let top = y + max(2, (rowH - 2 * fonts.saidLineHeight) / 2)
            _ = tailscode_text_draw(
                cr, row.lines.joined(separator: " "), fonts.saidLine, 83, top, room, 0, 2, inks.ink.red,
                inks.ink.green, inks.ink.blue, alpha)
        } else {
            let room = max(0, textLimit - 83)
            BrainDraw.line(
                cr, row.argument, font: fonts.note, lineHeight: fonts.lineHeight, x: 83, top: y,
                height: rowH, width: room, color: inks.dim, alpha: alpha)
        }
        cairo_restore(cr)
    }

    private func highlight(
        _ cr: OpaquePointer, text: String, x: Double, y: Double, query: String, inks: BrainInks, alpha: Double
    ) {
        guard let range = text.range(of: query, options: .caseInsensitive) else { return }
        let start = text.distance(from: text.startIndex, to: range.lowerBound)
        let length = text.distance(from: range.lowerBound, to: range.upperBound)
        BrainDraw.fill(cr, inks.warn, 0.34 * alpha)
        BrainDraw.roundedRect(
            cr, x + Double(start) * fonts.monoWidth - 1, y + 5, Double(length) * fonts.monoWidth + 2,
            rowHeight - 10, 3)
        cairo_fill(cr)
    }

    private func paintBracket(
        _ cr: OpaquePointer, row: NeuralStepList.Row, previous: NeuralStepList.Row?,
        next: NeuralStepList.Row?, y: Double, height rowH: Double, inks: BrainInks, alpha: Double
    ) {
        guard row.bracket != .none else { return }
        let joinsAbove = previous.map { $0.group == row.group && $0.bracket != .none } ?? false
        let joinsBelow = next.map { $0.group == row.group && $0.bracket != .none } ?? false
        guard joinsAbove || joinsBelow else { return }
        let mid = y + rowH / 2
        cairo_save(cr)
        BrainDraw.fill(cr, inks.dim, 0.75 * alpha)
        cairo_set_line_width(cr, 1)
        cairo_new_path(cr)
        let x = 9.5
        cairo_move_to(cr, x, joinsAbove ? y : mid)
        cairo_line_to(cr, x, joinsBelow ? y + rowH : mid)
        cairo_move_to(cr, x, mid)
        cairo_line_to(cr, x + 6, mid)
        cairo_stroke(cr)
        cairo_restore(cr)
    }

    /// The mark on the right of a row and the left edge it begins at; the copy button of a
    /// hovered row stands in its place.
    private func paintStatus(
        _ cr: OpaquePointer, row: NeuralStepList.Row, y: Double, height rowH: Double, width: Double,
        inks: BrainInks, alpha: Double, showCopy: Bool, touch: Touch
    ) -> Double {
        let band = row.isSaid ? 28.0 : rowH
        let mid = y + band / 2
        if showCopy {
            let rect = copyRect(for: row, width: width, touch: touch)
            let label = touch.copiedID == row.id ? BrainWords.copied : BrainWords.copy
            BrainDraw.roundedRect(cr, rect.x + 0.5, y + rect.y + 0.5, rect.width - 1, rect.height - 1, 12)
            BrainDraw.fill(cr, inks.card, 0.95 * alpha)
            cairo_fill_preserve(cr)
            BrainDraw.fill(cr, touch.copyHotID == row.id ? inks.accent : inks.rule2, alpha)
            cairo_set_line_width(cr, 1)
            cairo_stroke(cr)
            BrainDraw.line(
                cr, label, font: fonts.status, lineHeight: fonts.lineHeight, x: rect.x, top: y + rect.y,
                height: rect.height, width: rect.width, align: 1, color: inks.ink, alpha: alpha)
            return rect.x
        }
        let right = width - 10
        let verdict = row.verdict
        guard verdict.isMarked else { return right }
        let color = BrainDraw.verdictColor(verdict, inks: inks)
        switch verdict {
        case .fixed:
            let target = row.related.map { "\u{2192}\($0.number)" } ?? ""
            let size = BrainDraw.measure(target, fonts.status)
            if !target.isEmpty {
                BrainDraw.line(
                    cr, target, font: fonts.status, lineHeight: fonts.lineHeight, x: right - size, top: y,
                    height: band, color: color, alpha: alpha)
            }
            let glyphX = right - size - (target.isEmpty ? 0 : 6) - 7
            BrainDraw.verdictGlyph(cr, .fixed, cx: glyphX, cy: mid, size: 13, color: color, alpha: alpha)
            return glyphX - 12
        default:
            BrainDraw.verdictGlyph(cr, verdict, cx: right - 6, cy: mid, size: 13, color: color, alpha: alpha)
            return right - 20
        }
    }
}

extension BrainDraw {
    /// The quote a said row and a note wear: two filled commas turned the way an opening double
    /// quote is, in `color`.
    static func quoteGlyph(
        _ cr: OpaquePointer, cx: Double, cy: Double, color: RGB, alpha: Double, font: String = ""
    ) {
        _ = font
        cairo_save(cr)
        fill(cr, color, alpha)
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
        for offset in [-4.2, 3.2] {
            let x = cx + offset
            cairo_new_path(cr)
            cairo_arc(cr, x, cy + 2.2, 2.6, 0, 2 * .pi)
            cairo_fill(cr)
            cairo_set_line_width(cr, 2.2)
            cairo_new_path(cr)
            cairo_move_to(cr, x + 2.3, cy + 1.6)
            cairo_curve_to(cr, x + 2.9, cy - 2.4, x + 1.8, cy - 4.4, x - 0.6, cy - 5.6)
            cairo_stroke(cr)
        }
        cairo_restore(cr)
    }

    /// The size of a Pango font description in pixels at 96 dpi: a bare number or a point size is
    /// points.
    static func pixelSize(of font: String) -> Double {
        guard let last = font.split(separator: " ").last else { return 0 }
        let isPixels = last.hasSuffix("px")
        let unit = isPixels ? "px" : last.hasSuffix("pt") ? "pt" : ""
        guard let size = Double(last.dropLast(unit.count)) else { return 0 }
        return isPixels ? size : size * 96 / 72
    }

    /// A Pango font description with its size multiplied and nothing else changed; the size may
    /// carry a unit, as GTK writes it (`22.18px`).
    static func resized(_ font: String, by factor: Double) -> String {
        var parts = font.split(separator: " ").map(String.init)
        guard let last = parts.last else { return font }
        let unit = last.hasSuffix("px") ? "px" : last.hasSuffix("pt") ? "pt" : ""
        guard let size = Double(last.dropLast(unit.count)) else { return font }
        parts[parts.count - 1] = String(format: "%.2f", size * factor) + unit
        return parts.joined(separator: " ")
    }

    /// A Pango font description with its size multiplied, set bold.
    static func scaled(_ font: String, by factor: Double) -> String {
        var parts = font.split(separator: " ").map(String.init)
        guard let last = parts.last, let size = Double(last) else { return font }
        parts[parts.count - 1] = String(format: "%.2f", size * factor)
        if !parts.contains(where: { $0.lowercased() == "bold" }) { parts.insert("Bold", at: max(0, parts.count - 1)) }
        return parts.joined(separator: " ")
    }
}
