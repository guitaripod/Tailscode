import TailscodeCore
import UIKit

/// What a cell needs to paint one frame of the wave.
///
/// The reveal counts *rendered* characters, so a row is rendered once per arrival and only its
/// colours change per frame: everything past the reveal is drawn at zero alpha rather than cut
/// off, and the last `span` revealed glyphs carry the wave.
@MainActor
struct CascadeTail {
    let revealed: Int
    let span: Int
    let phase: Double
    let edge: UIColor
    let spark: UIColor

    /// The row as it should look this frame. Everything past the reveal is drawn at zero alpha
    /// rather than cut off: the paragraph is measured once when it arrives and never again, so no
    /// glyph moves after it lands and no line re-wraps under the reader. A frame changes colours,
    /// never layout.
    func paint(_ rendered: NSAttributedString, settled: UIColor) -> NSAttributedString {
        let total = rendered.length
        let shown = min(max(revealed, 0), total)
        let slice = NSMutableAttributedString(attributedString: rendered)
        if shown < total {
            slice.addAttribute(
                .foregroundColor, value: UIColor.clear,
                range: NSRange(location: shown, length: total - shown))
        }
        tint(slice, upTo: shown, settled: settled)
        return slice
    }

    /// Repaints the wave over a text view's existing storage when the glyphs did not change since
    /// the last frame: only colours move, so nothing re-measures and no line can re-wrap under
    /// the reader. Text that arrived must go through `paint` — a different length is a new
    /// paragraph.
    func repaint(_ storage: NSMutableAttributedString, base: NSAttributedString, settled: UIColor) {
        let total = base.length
        guard total > 0, storage.length == total else { return }
        let shown = min(max(revealed, 0), total)
        let bandStart = max(0, shown - span)
        storage.beginEditing()
        base.enumerateAttributes(
            in: NSRange(location: bandStart, length: total - bandStart), options: []
        ) { attributes, range, _ in
            storage.setAttributes(attributes, range: range)
        }
        if shown < total {
            storage.addAttribute(
                .foregroundColor, value: UIColor.clear,
                range: NSRange(location: shown, length: total - shown))
        }
        tint(storage, upTo: shown, settled: settled)
        storage.endEditing()
    }

    /// The wave tints what is already there rather than replacing it: a keyword in a code block, a
    /// link, an inline code span all keep their own colour as the settled end of the blend, so a
    /// glyph leaving the wave lands on the colour it would have had if it had never been in one.
    private func tint(_ string: NSMutableAttributedString, upTo shown: Int, settled: UIColor) {
        guard span > 0, shown > 0 else { return }
        let traits = UITraitCollection.current
        let fallback = CascadeTint.hex(settled, traits)
        let leading = CascadeTint.hex(edge, traits)
        let burn = CascadeTint.hex(spark, traits)
        for distance in 0..<min(span, shown) {
            let index = shown - 1 - distance
            let range = NSRange(location: index, length: 1)
            let existing = string.attribute(.foregroundColor, at: index, effectiveRange: nil)
            let base = (existing as? UIColor).map { CascadeTint.hex($0, traits) } ?? fallback
            let sample = StreamCascade.sample(distance: distance, phase: phase)
            let colour = CascadeTint.colour(sample, settled: base, edge: leading, spark: burn)
            string.addAttribute(
                .foregroundColor, value: colour.withAlphaComponent(sample.alpha), range: range)
        }
    }
}

/// The shared wave, resolved against UIKit's colours.
///
/// The blend runs through `Contrast` in OKLab rather than through UIColor's own sRGB
/// interpolation, so the walk from prose colour to accent is the same walk the GTK and AppKit
/// clients make — one effect on three toolkits, and a midpoint that goes grey on one of them is a
/// drift nobody notices until two screenshots sit side by side.
@MainActor
enum CascadeTint {
    static func colour(_ sample: CascadeSample, settled: String, edge: String, spark: String)
        -> UIColor
    {
        let warmed = Contrast.blend(settled, edge, sample.heat * 0.86) ?? settled
        let lit = Contrast.blend(warmed, spark, sample.shimmer) ?? warmed
        return colour(lit)
    }

    /// The specular colour the band pushes toward: brighter than the accent in the dark, denser in
    /// the light, so a sweep reads as light passing over the words either way.
    /// Under a theme the extreme is the palette's own ink rather than white or near-black, because
    /// a spark that leaves the palette reads as a defect in the glyph rather than as light.
    static func spark(for edge: UIColor, traits: UITraitCollection) -> UIColor {
        let hex = hex(edge, traits)
        let toward =
            traits.palette?.text ?? (traits.userInterfaceStyle == .light ? "#101014" : "#ffffff")
        return colour(Contrast.blend(hex, toward, 0.5) ?? hex)
    }

    /// The leading edge: the app's accent, or the shared rainbow while ultracode is on, so the
    /// unlocked powers are legible in the writing and not only around the composer.
    static func edge(ultracode: Bool, phase: Double) -> UIColor {
        guard ultracode else { return Theme.Color.accent }
        let stop = StreamCascade.rainbow(at: phase)
        return UIColor(red: stop.red, green: stop.green, blue: stop.blue, alpha: 1)
    }

    static func hex(_ colour: UIColor, _ traits: UITraitCollection) -> String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        colour.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func clamp(_ value: CGFloat) -> Double { Double(min(max(value, 0), 1)) }
        return Contrast.hex(red: clamp(red), green: clamp(green), blue: clamp(blue))
    }

    static func colour(_ hex: String) -> UIColor {
        var digits = Substring(hex)
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard let value = UInt32(digits, radix: 16) else { return .label }
        return UIColor(
            red: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1)
    }
}

/// The transcript's hand: it holds the one row the agent is writing into, moves the reveal on the
/// display's own clock — up to 120Hz where the screen has it — and tells the controller when that
/// row needs repainting.
///
/// Exactly one row grows at a time, which is what makes an animation this fine affordable: every
/// row above it is settled text nobody re-measures, so a frame costs one cell's worth of layout
/// rather than a transcript's.
@MainActor
final class CascadeDriver {
    private var live = LiveCascade()
    private var link: CADisplayLink?
    private var watchdog: Timer?
    private var ultracode = false

    /// Called on a frame that changed something, saying whether the reveal itself moved or only the
    /// band did. The controller repaints exactly the live row, and the answer is what tells it
    /// whether a repaint it cannot make in place is worth a snapshot: the band moves every frame
    /// and the reveal does not, so a row scrolled out of view would otherwise cost a whole-list
    /// copy and an apply a hundred and twenty times a second for a paint nobody could see.
    var onFrame: ((_ revealMoved: Bool) -> Void)?

    /// Called when the reveal stopped moving while it still owed the reader text. The controller
    /// hands that row back whole.
    var onStalled: (() -> Void)?

    var key: String? { live.id }
    var isActive: Bool { live.isActive }
    var isSettled: Bool { live.isSettled }
    var owes: Bool { live.owes }
    var revealed: Int { live.revealed }

    static var motionAllowed: Bool { !UIAccessibility.isReduceMotionEnabled }

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
        start()
        watch()
    }

    func release() {
        live.focus(nil, rendered: "", sealed: true, at: CACurrentMediaTime())
        stop()
    }

    /// The markdown-safe prefix of what the agent has written, held only while a closer might still
    /// be coming. The judgement is Core's: a cut that stops moving is the end of a part, not a
    /// token in flight, and the rest of the row is handed over rather than held for the turn.
    /// With motion switched off nothing reveals, so nothing needs protecting from a marker that
    /// has not closed yet — and the gate must not run, because a gate whose give-up clock is reset
    /// by every arrival (the driver releases the row on each one) can never expire, and the row
    /// would sit cut at its last unmatched bracket for the rest of the turn.
    ///
    /// Only prose is judged as markdown. Code is written in the same punctuation — `**kwargs`,
    /// `*ptr`, `self._value`, an odd backtick inside a comment — and every one of those reads as a
    /// token that never closes, so a streaming code block does not type: it stops at the first one,
    /// dumps the rest when the gate gives up, and stops again.
    func renderable(row: String, _ source: String, sealed: Bool, markdown: Bool) -> String {
        guard Self.motionAllowed else { return source }
        return live.renderable(
            row: row, source, sealed: sealed, markdown: markdown, at: CACurrentMediaTime())
    }

    /// The wave's second clock, and the reason a stuck answer cannot outlive its turn.
    ///
    /// The reveal moves on the display's clock, and the display's clock is not this app's to
    /// promise: a link stops being served when the app goes to the background or a frame runs long,
    /// and the reveal stops with it — leaving a row holding half a sentence with nothing coming to
    /// finish it. So the wave also keeps a timer, which no display link can take down, and Core
    /// times the debt: a reveal that still owes text and has not moved for its patience is given up
    /// and the row handed over whole.
    private func watch() {
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.live.isActive else {
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
    /// paints nothing, so a frame that quietly painted no cell leaves the debt standing and the
    /// watchdog is the one that notices.
    func landed() {
        live.lands(live.revealed, at: CACurrentMediaTime())
    }

    /// The wave a cell should paint for this row, or nil when the row is not the live one.
    func tail(for id: String) -> CascadeTail? {
        guard live.id == id, Self.motionAllowed else { return nil }
        let edge = CascadeTint.edge(ultracode: ultracode, phase: live.phase)
        return CascadeTail(
            revealed: live.revealed, span: StreamCascade.span, phase: live.phase, edge: edge,
            spark: CascadeTint.spark(for: edge, traits: UITraitCollection.current))
    }

    private func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stop() {
        link?.invalidate()
        link = nil
        unwatch()
    }

    @objc private func tick(_ link: CADisplayLink) {
        let before = live.revealed
        guard live.advance(to: link.timestamp) else { return }
        onFrame?(live.revealed != before)
        if !live.isActive { stop() }
    }
}

extension ChatRow {
    /// The text the agent is still writing into, when this row is the kind that grows a character
    /// at a time. Everything else — a tool run, a picture, a seam — arrives whole and has nothing
    /// for the cascade to pace.
    var streamedText: String? {
        switch content {
        case .text(let text): return role == .user ? nil : text
        case .code(let block): return block.source
        default: return nil
        }
    }

    /// Whether the text this row is growing is prose, whose disappearing punctuation the gate is
    /// there to protect, or code, which has none: the same characters are the language's syntax,
    /// and holding a block behind them stops it typing altogether.
    var streamsMarkdown: Bool {
        if case .code = content { return false }
        return true
    }

    /// The same row holding only the part of its source that is safe to render — never ending
    /// inside a half-open markdown token, so the renderer cannot flash a marker it is about to
    /// swallow.
    func held(to safe: String) -> ChatRow {
        switch content {
        case .text:
            return ChatRow(id: id, messageID: messageID, role: role, content: .text(safe))
        case .code(let block):
            return ChatRow(
                id: id, messageID: messageID, role: role,
                content: .code(CodeBlock(language: block.language, source: safe)))
        default:
            return self
        }
    }
}
