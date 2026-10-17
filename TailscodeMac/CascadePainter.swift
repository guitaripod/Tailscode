import AppKit
import TailscodeCore

/// What a row needs to paint one frame of the wave.
///
/// The reveal counts *rendered* characters, so the row is rendered once per arrival and only its
/// colours change per frame: everything past the reveal is drawn at zero alpha rather than cut
/// off, and the last `span` revealed glyphs carry the wave.
@MainActor
struct CascadeTail {
    let revealed: Int
    let span: Int
    let phase: Double
    let edge: NSColor
    let spark: NSColor
    /// The edge and the spark as the hex the blend reads, resolved once by whoever made the tail:
    /// the accent does not change between frames, and resolving a colour under an appearance for
    /// every glyph of every frame was most of what the wave spent.
    var edgeHex: String?
    var sparkHex: String?

    /// The row as it should look this frame. Everything past the reveal is drawn at zero alpha
    /// rather than cut off: the paragraph is measured once when it arrives and never again, so no
    /// glyph moves after it lands and no line re-wraps under the reader. A frame changes colours,
    /// never layout.
    ///
    /// Clear ink is not the whole of invisible. A chip behind an inline code span and a rule through
    /// a struck-out run are drawn from the glyphs' own boxes rather than from their colour, so left
    /// alone they march ahead of the sentence as a row of empty boxes — text ahead of the reveal,
    /// which is the one thing this technique exists to prevent.
    func paint(_ rendered: NSAttributedString, settled: NSColor) -> NSAttributedString {
        let total = rendered.length
        let shown = min(max(revealed, 0), total)
        let slice = NSMutableAttributedString(attributedString: rendered)
        if shown < total {
            let unread = NSRange(location: shown, length: total - shown)
            slice.addAttribute(.foregroundColor, value: NSColor.clear, range: unread)
            slice.removeAttribute(.backgroundColor, range: unread)
            slice.removeAttribute(.strikethroughStyle, range: unread)
        }
        tint(slice, upTo: shown, settled: settled)
        return slice
    }

    /// The wave tints what is already there rather than replacing it: a keyword in a code block,
    /// a link, an inline code span all keep their own colour as the settled end of the blend, so a
    /// glyph leaving the wave lands on the colour it would have had if it had never been in one.
    func tint(_ string: NSMutableAttributedString, upTo shown: Int, settled: NSColor) {
        guard span > 0, shown > 0 else { return }
        let fallback = CascadeTint.hex(settled)
        let leading = edgeHex ?? CascadeTint.hex(edge)
        let burn = sparkHex ?? CascadeTint.hex(spark)
        var resolved: [ObjectIdentifier: String] = [:]
        for distance in 0..<min(span, shown) {
            let index = shown - 1 - distance
            let range = NSRange(location: index, length: 1)
            let existing = string.attribute(.foregroundColor, at: index, effectiveRange: nil)
            let base: String
            if let colour = existing as? NSColor {
                let id = ObjectIdentifier(colour)
                if let hit = resolved[id] {
                    base = hit
                } else {
                    base = CascadeTint.hex(colour)
                    resolved[id] = base
                }
            } else {
                base = fallback
            }
            let sample = StreamCascade.sample(distance: distance, phase: phase)
            let colour = CascadeTint.colour(sample, settled: base, edge: leading, spark: burn)
            string.addAttribute(
                .foregroundColor, value: colour.withAlphaComponent(sample.alpha), range: range)
        }
    }
}

/// The row being written, held as the paint it last had, so a frame changes only what moved.
///
/// The wave used to build a whole new attributed string for the answer on every frame: a copy of
/// the rendering, the unread part cleared and the last glyphs tinted. Between two frames only the
/// characters the reveal just crossed and the ones the band is on differ, so the paint is kept and
/// those ranges are put back to what the rendering says and tinted again. The buffer is valid for
/// one rendering of one row; a new rendering, another row or a reveal that went backwards starts it
/// over, and the result is byte for byte what `CascadeTail.paint` makes of the same inputs.
@MainActor
final class CascadePaintBuffer {
    private let rendered: NSAttributedString
    private let key: String
    private(set) var string: NSMutableAttributedString
    private var shown: Int
    private var waveLow: Int

    init(rendered: NSAttributedString, key: String, revealed: Int) {
        self.rendered = rendered
        self.key = key
        string = NSMutableAttributedString(attributedString: rendered)
        shown = min(max(revealed, 0), rendered.length)
        waveLow = shown
        clear(from: shown)
    }

    func matches(rendered: NSAttributedString, key: String) -> Bool {
        self.rendered === rendered && self.key == key
    }

    /// The row as the tail says it looks this frame, painted into the held string.
    func paint(_ tail: CascadeTail, settled: NSColor) -> NSAttributedString {
        let total = rendered.length
        let next = min(max(tail.revealed, 0), total)
        if next < shown {
            string = NSMutableAttributedString(attributedString: rendered)
            shown = next
            waveLow = next
            clear(from: next)
        } else {
            let from = max(0, min(waveLow, shown))
            if next > from {
                let range = NSRange(location: from, length: next - from)
                string.replaceCharacters(in: range, with: rendered.attributedSubstring(from: range))
            }
            shown = next
        }
        tail.tint(string, upTo: shown, settled: settled)
        waveLow = max(0, shown - tail.span)
        return string
    }

    private func clear(from index: Int) {
        let total = rendered.length
        guard index < total else { return }
        let unread = NSRange(location: index, length: total - index)
        string.addAttribute(.foregroundColor, value: NSColor.clear, range: unread)
        string.removeAttribute(.backgroundColor, range: unread)
        string.removeAttribute(.strikethroughStyle, range: unread)
    }
}

/// The shared wave, resolved against AppKit's colours.
///
/// The blend runs through `Contrast` in OKLab rather than through NSColor's own sRGB
/// interpolation, so the walk from prose colour to accent is the same walk the phone and the GTK
/// client make — one effect on three toolkits, and a midpoint that goes grey on one of them is a
/// drift nobody notices until two screenshots sit side by side.
@MainActor
enum CascadeTint {
    static func colour(_ sample: CascadeSample, settled: String, edge: String, spark: String)
        -> NSColor
    {
        let warmed = Contrast.blend(settled, edge, sample.heat * 0.86) ?? settled
        let lit = Contrast.blend(warmed, spark, sample.shimmer) ?? warmed
        return colour(lit)
    }

    /// The specular colour the band pushes toward: brighter than the accent in the dark, denser in
    /// the light, so a sweep reads as light passing over the words either way.
    /// Under a theme the extreme is the palette's own ink rather than white or near-black, because
    /// a spark that leaves the palette reads as a defect in the glyph rather than as light.
    static func spark(for edge: NSColor) -> NSColor {
        let hex = hex(edge)
        let toward =
            ThemePalette.current?.text ?? (appearance.isDark ? "#ffffff" : "#101014")
        return colour(Contrast.blend(hex, toward, 0.5) ?? hex)
    }

    /// The leading edge: the system accent, or the shared rainbow while ultracode is on, so the
    /// unlocked powers are legible in the writing and not only around the prompt box.
    static func edge(ultracode: Bool, phase: Double) -> NSColor {
        guard ultracode else { return MacTheme.Color.accent }
        let stop = StreamCascade.rainbow(at: phase)
        return NSColor(srgbRed: stop.red, green: stop.green, blue: stop.blue, alpha: 1)
    }

    /// The window's appearance when there is an application to ask, and whatever is being drawn in
    /// when there is not — `--selftest` runs this arithmetic with no NSApp at all.
    private static var appearance: NSAppearance {
        NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
    }

    /// A semantic colour has no components until an appearance resolves it, and the wave is
    /// arithmetic on components — so the resolution happens under the window's own appearance
    /// rather than whatever the caller happened to be drawing in.
    static func hex(_ colour: NSColor) -> String {
        var rgb: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            rgb = colour.usingColorSpace(.sRGB)
        }
        guard let rgb else { return "#ffffff" }
        func clamp(_ value: CGFloat) -> Double { Double(min(max(value, 0), 1)) }
        return Contrast.hex(
            red: clamp(rgb.redComponent), green: clamp(rgb.greenComponent),
            blue: clamp(rgb.blueComponent))
    }

    static func colour(_ hex: String) -> NSColor {
        var digits = Substring(hex)
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard let value = UInt32(digits, radix: 16) else { return .labelColor }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1)
    }
}

/// The transcript's hand: it holds the one row the agent is writing into, moves the reveal on the
/// display's own clock, and tells the controller when that row needs repainting.
///
/// Exactly one row grows at a time, which is what makes an animation this fine affordable — every
/// row above it is settled text nobody re-measures, so a frame costs one label's worth of layout
/// rather than a transcript's.
@MainActor
final class CascadePainter {
    private var live = LiveCascade()
    private var link: CADisplayLink?
    private var watchdog: Timer?
    private var ultracode = false
    private var inks: (appearance: String, theme: String, edge: String, spark: String)?

    /// The view whose screen sets the frame rate. Without one there is nothing to pace against, so
    /// the wave never starts and the text simply appears.
    weak var host: NSView?

    /// Called on a frame that changed something. The controller repaints exactly the live row.
    var onFrame: (() -> Void)?

    /// Called when the reveal stopped moving while it still owed the reader text. The controller
    /// hands that row back whole.
    var onStalled: (() -> Void)?

    var key: String? { live.id }
    /// Whether the wave holds a display link or its watchdog right now.
    var isLinked: Bool { link != nil || watchdog != nil }
    var isActive: Bool { live.isActive }
    var isSettled: Bool { live.isSettled }
    var owes: Bool { live.owes }
    var revealed: Int { live.revealed }

    /// Whether the desktop wants motion at all. A person who has asked for less of it has said
    /// what they want from a cascade, and the answer is the text — and so has a window shedding
    /// load at loaded or above, where text appears as it arrives (`MotionBudget`).
    static var motionAllowed: Bool {
        MotionBudget.cascadeAllowed
    }

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(budgetChanged), name: MotionBudget.didChange, object: nil)
    }

    /// The shed level moved what the cascade may spend. A reveal no longer allowed hands its row
    /// over whole, the way a stalled one does; one still allowed takes the level's frame rate.
    @objc private func budgetChanged() {
        guard live.isActive else { return }
        guard Self.motionAllowed else {
            stop()
            onStalled?()
            return
        }
        applyTempo()
    }

    /// Points the wave at the row the stream is writing into, with that row's fully rendered text.
    /// Passing nil lets go of it: a finished paragraph with a glowing tail is a lie about what is
    /// live.
    func focus(_ id: String?, length: Int, sealed: Bool, ultracode: Bool) {
        self.ultracode = ultracode
        guard Self.motionAllowed, let id else {
            release()
            return
        }
        live.focus(id, length: length, sealed: sealed, at: CACurrentMediaTime())
        guard live.isActive else {
            stop()
            unwatch()
            return
        }
        if live.tempo != .stopped { start() }
        if live.tempo != .stopped || live.owes { watch() } else { unwatch() }
    }

    /// Changes whenever a frame could show something new: words arrived, the reveal moved, the band
    /// did. A frame painted at this number is a frame of the row as it stands.
    var paintRevision: Int { live.paintRevision }

    /// How many times the words this row is revealing have changed.
    var textRevision: Int { live.textRevision }

    /// How often the wave wants a frame right now.
    var tempo: CascadeTempo { live.tempo }

    func release() {
        live.focus(nil, rendered: "", sealed: true, at: CACurrentMediaTime())
        stop()
    }

    /// The markdown-safe prefix of what the agent has written, held only while a closer might still
    /// be coming. The judgement is Core's: a cut that stops moving is the end of a part, not a
    /// token in flight, and the rest of the row is handed over rather than held for the turn.
    /// With motion switched off nothing reveals, so nothing needs protecting from a marker that
    /// has not closed yet — and a gate whose give-up clock is reset by every arrival can never
    /// expire, which would leave the row cut at its last unmatched bracket for the rest of the turn.
    ///
    /// `markdown` is the row's own answer to whether the gate applies to it at all. Prose has inline
    /// tokens worth protecting; code has the same characters meaning something else entirely, and
    /// judging `**kwargs` or `self._value` as a half-open marker freezes the block behind it until
    /// the gate gives up, dumps the rest at once, and freezes again on the next one.
    func renderable(row: String, _ source: String, sealed: Bool, markdown: Bool) -> String {
        guard Self.motionAllowed else { return source }
        return live.renderable(
            row: row, source, sealed: sealed, markdown: markdown, at: CACurrentMediaTime())
    }

    /// The wave's second clock, and the reason a stuck answer cannot outlive its turn.
    ///
    /// The reveal moves on the display's clock, and the display's clock is not this app's to
    /// promise: a window that is occluded, on a sleeping screen, or behind a frame that ran long
    /// simply stops being served, and the reveal stops with it — leaving a row holding half a
    /// sentence with nothing coming to finish it. So the wave also keeps a timer, which no display
    /// link can take down, and Core times the debt: a reveal that still owes text and has not moved
    /// for its patience is given up and the row handed over whole.
    private func watch() {
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.live.isActive, self.live.tempo != .stopped || self.live.owes else {
                    self.unwatch()
                    return
                }
                guard self.live.stalled(at: CACurrentMediaTime()) else { return }
                self.unwatch()
                self.onStalled?()
            }
        }
    }

    private func unwatch() {
        watchdog?.invalidate()
        watchdog = nil
    }

    /// What the transcript just proved it put on screen. The reveal is arithmetic and arithmetic
    /// paints nothing, so a frame that quietly painted no row leaves the debt standing and the
    /// watchdog is the one that notices.
    func landed() {
        live.lands(live.revealed, at: CACurrentMediaTime())
    }

    /// The wave a row should paint, or nil when it is not the live one.
    func tail(for key: String) -> CascadeTail? {
        guard live.id == key, Self.motionAllowed else { return nil }
        let edge = CascadeTint.edge(ultracode: ultracode, phase: live.phase)
        var tail = CascadeTail(
            revealed: live.revealed, span: StreamCascade.span, phase: live.phase, edge: edge,
            spark: CascadeTint.spark(for: edge))
        let hexes = edgeInks(for: tail)
        tail.edgeHex = hexes.edge
        tail.sparkHex = hexes.spark
        return tail
    }

    /// The edge and the spark as hex. The accent is the same on every frame, so it is resolved once
    /// per appearance and theme; the rainbow of an unlocked power moves every frame and is resolved
    /// every frame.
    private func edgeInks(for tail: CascadeTail) -> (edge: String, spark: String) {
        guard !ultracode else {
            return (CascadeTint.hex(tail.edge), CascadeTint.hex(tail.spark))
        }
        let appearance = NSApp?.effectiveAppearance.name.rawValue ?? ""
        let theme = ThemeSelection.themeID
        if let inks, inks.appearance == appearance, inks.theme == theme {
            return (inks.edge, inks.spark)
        }
        let fresh = (CascadeTint.hex(tail.edge), CascadeTint.hex(tail.spark))
        inks = (appearance, theme, fresh.0, fresh.1)
        return fresh
    }

    /// The one clock in this client that is deliberately not the vocabulary's tempo.
    ///
    /// A mark says a fact and thirty frames a second is plenty to say it with; this is a renderer,
    /// writing an answer out glyph by glyph under the reader's eye, and text revealed at thirty
    /// reads as a hand that stutters rather than one that writes. It asks for the panel's own rate
    /// on purpose — `ActivityTuning` governs marks, not the cascade — while this is the only pane
    /// streaming, and takes the rate `CascadeRate` gives for the number streaming and the level
    /// the window sheds at, through `MotionBudget`.
    private func start() {
        guard link == nil else {
            applyTempo()
            return
        }
        guard let host else { return }
        let link = host.displayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = Self.range(for: live.tempo)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stop() {
        link?.invalidate()
        link = nil
        unwatch()
    }

    /// The rate a frame is wanted at. Characters being revealed are a renderer putting words on the
    /// screen and take the panel's rate (under the level's cap); a band that is only shimmering
    /// over a row that has caught up is a mark, and takes the activity tempo like every other.
    private static func range(for tempo: CascadeTempo) -> CAFrameRateRange {
        guard tempo == .activity else { return MotionBudget.cascadeRange }
        let cap = MotionBudget.cascadeRange
        let tempo = CAFrameRateRange.activityTempo
        guard cap.maximum > 0, cap.maximum < tempo.maximum else { return tempo }
        return cap
    }

    /// Moves the link to the tempo the row is at now, and lets it go altogether once the reveal has
    /// caught up and the band has left the tail: a row that is open and has nothing more to write
    /// holds still and costs no frames, and the next words to arrive start the clock again.
    private func applyTempo() {
        guard let link else { return }
        switch live.tempo {
        case .stopped:
            link.invalidate()
            self.link = nil
        case .activity, .display:
            link.preferredFrameRateRange = Self.range(for: live.tempo)
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        if live.advance(to: link.timestamp) { onFrame?() }
        if !live.isActive {
            stop()
            return
        }
        applyTempo()
    }
}

extension TranscriptRow {
    /// The text the agent is still writing into, when this row is the kind that grows a character
    /// at a time. Everything else — a tool call, a picture, a seam — arrives whole and has nothing
    /// for the cascade to pace.
    /// Whether this row is a rail rather than something the agent wrote. A rail is docked after
    /// the prose that mentioned its addresses, so it is the last row though the prose is the one
    /// being streamed into.
    var isLinkRail: Bool {
        if case .linkRail = kind { return true }
        return false
    }

    var streamedText: String? {
        switch kind {
        case .agentProse(let text, _): return text
        case .codeBlock(_, let body): return body
        default: return nil
        }
    }

    /// The same row holding only the part of its source that is safe to render — never ending
    /// inside a half-open markdown token, so the renderer cannot flash a marker it is about to
    /// swallow.
    @MainActor
    func held(to safe: String) -> TranscriptRow {
        switch kind {
        case .agentProse:
            return TranscriptRow(
                key: key,
                kind: .agentProse(text: safe, rendered: MacMarkdown.render(safe, cache: false)))
        case .codeBlock(let language, _):
            return TranscriptRow(key: key, kind: .codeBlock(language: language, body: safe))
        default:
            return self
        }
    }

    /// What the reveal counts: the characters a reader will actually see, markers already eaten.
    var renderedText: String? {
        switch kind {
        case .agentProse(_, let rendered): return rendered.string
        case .codeBlock(_, let body): return body
        default: return nil
        }
    }

    /// Whether the words this row is growing are markdown the gate should read. Only prose is: a
    /// code block's source is full of characters that are markdown's punctuation and the language's
    /// syntax at the same time, and there is no inline token inside a fence for a reader to be
    /// protected from.
    var streamsMarkdown: Bool {
        if case .agentProse = kind { return true }
        return false
    }

    /// Whether this row's first appearance is worth announcing. The words a person typed have been
    /// on screen since they pressed Enter — echoed optimistically under one key, then re-keyed when
    /// the server confirms the same sentence — so fading them in is not an arrival, it is the prompt
    /// blinking out and coming back. The rule between turns goes with it: a hairline that fades in
    /// under a prompt that did not is one seam moving in two halves.
    var announcesArrival: Bool {
        switch kind {
        case .userText, .turnBreak: return false
        default: return true
        }
    }
}

/// New rows do not blink into existence. A tool call, the picture it read and the sentence after
/// it arrive together, and landing them all on the same frame reads as the transcript jumping;
/// landing them a beat apart, in order, reads as it growing. Same easing as everything else, so
/// the whole product moves with one hand.
@MainActor
enum CascadeEntrance {
    /// When the next row may land. The stagger is queued against one clock rather than against a
    /// row's position in the batch it arrived in: states land many times a second, and a batch that
    /// restarts its count at zero lets a row from the next one fade in above a gap that is still
    /// blank — the transcript filling in back-to-front, with holes.
    private static var nextEntrance: CFTimeInterval = 0

    static func animate(_ view: NSView) {
        guard CascadePainter.motionAllowed, MotionBudget.animationAllowed else { return }
        view.wantsLayer = true
        view.alphaValue = 0
        let now = CACurrentMediaTime()
        let at = min(max(now, nextEntrance), now + StreamCascade.entranceCeiling)
        nextEntrance = at + StreamCascade.entranceStep
        DispatchQueue.main.asyncAfter(deadline: .now() + (at - now)) { [weak view] in
            guard let view, view.superview != nil else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.19
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                view.animator().alphaValue = 1
            } completionHandler: {
                MainActor.assumeIsolated { view.alphaValue = 1 }
            }
        }
    }
}
