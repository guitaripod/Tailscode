import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The video button's light: where the render is, drawn round the button's own edge.
///
/// Core decides what is said (`ForgeLight`) and where each stroke goes (`ForgeRing`); this only
/// paints it. The button is the overlay's child and the light a transparent layer over it that
/// never takes a press, so the control is exactly the size and the shape it was and a frame can
/// change nothing but ink. Frames come from the widget's own frame clock at the vocabulary's tempo,
/// read as absolute time like every other moving mark, and a face that holds still is drawn once
/// and costs nothing. When the outcome has been looked at the light fades rather than vanishing —
/// the desk's own animation switch takes the fade away with every other transition.
final class ForgeButtonRing: @unchecked Sendable {
    /// What the header packs: the button with the light laid over its edge.
    let widget = gtk_overlay_new()!
    private let area = tailscode_edge_new()!
    private var light: ForgeLight = .dark
    private var displayed = 0.0
    private var lastStep = 0.0
    private var moving = false
    private var lastFrame = ForgeRingFrame(tone: .quiet, track: 0, strokes: [])
    private var fadeTicket = 0
    private lazy var lap = RepeatingMotion(holding: false) { [weak self] in self?.step(forced: false) }

    private static let radius = 7.5
    private static let line = 2.0
    private static let fade: UInt32 = 320

    init(button: UnsafeMutablePointer<GtkWidget>) {
        gtk_overlay_set_child(op(widget), button)
        gtk_overlay_add_overlay(op(widget), area)
        Gtk.addClass(area, "forge-ring")
        Gtk.addClass(area, "forge-ring-off")
        RepeatingMotion.watch(area) { [weak self] in self?.relay() }
    }

    private static var now: Double { Double(g_get_monotonic_time()) / 1_000_000 }

    /// Points the light at a face. The same kind of face with a new number — the arc a little
    /// further round — is a new target for the clock already running, never a restart of it.
    func apply(_ next: ForgeLight) {
        let previous = light
        light = next
        guard next.isLit else {
            guard previous.isLit else { return }
            lap.lift()
            moving = false
            gtk_widget_add_css_class(area, "forge-ring-off")
            fadeTicket += 1
            let ticket = fadeTicket
            Gtk.after(Self.fade) { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self, self.fadeTicket == ticket, !self.light.isLit else { return }
                    self.paint(ForgeRingFrame(tone: .quiet, track: 0, strokes: []))
                }
            }
            return
        }
        fadeTicket += 1
        gtk_widget_remove_css_class(area, "forge-ring-off")
        if Self.sameFace(previous, next), previous.isLit {
            if !moving { step(forced: true) }
            return
        }
        displayed = 0
        relay()
    }

    /// The desk changed the palette: the same frame again, in the new ink.
    func retheme() {
        paint(lastFrame)
    }

    /// Whether two lights are the same face, whatever number they carry.
    private static func sameFace(_ first: ForgeLight, _ second: ForgeLight) -> Bool {
        switch (first, second) {
        case (.dark, .dark), (.waking, .waking), (.saving, .saving), (.landed, .landed),
            (.failed, .failed), (.waiting, .waiting), (.rendering, .rendering):
            return true
        default:
            return false
        }
    }

    /// Takes the moving-or-still decision again and does whichever it decided: the desk can change
    /// its mind about movement inside a render that lasts minutes.
    private func relay() {
        guard light.isLit else {
            lap.lift()
            return
        }
        moving = lap.lay(on: area, meaning: light.motion)
        lastStep = 0
        step(forced: true)
    }

    private func step(forced: Bool) {
        let time = Self.now
        guard forced || ActivityTuning.wantsFrame(at: time, lastDrawn: lastStep) else { return }
        let elapsed = lastStep == 0 ? 0 : time - lastStep
        lastStep = time
        if case .rendering(let target) = light {
            displayed = moving ? ForgeRing.follow(displayed: displayed, target: target, elapsed: elapsed) : target
        }
        paint(light.frame(at: time, displayed: displayed, reduceMotion: light.motion.isAnimated && !moving))
    }

    private func paint(_ frame: ForgeRingFrame) {
        lastFrame = frame
        let palette = MatrixTheme.palette
        let hex: String
        switch frame.tone {
        case .live: hex = palette.accent
        case .attention: hex = palette.warn
        case .danger: hex = palette.danger
        case .quiet: hex = palette.textDim
        }
        let ink = PresenceRGB(hex: hex) ?? PresenceRGB(red: 0.5, green: 0.5, blue: 0.5)
        let rgb = [ink.red, ink.green, ink.blue]
        let starts = frame.strokes.map(\.start)
        let lengths = frame.strokes.map(\.length)
        let intensities = frame.strokes.map(\.intensity)
        rgb.withUnsafeBufferPointer { rgb in
            starts.withUnsafeBufferPointer { starts in
                lengths.withUnsafeBufferPointer { lengths in
                    intensities.withUnsafeBufferPointer { intensities in
                        tailscode_edge_set(
                            area, rgb.baseAddress, frame.track, Int32(frame.strokes.count),
                            starts.baseAddress, lengths.baseAddress, intensities.baseAddress,
                            Self.radius, Self.line)
                    }
                }
            }
        }
    }

    /// What the light is doing, for a harness that has to prove a claim about it: the face, whether
    /// a clock is turning it, and how much of the ring is inked.
    var reading: String {
        let inked = lastFrame.strokes.reduce(0) { $0 + $1.length }
        return "light=\(light) moving=\(moving) strokes=\(lastFrame.strokes.count) inked="
            + String(format: "%.2f", inked) + " tone=\(lastFrame.tone.rawValue)"
    }
}
