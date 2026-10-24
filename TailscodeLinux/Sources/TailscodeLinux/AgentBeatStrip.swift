import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The last minute of an agent's pulse, drawn from Core's `[Int]`: one bar per slice, as tall as
/// the times this device saw it move (capped at `AgentBeat.ceiling`). A strip with every bar at
/// its floor is a stall you can see, and it says so in words to anyone who cannot.
final class AgentBeatStrip: @unchecked Sendable {
    static let barWidth = 3.0
    static let gap = 1.0
    static let height: Int32 = 16

    let widget: UnsafeMutablePointer<GtkWidget>
    private let canvas: AgentsCanvas
    private(set) var beat: [Int] = []
    private(set) var tone: ActivityTone = .live

    init() {
        let width = Int32(Double(AgentBeat.buckets) * (Self.barWidth + Self.gap) - Self.gap)
        canvas = AgentsCanvas(width: width, height: Self.height)
        widget = canvas.widget
        gtk_widget_set_halign(widget, GTK_ALIGN_START)
        gtk_widget_set_valign(widget, GTK_ALIGN_CENTER)
        gtk_widget_set_can_target(widget, 0)
        gtk_widget_set_can_focus(widget, 0)
        canvas.paint = { [weak self] cr, width, height in
            self?.paint(cr, width: width, height: height)
        }
    }

    var isStalled: Bool { !beat.isEmpty && beat.allSatisfy { $0 == 0 } }

    /// What the strip says without being seen.
    var spoken: String {
        guard !beat.isEmpty else { return "" }
        if isStalled { return Localized.text("Nothing moved in the last minute") }
        return Localized.text("Activity over the last minute: %d steps", beat.reduce(0, +))
    }

    /// Shows a beat, or hides the strip when there is none: an agent nobody watches has no pulse to
    /// draw, and a drawn nothing would read as a stall.
    func show(beat next: [Int]?, tone: ActivityTone) {
        guard let next, !next.isEmpty else {
            beat = []
            gtk_widget_set_visible(widget, 0)
            return
        }
        gtk_widget_set_visible(widget, 1)
        guard next != beat || tone != self.tone else { return }
        beat = next
        self.tone = tone
        tailscode_set_accessible_label(widget, spoken)
        canvas.redraw()
    }

    private func paint(_ cr: OpaquePointer, width: Double, height: Double) {
        let inks = AgentsInks()
        let ink = inks.ink(tone)
        let ceiling = Double(AgentBeat.ceiling)
        for (index, value) in beat.enumerated() {
            let x = Double(index) * (Self.barWidth + Self.gap)
            let lift = value == 0 ? 1.5 : max(3, height * Double(value) / ceiling)
            if value == 0 {
                inks.quiet.set(cr, alpha: 0.45)
            } else {
                ink.set(cr, alpha: 0.55 + 0.45 * Double(value) / ceiling)
            }
            cairo_new_path(cr)
            cairo_rectangle(cr, x, height - lift, Self.barWidth, lift)
            cairo_fill(cr)
        }
    }
}
