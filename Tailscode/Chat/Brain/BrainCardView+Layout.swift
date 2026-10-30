import TailscodeCore
import UIKit

extension BrainCardView {
    struct Layout {
        var height: CGFloat
        var headline: CGRect
        var clauses: CGRect
        var liveHeadline: CGRect
        var liveCounts: CGRect
        var chips: [CGRect]
        var third: CGRect
        var now: CGRect
        var trailing: CGRect
        var quote: CGRect
        var replay: CGRect
        var rows: CGRect
        var open: CGRect
        var narrow: Bool
        var wordmark = CGRect.zero
        var tucked = false
    }

    /// What the card needs in height at this width: the metrics' height, or more when the reader's
    /// type is large enough that the lines would not fit in it.
    func requiredHeight(width: CGFloat) -> CGFloat {
        guard let metrics else { return 0 }
        return max(CGFloat(metrics.card.height), fittedLayout(width: width).height)
    }

    /// The card's layout at a width. Measuring its lines is what a card costs the main thread
    /// most, and every state a conversation emits asks the transcript to size every card again, so
    /// a layout is kept for what it was made from: the words drawn (`drawnSignature` changes with
    /// any of them), the width, the metrics' height and the reader's type size.
    private func fittedLayout(width: CGFloat) -> Layout {
        guard !drawnSignature.isEmpty, let metrics else { return computeLayout(width: width) }
        let key =
            "\(drawnSignature)|\(Int(width * 4))|\(metrics.card.height)|\(traitCollection.preferredContentSizeCategory.rawValue)"
        if let memo = layoutMemo, memo.key == key { return memo.layout }
        let made = computeLayout(width: width)
        layoutMemo = (key, made)
        return made
    }

    private func computeLayout(width: CGFloat) -> Layout {
        guard let metrics, let card else {
            return Layout(
                height: 0, headline: .zero, clauses: .zero, liveHeadline: .zero, liveCounts: .zero,
                chips: [], third: .zero, now: .zero, trailing: .zero, quote: .zero, replay: .zero,
                rows: .zero, open: .zero, narrow: false)
        }
        if isTucked { return tuckedLayout(width: width, metrics: metrics, card: card) }
        let geometry = metrics.card
        let narrow = geometry.layout == .narrow
        let textX = CGFloat(geometry.text.x)
        let trailingInset: CGFloat = 12
        let textWidth = max(0, width - textX - trailingInset)
        let live = card.live != nil
        let buttonHeight: CGFloat = isCompact ? 26 : 28
        let buttonSet: [CardButton] = live ? [replay, open] : [replay, rows]
        let sizes = buttonSet.map { $0.fitted(height: buttonHeight) }
        let buttonsWidth = sizes.reduce(0) { $0 + $1.width } + CGFloat(max(0, sizes.count - 1)) * 6
        let gap: CGFloat = isCompact ? 4 : 6
        func buttonFrames(origin: CGPoint) -> (replay: CGRect, second: CGRect) {
            let first = CGRect(origin: origin, size: sizes[0])
            let second = CGRect(
                x: first.maxX + 6, y: origin.y, width: sizes[1].width, height: sizes[1].height)
            return (first, second)
        }
        var layout = Layout(
            height: CGFloat(geometry.height), headline: .zero, clauses: .zero, liveHeadline: .zero,
            liveCounts: .zero, chips: [], third: .zero, now: .zero, trailing: .zero, quote: .zero,
            replay: .zero, rows: .zero, open: .zero, narrow: narrow)
        let rest: CGFloat = isCompact ? 6 : 8
        if !narrow {
            let headlineWidth = max(0, textWidth - buttonsWidth - 10)
            let settledHeight = lineSize(headline, width: headlineWidth).height
            let liveHeight = max(
                lineSize(liveHeadline, width: headlineWidth).height,
                lineSize(liveCounts, width: headlineWidth).height)
            let headlineHeight = max(settledHeight, liveHeight, isCompact ? 22 : 28)
            let chipHeight: CGFloat = isCompact ? 24 : 28
            let thirdHeight = max(
                lineSize(third, width: textWidth).height,
                lineSize(nowLabel, width: textWidth).height, 18)
            let parts = card.fit(width: width)
            let hasChips = parts.contains(.zoneStrip)
            let hasThird = parts.contains(.digest) || live
            var total = headlineHeight
            if hasChips { total += gap + chipHeight }
            if hasThird { total += gap + thirdHeight }
            let height = max(CGFloat(geometry.height), total + rest * 2)
            var y = max(rest, ((height - total) / 2).rounded(.down))
            layout.height = height
            layout.headline = CGRect(x: textX, y: y, width: headlineWidth, height: headlineHeight)
            let countsX = textX
            layout.liveHeadline = CGRect(x: countsX, y: y, width: 0, height: headlineHeight)
            y += headlineHeight
            if hasChips {
                y += gap
                var x = textX
                var frames: [CGRect] = []
                for chip in chips where !chip.isHidden {
                    let size = chip.intrinsicContentSize
                    guard x + size.width <= textX + textWidth + 1 else {
                        frames.append(.zero)
                        continue
                    }
                    frames.append(CGRect(x: x, y: y, width: size.width, height: chipHeight))
                    x += size.width + 6
                }
                layout.chips = frames
                y += chipHeight
            }
            if hasThird {
                y += gap
                layout.third = CGRect(x: textX, y: y, width: textWidth, height: thirdHeight)
                layout.quote = layout.third
                let trailingWidth = min(
                    lineSize(nowTrailing, width: textWidth).width, (textWidth * 0.42).rounded())
                layout.trailing = CGRect(
                    x: textX + textWidth - trailingWidth, y: y, width: trailingWidth, height: thirdHeight)
                layout.now = CGRect(
                    x: textX, y: y, width: max(0, textWidth - trailingWidth - 8), height: thirdHeight)
            }
            let origin = CGPoint(x: width - 12 - buttonsWidth, y: 8)
            let frames = buttonFrames(origin: origin)
            layout.replay = frames.replay
            if live { layout.open = frames.second } else { layout.rows = frames.second }
        } else {
            let mainHeight = max(lineSize(headline, width: textWidth).height, isCompact ? 20 : 26)
            let mainWidth = textWidth
            let clauseHeight = max(lineSize(clauses, width: textWidth).height, 0)
            let liveVerdict = lineSize(liveHeadline, width: textWidth).height
            let liveCountHeight = lineSize(liveCounts, width: textWidth).height
            let nowHeight = max(
                lineSize(nowLabel, width: textWidth).height, lineSize(quoteLabel, width: textWidth).height)
            var total: CGFloat
            if live {
                total = max(liveVerdict, 20)
                if !isCompact { total += 2 + liveCountHeight }
                total += gap + max(nowHeight, 16)
            } else {
                total = max(mainHeight, 20)
                if clauseHeight > 0 { total += 2 + clauseHeight }
            }
            total += gap + buttonHeight
            let height = max(CGFloat(geometry.height), total + rest * 2)
            var y = max(rest - 2, ((height - total) / 2).rounded(.down))
            layout.height = height
            if live {
                layout.liveHeadline = CGRect(x: textX, y: y, width: textWidth, height: max(liveVerdict, 20))
                y += max(liveVerdict, 20)
                if !isCompact {
                    y += 2
                    layout.liveCounts = CGRect(x: textX, y: y, width: textWidth, height: liveCountHeight)
                    y += liveCountHeight
                } else {
                    let verdictWidth = ceil(liveHeadline.attributedText?.size().width ?? 0) + 8
                    layout.liveHeadline.size.width = verdictWidth
                    layout.liveCounts = CGRect(
                        x: textX + verdictWidth, y: layout.liveHeadline.minY,
                        width: max(0, textWidth - verdictWidth), height: max(liveVerdict, 20))
                }
                y += gap
                layout.now = CGRect(x: textX, y: y, width: textWidth, height: max(nowHeight, 16))
                layout.quote = layout.now
                layout.trailing = .zero
                y += max(nowHeight, 16)
            } else {
                layout.headline = CGRect(x: textX, y: y, width: mainWidth, height: max(mainHeight, 20))
                layout.liveHeadline = layout.headline
                y += max(mainHeight, 20)
                if clauseHeight > 0 {
                    y += 2
                    layout.clauses = CGRect(x: textX, y: y, width: textWidth, height: clauseHeight)
                    y += clauseHeight
                }
            }
            y += gap
            let frames = buttonFrames(origin: CGPoint(x: textX, y: y))
            layout.replay = frames.replay
            if live { layout.open = frames.second } else { layout.rows = frames.second }
        }
        layout.wordmark = wordmarkFrame(
            layout, width: width, right: narrow ? textX + textWidth : layout.headline.maxX, live: live)
        return layout
    }

    private func lineSize(_ label: UILabel, width limit: CGFloat) -> CGSize {
        guard let text = label.attributedText, text.length > 0 else { return .zero }
        return CGSize(
            width: ceil(text.size().width),
            height: BrainText.height(text, width: max(limit, 1), lines: label.numberOfLines))
    }

    /// A phone's narrow card: two lines of words and nothing else. The buttons are icons at the
    /// first line's end (Open while the turn runs, Replay and Rows once it has), the first line is
    /// the verdict and its counts or the headline, and the second is the step in flight or what
    /// the turn came to, at the card's full width.
    private func tuckedLayout(
        width: CGFloat, metrics: NeuralStageMetrics, card: NeuralBrainCard
    ) -> Layout {
        let geometry = metrics.card
        let textX = CGFloat(geometry.text.x)
        let textWidth = max(0, width - textX - 12)
        let live = card.live != nil
        let buttonHeight: CGFloat = isCompact ? 26 : 28
        let buttonSet: [CardButton] = live ? [open] : [replay, rows]
        let sizes = buttonSet.map { $0.fitted(height: buttonHeight) }
        let buttonsWidth = sizes.reduce(0) { $0 + $1.width } + CGFloat(sizes.count - 1) * 4
        let lineWidth = max(0, textWidth - buttonsWidth - 8)
        let verdictHeight = live ? lineSize(liveHeadline, width: lineWidth).height : lineSize(headline, width: lineWidth).height
        let countsHeight = live ? lineSize(liveCounts, width: lineWidth).height : 0
        let firstHeight = max(buttonHeight, verdictHeight, countsHeight)
        let secondHeight = max(
            live
                ? max(lineSize(nowLabel, width: textWidth).height, lineSize(quoteLabel, width: textWidth).height, 16)
                : lineSize(clauses, width: textWidth).height, 0)
        let total = firstHeight + (secondHeight > 0 ? 2 + secondHeight : 0)
        let rest: CGFloat = isCompact ? 4 : 6
        let height = max(CGFloat(geometry.height), total + rest * 2)
        let top = ((height - total) / 2).rounded(.down)
        let secondY = top + firstHeight + 2
        var layout = Layout(
            height: height, headline: .zero, clauses: .zero, liveHeadline: .zero, liveCounts: .zero,
            chips: [], third: .zero, now: .zero, trailing: .zero, quote: .zero, replay: .zero,
            rows: .zero, open: .zero, narrow: true)
        layout.tucked = true
        let buttonY = top + ((firstHeight - buttonHeight) / 2).rounded(.down)
        var x = width - 12 - buttonsWidth
        let buttonsLeft = x
        var frames: [CGRect] = []
        for size in sizes {
            frames.append(CGRect(x: x, y: buttonY, width: size.width, height: size.height))
            x += size.width + 4
        }
        if live {
            layout.open = frames[0]
            let verdictWidth = min(ceil(liveHeadline.attributedText?.size().width ?? 0) + 8, lineWidth)
            layout.liveHeadline = CGRect(x: textX, y: top, width: verdictWidth, height: firstHeight)
            layout.liveCounts = CGRect(
                x: textX + verdictWidth, y: top, width: max(0, lineWidth - verdictWidth), height: firstHeight)
            layout.now = CGRect(x: textX, y: secondY, width: textWidth, height: secondHeight)
            layout.quote = layout.now
        } else {
            layout.replay = frames[0]
            layout.rows = frames[1]
            layout.headline = CGRect(x: textX, y: top, width: lineWidth, height: firstHeight)
            layout.liveHeadline = layout.headline
            if secondHeight > 0 {
                layout.clauses = CGRect(x: textX, y: secondY, width: textWidth, height: secondHeight)
            }
        }
        layout.wordmark = wordmarkFrame(layout, width: width, right: buttonsLeft - 4, live: live)
        return layout
    }

    /// Where Megatron's name goes: the right end of the headline's line, on the headline's own
    /// baseline, when Core's rule says the headline's words leave it room; zero when they do not.
    /// A label of the card like the others, so it is drawn with them and costs no pass of its own.
    private func wordmarkFrame(_ layout: Layout, width: CGFloat, right: CGFloat, live: Bool) -> CGRect {
        guard let text = wordmark.attributedText else { return .zero }
        func extent(_ words: NSAttributedString?) -> CGFloat { ceil(words?.size().width ?? 0) }
        let line = live && layout.narrow ? layout.liveHeadline : layout.headline
        let lead: UIFont
        var end = line.minX
        if live {
            lead = Theme.Ramp.font(.cardTitle)
            end += extent(liveHeadline.attributedText)
            if !layout.narrow { end += 10 + extent(liveCounts.attributedText) }
            else if isCompact || layout.tucked { end += 8 + extent(liveCounts.attributedText) }
        } else {
            lead = Theme.Ramp.font(.metricLarge)
            end += extent(layout.narrow ? narrowMain : wideHeadline)
        }
        let face = Theme.Ramp.font(.sectionLabel)
        let size = CGSize(width: ceil(text.size().width) + 2, height: face.lineHeight)
        guard NeuralStageMetrics.cardShowsWordmark(
            width: Double(width), headlineEnd: Double(end), headlineRight: Double(right),
            wordmarkWidth: Double(size.width))
        else { return .zero }
        let baseline = line.midY + (lead.ascender + lead.descender) / 2
        return CGRect(
            x: right - size.width, y: baseline - face.ascender,
            width: size.width, height: size.height)
    }

    func layoutTexts(animated: Bool) {
        guard let metrics, let card, bounds.width > 0 else { return }
        surface.frame = bounds
        press.frame = bounds
        textGroup.bounds = CGRect(origin: .zero, size: bounds.size)
        textGroup.center = CGPoint(x: bounds.midX + moveOffsetX, y: bounds.midY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edge.path = {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 1.5, y: 0))
            path.addLine(to: CGPoint(x: 1.5, y: bounds.height))
            return path
        }()
        edge.frame = bounds
        CATransaction.commit()
        picture.frame = CGRect(
            x: metrics.card.picture.x, y: metrics.card.picture.y, width: metrics.card.picture.width,
            height: metrics.card.picture.height)
        let layout = fittedLayout(width: bounds.width)
        let live = card.live != nil || settle.progress < 1 && memory?.settleClock.settleStartedAt != nil
        lastLayout = layout
        let wide = !layout.narrow
        let showsLiveGroup = live
        headline.isHidden = false
        headline.attributedText = wide ? wideHeadline : narrowMain
        headline.frame = layout.headline
        clauses.isHidden = wide
        clauses.frame = layout.clauses
        liveHeadline.isHidden = !showsLiveGroup
        liveCounts.isHidden = !showsLiveGroup
        if wide {
            let headlineWidth = layout.headline.width
            let verdict = liveHeadline.attributedText?.size().width.rounded(.up) ?? 0
            let counts = liveCounts.attributedText?.size().width.rounded(.up) ?? 0
            let verdictFrame = CGRect(
                x: layout.headline.minX, y: layout.headline.minY,
                width: min(verdict + 2, headlineWidth), height: layout.headline.height)
            liveHeadline.frame = verdictFrame
            liveCounts.frame = CGRect(
                x: verdictFrame.maxX + 10, y: layout.headline.minY,
                width: max(0, min(counts + 2, headlineWidth - verdictFrame.width - 10)),
                height: layout.headline.height)
            liveHeadline.textAlignment = .natural
        } else {
            liveHeadline.frame = layout.liveHeadline
            liveCounts.frame = layout.liveCounts
        }
        liveCounts.isHidden = liveCounts.isHidden || (layout.liveCounts == .zero && layout.narrow)
        chipHost.frame = bounds
        var visible = 0
        var index = 0
        for chip in chips {
            if chip.isHidden && index >= card.chips.count { continue }
            defer { index += 1 }
            guard visible < layout.chips.count else {
                chip.isHidden = true
                continue
            }
            let frame = layout.chips[visible]
            visible += 1
            chip.isHidden = frame == .zero
            chip.frame = frame
        }
        for hidden in chips.dropFirst(card.chips.count) { hidden.isHidden = true }
        let hasThird = layout.third != .zero
        third.isHidden = !hasThird || !wide && true
        third.frame = layout.third
        if hasThird, !third.isHidden {
            if quoteSource != nil {
                third.attributedText = fittedQuote(width: layout.third.width) ?? third.attributedText
            } else {
                third.attributedText = fittedDigest(width: layout.third.width, card: card)
            }
        }
        nowLabel.frame = layout.now
        nowLabel.isHidden = card.live == nil && settle.nowLineAlpha <= 0
        nowTrailing.frame = layout.trailing
        nowTrailing.isHidden = nowLabel.isHidden || layout.trailing == .zero
        quoteLabel.frame = layout.quote
        quoteLabel.isHidden = nowLabel.isHidden || quoteLabel.attributedText == nil
        if quoteLabel.attributedText != nil { nowLabel.isHidden = true; nowTrailing.isHidden = true }
        replay.frame = layout.replay
        rows.frame = layout.rows
        open.frame = layout.open
        wordmark.frame = layout.wordmark
        wordmark.isHidden = layout.wordmark == .zero
    }
}
