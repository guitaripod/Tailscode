import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The fonts the step list and the filter panel draw with, read once from probe labels that wear
/// the style sheet's own roles, so a canvas sets type exactly as the labels beside it do and a
/// change of the type scale is one rebuild of this value.
struct BrainListFonts {
    let title: String
    let argument: String
    let number: String
    let note: String
    let status: String
    let count: String
    let cap: String
    let panelName: String
    let panelCount: String
    let pill: String
    let said: String
    let lineHeight: Double
    let monoWidth: Double
    let capHeight: Double

    init() {
        func probe(_ css: String) -> String { BrainUI.font(of: BrainUI.label("A", css)) }
        title = probe("bn-lr-title")
        argument = probe("bn-lr-arg")
        number = probe("bn-lr-no")
        note = probe("bn-lr-note")
        status = probe("bn-lr-status")
        count = probe("bn-lr-count")
        cap = probe("bn-lr-cap")
        panelName = probe("bn-lr-panel")
        panelCount = probe("bn-lr-panelcount")
        pill = probe("bn-lr-pill")
        said = BrainDraw.scaled(probe("bn-lr-panel"), by: 1)
        var width = 0.0
        var height = 0.0
        tailscode_text_measure("MMMMMMMMMMMMMMMMMMMM", argument, 0, 1, &width, &height)
        monoWidth = max(1, width / 20)
        var lineWidth = 0.0
        var lineHeight = 0.0
        tailscode_text_measure("Mg", title, 0, 1, &lineWidth, &lineHeight)
        self.lineHeight = lineHeight
        var capWidth = 0.0
        var capHeight = 0.0
        tailscode_text_measure("M", cap, 0, 1, &capWidth, &capHeight)
        self.capHeight = capHeight
    }
}

/// The small shapes every list and panel is made of, drawn with cairo and Pango: a rounded
/// rectangle's fill, a key cap, a pill, text in a colour. None of them keeps state.
enum BrainDraw {
    typealias RGB = BrainInks.RGB

    static func fill(_ cr: OpaquePointer, _ color: RGB, _ alpha: Double) {
        cairo_set_source_rgba(cr, color.red, color.green, color.blue, alpha)
    }

    static func measure(_ text: String, _ font: String) -> Double {
        var width = 0.0
        var height = 0.0
        tailscode_text_measure(text, font, 0, 1, &width, &height)
        return width
    }

    @discardableResult
    static func text(
        _ cr: OpaquePointer, _ text: String, font: String, x: Double, y: Double, width: Double = 0,
        align: Int32 = 0, color: RGB, alpha: Double = 1
    ) -> Double {
        guard !text.isEmpty, alpha > 0.002 else { return 0 }
        return tailscode_text_draw(
            cr, text, font, x, y, width, align, 1, color.red, color.green, color.blue, alpha)
    }

    /// Text centred vertically in a band of `height` starting at `top`.
    static func line(
        _ cr: OpaquePointer, _ text: String, font: String, lineHeight: Double, x: Double, top: Double,
        height: Double, width: Double = 0, align: Int32 = 0, color: RGB, alpha: Double = 1
    ) {
        BrainDraw.text(
            cr, text, font: font, x: x, y: top + (height - lineHeight) / 2, width: width, align: align,
            color: color, alpha: alpha)
    }

    static func roundedRect(
        _ cr: OpaquePointer, _ x: Double, _ y: Double, _ width: Double, _ height: Double, _ radius: Double
    ) {
        BrainPainter.round(cr, x, y, width, height, min(radius, min(width, height) / 2))
    }

    /// A key cap: a small outlined box with the key in it. Returns its width.
    @discardableResult
    static func keyCap(
        _ cr: OpaquePointer, _ key: String, x: Double, midY: Double, fonts: BrainListFonts, inks: BrainInks,
        alpha: Double = 1, draw: Bool = true
    ) -> Double {
        let textWidth = measure(key, fonts.cap)
        let width = max(16, textWidth + 8)
        guard draw else { return width }
        let height = 16.0
        roundedRect(cr, x + 0.5, midY - height / 2 + 0.5, width - 1, height - 1, 4)
        fill(cr, inks.rule2, alpha)
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)
        text(
            cr, key, font: fonts.cap, x: x, y: midY - fonts.capHeight / 2, width: width, align: 1,
            color: inks.dim, alpha: alpha)
        return width
    }

    /// The magnifier of the search field.
    static func magnifier(_ cr: OpaquePointer, x: Double, midY: Double, color: RGB, alpha: Double) {
        cairo_save(cr)
        fill(cr, color, alpha)
        cairo_set_line_width(cr, 1.5)
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
        cairo_new_path(cr)
        cairo_arc(cr, x + 5.5, midY - 1.5, 4.5, 0, 2 * .pi)
        cairo_stroke(cr)
        cairo_move_to(cr, x + 9, midY + 2)
        cairo_line_to(cr, x + 13, midY + 6)
        cairo_stroke(cr)
        cairo_restore(cr)
    }

    /// The cross a failure wears.
    static func cross(_ cr: OpaquePointer, cx: Double, cy: Double, size: Double, color: RGB, alpha: Double) {
        cairo_save(cr)
        fill(cr, color, alpha)
        cairo_set_line_width(cr, 1.8)
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
        cairo_new_path(cr)
        cairo_move_to(cr, cx - size, cy - size)
        cairo_line_to(cr, cx + size, cy + size)
        cairo_move_to(cr, cx + size, cy - size)
        cairo_line_to(cr, cx - size, cy + size)
        cairo_stroke(cr)
        cairo_restore(cr)
    }

    static func dashedRing(_ cr: OpaquePointer, cx: Double, cy: Double, radius: Double, color: RGB, alpha: Double) {
        cairo_save(cr)
        fill(cr, color, alpha)
        cairo_set_line_width(cr, 1.4)
        var dashes: [Double] = [2, 2]
        dashes.withUnsafeBufferPointer { cairo_set_dash(cr, $0.baseAddress, 2, 0) }
        cairo_new_path(cr)
        cairo_arc(cr, cx, cy, radius, 0, 2 * .pi)
        cairo_stroke(cr)
        cairo_restore(cr)
    }

    static func dot(_ cr: OpaquePointer, cx: Double, cy: Double, radius: Double, color: RGB, alpha: Double) {
        cairo_save(cr)
        fill(cr, color, alpha)
        cairo_new_path(cr)
        cairo_arc(cr, cx, cy, radius, 0, 2 * .pi)
        cairo_fill(cr)
        cairo_restore(cr)
    }

    /// A zone's shape, stroked in `color`, centred at (`cx`, `cy`) with the shape filling about
    /// 13 points of an 18 point box.
    static func zoneGlyph(
        _ cr: OpaquePointer, zone: NeuralZone, cx: Double, cy: Double, color: RGB, alpha: Double,
        radius: Double = 6.5
    ) {
        cairo_save(cr)
        cairo_translate(cr, cx, cy)
        BrainPainter.shape(cr, zone.shape, radius: radius)
        fill(cr, color, alpha)
        cairo_set_line_width(cr, 1.5)
        cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
        cairo_stroke(cr)
        cairo_restore(cr)
    }
}
