import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// What a card keeps while its turn runs and for the 400 ms after it ends: the live reading Core
/// made, what the person last saw arrive (for the silence and the held quote), the move the card
/// makes when it settles, and the two canvases that draw the live headline and the NOW line over
/// the settled ones, so the settled words never move and a settle is only a cross-fade.
final class BrainCardLive {
    /// The headline and the third line as they were when the turn ended, kept for the settle to
    /// fade out.
    struct Held {
        var word: String
        var tone: NeuralTone
        var glyph: NeuralLiveCard.Glyph
        var counts: String
        var line: NeuralLiveCard.Line
        var zone: NeuralZone?
    }

    struct Fonts {
        let word: String
        let counts: String
        let title: String
        let argument: String
        let output: String
        let quote: String
        let speaker: String
        let wordHeight: Double
        let lineHeight: Double

        /// The tallest line the 28 point headline band and the 22 point NOW band carry; the live
        /// card is drawn on those bands, so larger type is drawn at the largest size they hold.
        static let headLine = 26.0
        static let nowLine = 20.0

        init() {
            func probe(_ css: String, line: Double) -> String {
                BrainDraw.fitted(BrainUI.font(of: BrainUI.label("A", css)), toLine: line)
            }
            word = probe("bn-live-word", line: Self.headLine)
            counts = probe("bn-live-counts", line: Self.nowLine)
            title = probe("bn-lc-title", line: Self.nowLine)
            argument = probe("bn-lc-arg", line: Self.nowLine)
            output = probe("bn-lc-out", line: Self.nowLine)
            quote = probe("bn-lc-quote", line: Self.nowLine)
            speaker = probe("bn-lc-speaker", line: Self.nowLine)
            func height(_ font: String) -> Double {
                var width = 0.0
                var height = 0.0
                tailscode_text_measure("Ag", font, 0, 1, &width, &height)
                return height
            }
            wordHeight = height(word)
            lineHeight = height(title)
        }
    }

    var reading: NeuralLiveCard?
    var held: Held?
    var settle = NeuralCardSettleClock()
    var settleBegan = false
    var lastActivityAt: Date?
    var activityMark = ""
    var quoteStep: String?
    var quoteArrivedAt: Date?
    var output = ""
    var outputSince = -10.0
    var headCanvas: UnsafeMutablePointer<GtkWidget>?
    var nowCanvas: UnsafeMutablePointer<GtkWidget>?
    var fonts: Fonts?
    var drawnHead = ""
    var drawnNow = ""
    var lastSecond = 0.0
    /// A harness holds the settle at an instant of its move to look at it.
    var frozenElapsed: Double?

    var isLive: Bool { reading != nil }
}

extension BrainCard {
    /// Whether anything on this card moves by itself: a running turn, or the 400 ms after one.
    func needsLiveClock(at time: Double) -> Bool {
        guard !BrainBudget.reduceMotion else { return false }
        return live.reading != nil || live.settle.isSettling(now: time)
    }

    /// Whether the card is in the move it makes when its turn ends.
    func isSettling(at time: Double) -> Bool {
        live.reading == nil && live.settle.isSettling(now: time)
    }

    /// Reads what the card was just told: a turn that is running has a live reading; one that has
    /// just stopped hands its last words to the settle.
    func refreshLive() {
        let running = owner.model.turn.outcome == .running
        let now = BrainClock.now
        if running, let reading = card.live {
            if live.reading == nil { live.activityMark = "" }
            live.reading = reading
            noteActivity(reading)
            noteQuote(reading)
        } else if live.reading != nil {
            live.held = heldWords(of: live.reading!, at: Date())
            live.reading = nil
        }
        if live.settle.observe(running: running, now: now) {
            if owner.isVisible, !BrainBudget.reduceMotion {
                live.settleBegan = true
                if let armed = BrainCard.armedSettleFreeze {
                    live.frozenElapsed = armed
                    BrainCard.armedSettleFreeze = nil
                }
            } else {
                live.held = nil
            }
        }
        if !running, live.frozenElapsed == nil, !live.settle.isSettling(now: now) { live.held = nil }
    }

    private func noteActivity(_ reading: NeuralLiveCard) {
        let mark = "\(reading.stepCount)|\(reading.flight?.stepID ?? "")|\(reading.flight?.lastLine?.text ?? "")"
        if !live.activityMark.isEmpty, mark != live.activityMark { live.lastActivityAt = Date() }
        live.activityMark = mark
    }

    private func noteQuote(_ reading: NeuralLiveCard) {
        guard let quote = reading.quote else {
            live.quoteStep = nil
            return
        }
        if live.quoteStep == nil {
            live.quoteStep = quote.stepID
            return
        }
        if quote.stepID != live.quoteStep {
            live.quoteStep = quote.stepID
            live.quoteArrivedAt = Date()
        }
    }

    private func heldWords(of reading: NeuralLiveCard, at now: Date) -> BrainCardLive.Held {
        let words = reading.reading(now: now, lastActivity: live.lastActivityAt)
        let line = reading.line(
            now: now, lastActivity: live.lastActivityAt, quoteArrivedAt: live.quoteArrivedAt,
            compact: owner.density == .compact)
        return BrainCardLive.Held(
            word: words.word, tone: words.tone, glyph: words.glyph, counts: words.counts, line: line,
            zone: reading.activeZone)
    }

    /// The words the live headline and the NOW line say at `now`: the live reading's, or the ones a
    /// settling card was saying when it stopped.
    private func liveWords(now: Date) -> BrainCardLive.Held? {
        if let reading = live.reading { return heldWords(of: reading, at: now) }
        return live.held
    }


    /// One tick of the card's own life: the headline and the line move on, a new output slides
    /// in, the settled words cross-fade in when the move is running, and the picture and the edge
    /// breathe. Everything is read from absolute time, so every live card on screen is at the same
    /// point of the same breath.
    func tickLive(_ time: Double) {
        guard live.frozenElapsed == nil else { return }
        guard needsLiveClock(at: time) else {
            if live.held != nil { finishSettle() }
            return
        }
        let settling = isSettling(at: time)
        if live.reading == nil, !settling {
            finishSettle()
            return
        }
        let reduce = BrainBudget.reduceMotion
        live.lastSecond = time
        let now = Date()
        let words = liveWords(now: now)
        if let words { trackOutput(words.line, time: time) }
        applyLiveOpacity(time: time)
        let signature = headSignature(words, time: time)
        if signature != live.drawnHead, let canvas = live.headCanvas {
            live.drawnHead = signature
            gtk_widget_queue_draw(canvas)
        }
        let nowSignature = nowSignature(words, time: time)
        if nowSignature != live.drawnNow, let canvas = live.nowCanvas {
            live.drawnNow = nowSignature
            gtk_widget_queue_draw(canvas)
        }
        if !reduce {
            gtk_widget_queue_draw(picture)
            gtk_widget_queue_draw(edgeLive)
        }
    }

    private func trackOutput(_ line: NeuralLiveCard.Line, time: Double) {
        var text = ""
        if case .output(let words, _) = line.trailing { text = words }
        if text != live.output {
            live.output = text
            if !text.isEmpty { live.outputSince = time }
        }
    }

    private func headSignature(_ words: BrainCardLive.Held?, time: Double) -> String {
        guard let words else { return "" }
        let settle = settleState(at: time)
        return "\(words.word)|\(words.counts)|\(words.tone)|\(width)|\(layoutClass)|\(live.reading == nil ? Int(settle.progress * 60) : -1)"
    }

    private func nowSignature(_ words: BrainCardLive.Held?, time: Double) -> String {
        guard let words else { return "" }
        let slide = time - live.outputSince
        let moving = slide < NeuralLiveCard.outputSlide + 0.05
        let settle = settleState(at: time)
        var trailing = ""
        switch words.line.trailing {
        case .output(let text, let tone): trailing = "o\(text)\(tone)"
        case .silence(let text): trailing = "s\(text)"
        case .none: break
        }
        return "\(words.line.kind)|\(words.line.title)|\(words.line.argument ?? "")|\(trailing)|\(width)|\(moving ? Int(slide * 60) : -1)|\(live.reading == nil ? Int(settle.progress * 60) : -1)"
    }

    /// The settled words wait invisibly under the live ones while the turn runs, and take over as
    /// the settle's own curves say.
    func applyLiveOpacity(time: Double) {
        let settle = settleState(at: time)
        let running = live.reading != nil
        let headAlpha = running ? 0 : settle.settledHeadlineAlpha
        let thirdAlpha = running ? 0 : settle.firstWordsAlpha
        for widget in settledHeadWidgets { gtk_widget_set_opacity(widget, headAlpha) }
        for widget in settledThirdWidgets { gtk_widget_set_opacity(widget, thirdAlpha) }
        for canvas in [live.headCanvas, live.nowCanvas].compactMap({ $0 }) {
            gtk_widget_set_visible(canvas, 1)
        }
    }

    /// The move is over: the live canvases leave and the settled words stand exactly as a card
    /// that was never live has them.
    func finishSettle() {
        live.held = nil
        live.settleBegan = false
        for widget in settledHeadWidgets + settledThirdWidgets { gtk_widget_set_opacity(widget, 1) }
        for canvas in [live.headCanvas, live.nowCanvas].compactMap({ $0 }) {
            gtk_widget_set_visible(canvas, 0)
        }
        live.drawnHead = ""
        live.drawnNow = ""
        if live.reading == nil { dropLivePictures() }
        redraw()
    }

    /// Shows the live canvases and hides the settled words under them, or the other way round, for
    /// a card whose content has just been made or whose turn has just changed state.
    func syncLiveVisibility() {
        let time = BrainClock.now
        let active =
            live.reading != nil || live.frozenElapsed != nil
            || (!BrainBudget.reduceMotion && live.settle.isSettling(now: time))
        for canvas in [live.headCanvas, live.nowCanvas].compactMap({ $0 }) {
            gtk_widget_set_visible(canvas, active ? 1 : 0)
        }
        if active {
            applyLiveOpacity(time: time)
            live.drawnHead = ""
            live.drawnNow = ""
        } else {
            for widget in settledHeadWidgets + settledThirdWidgets { gtk_widget_set_opacity(widget, 1) }
        }
        if let canvas = live.headCanvas { gtk_widget_queue_draw(canvas) }
        if let canvas = live.nowCanvas { gtk_widget_queue_draw(canvas) }
        owner.updateClock()
    }


    /// The two canvases that lay the live headline and the NOW line over the settled ones.
    func makeLiveCanvas(isHead: Bool) -> UnsafeMutablePointer<GtkWidget> {
        let holder = LiveHolder()
        holder.card = self
        holder.isHead = isHead
        _ = Gtk.releaseInstalled
        let canvas = tailscode_canvas_new(
            { cr, width, height, raw in
                guard let cr, let raw else { return }
                let holder = Unmanaged<LiveHolder>.fromOpaque(raw).takeUnretainedValue()
                guard let card = holder.card else { return }
                if holder.isHead {
                    card.paintLiveHead(cr, width: Double(width), height: Double(height))
                } else {
                    card.paintNow(cr, width: Double(width), height: Double(height))
                }
            }, Unmanaged.passRetained(holder).toOpaque(),
            { raw in
                guard let raw else { return }
                Unmanaged<LiveHolder>.fromOpaque(raw).release()
            })!
        gtk_widget_set_can_target(canvas, 0)
        gtk_widget_set_can_focus(canvas, 0)
        tailscode_set_accessible_hidden(canvas, 1)
        return canvas
    }

    final class LiveHolder: @unchecked Sendable {
        weak var card: BrainCard?
        var isHead = true
    }

    private func liveFonts() -> BrainCardLive.Fonts {
        if let fonts = live.fonts { return fonts }
        let fonts = BrainCardLive.Fonts()
        live.fonts = fonts
        return fonts
    }

    func resetLiveFonts() { live.fonts = nil }

    private func step(for glyph: NeuralLiveCard.Glyph) -> NeuralVerdict.Step {
        switch glyph {
        case .pulse: return .running
        case .pauseBars: return .waiting
        case .dashedClock: return .stalled
        case .triangle: return .tryingAgain
        }
    }

    private func paintLiveHead(_ cr: OpaquePointer, width: Double, height: Double) {
        let time = BrainClock.now
        guard let words = liveWords(now: Date()) else { return }
        let inks = owner.inks
        let fonts = liveFonts()
        let settle = settleState(at: time)
        let running = live.reading != nil
        let alpha = running ? 1 : settle.liveHeadlineAlpha
        guard alpha > 0.002 else { return }
        let lift = running ? 0 : settle.liveHeadlineOffsetY
        let color = BrainDraw.toneColor(words.tone, inks: inks)
        let mid = height / 2 + lift
        BrainDraw.verdictGlyph(
            cr, step(for: words.glyph), cx: 8, cy: mid, size: 14, color: color, alpha: alpha)
        let wordX = 24.0
        BrainDraw.text(
            cr, words.word, font: fonts.word, x: wordX, y: mid - fonts.wordHeight / 2, color: color, alpha: alpha)
        let wordWidth = BrainDraw.measure(words.word, fonts.word)
        let reserve = layoutClass == .wide ? 170.0 : 0
        let countsX = wordX + wordWidth + 12
        let room = width - reserve - countsX
        if room > 40 {
            let counts = cut(words.counts, font: fonts.counts, width: room)
            var countsHeight = 0.0
            var unused = 0.0
            tailscode_text_measure("Ag", fonts.counts, 0, 1, &unused, &countsHeight)
            BrainDraw.text(
                cr, counts, font: fonts.counts, x: countsX, y: mid - countsHeight / 2 + 1, color: inks.dim,
                alpha: alpha)
        }
    }

    /// `text` cut with an ellipsis to fit `width`.
    private func cut(_ text: String, font: String, width: Double) -> String {
        guard BrainDraw.measure(text, font) > width else { return text }
        var low = 0
        var high = text.count
        while low < high {
            let middle = (low + high + 1) / 2
            let candidate = String(text.prefix(middle)) + "\u{2026}"
            if BrainDraw.measure(candidate, font) <= width { low = middle } else { high = middle - 1 }
        }
        return low == 0 ? "" : String(text.prefix(low)) + "\u{2026}"
    }

    private func paintNow(_ cr: OpaquePointer, width: Double, height: Double) {
        let time = BrainClock.now
        guard let words = liveWords(now: Date()) else { return }
        let inks = owner.inks
        let fonts = liveFonts()
        let settle = settleState(at: time)
        let running = live.reading != nil
        let alpha = running ? 1 : settle.nowLineAlpha
        guard alpha > 0.002 else { return }
        let line = words.line
        let mid = height / 2
        if line.kind == .quote, let quote = line.quote {
            BrainDraw.quoteGlyph(cr, cx: 6, cy: mid, color: inks.accent, alpha: alpha)
            let speaker = quote.speaker
            let speakerX = 20.0
            BrainDraw.text(
                cr, speaker, font: fonts.speaker, x: speakerX, y: mid - fonts.lineHeight / 2, color: inks.accent,
                alpha: alpha)
            let wordsX = speakerX + BrainDraw.measure(speaker, fonts.speaker) + 10
            let fitted = cut(line.title, font: fonts.quote, width: width - wordsX)
            BrainDraw.text(
                cr, fitted, font: fonts.quote, x: wordsX, y: mid - fonts.lineHeight / 2, color: inks.ink,
                alpha: alpha)
            return
        }
        var x = 0.0
        let titleColor = line.isWaiting ? inks.warn : inks.ink
        BrainDraw.text(
            cr, line.title, font: fonts.title, x: x, y: mid - fonts.lineHeight / 2, color: titleColor, alpha: alpha)
        x += BrainDraw.measure(line.title, fonts.title) + 10
        var trailingWidth = 0.0
        var trailingText = ""
        var trailingColor = inks.dim
        var glyph = false
        switch line.trailing {
        case .output(let text, let tone):
            trailingText = text
            trailingColor = tone == .attention ? inks.warn : inks.dim
        case .silence(let text):
            trailingText = text
            trailingColor = inks.warn
            glyph = true
        case .none:
            break
        }
        if !trailingText.isEmpty {
            let limit = glyph ? width * 0.5 : width * 0.42
            trailingText = cut(trailingText, font: fonts.output, width: limit)
            trailingWidth = BrainDraw.measure(trailingText, fonts.output) + (glyph ? 20 : 0)
        }
        let argumentRoom = width - x - (trailingWidth > 0 ? trailingWidth + 14 : 0)
        if let argument = line.argument, argumentRoom > 30 {
            let fitted = cut(argument, font: fonts.argument, width: argumentRoom)
            BrainDraw.text(
                cr, fitted, font: fonts.argument, x: x, y: mid - fonts.lineHeight / 2 + 0.5, color: inks.dim, alpha: alpha)
        }
        guard !trailingText.isEmpty else { return }
        var slide = 0.0
        var fade = 1.0
        if !glyph {
            let progress = NeuralTransition.clamp((time - live.outputSince) / NeuralLiveCard.outputSlide)
            let eased = NeuralTransition.easeOutCubic(progress)
            slide = NeuralLiveCard.outputSlideDistance * (1 - eased)
            fade = eased
        }
        let right = width
        var textX = right - BrainDraw.measure(trailingText, fonts.output)
        if glyph {
            BrainDraw.verdictGlyph(
                cr, .stalled, cx: textX - 12, cy: mid, size: 14, color: inks.warn, alpha: alpha)
        }
        textX = max(x, textX)
        BrainDraw.text(
            cr, trailingText, font: fonts.output, x: textX, y: mid - fonts.lineHeight / 2 + slide,
            color: trailingColor, alpha: alpha * fade)
    }


    /// How lit the live head's active zone is now, `floor...1`, and the share of the peak frame
    /// laid over the floor frame to say so.
    func liveMix(at time: Double) -> Double {
        guard let reading = live.reading, !BrainBudget.reduceMotion else { return 1 }
        let level = reading.swell(at: time)
        let floor: Double
        switch reading.motion {
        case .breath: floor = ActivityTuning.breathFloor
        case .heartbeat: floor = ActivityTuning.heartbeatFloor
        case .sweep, .still: return 1
        }
        return NeuralTransition.clamp((level - floor) / max(0.001, 1 - floor))
    }

    /// The two instants of the live head's breath the card draws and mixes: its dimmest and its
    /// brightest, as absolute times the compositor renders.
    static func swellTimes(for motion: NeuralMotion) -> (low: Double, high: Double)? {
        switch motion {
        case .breath:
            return (0, ActivityTuning.breathPeriod / 2)
        case .heartbeat:
            return (
                ActivityTuning.heartbeatPeriod * 0.6,
                ActivityTuning.heartbeatPeriod * NeuralMotion.firstBeat.centre)
        case .sweep, .still:
            return nil
        }
    }
}

extension BrainCard {
    /// The compositor's two frames of a live head's breath, dimmest and brightest, rendered once
    /// each and mixed by the swell: the head really breathes and nothing is rendered per frame.
    func requestLivePictures(scale: Int) {
        guard let reading = live.reading else {
            if live.held == nil, liveLow != nil || liveHigh != nil { dropLivePictures() }
            return
        }
        let model = owner.model
        let table = NeuralToneTable(palette: MatrixTheme.palette, face: model.face)
        let times = Self.swellTimes(for: reading.motion)
        let still = BrainBudget.reduceMotion || times == nil
        let lowFrame = model.frame(time: still ? 0 : times!.low, reduceMotion: still)
        let highFrame = still ? nil : model.frame(time: times!.high, reduceMotion: false)
        let wholeWidth = pictureRect.width * NeuralDesign.width / NeuralStageMetrics.designWidth
        func key(_ frame: NeuralFrame) -> BrainPictures.Key {
            BrainPictures.Key(
                table: table, frame: frame, width: Int((wholeWidth * Double(scale)).rounded()),
                height: Int((pictureRect.height * Double(scale)).rounded()))
        }
        let lowKey = key(lowFrame)
        let highKey = highFrame.map(key)
        if liveLowKey == lowKey, liveHighKey == highKey, liveLow != nil { return }
        guard !livePending else { return }
        liveLowKey = lowKey
        liveHighKey = highKey
        livePending = true
        let rectHeight = pictureRect.height
        BrainPictures.picture(
            frame: lowFrame, table: table, width: wholeWidth, height: rectHeight, scale: scale
        ) { [weak self] low in
            guard let self else { return }
            guard let highFrame else {
                self.livePending = false
                guard self.liveLowKey == lowKey else { return }
                self.liveLow = low
                self.liveHigh = nil
                gtk_widget_queue_draw(self.picture)
                self.owner.cardPictureReady()
                return
            }
            BrainPictures.picture(
                frame: highFrame, table: table, width: wholeWidth, height: rectHeight, scale: scale
            ) { [weak self] high in
                guard let self else { return }
                self.livePending = false
                guard self.liveLowKey == lowKey else { return }
                self.liveLow = low
                self.liveHigh = high
                gtk_widget_queue_draw(self.picture)
                self.owner.cardPictureReady()
            }
        }
    }

    func dropLivePictures() {
        liveLow = nil
        liveHigh = nil
    }

    /// Lays the live head: the dimmest frame with the brightest over it by the swell, and during a
    /// settle the settled head coming up under the live one as it leaves. False when the card
    /// has no live head to draw.
    func paintLiveHead(_ cr: OpaquePointer, rect: NeuralRect) -> Bool {
        guard let low = liveLow, live.reading != nil || live.held != nil else { return false }
        let time = BrainClock.now
        let settle = settleState(at: time)
        let running = live.reading != nil
        let mix = running ? liveMix(at: time) : 1
        let fade = running ? 1 : 1 - settle.lights
        if !running, let rest = restPicture {
            BrainCardPainter.head(cr, picture: rest, rect: rect)
        }
        guard fade > 0.002 else { return true }
        if fade < 0.999 { cairo_push_group(cr) }
        BrainCardPainter.head(cr, picture: low, rect: rect)
        if let high = liveHigh { BrainCardPainter.head(cr, picture: high, rect: rect, alpha: mix) }
        if fade < 0.999 {
            cairo_pop_group_to_source(cr)
            cairo_paint_with_alpha(cr, fade)
        }
        return true
    }

    /// The active zone's light as the breath sets it: dimmest at the floor, full at the peak, and
    /// easing to full as the card settles.
    func breathingLight() -> (zone: NeuralZone, level: Double)? {
        guard let zone = live.reading?.activeZone ?? live.held?.zone else { return nil }
        let time = BrainClock.now
        if let reading = live.reading {
            return (zone, BrainBudget.reduceMotion ? 1 : reading.swell(at: time))
        }
        let settle = settleState(at: time)
        return (zone, settle.lights)
    }
}

extension BrainCard {
    /// Whether a canvas of its own draws the card's edge: while the turn runs and through the
    /// settle, so a pulse repaints three points of width and not the whole card.
    var edgeIsLive: Bool {
        live.reading != nil || live.frozenElapsed != nil || live.held != nil
    }

    /// The live edge: the tone's bar at the card's left, at the pulse's strength.
    func paintLiveEdge(_ cr: OpaquePointer, width: Double, height: Double) {
        guard edgeIsLive else { return }
        let tone = owner.inks.corrected(card.edgeTone)
        cairo_save(cr)
        BrainPainter.round(cr, 0.5, 0.5, 40, height - 1, 12)
        cairo_clip(cr)
        cairo_set_source_rgba(cr, tone.red, tone.green, tone.blue, edgeAlpha())
        cairo_rectangle(cr, 0, 0, 3, height)
        cairo_fill(cr)
        cairo_restore(cr)
    }

    /// How strong the card's tone edge is: it pulses with the swell while the turn works and knocks
    /// twice while it waits; every other state, and a card that has settled, holds at full.
    func edgeAlpha() -> Double {
        guard let reading = live.reading, !BrainBudget.reduceMotion else { return 1 }
        return reading.edgeLevel(at: BrainClock.now)
    }
}

extension BrainCard {
    /// What the live headline says at `now`, for the harness.
    func liveHeadline(now: Date = Date()) -> NeuralLiveCard.Reading? {
        live.reading.map { $0.reading(now: now, lastActivity: live.lastActivityAt) }
    }

    /// What the NOW line says at `now`, for the harness.
    func liveLine(now: Date = Date()) -> NeuralLiveCard.Line? {
        live.reading.map {
            $0.line(
                now: now, lastActivity: live.lastActivityAt, quoteArrivedAt: live.quoteArrivedAt,
                compact: owner.density == .compact)
        }
    }

    /// Whether the live headline and the NOW line are on the card.
    var liveCanvasesShown: Bool {
        [live.headCanvas, live.nowCanvas].compactMap { $0 }.contains { gtk_widget_get_visible($0) != 0 }
    }

    /// How visible the settled headline is: nothing while the turn runs, everything once settled.
    var settledHeadlineOpacity: Double {
        settledHeadWidgets.first.map { gtk_widget_get_opacity($0) } ?? 1
    }

    var settledThirdOpacity: Double {
        settledThirdWidgets.first.map { gtk_widget_get_opacity($0) } ?? 1
    }
}

extension BrainCard {
    /// A harness arms a freeze and the next settle that begins on screen is held at that instant.
    nonisolated(unsafe) static var armedSettleFreeze: Double?

    /// The settle's numbers now: the clock's, or the instant a harness froze it at.
    func settleState(at time: Double) -> NeuralCardSettle {
        if let frozen = live.frozenElapsed { return NeuralCardSettle.at(frozen) }
        return live.settle.settle(now: time, reduceMotion: BrainBudget.reduceMotion)
    }

    /// Holds a settle at `seconds` into its move for a picture, or lets it go with nil.
    func freezeSettle(_ seconds: Double?) {
        live.frozenElapsed = seconds
        if seconds == nil {
            finishSettle()
            return
        }
        applyLiveOpacity(time: BrainClock.now)
        live.drawnHead = ""
        live.drawnNow = ""
        for widget in [live.headCanvas, live.nowCanvas].compactMap({ $0 }) {
            gtk_widget_set_visible(widget, 1)
            gtk_widget_queue_draw(widget)
        }
        redraw()
    }
}
