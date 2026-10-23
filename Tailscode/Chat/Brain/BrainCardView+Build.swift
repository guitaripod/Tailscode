import TailscodeCore
import UIKit

extension BrainCardView {
    func rebuild(now: Date) {
        guard let card, let model, let row, let metrics, let memory else { return }
        let line = card.live.map {
            memory.line(for: $0, now: now, compact: isCompact)
        }
        let reading = card.live.map { $0.reading(now: now, lastActivity: memory.lastActivity) }
        var signature = [
            card.headline.pieces.map(\.text).joined(separator: "|"),
            card.chips.map { "\($0.zone)\($0.count)\($0.tone)" }.joined(separator: ","),
            card.digest, card.quote.map { $0.speaker + $0.words } ?? "",
            "\(metrics.width)|\(density)|\(row.showsRows)|\(isHovered)",
        ].joined(separator: "#")
        if let reading, let line {
            signature += "#live#\(reading.word)|\(reading.counts)|\(line.title)|\(line.argument ?? "")|\(line.kind)"
            switch line.trailing {
            case .output(let text, let tone): signature += "|o\(text)\(tone)"
            case .silence(let text): signature += "|s\(text)"
            case .none: break
            }
        }
        let settledNow = memory.settleClock.settleStartedAt != nil
        signature += "#\(settledNow)"
        guard signature != drawnSignature else { return }
        drawnSignature = signature

        let settling = memory.settleClock.isSettling(now: CACurrentMediaTime())
        if settling, !isLive { startSettle() }

        surface.backgroundColor = Theme.Color.secondaryBackground
        applyEdge(card)
        applyEmphasis()
        buildHeadlines(card, reading: reading)
        buildChips(card)
        buildThird(card, line: line)
        buttons(model: model, row: row, live: isLive)
        picture.configure(card: card, ink: ink ?? BrainInk(palette: BrainPalette.palette(for: traitCollection), face: model.face), hovered: isHovered)
        if !settling && !isLive {
            apply(settle: .settled)
        } else if isLive {
            apply(settle: .live)
        }
        drawn = (
            card.headline.pieces.map(\.text).joined(separator: " "),
            card.chips.map { "\($0.label) \($0.count)" },
            third.attributedText?.string ?? nowLabel.attributedText?.string ?? "", isLive)
        isAccessibilityElement = false
        press.isAccessibilityElement = true
        press.accessibilityLabel = Localized.text(
            "%1$@, %2$@", Localized.text("Megatron"),
            isLive ? liveSpoken(card, reading: reading) : card.spoken)
        press.accessibilityValue = row.isOpen ? Localized.text("Expanded") : Localized.text("Collapsed")
        press.accessibilityHint = Localized.text("Double tap to open Megatron")
        press.accessibilityCustomActions = actions(card: card, model: model)
        setNeedsLayout()
    }

    private func liveSpoken(_ card: NeuralBrainCard, reading: NeuralLiveCard.Reading?) -> String {
        guard let reading else { return card.spoken }
        return Localized.text("%1$@, %2$@", reading.word, reading.counts)
    }

    private func actions(card: NeuralBrainCard, model: NeuralBrainModel) -> [UIAccessibilityCustomAction] {
        var out: [UIAccessibilityCustomAction] = []
        if model.turn.outcome != .running {
            out.append(
                UIAccessibilityCustomAction(name: NeuralReading.replayLabel) { [weak self] _ in
                    self?.onReplay?()
                    return true
                })
            out.append(
                UIAccessibilityCustomAction(name: Localized.text("Share this turn")) { [weak self] _ in
                    self?.onShare?()
                    return true
                })
        }
        out.append(
            UIAccessibilityCustomAction(name: NeuralReading.rowsLabel) { [weak self] _ in
                self?.onRows?()
                return true
            })
        for chip in card.chips {
            let zone = chip.zone
            out.append(
                UIAccessibilityCustomAction(
                    name: Localized.text("Dive into %@", chip.label)
                ) { [weak self] _ in
                    self?.onDive?(zone)
                    return true
                })
        }
        return out
    }

    private func applyEdge(_ card: NeuralBrainCard) {
        let tone = BrainCanvas.tone(card.edgeTone).resolvedColor(with: traitCollection)
        edge.strokeColor = tone.cgColor
        edge.lineDashPattern = card.edge == .stopped ? [6, 4] : nil
        edge.removeAnimation(forKey: "pulse")
        guard let live = card.live, live.edgePulses, !UIAccessibility.isReduceMotionEnabled,
            settle.progress < 1 || memory?.settleClock.settleStartedAt == nil,
            let animation = BrainSwell.level(for: live.motion)
        else { return }
        edge.setRepeatingMotion(
            animation, forKey: "pulse", meaning: live.motion == .heartbeat ? .attention : .working)
    }

    private func buildHeadlines(_ card: NeuralBrainCard, reading: NeuralLiveCard.Reading?) {
        let split = Self.countPieces(card)
        let main = NSMutableAttributedString(
            string: split.number,
            attributes: Theme.Ramp.attributes(.metricLarge, color: Theme.Color.label))
        if !split.unit.isEmpty {
            main.append(
                NSAttributedString(
                    string: " " + split.unit,
                    attributes: Theme.Ramp.attributes(.panelLabel, color: Theme.Color.secondaryLabel)))
        }
        if let duration = card.headline.piece(.duration) {
            main.append(
                NSAttributedString(
                    string: "  " + duration.text,
                    attributes: Theme.Ramp.attributes(.rowStamp, color: Theme.Color.secondaryLabel)))
        }
        let tail = NSMutableAttributedString()
        if let tally = card.headline.piece(.tally) {
            for word in tally.text.split(separator: " ") {
                if tail.length > 0 { tail.append(NSAttributedString(string: " ")) }
                tail.append(
                    NSAttributedString(
                        string: String(word),
                        attributes: Theme.Ramp.attributes(
                            .rowMeta,
                            color: word.hasPrefix("+") ? Theme.Color.accent : Theme.Color.danger)))
            }
        }
        for kind in [NeuralBrainCard.Piece.Kind.failure, .state] {
            guard let piece = card.headline.piece(kind) else { continue }
            if tail.length > 0 { tail.append(NSAttributedString(string: "  ")) }
            let ink = piece.tone.map { BrainCanvas.tone($0) } ?? Theme.Color.secondaryLabel
            if kind == .failure, let name = Self.clauseSymbol(card.verdict),
                let image = BrainCanvas.image(name, size: 11)
            {
                let attachment = NSTextAttachment()
                attachment.image = image.withTintColor(ink, renderingMode: .alwaysOriginal)
                attachment.bounds = CGRect(x: 0, y: -1.5, width: 11, height: 11)
                tail.append(NSAttributedString(attachment: attachment))
                tail.append(NSAttributedString(string: " "))
            }
            tail.append(
                NSAttributedString(
                    string: piece.text, attributes: Theme.Ramp.attributes(.rowMeta, color: ink)))
        }
        wordmark.attributedText = NSAttributedString(
            string: NeuralReading.wordmark,
            attributes: Theme.Ramp.attributes(.sectionLabel, color: Theme.Color.secondaryLabel))
        wideHeadline = NSMutableAttributedString(attributedString: main)
        if tail.length > 0 {
            wideHeadline.append(NSAttributedString(string: "   "))
            wideHeadline.append(tail)
        }
        headline.attributedText = wideHeadline
        narrowMain = main
        clauses.attributedText = tail

        if let reading, card.live != nil {
            let verdictInk = BrainCanvas.tone(reading.tone)
            let word = NSMutableAttributedString()
            if let image = BrainCanvas.image(BrainCanvas.symbol(for: reading.glyph), size: reading.glyph == .pulse ? 8 : 12) {
                let attachment = NSTextAttachment()
                attachment.image = image.withTintColor(verdictInk, renderingMode: .alwaysOriginal)
                let size = image.size
                attachment.bounds = CGRect(x: 0, y: reading.glyph == .pulse ? 1 : -1, width: size.width, height: size.height)
                word.append(NSAttributedString(attachment: attachment))
                word.append(NSAttributedString(string: " "))
            }
            word.append(
                NSAttributedString(
                    string: reading.word,
                    attributes: Theme.Ramp.attributes(.cardTitle, color: verdictInk)))
            liveHeadline.attributedText = word
            liveCounts.attributedText = NSAttributedString(
                string: reading.counts,
                attributes: Theme.Ramp.attributes(.rowStamp, color: Theme.Color.secondaryLabel))
        } else {
            liveHeadline.attributedText = nil
            liveCounts.attributedText = nil
        }
    }

    private static func clauseSymbol(_ verdict: NeuralVerdict.Turn) -> String? {
        switch verdict {
        case .doneAfterRetries: return "arrow.trianglehead.2.clockwise.rotate.90"
        case .failed: return "xmark"
        default: return nil
        }
    }

    private static func countPieces(_ card: NeuralBrainCard) -> (number: String, unit: String) {
        let count = card.headline.count
        let number = String(card.headline.number)
        guard count.hasPrefix(number) else { return (count, "") }
        return (number, count.dropFirst(number.count).trimmingCharacters(in: .whitespaces))
    }

    private func buildChips(_ card: NeuralBrainCard) {
        let wanted = card.chips
        while chips.count < wanted.count {
            let chip = BrainZoneChip(height: isCompact ? 24 : 28)
            chipHost.addSubview(chip)
            chips.append(chip)
        }
        for (index, chip) in chips.enumerated() {
            guard index < wanted.count else {
                chip.isHidden = true
                continue
            }
            let item = wanted[index]
            chip.configure(
                BrainZoneChip.Content(
                    zone: item.zone, count: item.count, tone: item.tone, showsWord: true, isOn: false,
                    word: item.label))
            chip.onTap = { [weak self] in self?.onDive?(item.zone) }
            chip.isAccessibilityElement = false
        }
    }

    private func buildThird(_ card: NeuralBrainCard, line: NeuralLiveCard.Line?) {
        if let quote = card.quote {
            third.attributedText = Self.quoteText(
                speaker: quote.speaker, words: quote.words, fit: nil, ink: Theme.Color.label)
            quoteSource = (quote.speaker, quote.words)
        } else {
            third.attributedText = NSAttributedString(
                string: card.digest,
                attributes: Theme.Ramp.attributes(.cardBody, color: Theme.Color.secondaryLabel))
            quoteSource = nil
        }
        guard let line else {
            nowLabel.attributedText = nil
            nowTrailing.attributedText = nil
            quoteLabel.attributedText = nil
            return
        }
        switch line.kind {
        case .quote:
            let quote = line.quote
            quoteLabel.attributedText = Self.quoteText(
                speaker: quote?.speaker ?? "", words: quote?.words ?? "", fit: nil, ink: Theme.Color.label)
            nowLabel.attributedText = nil
            nowTrailing.attributedText = nil
        case .step:
            quoteLabel.attributedText = nil
            let text = NSMutableAttributedString(
                string: line.title,
                attributes: Theme.Ramp.attributes(.rowTitleStrong, color: Theme.Color.label))
            if let argument = line.argument, !argument.isEmpty {
                text.append(
                    NSAttributedString(
                        string: "  " + argument,
                        attributes: Theme.Ramp.attributes(.rowDetail, color: Theme.Color.secondaryLabel)))
            }
            nowLabel.attributedText = text
            switch line.trailing {
            case .output(let output, let tone):
                nowTrailing.attributedText = NSAttributedString(
                    string: output,
                    attributes: Theme.Ramp.attributes(
                        .rowDetail,
                        color: tone == .attention ? Theme.Color.warning : Theme.Color.secondaryLabel,
                        alignment: .right))
            case .silence(let words):
                let silent = NSMutableAttributedString()
                if let image = BrainCanvas.image("clock.badge.exclamationmark", size: 11) {
                    let attachment = NSTextAttachment()
                    attachment.image = image.withTintColor(Theme.Color.warning.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal)
                    attachment.bounds = CGRect(x: 0, y: -1.5, width: 12, height: 11)
                    silent.append(NSAttributedString(attachment: attachment))
                    silent.append(NSAttributedString(string: " "))
                }
                silent.append(
                    NSAttributedString(
                        string: words,
                        attributes: Theme.Ramp.attributes(
                            .rowDetail, color: Theme.Color.warning, alignment: .right)))
                nowTrailing.attributedText = silent
            case .none:
                nowTrailing.attributedText = nil
            }
        }
        if line.kind == .quote, let memory, let arrived = memory.quoteArrivals[line.quote?.stepID ?? ""] {
            scheduleQuoteRelease(after: NeuralLiveCard.quoteHold - BrainDebug.now.timeIntervalSince(arrived))
        }
    }

    private func scheduleQuoteRelease(after seconds: TimeInterval) {
        quoteRelease?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.clockTick() }
        }
        quoteRelease = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, seconds + 0.05), execute: item)
    }

    /// The agent's own words as a line: the quote mark and its name in the accent, the words in
    /// italic ink. `fit` cuts the words at a whole word to what a width can say.
    private static func quoteText(
        speaker: String, words: String, fit width: CGFloat?, ink: UIColor
    ) -> NSAttributedString {
        let out = NSMutableAttributedString(
            string: "\u{201C} ",
            attributes: Theme.Ramp.attributes(.cardTitle, color: Theme.Color.accent))
        out.append(
            NSAttributedString(
                string: speaker + "  ",
                attributes: Theme.Ramp.attributes(.rowTitleStrong, color: Theme.Color.accent)))
        out.append(
            NSAttributedString(
                string: words, attributes: Theme.Ramp.attributes(.thought, color: ink)))
        return out
    }

    /// The quote cut at a whole word to the room the line has.
    func fittedQuote(width: CGFloat) -> NSAttributedString? {
        guard let source = quoteSource else { return nil }
        var best = Self.quoteText(
            speaker: source.speaker,
            words: NeuralAccount.quote(of: source.words, maxChars: 8), fit: nil, ink: Theme.Color.label)
        var characters = 12
        let limit = source.words.count + 8
        while characters <= limit + 12 {
            let words = NeuralAccount.quote(of: source.words, maxChars: characters)
            let candidate = Self.quoteText(
                speaker: source.speaker, words: words, fit: nil, ink: Theme.Color.label)
            guard candidate.size().width.rounded(.up) <= width else { break }
            best = candidate
            if words == NeuralAccount.quote(of: source.words, maxChars: Int.max / 4) { break }
            characters += 4
        }
        return best
    }

    func fittedDigest(width: CGFloat, card: NeuralBrainCard) -> NSAttributedString {
        var best = card.digest(fitting: 0)
        var characters = 24
        let limit = card.digest.count
        let attributes = Theme.Ramp.attributes(.cardBody, color: Theme.Color.secondaryLabel)
        while characters <= limit + 24 {
            let candidate = card.digest(fitting: characters)
            guard NSAttributedString(string: candidate, attributes: attributes).size().width.rounded(.up) <= width
            else { break }
            best = candidate
            if candidate == card.digest { break }
            characters += 6
        }
        return NSAttributedString(string: best, attributes: attributes)
    }

    func buttons(model: NeuralBrainModel, row: BrainRow, live: Bool) {
        replay.set(
            title: NeuralReading.replayLabel, symbol: "play.fill", on: false, compact: isCompact)
        rows.set(title: NeuralReading.rowsLabel, symbol: nil, on: row.showsRows, compact: isCompact)
        open.set(title: Localized.text("Open"), symbol: nil, on: false, compact: isCompact)
        replay.isHidden = false
        replay.isEnabled = !(live || model.steps.count <= 1)
        replay.accessibilityLabel = NeuralReading.replayLabel
        rows.accessibilityLabel = NeuralReading.rowsLabel
        rows.accessibilityTraits = row.showsRows ? [.button, .selected] : .button
        open.isHidden = !live
        rows.isHidden = live
        for button in [replay, rows, open] { button.isAccessibilityElement = false }
    }
}
