import AppKit
import TailscodeCore

extension WatchTileWordsView {
    /// The frames for one level of type, or nil when the words do not fit it. The last level never
    /// refuses: it cuts what may be cut (the words, the steps) and says so when a command has to be
    /// read in the peek, and it leaves nothing promised whole behind.
    func plan(_ index: Int, truncating last: Bool) -> Plan? {
        guard let tile else { return nil }
        let level = Self.levels[index]
        let type = face.type
        let palette = face.palette
        let unit = type.unit
        let size = bounds.size
        let metrics = WallTileMetrics.tile(
            WallRect(x: 0, y: 0, width: Double(size.width), height: Double(size.height)), unit: unit)
        let pad = CGFloat(metrics.padding)
        let innerWidth = size.width - 2 * pad
        let gap = CGFloat(max(0.7 * unit, 5))
        var plan = Plan()

        let head = headFrames(tile, level: level, metrics: metrics, size: size)
        plan.title = head.title
        plan.status = head.status
        var top = head.bottom + gap
        var bottom = size.height - pad

        let contextFont = type.prose(1.4, weight: .medium)
        let contextHeight = WatchText.lineHeight(contextFont) + 2
        let hasBeat = tile.beat?.isEmpty == false
        let share = tile.contextShare
        let strip = hasBeat ? CGFloat(metrics.beat.height) : (share == nil ? 0 : contextHeight)
        if strip > 0 {
            let stripY = bottom - strip
            if let share {
                contextLabel.show(
                    "\(Int((share * 100).rounded()))%", font: contextFont, ink: palette.dim.watchColor(),
                    align: .right)
                let x = hasBeat ? CGFloat(metrics.beat.maxX) + gap : pad
                plan.context = CGRect(
                    x: x, y: stripY + (strip - contextHeight) / 2, width: max(0, size.width - pad - x),
                    height: contextHeight)
            }
            bottom = stripY - gap
        }

        if answers != .none {
            guard let row = answerFrames(level: level, bottom: bottom, innerWidth: innerWidth, pad: pad, gap: gap, last: last)
            else { return nil }
            plan.deny = row.deny
            plan.approve = row.approve
            plan.chat = row.chat
            bottom = row.top - gap
        }

        let failure = failureHint()
        let hintFont = type.prose(1.5)
        if failure != nil {
            hintLabel.configure(wrap: .words, lines: 2)
            hintLabel.show(failure ?? "", font: hintFont, ink: palette.failed.lifted(0.2).watchColor())
            let height = hintLabel.height(forWidth: innerWidth)
            plan.hint = CGRect(x: pad, y: bottom - height, width: innerWidth, height: height)
            bottom -= height + gap
        }

        let wordsFont = type.prose(level.words, weight: .medium)
        wordsLabel.configure(wrap: .words, lines: level.wordLines)
        wordsLabel.show(tile.words, font: wordsFont, ink: palette.text.watchColor())
        if !tile.words.isEmpty {
            var height = wordsLabel.height(forWidth: innerWidth)
            if top + height > bottom + 1 {
                guard last else { return nil }
                let lines = max(1, Int((bottom - top - 2) / WatchText.lineHeight(wordsFont)))
                wordsLabel.configure(wrap: .words, lines: lines)
                height = wordsLabel.height(forWidth: innerWidth)
            }
            plan.words = CGRect(x: pad, y: top, width: innerWidth, height: height)
            top += height + gap
        }

        guard placeDetail(&plan, tile: tile, level: level, top: &top, bottom: bottom, width: innerWidth, pad: pad, gap: gap, last: last)
        else { return nil }
        placeSteps(&plan, tile: tile, level: level, top: top, bottom: bottom, width: innerWidth, pad: pad)
        return plan
    }

    private func headFrames(
        _ tile: WallTile, level: Level, metrics: WallTileMetrics, size: CGSize
    ) -> (title: CGRect, status: CGRect, bottom: CGFloat) {
        let type = face.type
        let titleFont = type.prose(level.title, weight: .semibold)
        let statusFont = type.prose(level.status, weight: .semibold)
        titleLabel.show(tile.title, font: titleFont, ink: face.palette.text.watchColor())
        let titleHeight = WatchText.lineHeight(titleFont) + 2
        let statusHeight = WatchText.lineHeight(statusFont) + 2
        let glyphTop = CGFloat(metrics.glyphY - metrics.glyphSize / 2)
        let glyphSize = CGFloat(metrics.glyphSize)
        let stack = titleHeight + statusHeight
        let stackTop = glyphTop + max(0, (glyphSize - stack) / 2)
        let columnX = CGFloat(metrics.textLeading)
        let columnWidth = max(8, size.width - columnX - CGFloat(metrics.padding))
        return (
            CGRect(x: columnX, y: stackTop, width: columnWidth, height: titleHeight),
            CGRect(x: columnX, y: stackTop + titleHeight, width: columnWidth, height: statusHeight),
            max(glyphTop + glyphSize, stackTop + stack)
        )
    }

    private func failureHint() -> String? {
        guard answers != .none, case .failed(let why) = phase else { return nil }
        return Localized.text("Could not send it: %@", why)
    }

    private func answerWidth(_ words: [String], font: NSFont, unit: Double) -> CGFloat {
        (words.map { WatchText.width($0, font: font) }.max() ?? 0) + 2 * CGFloat(max(1.4 * unit, 12))
    }

    private func answerFrames(
        level: Level, bottom: CGFloat, innerWidth: CGFloat, pad: CGFloat, gap: CGFloat, last: Bool
    ) -> (deny: CGRect?, approve: CGRect?, chat: CGRect?, top: CGFloat)? {
        let unit = face.type.unit
        let font = face.type.prose(level.button, weight: .semibold)
        let height = min(max(CGFloat(2.9 * unit), 28), 46)
        let y = bottom - height
        switch answers {
        case .holdAndDeny:
            var denyWidth = answerWidth(Self.denyWords, font: font, unit: unit)
            var approveWidth = answerWidth(Self.approveWords, font: font, unit: unit)
            let total = denyWidth + gap + approveWidth
            if total > innerWidth {
                guard last else { return nil }
                let scale = max(0.4, (innerWidth - gap) / (denyWidth + approveWidth))
                denyWidth *= scale
                approveWidth *= scale
            }
            return (
                CGRect(x: pad, y: y, width: denyWidth, height: height),
                CGRect(x: pad + denyWidth + gap, y: y, width: approveWidth, height: height), nil, y
            )
        case .openChat:
            let width = min(innerWidth, answerWidth([Localized.text("Open chat")], font: font, unit: unit))
            return (nil, nil, CGRect(x: pad, y: y, width: width, height: height), y)
        case .none:
            return (nil, nil, nil, bottom)
        }
    }

    static var denyWords: [String] {
        [Localized.text("Deny"), Localized.text("Denying…"), Localized.text("Denied")]
    }

    static var approveWords: [String] {
        [
            Localized.text("Approve"), Localized.text("Approving…"), Localized.text("Approved"),
            Localized.text("Keep holding…"), Localized.text("Hold to approve"),
        ]
    }

    private func placeDetail(
        _ plan: inout Plan, tile: WallTile, level: Level, top: inout CGFloat, bottom: CGFloat,
        width: CGFloat, pad: CGFloat, gap: CGFloat, last: Bool
    ) -> Bool {
        let type = face.type
        let asking = tile.state.isNeedsYou
        let isCommand = !asking || tile.ask?.isApproval ?? true
        let text = tile.detail == tile.words ? "" : (tile.detail ?? "")
        let font =
            isCommand
            ? type.mono(level.detail * (asking ? 1.2 : 1))
            : type.prose(level.detail * 1.2, weight: .medium)
        detailLabel.configure(wrap: isCommand ? .characters : .words, lines: 999)
        detailLabel.show(text, font: font, ink: face.palette.text.watchColor(alpha: asking ? 1 : 0.86))
        guard !text.isEmpty else { return top <= bottom + 1 || last }
        let lineHeight = WatchText.lineHeight(font)
        let lines = detailLabel.naturalLines(forWidth: width)
        let natural = CGFloat(lines) * lineHeight + 2
        let room = bottom - top
        if natural <= room {
            plan.detail = CGRect(x: pad, y: top, width: width, height: natural)
            plan.detailLines = lines
            top += natural + gap
            return true
        }
        guard last else { return false }
        let hintFont = type.prose(1.5)
        let hintHeight = WatchText.lineHeight(hintFont) + 2
        hintLabel.configure(wrap: .words, lines: 1)
        hintLabel.show(
            Localized.text("Click to read it all"), font: hintFont, ink: face.palette.dim.watchColor())
        plan.truncated = true
        let fits = Int((room - hintHeight - 2) / lineHeight)
        if fits >= 1 {
            let height = CGFloat(fits) * lineHeight + 2
            plan.detail = CGRect(x: pad, y: top, width: width, height: height)
            plan.detailLines = fits
            plan.hint = CGRect(x: pad, y: top + height, width: width, height: hintHeight)
        } else {
            plan.hint = CGRect(x: pad, y: max(top, bottom - hintHeight), width: width, height: hintHeight)
        }
        top = bottom
        return true
    }

    /// Fills what the line, the command and the heartbeat leave with the brief, as `WallBriefFill`
    /// chooses: the counts, the plan, the agent's last words, its steps and the files it changed,
    /// each as many lines as there is room for, in reading order.
    private func placeSteps(
        _ plan: inout Plan, tile: WallTile, level: Level, top: CGFloat, bottom: CGFloat, width: CGFloat,
        pad: CGFloat
    ) {
        guard level.steps > 0, !plan.truncated else { return }
        let type = face.type
        let palette = face.palette
        let font = type.prose(level.steps)
        let saidFont = type.prose(level.steps * 1.06)
        let filesFont = type.mono(level.steps * 0.94)
        let line = WatchText.lineHeight(font) + 2
        let saidLine = WatchText.lineHeight(saidFont)
        let filesLine = WatchText.lineHeight(filesFont)
        let gap = CGFloat(max(0.7 * type.unit, 5))
        let items = Self.stepLines(tile)
        let planLines = tile.brief.plan.map { [$0.headline] + $0.lines } ?? []
        let fileLines = tile.brief.files.reversed().map(\.words)
        factsLabel.show(tile.brief.facts ?? "", font: font, ink: palette.dim.watchColor())
        saidLabel.configure(wrap: .words, lines: 999)
        saidLabel.show(
            tile.brief.said.map { "\u{201C}" + $0 + "\u{201D}" } ?? "", font: saidFont,
            ink: palette.text.watchColor(alpha: 0.74))
        let saidLines = saidLabel.text.isEmpty ? 0 : saidLabel.naturalLines(forWidth: width)
        let offers = [
            WallBriefFill.Offer(part: .facts, lineHeight: Double(line), lines: tile.brief.facts == nil ? 0 : 1),
            WallBriefFill.Offer(part: .plan, lineHeight: Double(line), lines: min(planLabels.count, planLines.count)),
            WallBriefFill.Offer(part: .said, lineHeight: Double(saidLine), lines: min(5, saidLines)),
            WallBriefFill.Offer(part: .steps, lineHeight: Double(line), lines: items.count),
            WallBriefFill.Offer(part: .files, lineHeight: Double(filesLine + 2), lines: min(fileLabels.count, fileLines.count)),
        ]
        let granted = WallBriefFill.choose(offers, room: Double(bottom - top), gap: Double(gap))
        var y = top
        if granted[.facts] != nil {
            plan.facts = CGRect(x: pad, y: y, width: width, height: line)
            y += line + gap
        }
        if let count = granted[.plan] {
            for (index, words) in planLines.prefix(count).enumerated() {
                planLabels[index].show(
                    words, font: index == 0 ? type.prose(level.steps, weight: .semibold) : font,
                    ink: palette.text.watchColor(alpha: index == 0 ? 0.9 : 0.78))
                plan.plan.append(CGRect(x: pad, y: y, width: width, height: line))
                y += line
            }
            y += gap
        }
        if let count = granted[.said] {
            saidLabel.configure(wrap: .words, lines: count)
            plan.said = CGRect(x: pad, y: y, width: width, height: CGFloat(count) * saidLine + 2)
            y += CGFloat(count) * saidLine + 2 + gap
        }
        if let count = granted[.steps] {
            for (index, step) in items.prefix(count).enumerated() where index < stepLabels.count {
                let ink = palette.dim.watchColor(alpha: max(0.4, 1 - 0.11 * Double(index)))
                stepLabels[index].show(step.mark + "  " + step.words, font: font, ink: ink)
                plan.steps.append(CGRect(x: pad, y: y, width: width, height: line))
                y += line
            }
            y += gap
        }
        if let count = granted[.files] {
            for (index, words) in fileLines.prefix(count).enumerated() {
                fileLabels[index].show(words, font: filesFont, ink: palette.dim.watchColor())
                plan.files.append(CGRect(x: pad, y: y, width: width, height: filesLine + 2))
                y += filesLine + 2
            }
        }
    }

    func place(_ plan: Plan) {
        titleLabel.frame = plan.title.integral
        statusLabel.frame = plan.status.integral
        wordsLabel.frame = plan.words.integral
        wordsLabel.isHidden = plan.words.isEmpty || (tile?.words.isEmpty ?? true)
        detailLabel.isHidden = plan.detail == nil
        if let detail = plan.detail {
            detailLabel.frame = detail.integral
            detailLabel.configure(
                wrap: detailLabel.wrap, lines: max(1, plan.detailLines))
        }
        for (index, label) in stepLabels.enumerated() {
            label.isHidden = index >= plan.steps.count
            if index < plan.steps.count { label.frame = plan.steps[index].integral }
        }
        for (label, frame) in [(factsLabel, plan.facts), (saidLabel, plan.said)] {
            label.isHidden = frame == nil
            if let frame { label.frame = frame.integral }
        }
        for (labels, frames) in [(planLabels, plan.plan), (fileLabels, plan.files)] {
            for (index, label) in labels.enumerated() {
                label.isHidden = index >= frames.count
                if index < frames.count { label.frame = frames[index].integral }
            }
        }
        contextLabel.isHidden = plan.context == nil
        if let context = plan.context { contextLabel.frame = context.integral }
        hintLabel.isHidden = plan.hint == nil
        if let hint = plan.hint { hintLabel.frame = hint.integral }
        isTruncated = plan.truncated
        for (button, frame) in [(deny, plan.deny), (approve, plan.approve), (chat, plan.chat)] {
            button.isHidden = frame == nil
            if let frame { button.frame = frame.integral }
        }
        refreshAsk()
    }
}
