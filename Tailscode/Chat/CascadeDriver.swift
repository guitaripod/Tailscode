import MidgarCore
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
    /// Which arrival of text this frame is for (`LiveCascade.textRevision` and the source's own
    /// fingerprint, counted by the driver). A cell keys the work
    /// that depends on the words, rendering them and comparing them with what it already holds, on
    /// this instead of on the words, so a frame in which only colours moved never reads the answer.
    let textRevision: Int
    let edge: UIColor
    let spark: UIColor
    /// The traits of the view this frame is for. A frame is built off the display's clock, outside
    /// any view's drawing, where `UITraitCollection.current` is the system's — not the window's
    /// theme and appearance — so the prose colour resolved there is the platform's black on a
    /// dark theme, and the wave bakes that colour into the text for good.
    let traits: UITraitCollection
    /// The same frame, for the hand that draws the edge instead of tinting the characters behind
    /// it. Non-nil only while the alpha renderer is the chosen one and this device can run it; a
    /// cell that cannot use it falls back to `paint`/`repaint` below and loses no meaning.
    var aurora: AuroraFrame?

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
        let hiddenFrom = Self.hiddenStart(in: storage)
        let tailIsHidden = hiddenFrom <= shown
        let restoreFrom = min(bandStart, hiddenFrom)
        let restoreTo = tailIsHidden ? shown : total
        storage.beginEditing()
        base.enumerateAttributes(
            in: NSRange(location: restoreFrom, length: restoreTo - restoreFrom), options: []
        ) { attributes, range, _ in
            storage.setAttributes(attributes, range: range)
        }
        if shown < total, !tailIsHidden {
            storage.addAttribute(
                .foregroundColor, value: UIColor.clear,
                range: NSRange(location: shown, length: total - shown))
        }
        tint(storage, upTo: shown, settled: settled)
        storage.endEditing()
    }

    /// Where the invisible tail the last frame left begins, or the end when there is none. Read off
    /// the storage itself rather than remembered beside it, so a storage something else rewrote
    /// can only make the answer wider, never wrong. Reveal moves forward, so a tail that is hidden
    /// already is hidden past this frame's reveal as well and needs no second coat of clear: a
    /// frame has to put back only the glyphs between where the tail began and where it begins now,
    /// not copy the attributes of everything the reader has not reached yet.
    private static func hiddenStart(in storage: NSAttributedString) -> Int {
        let total = storage.length
        guard total > 0 else { return 0 }
        var run = NSRange(location: 0, length: 0)
        let colour = storage.attribute(
            .foregroundColor, at: total - 1, longestEffectiveRange: &run,
            in: NSRange(location: 0, length: total))
        return (colour as? UIColor)?.isEqual(UIColor.clear) == true ? run.location : total
    }

    /// The channels of the colour a glyph already wears. Neighbouring glyphs share one attribute
    /// run and so one colour object, which makes the previous answer the answer nearly every time.
    private func settledChannels(
        of colour: UIColor?, _ traits: UITraitCollection, _ fallback: CascadeTint.Channels,
        _ lastColour: inout UIColor?, _ lastChannels: inout CascadeTint.Channels
    ) -> CascadeTint.Channels {
        guard let colour else { return fallback }
        if let lastColour, lastColour === colour { return lastChannels }
        lastColour = colour
        lastChannels = CascadeTint.channels(colour, traits)
        return lastChannels
    }

    /// The wave tints what is already there rather than replacing it: a keyword in a code block, a
    /// link, an inline code span all keep their own colour as the settled end of the blend, so a
    /// glyph leaving the wave lands on the colour it would have had if it had never been in one.
    private func tint(_ string: NSMutableAttributedString, upTo shown: Int, settled: UIColor) {
        guard span > 0, shown > 0 else { return }
        let fallback = CascadeTint.channels(settled, traits)
        let leading = CascadeTint.channels(edge, traits)
        let burn = CascadeTint.channels(spark, traits)
        var lastColour: UIColor?
        var lastChannels = fallback
        for distance in 0..<min(span, shown) {
            let index = shown - 1 - distance
            let existing = string.attribute(.foregroundColor, at: index, effectiveRange: nil)
            let base = settledChannels(
                of: existing as? UIColor, traits, fallback, &lastColour, &lastChannels)
            let sample = StreamCascade.sample(distance: distance, phase: phase)
            string.addAttribute(
                .foregroundColor,
                value: CascadeTint.colour(sample, settled: base, edge: leading, spark: burn),
                range: NSRange(location: index, length: 1))
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
    typealias Channels = (red: Double, green: Double, blue: Double)

    /// The wave is arithmetic and stays arithmetic: a frame walks this a couple of dozen times, so
    /// the colours cross as numbers and a hex string is never built to be parsed straight back.
    static func colour(_ sample: CascadeSample, settled: Channels, edge: Channels, spark: Channels)
        -> UIColor
    {
        let warmed = Contrast.blendChannels(settled, edge, sample.heat * 0.86)
        let lit = Contrast.blendChannels(warmed, spark, sample.shimmer)
        return UIColor(
            red: CGFloat(lit.red), green: CGFloat(lit.green), blue: CGFloat(lit.blue),
            alpha: CGFloat(sample.alpha))
    }

    /// The specular colour the band pushes toward: brighter than the accent in the dark, denser in
    /// the light, so a sweep reads as light passing over the words either way.
    /// Under a theme the extreme is the palette's own ink rather than white or near-black, because
    /// a spark that leaves the palette reads as a defect in the glyph rather than as light.
    static func spark(for edge: UIColor, traits: UITraitCollection) -> UIColor {
        let toward =
            traits.palette?.text ?? (traits.userInterfaceStyle == .light ? "#101014" : "#ffffff")
        guard let target = Contrast.channels(toward) else { return edge }
        let mixed = Contrast.blendChannels(channels(edge, traits), target, 0.5)
        return UIColor(
            red: CGFloat(mixed.red), green: CGFloat(mixed.green), blue: CGFloat(mixed.blue),
            alpha: 1)
    }

    /// The leading edge: the app's accent, or the shared rainbow while ultracode is on, so the
    /// unlocked powers are legible in the writing and not only around the composer.
    static func edge(ultracode: Bool, phase: Double) -> UIColor {
        guard ultracode else { return Theme.Color.accent }
        let stop = StreamCascade.rainbow(at: phase)
        return UIColor(red: stop.red, green: stop.green, blue: stop.blue, alpha: 1)
    }

    static func channels(_ colour: UIColor, _ traits: UITraitCollection) -> Channels {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        colour.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func clamp(_ value: CGFloat) -> Double { Double(min(max(value, 0), 1)) }
        return (clamp(red), clamp(green), clamp(blue))
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
    private var linkTempo: CascadeTempo = .stopped
    #if DEBUG
        private var ticks = 0
        private var painted = 0
        private var startedAt: Double?
    #endif
    private var watchdog: Timer?
    private var ultracode = false
    private var clock = CACurrentMediaTime()

    /// Which hand writes, decided once when the row is taken up rather than asked per frame: a
    /// setting changed mid-answer would swap renderers under the reader's eye, and the row the
    /// switch was thrown during is the one row it must not disturb.
    private var renderer = StreamRenderer.default
    private var arrival = AuroraArrival()

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
    var tempo: CascadeTempo { live.tempo }
    var isActive: Bool { live.isActive }
    var isSettled: Bool { live.isSettled }
    var owes: Bool { live.owes }
    var revealed: Int { live.revealed }

    static var motionAllowed: Bool { !UIAccessibility.isReduceMotionEnabled }

    /// Points the wave at the row the stream is writing into, with that row's fully rendered text.
    /// Passing nil lets go of it: a finished paragraph with a glowing tail is a lie about what is
    /// live.
    ///
    /// The wave may decline the row — Core refuses one it has already written to that length — so
    /// the caller reads `key` back afterwards rather than assuming it took.
    func focus(_ id: String?, length: Int, sealed: Bool, ultracode: Bool, source: String? = nil) {
        self.ultracode = ultracode
        guard Self.motionAllowed, let id else {
            release()
            return
        }
        if id != live.id {
            renderer = StreamRendererSetting.choice
            arrival = AuroraArrival()
        }
        live.focus(id, length: length, sealed: sealed, at: CACurrentMediaTime())
        noteSource(source)
        guard live.isActive else {
            stop()
            unwatch()
            return
        }
        if live.tempo == .stopped, !isArriving {
            pause()
        } else {
            start()
        }
        watch()
    }

    func release() {
        live.focus(nil, rendered: "", sealed: true, at: CACurrentMediaTime())
        stop()
    }

    /// Counts the arrivals of the words themselves. Core counts a text revision when the rendered
    /// length moves; the words can change without it (a closing marker is swallowed by the
    /// renderer), so the controller hands over the source once per arrival and its fingerprint is
    /// read here, never per frame.
    private func noteSource(_ source: String?) {
        let fingerprint = source?.hashValue
        defer {
            lastRevision = live.textRevision
            lastFingerprint = fingerprint
        }
        guard live.textRevision != lastRevision || fingerprint != lastFingerprint else { return }
        stamp += 1
    }

    private var stamp = 0
    private var lastRevision = -1
    private var lastFingerprint: Int?

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
    func tail(for id: String, traits: UITraitCollection) -> CascadeTail? {
        guard live.id == id, Self.motionAllowed else { return nil }
        let edge = CascadeTint.edge(ultracode: ultracode, phase: live.phase)
        let spark = CascadeTint.spark(for: edge, traits: traits)
        return CascadeTail(
            revealed: live.revealed, span: StreamCascade.span, phase: live.phase,
            textRevision: stamp, edge: edge, spark: spark, traits: traits,
            aurora: auroraFrame(edge: edge, spark: spark))
    }

    /// The alpha renderer's own half of the frame, offered only where it can actually be run. A
    /// device with no Metal device, or a build whose shader did not compile, is handed nothing and
    /// writes with the settled hand — which is the whole product's floor and says the same thing.
    private func auroraFrame(edge: UIColor, spark: UIColor) -> AuroraFrame? {
        guard renderer == .aurora, AuroraStreamView.isAvailable else { return nil }
        return AuroraFrame(
            progress: live.progress, phase: live.phase, time: clock, rate: live.rate, edge: edge,
            spark: spark, motion: true, arrival: arrival.level)
    }

    /// Whether the alpha renderer's arrival effect is still fading: the one thing besides the
    /// reveal and the band that asks for frames. The settled renderer has no such effect.
    private var isArriving: Bool { renderer == .aurora && arrival.level > 0 }

    /// The range the display is asked for at a tempo: the cascade's own while characters are being
    /// revealed, the vocabulary's while only the band finishes its pass.
    private static func range(for tempo: CascadeTempo) -> CAFrameRateRange {
        tempo == .display ? .cascadeTempo : .activityTempo
    }

    private func start() {
        let wanted = live.tempo == .stopped ? CascadeTempo.activity : live.tempo
        if let link {
            guard wanted != linkTempo else { return }
            link.preferredFrameRateRange = Self.range(for: wanted)
            linkTempo = wanted
            return
        }
        #if DEBUG
            startedAt = startedAt ?? CACurrentMediaTime()
        #endif
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = Self.range(for: wanted)
        link.add(to: .main, forMode: .common)
        self.link = link
        linkTempo = wanted
    }

    /// Takes the frame clock down while the row holds still, leaving the watchdog: a row that is
    /// resting has been painted, and the next arrival starts the clock again from `focus`.
    private func pause() {
        #if DEBUG
            if link != nil, let began = startedAt {
                MidgarLog.info(
                    "cascade pause ticks=\(ticks) painted=\(painted) seconds=\(String(format: "%.2f", CACurrentMediaTime() - began))",
                    category: .performance
                )
                ticks = 0
                painted = 0
                startedAt = nil
            }
        #endif
        link?.invalidate()
        link = nil
        linkTempo = .stopped
    }

    private func stop() {
        pause()
        unwatch()
    }

    @objc private func tick(_ link: CADisplayLink) {
        let before = live.revealed
        clock = link.timestamp
        let moving = live.advance(to: link.timestamp)
        let landing =
            renderer == .aurora
            && arrival.advance(to: link.timestamp, settled: live.isSettled) > 0
        #if DEBUG
            ticks += 1
            if moving || landing { painted += 1 }
        #endif
        if moving || landing { onFrame?(live.revealed != before) }
        guard live.isActive else {
            stop()
            return
        }
        if live.tempo == .stopped, !isArriving {
            pause()
        } else {
            start()
        }
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
