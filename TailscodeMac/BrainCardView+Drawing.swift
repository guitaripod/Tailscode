import AppKit
import TailscodeCore

extension BrainCardView {
    func buildLayout(_ content: Content) -> CardLayout {
        var out = CardLayout()
        out.signature = signature(of: content)
        let metrics = content.geometry
        let narrow = metrics.layout == .narrow
        let compact = content.density == .compact
        let width = CGFloat(content.width)
        let textLeft = CGFloat(metrics.text.x)
        let textRight = width - 12
        out.textLeft = textLeft
        out.textRight = textRight
        let height = CGFloat(metrics.height)
        let buttonHeight: CGFloat = 24
        let inks = content.inks

        let replayTitle = content.isReplaying ? Localized.text("Stop") : NeuralReading.replayLabel
        let rowsTitle = NeuralReading.rowsLabel
        let controlFont = MacTheme.Ramp.font(.control)
        func buttonWidth(_ title: String, icon: Bool) -> CGFloat {
            let text = (title as NSString).size(withAttributes: [.font: controlFont]).width
            return ceil(text) + 20 + (icon ? 16 : 0)
        }
        let replayWidth = buttonWidth(replayTitle, icon: true)
        let isLive = content.card.live != nil
        let rowsWidth = buttonWidth(isLive ? Localized.text("Open") : rowsTitle, icon: false)
        let top: CGFloat = compact ? 6 : 8
        var buttonsLeft = textRight
        if !narrow {
            let rows = CGRect(x: textRight - rowsWidth, y: top, width: rowsWidth, height: buttonHeight)
            let replay = CGRect(x: rows.minX - 6 - replayWidth, y: top, width: replayWidth, height: buttonHeight)
            out.targets.append(CardTarget(kind: isLive ? .open : .rows, rect: rows))
            let showsReplay = content.canReplay || isLive
            if showsReplay { out.targets.append(CardTarget(kind: .replay, rect: replay)) }
            buttonsLeft = showsReplay ? replay.minX : rows.minX
        }
        out.headlineRight = narrow ? textRight : buttonsLeft - 10
        out.wordmark = NSAttributedString(
            string: NeuralReading.wordmark,
            attributes: MacTheme.Ramp.attributes(.sectionLabel, color: inks.textDim))
        let wordmarkSize = out.wordmark.size()
        out.wordmarkSize = CGSize(width: ceil(wordmarkSize.width), height: ceil(wordmarkSize.height))

        let centerY: CGFloat = compact ? 20 : 29
        out.headlineCenterY = centerY
        var chipsTop: CGFloat = compact ? 38 : 52
        let chipHeight: CGFloat = compact ? 22 : 24
        if narrow {
            let rows = compact ? (headline: 15.0, clause: 33.0, third: 0.0, buttons: 48.0)
                : (headline: 22.0, clause: 44.0, third: 66.0, buttons: 78.0)
            out.headlineCenterY = CGFloat(rows.headline)
            out.clauseCenterY = CGFloat(rows.clause)
            out.showsThird = !compact
            let buttonsTop = CGFloat(rows.buttons)
            let showsReplay = content.canReplay || isLive
            let rowsButton = CGRect(x: textLeft + replayWidth + 6, y: buttonsTop, width: rowsWidth, height: buttonHeight)
            let replay = CGRect(x: textLeft, y: buttonsTop, width: replayWidth, height: buttonHeight)
            out.targets.append(CardTarget(kind: isLive ? .open : .rows, rect: showsReplay ? rowsButton : replay))
            if showsReplay { out.targets.append(CardTarget(kind: .replay, rect: replay)) }
            chipsTop = CGFloat(rows.third) - 9
        }
        out.chipsTop = chipsTop

        let parts = content.card.fit(width: width)
        if !narrow, parts.contains(.zoneStrip) {
            let badge = MacTheme.Ramp.font(.badge)
            var cursor = textLeft
            for chip in content.card.chips {
                let label = chip.label.uppercased()
                let labelWidth = (label as NSString).size(withAttributes: [
                    .font: badge, .kern: 0.6,
                ]).width
                let countWidth = ("\(chip.count)" as NSString).size(withAttributes: [.font: badge]).width
                let chipWidth = ceil(10 + 14 + labelWidth + 6 + countWidth + 10)
                guard cursor + chipWidth <= textRight else { break }
                let rect = CGRect(x: cursor, y: chipsTop, width: chipWidth, height: chipHeight)
                out.chipRects.append((chip, rect))
                out.targets.append(CardTarget(kind: .zone(chip.zone), rect: rect))
                cursor += chipWidth + 4
            }
        }
        let thirdTop = narrow ? (compact ? out.clauseCenterY - 9 : chipsTop) : chipsTop + chipHeight + (compact ? 4 : 9)
        out.thirdBaselineY = thirdTop
        out.thirdLine = CGRect(
            x: textLeft, y: thirdTop, width: max(0, textRight - textLeft), height: 18)
        return out
    }

    func drawText(_ content: Content, cg: CGContext) {
        wordmarkDrawn = false
        let inks = content.inks
        let card = content.card
        let narrow = content.geometry.layout == .narrow
        let compact = content.density == .compact
        let now = Date()
        let clock = CACurrentMediaTime()
        let settle = settleClock.settle(now: clock, reduceMotion: content.reduceMotion)
        let settling = settleClock.isSettling(now: clock)
        let live = card.live
        let textLeft = layout.textLeft
        let textRight = layout.textRight

        let showLive = live != nil || settling
        if showLive, let live = live ?? retainedLive {
            let alpha = settling ? settle.liveHeadlineAlpha : 1
            let lift = settling ? CGFloat(settle.liveHeadlineOffsetY) : 0
            if alpha > 0.003 {
                cg.saveGState()
                cg.setAlpha(CGFloat(alpha))
                drawLiveHeadline(live, content: content, lift: lift, now: now)
                cg.restoreGState()
            }
        }
        if !showLive || settling {
            let alpha = settling ? settle.settledHeadlineAlpha : 1
            let rise = settling ? CGFloat(settle.settledHeadlineOffsetY) : 0
            if alpha > 0.003 {
                cg.saveGState()
                cg.setAlpha(CGFloat(alpha))
                drawSettledHeadline(content, rise: rise)
                cg.restoreGState()
            }
        }
        for target in layout.targets {
            switch target.kind {
            case .replay:
                drawButton(
                    target, title: content.isReplaying ? Localized.text("Stop") : NeuralReading.replayLabel,
                    icon: content.isReplaying ? "stop.fill" : "play.fill", on: false, inks: inks,
                    enabled: content.canReplay)
            case .rows:
                drawButton(target, title: NeuralReading.rowsLabel, icon: nil, on: content.showsRows, inks: inks)
            case .open:
                drawButton(target, title: Localized.text("Open"), icon: nil, on: false, inks: inks)
            case .zone: break
            }
        }
        for entry in layout.chipRects {
            drawChip(entry.chip, rect: entry.rect, inks: inks, hot: hoverTarget == .zone(entry.chip.zone), face: content.face)
        }
        let parts = card.fit(width: CGFloat(content.width))
        if narrow, !parts.contains(.digest) { return }
        let third = layout.thirdLine
        guard third.width > 20 else { return }
        if narrow, compact, live == nil, !settling { return }
        if let live = live ?? (settling ? retainedLive : nil) {
            let nowAlpha = settling ? settle.nowLineAlpha : 1
            if nowAlpha > 0.003 {
                cg.saveGState()
                cg.setAlpha(CGFloat(nowAlpha))
                drawNowLine(live, content: content, rect: third, now: now, clock: clock)
                cg.restoreGState()
            }
            if settling, settle.firstWordsAlpha > 0.003 {
                cg.saveGState()
                cg.setAlpha(CGFloat(settle.firstWordsAlpha))
                drawFirstWords(card, content: content, rect: third)
                cg.restoreGState()
            }
        } else if !(narrow && compact) {
            drawFirstWords(card, content: content, rect: third)
        }
    }

    private func headlineFonts(_ content: Content) -> (number: NSFont, unit: NSFont, duration: NSFont) {
        (
            MacTheme.Ramp.font(.metricLarge), MacTheme.Ramp.font(.panelLabel),
            MacTheme.Ramp.font(.rowStamp)
        )
    }

    private func drawSettledHeadline(_ content: Content, rise: CGFloat) {
        let card = content.card
        let inks = content.inks
        let fonts = headlineFonts(content)
        let numberText = String(card.headline.number)
        let countText = card.headline.count
        let unitText =
            countText.hasPrefix(numberText)
            ? countText.dropFirst(numberText.count).trimmingCharacters(in: .whitespaces) : ""
        var x = layout.textLeft
        var baseline = layout.headlineCenterY + rise
        func draw(_ text: String, font: NSFont, color: NSColor, kern: CGFloat = 0, gap: CGFloat = 8) {
            guard !text.isEmpty, x < layout.headlineRight - 24 else { return }
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: kern]
            let size = (text as NSString).size(withAttributes: attributes)
            let y = baseline - size.height / 2
            (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
            x += ceil(size.width) + gap
        }
        draw(
            countText.hasPrefix(numberText) ? numberText : countText, font: fonts.number,
            color: inks.text, gap: 6)
        draw(unitText, font: fonts.unit, color: inks.textDim)
        if let duration = card.headline.piece(.duration) {
            draw(duration.text, font: fonts.duration, color: inks.textDim)
        }
        drawWordmark(lineEnd: x, baseline: baseline, width: content.width)
        if content.geometry.layout == .narrow {
            x = layout.textLeft
            baseline = layout.clauseCenterY + rise
        }
        if let tally = card.headline.piece(.tally) {
            let parts = tally.text.split(separator: " ", maxSplits: 1).map(String.init)
            let diff = MacTheme.Ramp.font(.diff)
            draw(parts.first ?? "", font: diff, color: inks.page(.live, face: content.face), gap: 4)
            if parts.count > 1 { draw(parts[1], font: diff, color: NSColor(hex: inks.palette.danger) ?? .systemRed) }
        }
        for kind in [NeuralBrainCard.Piece.Kind.failure, .state] {
            guard let piece = card.headline.piece(kind) else { continue }
            let tone = piece.tone.map { inks.page($0, face: content.face) } ?? inks.textDim
            drawClause(piece.text, kind: kind, tone: tone, x: &x, baseline: baseline, inks: inks)
        }
    }

    private func drawClause(
        _ text: String, kind: NeuralBrainCard.Piece.Kind, tone: NSColor, x: inout CGFloat,
        baseline: CGFloat, inks: BrainInks
    ) {
        let font = MacTheme.Ramp.font(.control)
        var glyph = ""
        if kind == .failure, text.lowercased().contains("fixed") || text.lowercased().contains("passed") {
            glyph = "↻ "
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tone]
        let string = glyph + text
        let size = (string as NSString).size(withAttributes: attributes)
        let room = layout.headlineRight - x
        guard room > 40 else { return }
        let drawn = size.width > room ? truncated(string, attributes: attributes, width: room) : string
        (drawn as NSString).draw(at: CGPoint(x: x, y: baseline - size.height / 2), withAttributes: attributes)
        x += min(size.width, room) + 8
    }

    private func truncated(_ text: String, attributes: [NSAttributedString.Key: Any], width: CGFloat) -> String {
        var characters = Array(text)
        while !characters.isEmpty {
            let candidate = String(characters) + "…"
            if (candidate as NSString).size(withAttributes: attributes).width <= width { return candidate }
            characters.removeLast()
        }
        return "…"
    }

    private func drawLiveHeadline(_ live: NeuralLiveCard, content: Content, lift: CGFloat, now: Date) {
        let inks = content.inks
        let compact = content.density == .compact
        let reading = live.reading(now: now, lastActivity: lastActivity)
        let tone = inks.page(reading.tone, face: content.face)
        let wordFont = MacTheme.Ramp.font(.cardTitle)
        let sized = NSFont(descriptor: wordFont.fontDescriptor, size: compact ? 14 : 16) ?? wordFont
        let mono = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let baseline = layout.headlineCenterY + lift
        var x = layout.textLeft
        let glyphSize: CGFloat = compact ? 12 : 14
        drawLiveGlyph(reading.glyph, at: CGPoint(x: x + glyphSize / 2, y: baseline), size: glyphSize, tone: tone)
        x += glyphSize + 8
        let wordColor: NSColor = tone
        let word = reading.word
        let wordAttributes: [NSAttributedString.Key: Any] = [.font: sized, .foregroundColor: wordColor]
        let narrow = content.geometry.layout == .narrow
        let wordSize = (word as NSString).size(withAttributes: wordAttributes)
        (word as NSString).draw(
            at: CGPoint(x: x, y: baseline - wordSize.height / 2), withAttributes: wordAttributes)
        x += ceil(wordSize.width) + 12
        var lineEnd = x
        defer { drawWordmark(lineEnd: lineEnd, baseline: baseline, width: content.width) }
        let counts = reading.counts
        let countAttributes: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: inks.textDim]
        var countsX = x
        var countsY = baseline
        if narrow {
            if compact { return }
            countsX = layout.textLeft
            countsY = layout.clauseCenterY + lift
        }
        let room = layout.headlineRight - countsX
        if room > 60 {
            let drawn = (counts as NSString).size(withAttributes: countAttributes).width > room
                ? truncated(counts, attributes: countAttributes, width: room) : counts
            let size = (drawn as NSString).size(withAttributes: countAttributes)
            (drawn as NSString).draw(
                at: CGPoint(x: countsX, y: countsY - size.height / 2), withAttributes: countAttributes)
            if !narrow { lineEnd = countsX + ceil(size.width) + 8 }
        }
    }

    /// Megatron's name at the right end of the headline's line, when Core's rule says the headline
    /// leaves it room. It is part of the card's one pass, in the chips' own label voice.
    private func drawWordmark(lineEnd: CGFloat, baseline: CGFloat, width: Double) {
        guard NeuralStageMetrics.cardShowsWordmark(
            width: width, headlineEnd: Double(lineEnd), headlineRight: Double(layout.headlineRight),
            wordmarkWidth: Double(layout.wordmarkSize.width))
        else { return }
        let size = layout.wordmarkSize
        wordmarkDrawn = true
        layout.wordmark.draw(
            at: CGPoint(x: layout.headlineRight - size.width, y: baseline - size.height / 2))
    }

    private func drawLiveGlyph(_ glyph: NeuralLiveCard.Glyph, at center: CGPoint, size: CGFloat, tone: NSColor) {
        tone.setStroke()
        tone.setFill()
        switch glyph {
        case .pulse:
            let path = NSBezierPath(ovalIn: NSRect(x: center.x - size * 0.3, y: center.y - size * 0.3, width: size * 0.6, height: size * 0.6))
            path.fill()
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size))
            ring.lineWidth = 1.2
            ring.stroke()
        case .pauseBars:
            NSBezierPath(roundedRect: NSRect(x: center.x - size * 0.32, y: center.y - size * 0.4, width: size * 0.22, height: size * 0.8), xRadius: 1, yRadius: 1).fill()
            NSBezierPath(roundedRect: NSRect(x: center.x + size * 0.1, y: center.y - size * 0.4, width: size * 0.22, height: size * 0.8), xRadius: 1, yRadius: 1).fill()
        case .dashedClock:
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size))
            ring.lineWidth = 1.3
            ring.setLineDash([2.2, 2], count: 2, phase: 0)
            ring.stroke()
            let hands = NSBezierPath()
            hands.move(to: center)
            hands.line(to: CGPoint(x: center.x, y: center.y - size * 0.3))
            hands.move(to: center)
            hands.line(to: CGPoint(x: center.x + size * 0.22, y: center.y))
            hands.lineWidth = 1.2
            hands.stroke()
        case .triangle:
            let path = NSBezierPath()
            path.move(to: CGPoint(x: center.x, y: center.y - size * 0.5))
            path.line(to: CGPoint(x: center.x + size * 0.5, y: center.y + size * 0.42))
            path.line(to: CGPoint(x: center.x - size * 0.5, y: center.y + size * 0.42))
            path.close()
            path.lineWidth = 1.4
            path.lineJoinStyle = .round
            path.stroke()
        }
    }

    private func drawNowLine(_ live: NeuralLiveCard, content: Content, rect: CGRect, now: Date, clock: Double) {
        let inks = content.inks
        let compact = content.density == .compact
        let line = live.line(
            now: now, lastActivity: lastActivity,
            quoteArrivedAt: live.quote.flatMap { quoteArrivals[$0.stepID] }, compact: compact)
        let centerY = rect.midY
        if line.kind == .quote, let quote = line.quote {
            drawQuote(
                speaker: quote.speaker, words: { quote.line(fittingChars: $0) }, rect: rect,
                inks: inks, centerY: centerY)
            return
        }
        let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let argFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: inks.text]
        var x = rect.minX
        let titleSize = (line.title as NSString).size(withAttributes: titleAttributes)
        var trailingText = ""
        var trailingColor = inks.textDim
        var slide: CGFloat = 0
        var trailingAlpha: CGFloat = 1
        switch line.trailing {
        case .output(let text, let tone):
            trailingText = text
            trailingColor = tone == .quiet ? inks.textDim : inks.page(.attention, face: content.face)
            let elapsed = clock - outputArrivedAt
            if elapsed < NeuralLiveCard.outputSlide {
                let t = NeuralTransition.easeOutCubic(elapsed / NeuralLiveCard.outputSlide)
                slide = CGFloat(NeuralLiveCard.outputSlideDistance * (1 - t))
                trailingAlpha = CGFloat(t)
            }
        case .silence(let text):
            trailingText = text
            trailingColor = inks.page(.attention, face: content.face)
        case .none:
            break
        }
        let trailingAttributes: [NSAttributedString.Key: Any] = [.font: argFont, .foregroundColor: trailingColor.withAlphaComponent(trailingAlpha)]
        let maxTrailing = rect.width * 0.42
        var trailingWidth: CGFloat = 0
        if !trailingText.isEmpty {
            let drawn = truncated(trailingText, attributes: trailingAttributes, width: maxTrailing)
            let size = (drawn as NSString).size(withAttributes: trailingAttributes)
            trailingWidth = size.width
            let fitted = size.width > maxTrailing ? truncated(drawn, attributes: trailingAttributes, width: maxTrailing) : drawn
            (fitted as NSString).draw(
                at: CGPoint(x: rect.maxX - size.width, y: centerY - size.height / 2 + slide),
                withAttributes: trailingAttributes)
        }
        (line.title as NSString).draw(
            at: CGPoint(x: x, y: centerY - titleSize.height / 2), withAttributes: titleAttributes)
        x += ceil(titleSize.width) + 8
        if let argument = line.argument {
            let attributes: [NSAttributedString.Key: Any] = [.font: argFont, .foregroundColor: inks.textDim]
            let room = rect.maxX - trailingWidth - 12 - x
            if room > 30 {
                let drawn = truncated(argument, attributes: attributes, width: room)
                let shown = (argument as NSString).size(withAttributes: attributes).width <= room ? argument : drawn
                let size = (shown as NSString).size(withAttributes: attributes)
                (shown as NSString).draw(
                    at: CGPoint(x: x, y: centerY - size.height / 2), withAttributes: attributes)
            }
        }
    }

    private func drawFirstWords(_ card: NeuralBrainCard, content: Content, rect: CGRect) {
        let inks = content.inks
        if let quote = card.quote {
            drawQuote(
                speaker: quote.speaker,
                words: { card.quoteLine(fittingChars: $0) ?? quote.words }, rect: rect, inks: inks,
                centerY: rect.midY)
            return
        }
        let font = MacTheme.Ramp.font(.panelDetail)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: inks.textDim]
        let text = fitted(rect.width) { card.digest(fitting: $0) } measure: {
            ($0 as NSString).size(withAttributes: attributes).width
        }
        guard !text.isEmpty else { return }
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: CGPoint(x: rect.minX, y: rect.midY - size.height / 2), withAttributes: attributes)
    }

    private func fitted(_ width: CGFloat, make: (Int) -> String, measure: (String) -> CGFloat) -> String {
        var best = make(0)
        var characters = 24
        var last = ""
        while characters < 400 {
            let candidate = make(characters)
            if candidate == last { break }
            guard measure(candidate) <= width else { break }
            best = candidate
            last = candidate
            characters += 6
        }
        return best
    }

    private func drawQuote(
        speaker: String, words: (Int) -> String, rect: CGRect, inks: BrainInks, centerY: CGFloat
    ) {
        let accent = NSColor(hex: inks.palette.accent) ?? inks.text
        let mark = "\u{201C}"
        let markFont = NSFont.systemFont(ofSize: 15, weight: .bold)
        let markSize = (mark as NSString).size(withAttributes: [.font: markFont])
        (mark as NSString).draw(
            at: CGPoint(x: rect.minX, y: centerY - markSize.height / 2 + 2),
            withAttributes: [.font: markFont, .foregroundColor: accent])
        let nameFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        let nameAttributes: [NSAttributedString.Key: Any] = [.font: nameFont, .foregroundColor: accent]
        let nameSize = (speaker as NSString).size(withAttributes: nameAttributes)
        let nameX = rect.minX + markSize.width + 4
        (speaker as NSString).draw(
            at: CGPoint(x: nameX, y: centerY - nameSize.height / 2), withAttributes: nameAttributes)
        let wordsFont = italic(MacTheme.Ramp.font(.panelDetail))
        let wordsAttributes: [NSAttributedString.Key: Any] = [.font: wordsFont, .foregroundColor: inks.text]
        let wordsX = nameX + ceil(nameSize.width) + 8
        let room = rect.maxX - wordsX
        guard room > 24 else { return }
        let prefix = speaker + ": "
        let text = fitted(room) { characters in
            let line = words(characters + prefix.count)
            return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : line
        } measure: { ($0 as NSString).size(withAttributes: wordsAttributes).width }
        let size = (text as NSString).size(withAttributes: wordsAttributes)
        (text as NSString).draw(
            at: CGPoint(x: wordsX, y: centerY - size.height / 2), withAttributes: wordsAttributes)
    }

    private func italic(_ font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    private func drawButton(
        _ target: CardTarget, title: String, icon: String?, on: Bool, inks: BrainInks,
        enabled: Bool = true
    ) {
        let rect = target.rect.insetBy(dx: 0.5, dy: 0.5)
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState()
        defer { cg.restoreGState() }
        if !enabled { cg.setAlpha(0.45) }
        let isHot = hoverTarget == target.kind && enabled
        let isDown = pressed == target.kind
        let accent = NSColor(hex: inks.palette.accent) ?? inks.text
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        (isDown ? inks.rule : inks.canvas.blended(withFraction: 0.0, of: inks.raised) ?? inks.canvas).setFill()
        path.fill()
        let line = (isHot || on) ? accent : inks.rule
        line.setStroke()
        path.lineWidth = 1
        path.stroke()
        let font = MacTheme.Ramp.font(.control)
        let ink = (isHot || on) ? accent : inks.textDim
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let size = (title as NSString).size(withAttributes: attributes)
        var x = rect.minX + 10
        if let icon, let image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8.5, weight: .bold))
        {
            let tinted = image.tinted(ink)
            let imageSize = tinted.size
            tinted.draw(
                in: NSRect(x: x, y: rect.midY - imageSize.height / 2, width: imageSize.width, height: imageSize.height))
            x += imageSize.width + 5
        }
        (title as NSString).draw(
            at: CGPoint(x: x, y: rect.midY - size.height / 2), withAttributes: attributes)
    }

    private func drawChip(
        _ chip: NeuralBrainCard.ZoneChip, rect: CGRect, inks: BrainInks, hot: Bool, face: NeuralFace
    ) {
        let said = chip.zone == .say
        let tone: NSColor
        switch chip.tone {
        case .danger: tone = NSColor(hex: inks.palette.danger) ?? .systemRed
        case .attention: tone = NSColor(hex: inks.palette.warn) ?? .systemOrange
        default: tone = inks.page(chip.zone)
        }
        let accent = NSColor(hex: inks.palette.accent) ?? tone
        let outline = rect.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: outline, xRadius: outline.height / 2, yRadius: outline.height / 2)
        inks.canvas.setFill()
        path.fill()
        let edge: NSColor = said ? accent : (hot ? tone : inks.rule)
        edge.withAlphaComponent(said || hot ? 0.9 : 1).setStroke()
        path.lineWidth = 1
        path.stroke()
        let glyphRadius: CGFloat = 5.5
        let shape = BrainShapes.path(chip.zone.shape, radius: glyphRadius)
        if let cg = NSGraphicsContext.current?.cgContext {
            cg.saveGState()
            cg.translateBy(x: rect.minX + 10, y: rect.midY - glyphRadius)
            cg.addPath(shape)
            cg.setStrokeColor(tone.cgColor)
            cg.setLineWidth(1.3)
            cg.strokePath()
            cg.restoreGState()
        }
        let font = MacTheme.Ramp.font(.badge)
        let ink = said ? accent : inks.text
        let labelAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink, .kern: 0.6]
        let label = chip.label.uppercased()
        let labelSize = (label as NSString).size(withAttributes: labelAttributes)
        let x = rect.minX + 10 + 14
        (label as NSString).draw(at: CGPoint(x: x, y: rect.midY - labelSize.height / 2), withAttributes: labelAttributes)
        let countAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: inks.text]
        let count = "\(chip.count)"
        let countSize = (count as NSString).size(withAttributes: countAttributes)
        (count as NSString).draw(
            at: CGPoint(x: x + ceil(labelSize.width) + 6, y: rect.midY - countSize.height / 2),
            withAttributes: countAttributes)
    }
}

extension NSImage {
    /// The template image filled with `color`.
    fileprivate func tinted(_ color: NSColor) -> NSImage {
        let copy = self.copy() as? NSImage ?? self
        copy.lockFocus()
        color.set()
        NSRect(origin: .zero, size: copy.size).fill(using: .sourceAtop)
        copy.unlockFocus()
        copy.isTemplate = false
        return copy
    }
}
