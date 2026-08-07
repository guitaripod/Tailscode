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

    /// The row as it should look this frame. Everything past the reveal is drawn at zero alpha
    /// rather than cut off: the paragraph is measured once when it arrives and never again, so no
    /// glyph moves after it lands and no line re-wraps under the reader. A frame changes colours,
    /// never layout.
    func paint(_ rendered: NSAttributedString, settled: NSColor) -> NSAttributedString {
        let total = rendered.length
        let shown = min(max(revealed, 0), total)
        let slice = NSMutableAttributedString(attributedString: rendered)
        if shown < total {
            slice.addAttribute(
                .foregroundColor, value: NSColor.clear,
                range: NSRange(location: shown, length: total - shown))
        }
        tint(slice, upTo: shown, settled: settled)
        return slice
    }

    /// The wave tints what is already there rather than replacing it: a keyword in a code block,
    /// a link, an inline code span all keep their own colour as the settled end of the blend, so a
    /// glyph leaving the wave lands on the colour it would have had if it had never been in one.
    private func tint(_ string: NSMutableAttributedString, upTo shown: Int, settled: NSColor) {
        guard span > 0, shown > 0 else { return }
        let fallback = CascadeTint.hex(settled)
        let leading = CascadeTint.hex(edge)
        let burn = CascadeTint.hex(spark)
        for distance in 0..<min(span, shown) {
            let index = shown - 1 - distance
            let range = NSRange(location: index, length: 1)
            let existing = string.attribute(.foregroundColor, at: index, effectiveRange: nil)
            let base = (existing as? NSColor).map { CascadeTint.hex($0) } ?? fallback
            let sample = StreamCascade.sample(distance: distance, phase: phase)
            let colour = CascadeTint.colour(sample, settled: base, edge: leading, spark: burn)
            string.addAttribute(
                .foregroundColor, value: colour.withAlphaComponent(sample.alpha), range: range)
        }
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
    private var ultracode = false

    /// The view whose screen sets the frame rate. Without one there is nothing to pace against, so
    /// the wave never starts and the text simply appears.
    weak var host: NSView?

    /// Called on a frame that changed something. The controller repaints exactly the live row.
    var onFrame: (() -> Void)?

    var key: String? { live.id }
    var isActive: Bool { live.isActive }
    var isSettled: Bool { live.isSettled }
    var revealed: Int { live.revealed }

    /// Whether the desktop wants motion at all. A person who has asked for less of it has said
    /// what they want from a cascade, and the answer is the text.
    static var motionAllowed: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Points the wave at the row the stream is writing into, with that row's fully rendered text.
    /// Passing nil lets go of it: a finished paragraph with a glowing tail is a lie about what is
    /// live.
    func focus(_ id: String?, rendered: String, sealed: Bool, ultracode: Bool) {
        self.ultracode = ultracode
        guard Self.motionAllowed, let id else {
            release()
            return
        }
        live.focus(id, rendered: rendered, sealed: sealed, at: CACurrentMediaTime())
        start()
    }

    func release() {
        live.focus(nil, rendered: "", sealed: true, at: CACurrentMediaTime())
        stop()
    }

    /// The wave a row should paint, or nil when it is not the live one.
    func tail(for key: String) -> CascadeTail? {
        guard live.id == key, Self.motionAllowed else { return nil }
        let edge = CascadeTint.edge(ultracode: ultracode, phase: live.phase)
        return CascadeTail(
            revealed: live.revealed, span: StreamCascade.span, phase: live.phase, edge: edge,
            spark: CascadeTint.spark(for: edge))
    }

    private func start() {
        guard link == nil, let host else { return }
        let link = host.displayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard live.advance(to: link.timestamp) else { return }
        onFrame?()
        if !live.isActive { stop() }
    }
}

extension TranscriptRow {
    /// The text the agent is still writing into, when this row is the kind that grows a character
    /// at a time. Everything else — a tool call, a picture, a seam — arrives whole and has nothing
    /// for the cascade to pace.
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
}

/// New rows do not blink into existence. A tool call, the picture it read and the sentence after
/// it arrive together, and landing them all on the same frame reads as the transcript jumping;
/// landing them a beat apart, in order, reads as it growing. Same easing as everything else, so
/// the whole product moves with one hand.
@MainActor
enum CascadeEntrance {
    static func animate(_ view: NSView, index: Int, of count: Int) {
        guard CascadePainter.motionAllowed else { return }
        view.wantsLayer = true
        view.alphaValue = 0
        let delay = StreamCascade.entranceDelay(index: index, of: count)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view] in
            guard let view, view.superview != nil else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.19
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                view.animator().alphaValue = 1
            } completionHandler: {
                view.alphaValue = 1
            }
        }
    }
}
