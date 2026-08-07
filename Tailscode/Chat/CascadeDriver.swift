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
    static func spark(for edge: UIColor, traits: UITraitCollection) -> UIColor {
        let hex = hex(edge, traits)
        let toward = traits.userInterfaceStyle == .light ? "#101014" : "#ffffff"
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
    private var ultracode = false

    /// Called on a frame that changed something. The controller reconfigures exactly the live row.
    var onFrame: (() -> Void)?

    var key: String? { live.id }
    var isActive: Bool { live.isActive }
    var isSettled: Bool { live.isSettled }
    var revealed: Int { live.revealed }

    static var motionAllowed: Bool { !UIAccessibility.isReduceMotionEnabled }

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
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard live.advance(to: link.timestamp) else { return }
        onFrame?()
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
