import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The counts at the end of the Agents row, drawn rather than laid out: green for what is
/// working, amber for what needs the person and a quiet grey for work carried in the background,
/// each hidden at zero and each carrying its digits,
/// so the colour is never the whole message. They are drawn so a change of count can pop the chip
/// (1.0, 1.15, 1.0 over 220 ms) about its own centre without moving a pixel of the row around it.
final class AgentsEntryChips: @unchecked Sendable {
    enum Kind: Int, CaseIterable {
        case working
        case needs
        case background
    }

    static let popDuration = 0.22
    static let popPeak = 1.15

    let canvas = AgentsCanvas(width: 1, height: 1)
    private var counts: [Kind: Int] = [.working: 0, .needs: 0, .background: 0]
    private var popped: [Kind: Double] = [:]
    private(set) var pops = 0

    var widget: UnsafeMutablePointer<GtkWidget> { canvas.widget }
    var isPopping: Bool { !popped.isEmpty }

    init() {
        gtk_widget_set_valign(canvas.widget, GTK_ALIGN_CENTER)
        gtk_widget_set_halign(canvas.widget, GTK_ALIGN_END)
        tailscode_set_accessible_hidden(canvas.widget, 1)
        canvas.paint = { [weak self] cr, _, _ in self?.paint(cr) }
        resize()
    }

    func count(_ kind: Kind) -> Int { counts[kind] ?? 0 }
    func isShown(_ kind: Kind) -> Bool { count(kind) > 0 }
    var texts: [String] { Kind.allCases.filter(isShown).map { "\(count($0))" } }

    func set(working: Int, needs: Int, background: Int = 0, popping: Bool) {
        let next: [Kind: Int] = [.working: working, .needs: needs, .background: background]
        guard next != counts else { return }
        let now = AgentsMiniOrb.now
        for kind in Kind.allCases where popping && next[kind]! > 0 && next[kind] != counts[kind] {
            popped[kind] = now
            pops += 1
        }
        counts = next
        resize()
        canvas.redraw()
    }

    /// One frame of the pop, on the row's own clock: redraws while a chip is mid-swell and once
    /// more when it has settled at its own size.
    func step(time: Double) {
        guard !popped.isEmpty else { return }
        popped = popped.filter { time - $0.value < Self.popDuration }
        canvas.redraw()
    }

    func cancelPops() {
        guard !popped.isEmpty else { return }
        popped = [:]
        canvas.redraw()
    }

    private static func ink(_ kind: Kind, _ inks: AgentsInks) -> PartyInk {
        switch kind {
        case .working: return inks.live
        case .needs: return inks.attention
        case .background: return inks.quiet
        }
    }

    private func scale(_ kind: Kind, at time: Double) -> Double {
        guard let start = popped[kind] else { return 1 }
        let progress = min(1, max(0, (time - start) / Self.popDuration))
        return 1 + (Self.popPeak - 1) * sin(progress * .pi)
    }

    private func style() -> AgentsText.Style {
        var style = AgentsText.Style()
        style.scale = 0.92
        style.bold = true
        return style
    }

    private func layout(_ kind: Kind) -> OpaquePointer? {
        guard let layout = AgentsText.layout(widget, "\(count(kind))", style: style()) else { return nil }
        pango_layout_set_markup(
            layout, "<span font_features=\"tnum\">\(count(kind))</span>", -1)
        return layout
    }

    private func metrics(_ kind: Kind) -> (width: Double, height: Double, text: (Double, Double)) {
        guard let layout = layout(kind) else { return (0, 0, (0, 0)) }
        defer { g_object_unref(UnsafeMutableRawPointer(layout)) }
        var width: Int32 = 0
        var height: Int32 = 0
        pango_layout_get_pixel_size(layout, &width, &height)
        let chipHeight = Double(height) + 2
        return (max(chipHeight, Double(width) + 12), chipHeight, (Double(width), Double(height)))
    }

    private func resize() {
        let shown = Kind.allCases.filter(isShown)
        var width = 0.0
        var height = 0.0
        for kind in shown {
            let size = metrics(kind)
            width += size.width
            height = max(height, size.height)
        }
        width += Double(max(0, shown.count - 1)) * 4
        gtk_widget_set_visible(widget, shown.isEmpty ? 0 : 1)
        gtk_widget_set_size_request(widget, Int32(ceil(width + 4)), Int32(ceil(height + 4)))
    }

    private func paint(_ cr: OpaquePointer) {
        let inks = AgentsInks()
        let time = AgentsMiniOrb.now
        var x = 2.0
        for kind in Kind.allCases where isShown(kind) {
            let size = metrics(kind)
            let tone = Self.ink(kind, inks)
            let top = 2.0
            cairo_save(cr)
            let centreX = x + size.width / 2
            let centreY = top + size.height / 2
            let grown = scale(kind, at: time)
            cairo_translate(cr, centreX, centreY)
            cairo_scale(cr, grown, grown)
            cairo_translate(cr, -centreX, -centreY)
            agentsRoundedRect(cr, x: x, y: top, width: size.width, height: size.height, radius: size.height / 2)
            tone.set(cr, alpha: 0.2)
            cairo_fill_preserve(cr)
            tone.set(cr, alpha: 0.65)
            cairo_set_line_width(cr, 1)
            cairo_stroke(cr)
            if let layout = layout(kind) {
                tone.set(cr)
                cairo_move_to(
                    cr, x + (size.width - size.text.0) / 2, top + (size.height - size.text.1) / 2)
                pango_cairo_show_layout(cr, layout)
                g_object_unref(UnsafeMutableRawPointer(layout))
            }
            cairo_restore(cr)
            x += size.width + 4
        }
    }
}
