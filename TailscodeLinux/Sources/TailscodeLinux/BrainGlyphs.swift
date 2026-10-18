import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The small marks every verdict wears, so that amber and red are told apart by shape and word
/// and never by colour alone: a check for done, a circular arrow for fixed on retry, a cross for
/// failed, a triangle for an error being retried, a dot for running, pause bars for waiting, a
/// dashed clock for stuck, a square for stopped.
extension BrainDraw {
    /// The colour a verdict's mark is drawn in: amber for what was fixed or is waiting, red for
    /// what stayed failed, the live tone for what runs, and the quiet ink for the rest.
    static func verdictColor(_ verdict: NeuralVerdict.Step, inks: BrainInks) -> RGB {
        switch verdict {
        case .done: return inks.accent
        case .fixed, .tryingAgain, .waiting, .stalled: return inks.warn
        case .failed: return inks.cDanger
        case .running: return inks.live
        case .stopped: return inks.dim
        }
    }

    static func toneColor(_ tone: NeuralTone, inks: BrainInks) -> RGB {
        switch tone {
        case .live, .identity: return inks.accent
        case .attention: return inks.warn
        case .danger: return inks.cDanger
        case .quiet: return inks.dim
        }
    }

    /// Draws a verdict's mark centred at (`cx`, `cy`), about `size` points across.
    static func verdictGlyph(
        _ cr: OpaquePointer, _ verdict: NeuralVerdict.Step, cx: Double, cy: Double, size: Double = 12,
        color: RGB, alpha: Double = 1
    ) {
        switch verdict {
        case .done: check(cr, cx: cx, cy: cy, size: size, color: color, alpha: alpha)
        case .fixed: retryArrow(cr, cx: cx, cy: cy, size: size, color: color, alpha: alpha)
        case .failed: cross(cr, cx: cx, cy: cy, size: size * 0.3, color: color, alpha: alpha)
        case .tryingAgain: triangle(cr, cx: cx, cy: cy, size: size, color: color, alpha: alpha)
        case .running: dot(cr, cx: cx, cy: cy, radius: size * 0.3, color: color, alpha: alpha)
        case .waiting: pauseBars(cr, cx: cx, cy: cy, size: size, color: color, alpha: alpha)
        case .stalled: dashedClock(cr, cx: cx, cy: cy, size: size, color: color, alpha: alpha)
        case .stopped: stopSquare(cr, cx: cx, cy: cy, size: size, color: color, alpha: alpha)
        }
    }

    static func check(_ cr: OpaquePointer, cx: Double, cy: Double, size: Double, color: RGB, alpha: Double) {
        cairo_save(cr)
        fill(cr, color, alpha)
        cairo_set_line_width(cr, 1.7)
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
        cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
        let u = size / 12
        cairo_new_path(cr)
        cairo_move_to(cr, cx - 4.2 * u, cy + 0.2 * u)
        cairo_line_to(cr, cx - 1.3 * u, cy + 3.2 * u)
        cairo_line_to(cr, cx + 4.4 * u, cy - 3.4 * u)
        cairo_stroke(cr)
        cairo_restore(cr)
    }

    static func retryArrow(_ cr: OpaquePointer, cx: Double, cy: Double, size: Double, color: RGB, alpha: Double) {
        cairo_save(cr)
        fill(cr, color, alpha)
        cairo_set_line_width(cr, 1.7)
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
        cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
        let radius = size * 0.38
        let start = -0.15 * Double.pi
        let end = 1.55 * Double.pi
        cairo_new_path(cr)
        cairo_arc(cr, cx, cy, radius, start, end)
        cairo_stroke(cr)
        let tip = (x: cx + radius * cos(end), y: cy + radius * sin(end))
        cairo_new_path(cr)
        cairo_move_to(cr, tip.x - size * 0.28, tip.y - size * 0.22)
        cairo_line_to(cr, tip.x + size * 0.06, tip.y + size * 0.02)
        cairo_line_to(cr, tip.x - size * 0.26, tip.y + size * 0.26)
        cairo_stroke(cr)
        cairo_restore(cr)
    }

    static func triangle(_ cr: OpaquePointer, cx: Double, cy: Double, size: Double, color: RGB, alpha: Double) {
        cairo_save(cr)
        fill(cr, color, alpha)
        cairo_set_line_width(cr, 1.5)
        cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
        let h = size * 0.42
        cairo_new_path(cr)
        cairo_move_to(cr, cx, cy - h)
        cairo_line_to(cr, cx + h * 1.15, cy + h * 0.8)
        cairo_line_to(cr, cx - h * 1.15, cy + h * 0.8)
        cairo_close_path(cr)
        cairo_stroke(cr)
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
        cairo_new_path(cr)
        cairo_move_to(cr, cx, cy - h * 0.25)
        cairo_line_to(cr, cx, cy + h * 0.2)
        cairo_stroke(cr)
        cairo_new_path(cr)
        cairo_arc(cr, cx, cy + h * 0.52, 0.6, 0, 2 * .pi)
        cairo_fill(cr)
        cairo_restore(cr)
    }

    static func pauseBars(_ cr: OpaquePointer, cx: Double, cy: Double, size: Double, color: RGB, alpha: Double) {
        cairo_save(cr)
        fill(cr, color, alpha)
        let h = size * 0.7
        let w = max(1.8, size * 0.17)
        roundedRect(cr, cx - size * 0.28 - w / 2, cy - h / 2, w, h, w / 2)
        cairo_fill(cr)
        roundedRect(cr, cx + size * 0.28 - w / 2, cy - h / 2, w, h, w / 2)
        cairo_fill(cr)
        cairo_restore(cr)
    }

    static func dashedClock(_ cr: OpaquePointer, cx: Double, cy: Double, size: Double, color: RGB, alpha: Double) {
        cairo_save(cr)
        fill(cr, color, alpha)
        cairo_set_line_width(cr, 1.4)
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
        let dashes: [Double] = [1.8, 1.8]
        dashes.withUnsafeBufferPointer { cairo_set_dash(cr, $0.baseAddress, 2, 0) }
        cairo_new_path(cr)
        cairo_arc(cr, cx, cy, size * 0.42, 0, 2 * .pi)
        cairo_stroke(cr)
        cairo_set_dash(cr, nil, 0, 0)
        cairo_new_path(cr)
        cairo_move_to(cr, cx, cy - size * 0.24)
        cairo_line_to(cr, cx, cy)
        cairo_line_to(cr, cx + size * 0.18, cy + size * 0.1)
        cairo_stroke(cr)
        cairo_restore(cr)
    }

    static func stopSquare(_ cr: OpaquePointer, cx: Double, cy: Double, size: Double, color: RGB, alpha: Double) {
        cairo_save(cr)
        fill(cr, color, alpha)
        cairo_set_line_width(cr, 1.5)
        let side = size * 0.55
        roundedRect(cr, cx - side / 2, cy - side / 2, side, side, 1.6)
        cairo_stroke(cr)
        cairo_restore(cr)
    }

    /// The live card's glyph before the verdict.
    static func liveGlyph(
        _ cr: OpaquePointer, _ glyph: NeuralLiveCard.Glyph, cx: Double, cy: Double, size: Double,
        color: RGB, alpha: Double = 1
    ) {
        switch glyph {
        case .pulse: dot(cr, cx: cx, cy: cy, radius: size * 0.3, color: color, alpha: alpha)
        case .pauseBars: pauseBars(cr, cx: cx, cy: cy, size: size, color: color, alpha: alpha)
        case .dashedClock: dashedClock(cr, cx: cx, cy: cy, size: size, color: color, alpha: alpha)
        case .triangle: triangle(cr, cx: cx, cy: cy, size: size, color: color, alpha: alpha)
        }
    }
}

extension BrainUI {
    /// The step verdict a readout chip's kind stands for, so its mark is the one the list and the
    /// work lines wear.
    static func stepVerdict(for kind: NeuralReadout.ChipKind) -> NeuralVerdict.Step {
        switch kind {
        case .done: return .done
        case .failed: return .failed
        case .running: return .running
        case .waiting: return .waiting
        case .stalled: return .stalled
        case .stopped: return .stopped
        case .retried, .fixed: return .fixed
        case .hitError: return .tryingAgain
        }
    }

    /// A verdict's mark as a widget, `size` points square, in the verdict's colour.
    static func verdictGlyph(
        _ verdict: NeuralVerdict.Step, size: Double = 14, inks: BrainInks, color: BrainInks.RGB? = nil
    ) -> UnsafeMutablePointer<GtkWidget> {
        let holder = VerdictBox(verdict: verdict, color: color ?? BrainDraw.verdictColor(verdict, inks: inks))
        _ = Gtk.releaseInstalled
        let widget = tailscode_canvas_new(
            { cr, width, height, raw in
                guard let cr, let raw else { return }
                let box = Unmanaged<VerdictBox>.fromOpaque(raw).takeUnretainedValue()
                BrainDraw.verdictGlyph(
                    cr, box.verdict, cx: Double(width) / 2, cy: Double(height) / 2,
                    size: Double(min(width, height)), color: box.color)
            }, Unmanaged.passRetained(holder).toOpaque(),
            { raw in
                guard let raw else { return }
                Unmanaged<VerdictBox>.fromOpaque(raw).release()
            })!
        gtk_widget_set_size_request(widget, Int32(size), Int32(size))
        gtk_widget_set_valign(widget, GTK_ALIGN_CENTER)
        gtk_widget_set_can_target(widget, 0)
        tailscode_set_accessible_hidden(widget, 1)
        return widget
    }

    private final class VerdictBox: @unchecked Sendable {
        let verdict: NeuralVerdict.Step
        let color: BrainInks.RGB
        init(verdict: NeuralVerdict.Step, color: BrainInks.RGB) {
            self.verdict = verdict
            self.color = color
        }
    }
}
