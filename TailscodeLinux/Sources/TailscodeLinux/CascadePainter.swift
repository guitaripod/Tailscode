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
    /// The channels a frame blends between, resolved once for the frame rather than parsed out of
    /// three hex strings at every one of the twenty-six glyphs the wave covers.
    struct Inks {
        let settled: (red: Double, green: Double, blue: Double)
        let edge: (red: Double, green: Double, blue: Double)
        let spark: (red: Double, green: Double, blue: Double)

        init(settled: String, edge: String, spark: String) {
            let fallback = (red: 0.5, green: 0.5, blue: 0.5)
            self.settled = Contrast.channels(settled) ?? fallback
            self.edge = Contrast.channels(edge) ?? fallback
            self.spark = Contrast.channels(spark) ?? fallback
        }
    }

    /// One character's colour and opacity, as the shim wants them: packed RGB and Pango's
    /// sixteen-bit alpha.
    static func paint(_ sample: CascadeSample, inks: Inks) -> (rgb: UInt32, alpha: UInt16) {
        let warmed = Contrast.blendChannels(inks.settled, inks.edge, sample.heat * 0.86)
        let lit = Contrast.blendChannels(warmed, inks.spark, sample.shimmer)
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

    private static func packed(_ colour: (red: Double, green: Double, blue: Double)) -> UInt32 {
        func byte(_ channel: Double) -> UInt32 {
            UInt32((min(max(channel, 0), 1) * 255).rounded())
        }
        return byte(colour.red) << 16 | byte(colour.green) << 8 | byte(colour.blue)
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
    /// The markup the wave is holding, already null-terminated for the shim.
    ///
    /// A frame is supposed to cost a substring and an attribute list. It stopped being that as
    /// soon as the markup arrived as a `String`: handing a Swift string to a C parameter copies it
    /// into a fresh buffer, so the whole answer was allocated and thrown away sixty times a
    /// second, on top of the pane rebuilding the markup itself just as often. The answer changes
    /// when the stream says so, not when the display does — so it is converted where it changes
    /// and every frame after that reads the same bytes.
    private var markup: [CChar] = []
    /// The wave's colours, kept across frames. Two arrays of twenty-six are not much to allocate,
    /// sixty times a second for the length of an answer.
    private var rgb: [UInt32] = []
    private var alpha: [UInt16] = []

    /// What to do with a frame that changed something. The pane repaints exactly the live row.
    var onFrame: (() -> Void)?

    /// What to do with a reveal that stopped moving while it still owed the reader text. The pane
    /// hands that row back whole.
    var onStalled: (() -> Void)?

    private var watching = false
    /// How often the second clock looks. The verdict itself is Core's — `LiveCascade.stalled(at:)`
    /// times the debt against the display's clock rather than counting looks, so a slow hand is
    /// never mistaken for a stopped one however often the timeout happens to fire.
    private static let watchInterval: UInt32 = 300

    var key: String? { live.id }
    var isActive: Bool { live.isActive }
    var isSettled: Bool { live.isSettled }
    var owes: Bool { live.owes }
    var revealed: Int { live.revealed }

    /// The one clock every timed thing in a pane reads: the display's own monotonic time in
    /// seconds. An entrance queued against it lines up with the reveal moving on it.
    static var now: Double { Double(g_get_monotonic_time()) / 1_000_000 }

    /// The rendered text behind markup — what a reader sees, which is what the reveal counts. The
    /// shim parses once and remembers, so asking for it costs nothing on a frame that has already
    /// painted it.
    private static func renderedText(of markup: [CChar]) -> String? {
        let text = markup.withUnsafeBufferPointer { tailscode_markup_text($0.baseAddress) }
        guard let text else { return nil }
        return String(cString: text)
    }

    static func renderedText(of markup: String) -> String? {
        renderedText(of: Array(markup.utf8CString))
    }

    /// Points the wave at the row the stream is writing into, or lets go of it. Letting go settles
    /// the row at once: a finished paragraph with a glowing tail is a lie about what is live.
    ///
    /// The desk is asked here rather than where the clock is installed, and asked again on every
    /// arrival — which is what keeps this reveal off ``RepeatingMotion``'s road without being off
    /// the doctrine: the wave is bounded by the turn that is writing, and a turn that is writing is
    /// arriving. A desk that asks for less motion is answered by the next lump of text, which hands
    /// the row over whole rather than revealing it, exactly as it would have been answered at the
    /// start of the turn.
    func focus(
        _ id: String?, markup: String, sealed: Bool, ultracode: Bool,
        clock: UnsafeMutablePointer<GtkWidget>?
    ) {
        self.ultracode = ultracode
        let bytes = Array(markup.utf8CString)
        guard RepeatingMotion.allowed, let id, let rendered = Self.renderedText(of: bytes) else {
            release()
            return
        }
        live.focus(id, length: rendered.unicodeScalars.count, sealed: sealed, at: Self.now)
        guard live.isActive else {
            release()
            return
        }
        self.markup = bytes
        start(on: clock)
        watch()
    }

    func release() {
        live.focus(nil, rendered: "", sealed: true, at: Self.now)
        markup = []
        watching = false
        stop()
    }

    /// The markdown-safe prefix of what the agent has written, held only while a closer might still
    /// be coming. The judgement is Core's: a cut that stops moving is the end of a part, not a
    /// token in flight, and the rest of the row is handed over rather than held for the turn.
    /// With motion switched off nothing reveals, so nothing needs protecting from a marker that
    /// has not closed yet — and a gate whose give-up clock is reset by every arrival can never
    /// expire, which would leave the row cut at its last unmatched bracket for the rest of the turn.
    /// `markdown` is false for a row that streams code, which the gate must not read as prose.
    func renderable(row: String, _ source: String, sealed: Bool, markdown: Bool) -> String {
        guard RepeatingMotion.allowed else { return source }
        return live.renderable(row: row, source, sealed: sealed, markdown: markdown, at: Self.now)
    }

    /// One frame's arithmetic without the display's clock, so the reveal can be checked without a
    /// mapped window to serve frames.
    @discardableResult
    func advance(to time: Double) -> Bool { live.advance(to: time) }

    /// Paints one frame into the label the live row keeps its words in. The markup was converted
    /// and parsed when the stream last moved, so a frame is a substring and an attribute list
    /// rather than a markdown parse.
    ///
    /// Returns whether the words actually landed. The pane hands the widget over to the wave and
    /// stops diffing it — the whole point of painting in place is that the row is not rebuilt for
    /// every token — so a frame that quietly painted nothing does not leave the row a token behind,
    /// it leaves it wrong for the rest of the turn with nobody watching. A false here is the pane's
    /// cue to take the row back.
    @discardableResult
    func paint(_ label: UnsafeMutablePointer<GtkWidget>) -> Bool {
        guard !markup.isEmpty else { return false }
        let palette = MatrixTheme.palette
        let edge = CascadeTint.edge(for: palette, ultracode: ultracode, phase: live.phase)
        let spark = CascadeTint.spark(for: palette, edge: edge)
        let span = StreamCascade.span
        let inks = CascadeTint.Inks(settled: palette.text, edge: edge, spark: spark)
        if rgb.count != span {
            rgb = [UInt32](repeating: 0, count: span)
            alpha = [UInt16](repeating: 65535, count: span)
        }
        for distance in 0..<span {
            let painted = CascadeTint.paint(live.sample(distance: distance), inks: inks)
            rgb[distance] = painted.rgb
            alpha[distance] = painted.alpha
        }
        let shown = live.revealed
        let landed = markup.withUnsafeBufferPointer { bytes in
            tailscode_label_reveal(
                label, bytes.baseAddress, Int32(shown), Int32(span), &rgb, &alpha) >= 0
        }
        if landed { live.lands(shown, at: Self.now) }
        return landed
    }

    /// Hands the whole row back, unpaced and untinted — what a row that is no longer live must
    /// look like, and what a client with reduced motion sees from the start. Returns whether the
    /// row is now whole, so a repair that could not be made is not mistaken for one that was.
    @discardableResult
    func settle(_ label: UnsafeMutablePointer<GtkWidget>, markup: String) -> Bool {
        tailscode_label_reveal(label, markup, -1, 0, nil, nil) >= 0
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
        look()
    }

    private func look() {
        Gtk.after(Self.watchInterval) { [weak self] in
            guard let self, self.watching else { return }
            guard self.live.isActive else {
                self.watching = false
                return
            }
            guard !self.live.stalled(at: Self.now) else {
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
/// A fade is owned by the widget it is running on, and a widget can be rebuilt halfway through
/// one. The row's value changes — a tool call reaches its result, a thought counts itself up —
/// and the pane makes a new widget for it; the old fade then keeps running on a detached widget
/// until it notices it has no parent, while the replacement is drawn at full opacity because its
/// key has already been seen. The row pops. So every run is registered against its widget, a
/// superseded run stops at its next frame, and the pane can read where a fade had got to and hand
/// that opacity to the widget replacing it.
enum CascadeEntrance {
    private static let frames = 11
    private nonisolated(unsafe) static var runs: [UInt: Int] = [:]
    private nonisolated(unsafe) static var lastRun = 0

    /// The widget is referenced for the length of the fade and released at the end, because a row
    /// can be diffed away mid-animation and a timeout holding a raw pointer into a freed widget is
    /// a crash rather than a dropped frame.
    ///
    /// `delay` is seconds from now, decided by the pane against its own clock rather than by a
    /// position in one batch. `opacity` is where the fade starts, which is zero for a row nobody
    /// has seen and wherever the previous widget had got to for one being handed over.
    static func animate(
        _ widget: UnsafeMutablePointer<GtkWidget>, delay: Double, from opacity: Double = 0,
        onFinish: (@Sendable () -> Void)? = nil
    ) {
        guard RepeatingMotion.allowed else {
            onFinish?()
            return
        }
        gtk_widget_set_opacity(widget, opacity)
        g_object_ref(UnsafeMutableRawPointer(widget))
        let bits = UInt(bitPattern: widget)
        lastRun += 1
        let run = lastRun
        runs[bits] = run
        let first = startingFrame(for: opacity)
        Gtk.after(UInt32(max(0, delay) * 1000)) {
            step(bits, run: run, frame: first, onFinish: onFinish)
        }
    }

    /// Stops the fade running on a widget the pane is about to throw away. The run releases its
    /// reference on its next frame, which is why the widget stays alive long enough to be read.
    static func cancel(_ bits: UInt) {
        runs[bits] = nil
    }

    /// Which frame of the fade already shows this much of the row, so a handover continues the
    /// curve instead of restarting it. The inverse of ``StreamCascade/ease(_:)``.
    private static func startingFrame(for opacity: Double) -> Int {
        guard opacity > 0 else { return 0 }
        let clamped = min(max(opacity, 0), 1)
        let progress = 1 - pow(1 - clamped, 1.0 / 3.0)
        return min(frames, Int((progress * Double(frames)).rounded(.down)))
    }

    private static func step(
        _ bits: UInt, run: Int, frame: Int, onFinish: (@Sendable () -> Void)?
    ) {
        guard let held = UnsafeMutableRawPointer(bitPattern: bits) else { return }
        guard runs[bits] == run else {
            g_object_unref(held)
            return
        }
        let widget = held.assumingMemoryBound(to: GtkWidget.self)
        let progress = StreamCascade.ease(Double(frame) / Double(frames))
        gtk_widget_set_opacity(widget, progress)
        guard frame < frames, gtk_widget_get_parent(widget) != nil else {
            gtk_widget_set_opacity(widget, 1)
            runs[bits] = nil
            g_object_unref(held)
            onFinish?()
            return
        }
        Gtk.after(16) { step(bits, run: run, frame: frame + 1, onFinish: onFinish) }
    }
}
