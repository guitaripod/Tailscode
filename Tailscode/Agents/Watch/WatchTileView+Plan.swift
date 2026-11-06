import TailscodeCore
import UIKit

extension WatchTileView {
    private struct Geo {
        let unit: CGFloat
        let pad: CGFloat
        let glyph: CGFloat
        let columnX: CGFloat
        let columnWidth: CGFloat
        let bodyWidth: CGFloat
        let bodyTop: CGFloat
        let bodyBottom: CGFloat
        let beat: CGRect?
        let gap: CGFloat
    }

    private struct Fit {
        var title = CGRect.zero
        var status = CGRect.zero
        var meta: CGRect?
        var words: CGRect?
        var detail: CGRect?
        var more: CGRect?
        var steps: [CGRect?] = Array(repeating: nil, count: AgentRow.stepCount)
        var facts: CGRect?
        var plan: [CGRect?] = Array(repeating: nil, count: WatchTileView.planLines)
        var said: CGRect?
        var files: [CGRect?] = Array(repeating: nil, count: WatchTileView.fileLines)
        var context: CGRect?
        var hold: CGRect?
        var deny: CGRect?
        var chat: CGRect?
    }

    private static let levels: [CGFloat] = [1, 0.9, 0.8, 0.7, 0.62]

    static func opacity(of tile: WallTile) -> CGFloat {
        switch tile.state {
        case .finished(.failed): return 1
        case .finished: return 1 - 0.55 * CGFloat(min(1, max(0, tile.fade)))
        case .away: return 0.7
        default: return 1
        }
    }

    /// Sets every word of the tile from `tile` and lays it out inside `rect`, the cell Core gave it:
    /// the largest of five type levels at which the words, the command and the steps all fit, and at
    /// the smallest the words are cut by lines and an ask says the rest is in the peek.
    func apply(
        _ tile: WallTile, main rect: WallRect, context: WatchWordsContext, action: WatchAction?
    ) {
        remember(tile, main: rect)
        alpha = Self.opacity(of: tile)
        let geo = geometry(of: rect, unit: context.layout.unit)
        prepareContent(tile, context: context, action: action)
        for (index, level) in Self.levels.enumerated() {
            let last = index == Self.levels.count - 1
            if let fit = solve(tile, geo: geo, context: context, action: action, level: level, last: last) {
                place(fit)
                break
            }
        }
        tick(now: context.now, context: context, action: action)
    }

    private func geometry(of rect: WallRect, unit: Double) -> Geo {
        let metrics = WallTileMetrics.tile(rect, unit: unit)
        let pad = CGFloat(metrics.padding)
        let gap = max(6, CGFloat(0.9 * unit))
        let hasBeat = tile?.beat?.isEmpty == false
        let beat = hasBeat
            ? CGRect(
                x: metrics.beat.x - rect.x, y: metrics.beat.y - rect.y, width: metrics.beat.width,
                height: metrics.beat.height)
            : nil
        return Geo(
            unit: CGFloat(unit), pad: pad, glyph: CGFloat(metrics.glyphSize),
            columnX: CGFloat(metrics.textLeading - rect.x),
            columnWidth: CGFloat(rect.maxX - metrics.padding - metrics.textLeading),
            bodyWidth: CGFloat(rect.width) - 2 * pad, bodyTop: CGFloat(metrics.body.y - rect.y),
            bodyBottom: CGFloat(metrics.body.maxY - rect.y), beat: beat, gap: gap)
    }

    private func prepareContent(_ tile: WallTile, context: WatchWordsContext, action: WatchAction?) {
        let palette = context.palette
        title.set(tile.title, font: title.font ?? WatchFont.text(13, .semibold), ink: palette.text.color())
        var parts = [tile.machine]
        if let chip = tile.chip { parts.append(chip.effort.map { chip.name + " " + $0 } ?? chip.name) }
        meta.set(
            parts.filter { !$0.isEmpty }.joined(separator: " · "), font: meta.font ?? WatchFont.text(11),
            ink: palette.dim.color())
        words.set(tile.words, font: words.font ?? WatchFont.text(13), ink: palette.text.color(), lines: 3)
        let shownDetail = tile.detail == tile.words ? nil : tile.detail
        detail.set(
            shownDetail ?? "", font: detail.font ?? WatchFont.mono(11),
            ink: palette.text.color(isAsk ? 1 : 0.86), lines: 0)
        detail.lineBreakMode = isAsk ? .byWordWrapping : .byTruncatingTail
        more.set(
            String(localized: "More in the peek"), font: more.font ?? WatchFont.text(11),
            ink: palette.dim.color(), lines: 1)
        if let share = tile.contextShare, tile.beat?.isEmpty == false {
            let percent = Int((min(1, max(0, share)) * 100).rounded())
            contextLabel.set(
                String(localized: "\(percent)% context"), font: contextLabel.font ?? WatchFont.text(11),
                ink: (share > 0.85 ? palette.needs : palette.dim).color(), lines: 1, alignment: .right)
        } else {
            contextLabel.text = nil
        }
    }

    private func solve(
        _ tile: WallTile, geo: Geo, context: WatchWordsContext, action: WatchAction?, level s: CGFloat,
        last: Bool
    ) -> Fit? {
        let scale = context.scale
        let palette = context.palette
        var fit = Fit()
        title.font = WatchFont.text(scale.type(2.5 * s, floor: 13), .semibold)
        title.numberOfLines = s == 1 ? 2 : 1
        status.font = WatchFont.text(scale.type(1.95 * s, floor: 11), .semibold)
        meta.font = WatchFont.text(scale.type(1.6 * s, floor: 11))
        words.font = WatchFont.text(scale.type(3.2 * s, floor: 13), .semibold)
        detail.font = WatchFont.mono(scale.type((isAsk ? 2.5 : 2.0) * s, floor: 11), isAsk ? .medium : .regular)
        more.font = WatchFont.text(scale.type(1.5 * s, floor: 11))
        contextLabel.font = WatchFont.text(scale.type(1.5 * s, floor: 11))
        let stepFont = WatchFont.text(scale.type(1.8 * s, floor: 11))
        let columnWidth = max(20, geo.columnWidth)
        status.numberOfLines = s >= 0.9 ? 2 : 1
        setStatus(tile, now: context.now, context: context, action: action, lines: s >= 0.9 ? 2 : 1)
        let titleHeight = title.height(forWidth: columnWidth)
        let statusHeight = status.height(forWidth: columnWidth)
        let keepsMeta = !(isAsk && s <= 0.7) && columnWidth > 60
        let metaHeight = meta.text?.isEmpty == false && keepsMeta ? meta.height(forWidth: columnWidth) : 0
        let spacing: CGFloat = 2
        let column = titleHeight + spacing + statusHeight + (metaHeight > 0 ? spacing + metaHeight : 0)
        fit.title = CGRect(x: geo.columnX, y: geo.pad, width: columnWidth, height: titleHeight)
        fit.status = CGRect(x: geo.columnX, y: fit.title.maxY + spacing, width: columnWidth, height: statusHeight)
        if metaHeight > 0 {
            fit.meta = CGRect(x: geo.columnX, y: fit.status.maxY + spacing, width: columnWidth, height: metaHeight)
        }
        let top = max(geo.bodyTop, geo.pad + max(geo.glyph, column) + geo.gap * 0.6)
        var bottom = geo.beat.map { $0.minY - geo.gap * 0.5 } ?? geo.bodyBottom
        if let ask = tile.ask, tile.state.isNeedsYou {
            let height = min(54, max(38, scale.space(4.4 * s)))
            let size = min(scale.type(2.1 * s, floor: 13), height * 0.46)
            placePills(&fit, ask: ask, style: context.style, palette: palette, action: action, geo: geo, y: bottom - height, height: height, size: size)
            bottom -= height + geo.gap
        }
        if let beat = geo.beat, contextLabel.text?.isEmpty == false {
            let width = geo.pad + geo.bodyWidth - beat.maxX - geo.gap
            let needed = contextLabel.widthForOneLine()
            if width >= needed {
                let height = contextLabel.lineHeight
                fit.context = CGRect(x: geo.pad + geo.bodyWidth - width, y: beat.maxY - height, width: width, height: height)
            }
        }
        return stack(&fit, tile: tile, geo: geo, top: top, bottom: bottom, stepFont: stepFont, palette: palette, last: last)
    }

    private func stack(
        _ fit: inout Fit, tile: WallTile, geo: Geo, top: CGFloat, bottom: CGFloat, stepFont: UIFont,
        palette: WallPalette, last: Bool
    ) -> Fit? {
        let width = geo.bodyWidth
        let room = bottom - top
        let gap = geo.gap
        words.numberOfLines = 3
        var wordsHeight = words.text?.isEmpty == false ? words.height(forWidth: width) : 0
        let hasDetail = detail.text?.isEmpty == false
        detail.numberOfLines = 0
        let detailNatural = hasDetail ? detail.height(forWidth: width) : 0
        let lines = steps(of: tile).prefix(3)
        let stepHeight = ceil(stepFont.lineHeight)
        let stepsHeight = lines.isEmpty ? 0 : CGFloat(lines.count) * stepHeight + CGFloat(lines.count - 1) * 3
        let withDetail = wordsHeight + (hasDetail ? gap + detailNatural : 0)
        let allFit = withDetail + (stepsHeight > 0 ? gap + stepsHeight : 0) <= room
        let coreFit = withDetail <= room
        if !allFit && !last { return nil }
        var y = top
        if coreFit {
            if wordsHeight > 0 {
                fit.words = CGRect(x: geo.pad, y: y, width: width, height: wordsHeight)
                y += wordsHeight + gap
            }
            if hasDetail {
                fit.detail = CGRect(x: geo.pad, y: y, width: width, height: detailNatural)
                y += detailNatural + gap
            }
        } else if isAsk, hasDetail {
            y = cutAsk(&fit, geo: geo, top: top, room: room, wordsHeight: &wordsHeight)
        } else {
            y = cutWords(&fit, geo: geo, top: top, room: room, wordsHeight: wordsHeight, hasDetail: hasDetail)
        }
        guard coreFit else { return fit }
        fillBrief(&fit, tile: tile, geo: geo, top: y, bottom: bottom, font: stepFont, palette: palette)
        return fit
    }

    /// Fills what the line, the command and the heartbeat leave with the brief, as `WallBriefFill`
    /// chooses: the counts, the plan, the agent's last words, its steps and the files it changed,
    /// each as many lines as there is room for, in reading order.
    private func fillBrief(
        _ fit: inout Fit, tile: WallTile, geo: Geo, top: CGFloat, bottom: CGFloat, font: UIFont,
        palette: WallPalette
    ) {
        let width = geo.bodyWidth
        let gap = geo.gap
        let items = steps(of: tile)
        let planLines = tile.brief.plan.map { [$0.headline] + $0.lines } ?? []
        let fileLines = tile.brief.files.reversed().map(\.words)
        let saidFont = WatchFont.text(font.pointSize * 1.06)
        let filesFont = WatchFont.mono(font.pointSize * 0.94)
        factsLabel.set(tile.brief.facts ?? "", font: font, ink: palette.dim.color(), lines: 1)
        saidLabel.set(
            tile.brief.said.map { "\u{201C}" + $0 + "\u{201D}" } ?? "", font: saidFont,
            ink: palette.text.color(0.74), lines: 0)
        let line = ceil(font.lineHeight)
        let saidLine = ceil(saidFont.lineHeight)
        let filesLine = ceil(filesFont.lineHeight)
        let saidLines = saidLabel.text?.isEmpty == false
            ? max(1, Int((saidLabel.height(forWidth: width) / saidLine).rounded())) : 0
        let offers = [
            WallBriefFill.Offer(part: .facts, lineHeight: line, lines: tile.brief.facts == nil ? 0 : 1),
            WallBriefFill.Offer(part: .plan, lineHeight: line, lines: min(WatchTileView.planLines, planLines.count)),
            WallBriefFill.Offer(part: .said, lineHeight: saidLine, lines: min(5, saidLines)),
            WallBriefFill.Offer(part: .steps, lineHeight: line + 3, lines: items.count),
            WallBriefFill.Offer(part: .files, lineHeight: filesLine, lines: min(WatchTileView.fileLines, fileLines.count)),
        ]
        let granted = WallBriefFill.choose(offers, room: Double(bottom - top), gap: Double(gap))
        var y = top
        if granted[.facts] != nil {
            fit.facts = CGRect(x: geo.pad, y: y, width: width, height: line)
            y += line + gap
        }
        if let count = granted[.plan] {
            for (index, words) in planLines.prefix(count).enumerated() {
                planLabels[index].set(
                    words, font: index == 0 ? WatchFont.text(font.pointSize, .semibold) : font,
                    ink: palette.text.color(index == 0 ? 0.9 : 0.78), lines: 1)
                fit.plan[index] = CGRect(x: geo.pad, y: y, width: width, height: line)
                y += line
            }
            y += gap
        }
        if let count = granted[.said] {
            saidLabel.numberOfLines = count
            fit.said = CGRect(x: geo.pad, y: y, width: width, height: CGFloat(count) * saidLine)
            y += CGFloat(count) * saidLine + gap
        }
        if let count = granted[.steps] {
            for (index, step) in items.prefix(count).enumerated() {
                stepLabels[index].set(
                    "\(step.mark) \(step.words)", font: font,
                    ink: palette.dim.color(max(0.35, 0.95 - 0.1 * CGFloat(index))), lines: 1)
                fit.steps[index] = CGRect(x: geo.pad, y: y, width: width, height: line)
                y += line + 3
            }
            y += gap - 3
        }
        if let count = granted[.files] {
            for (index, words) in fileLines.prefix(count).enumerated() {
                fileLabels[index].set(words, font: filesFont, ink: palette.dim.color(), lines: 1)
                fit.files[index] = CGRect(x: geo.pad, y: y, width: width, height: filesLine)
                y += filesLine
            }
        }
    }

    /// The smallest level of an ask that still does not fit: the command is what a person decides on,
    /// so it keeps its lines and the lead gives way, one line first and then none; the rest of the
    /// command is in the peek, and the tile says so.
    private func cutAsk(
        _ fit: inout Fit, geo: Geo, top: CGFloat, room: CGFloat, wordsHeight: inout CGFloat
    ) -> CGFloat {
        let width = geo.bodyWidth
        let gap = geo.gap
        let line = ceil(detail.font.lineHeight)
        let moreHeight = ceil(more.font.lineHeight)
        var shownWords = wordsHeight > 0
        words.numberOfLines = 1
        wordsHeight = shownWords ? min(wordsHeight, ceil(words.font.lineHeight)) : 0
        var left = room - (shownWords ? wordsHeight + gap : 0)
        var fits = Int(((left - moreHeight - 2) / line).rounded(.down))
        if fits < 1, shownWords {
            shownWords = false
            wordsHeight = 0
            left = room
            fits = Int(((left - moreHeight - 2) / line).rounded(.down))
        }
        var y = top
        if shownWords {
            fit.words = CGRect(x: geo.pad, y: y, width: width, height: wordsHeight)
            y += wordsHeight + gap
        }
        let showsMore = fits >= 1
        let lines = max(1, showsMore ? fits : Int((left / line).rounded(.down)))
        detail.lineBreakMode = .byTruncatingTail
        detail.numberOfLines = lines
        fit.detail = CGRect(x: geo.pad, y: y, width: width, height: CGFloat(lines) * line)
        y += CGFloat(lines) * line + 2
        if showsMore {
            fit.more = CGRect(x: geo.pad, y: y, width: width, height: moreHeight)
            y += moreHeight + gap
        }
        return y
    }

    private func cutWords(
        _ fit: inout Fit, geo: Geo, top: CGFloat, room: CGFloat, wordsHeight: CGFloat, hasDetail: Bool
    ) -> CGFloat {
        let width = geo.bodyWidth
        let gap = geo.gap
        var y = top
        var shown = wordsHeight
        if shown > 0 {
            let allowed = max(1, min(3, Int((room * 0.5 / words.lineHeight).rounded(.down))))
            words.numberOfLines = allowed
            shown = min(shown, words.height(forWidth: width))
            fit.words = CGRect(x: geo.pad, y: y, width: width, height: shown)
            y += shown + gap
        }
        guard hasDetail else { return y }
        let line = ceil(detail.font.lineHeight)
        let fits = Int(((top + room - y) / line).rounded(.down))
        guard fits >= 1 else { return y }
        detail.numberOfLines = fits
        fit.detail = CGRect(x: geo.pad, y: y, width: width, height: CGFloat(fits) * line)
        return y + CGFloat(fits) * line + gap
    }

    private func placePills(
        _ fit: inout Fit, ask: AgentAsk, style: WallStyle, palette: WallPalette, action: WatchAction?,
        geo: Geo, y: CGFloat, height: CGFloat, size: CGFloat
    ) {
        let opens = !ask.isApproval || style.approvals == .openChat
        if opens {
            chatPill.apply(String(localized: "Open chat"), size: size, ink: palette.needs, style: .hold)
            let width = min(geo.bodyWidth, chatPill.naturalWidth() + 8)
            fit.chat = CGRect(x: geo.pad, y: y, width: width, height: height)
            return
        }
        var holdWords = String(localized: "Hold to approve")
        var dim: CGFloat = 1
        switch action {
        case .busy(.approve)?: holdWords = String(localized: "Approving…")
        case .done(.approve)?: holdWords = String(localized: "Approved")
        case .busy(.deny)?, .done(.deny)?: dim = 0.5
        default: break
        }
        var fontSize = size
        var padding: CGFloat = 36
        var holdWidth: CGFloat = 0
        var denyWidth: CGFloat = 0
        let gap: CGFloat = 10
        let hold = String(localized: "Hold to approve")
        while true {
            holdPill.apply(holdWords, size: fontSize, ink: palette.needs, style: .hold, alpha: dim)
            denyPill.apply(String(localized: "Deny"), size: fontSize, ink: palette.dim.lifted(0.2), style: .quiet, alpha: dim)
            let longest = max(holdPill.label.widthForOneLine(), holdPill.label.widthFor(hold))
            holdWidth = longest + padding
            denyWidth = denyPill.label.widthForOneLine() + padding
            if holdWidth + gap + denyWidth <= geo.bodyWidth || (fontSize <= 11 && padding <= 18) { break }
            if padding > 18 {
                padding = 18
            } else {
                fontSize = max(11, fontSize * 0.92)
            }
        }
        holdWidth = min(holdWidth, max(60, geo.bodyWidth - denyWidth - gap))
        fit.hold = CGRect(x: geo.pad, y: y, width: holdWidth, height: height)
        fit.deny = CGRect(
            x: geo.pad + holdWidth + gap, y: y, width: min(denyWidth, geo.bodyWidth - holdWidth - gap),
            height: height)
    }

    private func place(_ fit: Fit) {
        title.frame = fit.title.rounded()
        status.frame = fit.status.rounded()
        show(meta, fit.meta)
        show(words, fit.words)
        show(detail, fit.detail)
        show(more, fit.more)
        for (index, label) in stepLabels.enumerated() { show(label, fit.steps[index]) }
        show(factsLabel, fit.facts)
        for (index, label) in planLabels.enumerated() { show(label, fit.plan[index]) }
        show(saidLabel, fit.said)
        for (index, label) in fileLabels.enumerated() { show(label, fit.files[index]) }
        show(contextLabel, fit.context)
        show(holdPill, fit.hold)
        show(denyPill, fit.deny)
        show(chatPill, fit.chat)
    }

    private func show(_ view: UIView, _ rect: CGRect?) {
        guard let rect, rect.width > 0, rect.height > 0 else {
            view.isHidden = true
            return
        }
        view.isHidden = false
        view.frame = rect.rounded()
    }
}
