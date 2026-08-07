import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The shared wave, resolved against a GTK theme.
///
/// `StreamCascade` says how hot a glyph is and how brightly the band over it burns; this says what
/// those mean in a palette that might be Gruvbox or might be paper white. The settled colour is
/// the prose colour the row would have anyway, so a character that leaves the wave is
/// indistinguishable from one that was never in it — the effect has to disappear completely, or
/// every finished answer ends up wearing a differently-coloured tail.
enum CascadeTint {
    /// One character's colour and opacity, as the shim wants them: packed RGB and Pango's
    /// sixteen-bit alpha.
    static func paint(_ sample: CascadeSample, settled: String, edge: String, spark: String)
        -> (rgb: UInt32, alpha: UInt16)
    {
        let warmed = Contrast.blend(settled, edge, sample.heat * 0.86) ?? settled
        let lit = Contrast.blend(warmed, spark, sample.shimmer) ?? warmed
        return (packed(lit), UInt16(max(1, min(65535, sample.alpha * 65535))))
    }

    /// The specular colour the band pushes toward: brighter than the accent on a dark canvas,
    /// denser on a light one, so a sweep reads as light passing over the words either way.
    static func spark(for palette: Palette, edge: String) -> String {
        Contrast.blend(edge, palette.isDark ? "#ffffff" : "#101014", 0.5) ?? edge
    }

    /// The leading edge's colour: the theme's accent, or the shared rainbow while ultracode is on,
    /// so the unlocked powers are legible in the writing and not only around the prompt box.
    static func edge(for palette: Palette, ultracode: Bool, phase: Double) -> String {
        guard ultracode else { return palette.accent }
        let colour = StreamCascade.rainbow(at: phase)
        return Contrast.hex(red: colour.red, green: colour.green, blue: colour.blue)
    }

    private static func packed(_ hex: String) -> UInt32 {
        var digits = Substring(hex)
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        return UInt32(digits, radix: 16) ?? 0
    }
}

/// The pane's hand: it holds the one row the agent is writing into, moves the reveal on the
/// display's own clock, and paints the trailing glyphs with the wave.
///
/// Frames come from `gtk_widget_add_tick_callback`, not from a chained timeout. A timeout drifts
/// against the compositor and lands two frames in one refresh and none in the next, which is
/// exactly the stutter a cascade exists to remove — the frame clock is what the screen is doing.
final class CascadePainter: @unchecked Sendable {
    private var live = LiveCascade()
    private var ultracode = false
    private var tick: UInt = 0
    private var clockWidget: UnsafeMutablePointer<GtkWidget>?

    /// What to do with a frame that changed something. The pane repaints exactly the live row.
    var onFrame: (() -> Void)?

    /// What to do with a reveal that stopped moving while it still owed the reader text. The pane
    /// hands that row back whole.
    var onStalled: (() -> Void)?

    private var watching = false
    private var watchedReveal = -1
    private var stillFrames = 0
    /// How often the second clock looks, and how many looks in a row a motionless reveal gets
    /// before the row is given up. Long enough that a slow hand is never mistaken for a stopped
    /// one — the pacer's own floor moves the reveal every frame while it owes anything at all.
    private static let watchInterval: UInt32 = 400
    private static let watchStrikes = 3

    var key: String? { live.id }
    var isActive: Bool { live.isActive }
    var isSettled: Bool { live.isSettled }
    var revealed: Int { live.revealed }

    /// Whether the desktop wants motion at all, read per turn rather than per frame.
    static var motionAllowed: Bool { tailscode_animations_enabled() != 0 }

    private static var now: Double { Double(g_get_monotonic_time()) / 1_000_000 }

    /// The rendered text behind markup — what a reader sees, which is what the reveal counts. The
    /// shim parses once and remembers, so asking for it costs nothing on a frame that has already
    /// painted it.
    static func renderedText(of markup: String) -> String? {
        guard let text = tailscode_markup_text(markup) else { return nil }
        return String(cString: text)
    }

    /// Points the wave at the row the stream is writing into, or lets go of it. Letting go settles
    /// the row at once: a finished paragraph with a glowing tail is a lie about what is live.
    func focus(
        _ id: String?, markup: String, sealed: Bool, ultracode: Bool,
        clock: UnsafeMutablePointer<GtkWidget>?
    ) {
        self.ultracode = ultracode
        guard Self.motionAllowed, let id, let rendered = Self.renderedText(of: markup) else {
            live.focus(nil, rendered: "", sealed: true, at: Self.now)
            stop()
            return
        }
        live.focus(id, rendered: rendered, sealed: sealed, at: Self.now)
        start(on: clock)
        watch()
    }

    func release() {
        live.focus(nil, rendered: "", sealed: true, at: Self.now)
        stop()
    }

    /// Paints one frame into the label the live row keeps its words in. The markup is parsed once
    /// by the shim and cached, so a frame is a substring and an attribute list rather than a
    /// markdown parse.
    func paint(_ label: UnsafeMutablePointer<GtkWidget>, markup: String) {
        let palette = MatrixTheme.palette
        let edge = CascadeTint.edge(for: palette, ultracode: ultracode, phase: live.phase)
        let spark = CascadeTint.spark(for: palette, edge: edge)
        let span = StreamCascade.span
        var rgb = [UInt32](repeating: 0, count: span)
        var alpha = [UInt16](repeating: 65535, count: span)
        for distance in 0..<span {
            let painted = CascadeTint.paint(
                live.sample(distance: distance), settled: palette.text, edge: edge, spark: spark)
            rgb[distance] = painted.rgb
            alpha[distance] = painted.alpha
        }
        _ = tailscode_label_reveal(
            label, markup, Int32(live.revealed), Int32(span), &rgb, &alpha)
    }

    /// Hands the whole row back, unpaced and untinted — what a row that is no longer live must
    /// look like, and what a client with reduced motion sees from the start.
    func settle(_ label: UnsafeMutablePointer<GtkWidget>, markup: String) {
        _ = tailscode_label_reveal(label, markup, -1, 0, nil, nil)
    }

    /// The wave's second clock, and the reason a stuck answer cannot outlive its turn.
    ///
    /// The reveal moves on the display's clock, and the display's clock is not this app's to
    /// promise: a compositor stops sending frames to a window nobody is looking at, and a frame
    /// that runs long starves whatever is under it. Either way the reveal simply stops, and a row
    /// that stopped being revealed is a row holding half a sentence with nothing coming to finish
    /// it — the settle it is waiting for rides on the same main loop that just stopped delivering.
    /// So the wave also keeps a timeout, which no frame clock can take down: a reveal that still
    /// owes text and has not moved for three looks is given up and the row handed over whole.
    private func watch() {
        guard !watching else { return }
        watching = true
        watchedReveal = -1
        stillFrames = 0
        look()
    }

    private func look() {
        Gtk.after(Self.watchInterval) { [weak self] in
            guard let self, self.watching else { return }
            guard self.live.isActive else {
                self.watching = false
                return
            }
            if self.live.isSettled || self.live.revealed != self.watchedReveal {
                self.stillFrames = 0
            } else {
                self.stillFrames += 1
            }
            self.watchedReveal = self.live.revealed
            guard self.stillFrames < Self.watchStrikes else {
                self.watching = false
                self.onStalled?()
                return
            }
            self.look()
        }
    }

    /// The widget driving the clock is referenced for as long as a tick is installed. A pane can
    /// be torn down between frames, and removing a callback from a freed widget is a crash rather
    /// than a dropped frame.
    private func start(on clock: UnsafeMutablePointer<GtkWidget>?) {
        guard tick == 0, let clock else { return }
        g_object_ref(UnsafeMutableRawPointer(clock))
        clockWidget = clock
        let box = Unmanaged.passUnretained(self).toOpaque()
        tick = UInt(
            tailscode_add_tick(
                clock,
                { raw in
                    guard let raw else { return }
                    let painter = Unmanaged<CascadePainter>.fromOpaque(raw).takeUnretainedValue()
                    painter.step()
                }, box))
    }

    private func step() {
        guard live.advance(to: Self.now) else { return }
        onFrame?()
        if !live.isActive { stop() }
    }

    private func stop() {
        guard let clockWidget else {
            tick = 0
            return
        }
        if tick != 0 { tailscode_remove_tick(clockWidget, guint(tick)) }
        tick = 0
        g_object_unref(UnsafeMutableRawPointer(clockWidget))
        self.clockWidget = nil
    }

    deinit { stop() }
}

/// New rows do not blink into existence. A tool call, the picture it read and the sentence after
/// it arrive together, and landing them all on the same frame reads as the transcript jumping;
/// landing them a beat apart, in order, reads as it growing. Same easing as everything else, so
/// the whole product moves with one hand.
enum CascadeEntrance {
    private static let frames = 11

    /// The widget is referenced for the length of the fade and released at the end, because a row
    /// can be diffed away mid-animation and a timeout holding a raw pointer into a freed widget is
    /// a crash rather than a dropped frame.
    static func animate(_ widget: UnsafeMutablePointer<GtkWidget>, index: Int, of count: Int) {
        guard CascadePainter.motionAllowed else { return }
        gtk_widget_set_opacity(widget, 0)
        g_object_ref(UnsafeMutableRawPointer(widget))
        let bits = UInt(bitPattern: widget)
        let delay = StreamCascade.entranceDelay(index: index, of: count)
        Gtk.after(UInt32(delay * 1000)) { step(bits, frame: 0) }
    }

    private static func step(_ bits: UInt, frame: Int) {
        guard let held = UnsafeMutableRawPointer(bitPattern: bits) else { return }
        let widget = held.assumingMemoryBound(to: GtkWidget.self)
        let progress = StreamCascade.ease(Double(frame) / Double(frames))
        gtk_widget_set_opacity(widget, progress)
        guard frame < frames, gtk_widget_get_parent(widget) != nil else {
            gtk_widget_set_opacity(widget, 1)
            g_object_unref(held)
            return
        }
        Gtk.after(16) { step(bits, frame: frame + 1) }
    }
}
