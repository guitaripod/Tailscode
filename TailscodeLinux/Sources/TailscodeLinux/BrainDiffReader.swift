import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The whole of a file the agent wrote, or of an edit, laid out to be read: one canvas that draws
/// only the lines in view, so a two-thousand-line file costs what thirty do, inside a scroller
/// that is bounded in height and scrolls sideways for a long line. Written files carry a gutter
/// of line numbers; an edit carries the `+` and `-` of what changed and the same washes the clipped
/// block above it wears.
final class BrainDiffReader: @unchecked Sendable {
    let widget: UnsafeMutablePointer<GtkWidget>
    private let canvas: UnsafeMutablePointer<GtkWidget>
    private let lines: [NeuralReadout.DiffLine]
    private let numbered: Bool
    private let inks: BrainInks
    private let font: String
    private let lineHeight: Double
    private let charWidth: Double
    private let gutter: Double
    private let textLeft: Double
    private let contentWidth: Double
    private let adjustment: UnsafeMutablePointer<GtkAdjustment>

    /// The most characters of one line that are drawn; a line of a minified bundle is cut here.
    private static let characterCap = 600
    private static let pad = 8.0
    private static let markWidth = 18.0

    private final class Holder: @unchecked Sendable {
        weak var reader: BrainDiffReader?
    }

    init(lines: [NeuralReadout.DiffLine], inks: BrainInks, maxHeight: Double) {
        self.lines = lines
        self.inks = inks
        numbered = NeuralReading.isWholeFile(lines)
        let probe = BrainUI.label("A", "bn-diff-text")
        font = BrainUI.font(of: probe)
        var width = 0.0
        var height = 0.0
        tailscode_text_measure("MMMMMMMMMMMMMMMMMMMM", font, 0, 1, &width, &height)
        charWidth = max(1, width / 20)
        var lineWidth = 0.0
        var lineHeightRaw = 0.0
        tailscode_text_measure("Mg", font, 0, 1, &lineWidth, &lineHeightRaw)
        lineHeight = (lineHeightRaw + 3).rounded()
        let digits = numbered ? String(lines.count).count : 0
        gutter = numbered ? Double(max(digits, 2)) * charWidth + 12 : 0
        textLeft = Self.pad + gutter + Self.markWidth
        let longest = min(Self.characterCap, lines.reduce(0) { max($0, Self.expanded($1.text).count) })
        contentWidth = textLeft + Double(longest) * charWidth + Self.pad * 2
        let holder = Holder()
        _ = Gtk.releaseInstalled
        let drawing = tailscode_canvas_new(
            { cr, width, height, raw in
                guard let cr, let raw else { return }
                Unmanaged<Holder>.fromOpaque(raw).takeUnretainedValue().reader?.paint(
                    cr, width: Double(width), height: Double(height))
            }, Unmanaged.passRetained(holder).toOpaque(),
            { raw in
                guard let raw else { return }
                Unmanaged<Holder>.fromOpaque(raw).release()
            })!
        canvas = drawing
        let total = Double(lines.count) * lineHeight + 2
        gtk_widget_set_size_request(canvas, Int32(contentWidth.rounded(.up)), Int32(total.rounded(.up)))
        gtk_widget_set_halign(canvas, GTK_ALIGN_FILL)
        gtk_widget_set_can_focus(canvas, 0)
        tailscode_set_accessible_hidden(canvas, 1)
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_AUTOMATIC, GTK_POLICY_AUTOMATIC)
        let shown = min(total, maxHeight).rounded(.up)
        gtk_scrolled_window_set_min_content_height(op(scroller), Int32(shown))
        gtk_scrolled_window_set_max_content_height(op(scroller), Int32(maxHeight.rounded()))
        gtk_scrolled_window_set_propagate_natural_height(op(scroller), 1)
        gtk_scrolled_window_set_child(op(scroller), canvas)
        gtk_widget_set_hexpand(scroller, 1)
        Gtk.addClass(scroller, "bn-reader")
        widget = scroller
        adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))!
        holder.reader = self
        let hold = Gtk.WeakWidget(canvas)
        Gtk.connect(UnsafeMutableRawPointer(adjustment), "value-changed") {
            Gtk.onMain { if let canvas = hold.widget { gtk_widget_queue_draw(canvas) } }
        }
        Gtk.connect(UnsafeMutableRawPointer(adjustment), "changed") {
            Gtk.onMain { if let canvas = hold.widget { gtk_widget_queue_draw(canvas) } }
        }
        let label = Localized.text("%lld lines", lines.count)
        tailscode_set_accessible_label(scroller, label)
    }

    /// The lines in the window the scroller shows, with a line of margin either side.
    func visibleRange() -> Range<Int> {
        let top = gtk_adjustment_get_value(adjustment)
        let page = max(gtk_adjustment_get_page_size(adjustment), lineHeight * 8)
        let first = max(0, Int((top / lineHeight).rounded(.down)) - 1)
        let last = min(lines.count, Int(((top + page) / lineHeight).rounded(.up)) + 1)
        return first..<max(first, last)
    }

    var lineCount: Int { lines.count }

    /// What the harness reads: how tall the whole file is, and how many lines are drawn now.
    var reading: String {
        "reader lines=\(lines.count) numbered=\(numbered) drawn=\(visibleRange().count) height=\(Int(Double(lines.count) * lineHeight))"
    }

    private static func expanded(_ text: String) -> String {
        text.contains("\t") ? text.replacingOccurrences(of: "\t", with: "    ") : text
    }

    private func paint(_ cr: OpaquePointer, width: Double, height: Double) {
        let wide = max(width, contentWidth)
        for index in visibleRange() {
            let line = lines[index]
            let y = Double(index) * lineHeight + 1
            switch line.kind {
            case .add:
                BrainDraw.fill(cr, inks.accent, 0.14)
                cairo_rectangle(cr, 0, y, wide, lineHeight)
                cairo_fill(cr)
            case .remove:
                BrainDraw.fill(cr, inks.cDanger, 0.14)
                cairo_rectangle(cr, 0, y, wide, lineHeight)
                cairo_fill(cr)
            case .context: break
            }
            if numbered {
                BrainDraw.text(
                    cr, String(index + 1), font: font, x: Self.pad, y: y + 1.5, width: gutter - 8, align: 2,
                    color: inks.dim, alpha: 0.7)
            }
            switch line.kind {
            case .add:
                BrainDraw.text(
                    cr, "+", font: font, x: Self.pad + gutter, y: y + 1.5, color: inks.accent)
            case .remove:
                BrainDraw.text(
                    cr, "\u{2212}", font: font, x: Self.pad + gutter, y: y + 1.5, color: inks.cDanger)
            case .context: break
            }
            let text = Self.expanded(line.text)
            let shown = text.count > Self.characterCap ? String(text.prefix(Self.characterCap)) + "\u{2026}" : text
            BrainDraw.text(cr, shown, font: font, x: textLeft, y: y + 1.5, color: inks.ink)
        }
        if numbered {
            BrainDraw.fill(cr, inks.rule2, 0.8)
            cairo_rectangle(cr, Self.pad + gutter - 4, 0, 1, height)
            cairo_fill(cr)
        }
    }
}
