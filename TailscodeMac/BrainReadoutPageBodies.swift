import AppKit
import CodingAgentKit
import TailscodeCore

extension AccountReadoutPage {
    typealias R = NeuralReadout

    private var host: BrainSurfaceHost? { owner.host }

    private func section(_ label: String? = nil, right: String? = nil, tone: NSColor? = nil) -> AccountStack {
        let stack = AccountStack()
        if let label {
            let row = AccountLabelRow(label, paint: paint, tone: tone)
            row.rightWords = right
            stack.add(row)
        }
        return stack
    }

    private func tally(added: Int, removed: Int) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: "+\(added)", attributes: AccountType.attributes(.rowMeta, paint.accent))
        result.append(
            NSAttributedString(string: " \u{2212}\(removed)", attributes: AccountType.attributes(.rowMeta, paint.danger)))
        return result
    }

    private func button(_ title: String, style: AccountButton.Style, _ tap: @escaping () -> Void) -> AccountButton {
        let made = AccountButton(title: title, style: style, paint: paint)
        made.host = host
        made.onTap = tap
        return made
    }

    private func buttonRow(_ buttons: [AccountButton]) -> AccountButtonFlow {
        let row = AccountButtonFlow()
        row.set(buttons)
        return row
    }


    func buildStep(_ step: AccountStepParts) {
        copyText = step.subject.copyText
        flow.add(subjectSection(step), before: 8)
        if let detail = fixedSentence(step) { flow.add(detail, before: 8) }
        if !step.relations.isEmpty {
            let relations = section(AccountWords.relations)
            relations.add(relationRow(step.relations), before: 6)
            flow.add(relations, before: 16)
        }
        if let why = step.why { flow.add(whySection(why), before: 16) }
        if let result = step.result { flow.add(resultSection(result, step: step), before: 16) }
    }

    private func subjectSection(_ step: AccountStepParts) -> AccountStack {
        let subject = step.subject
        let stack = AccountStack()
        var action: AccountButton?
        if case .subagent(let agent)? = step.result, agent.canOpen {
            let id = step.stepID
            action = button(agent.openLabel, style: .pill) { [weak owner] in owner?.openSubagent(id) }
        } else if let copy = subject.copyText {
            let made = button(NeuralReading.copyLabel, style: .pill) { [weak self] in
                self?.copySubject(copy)
            }
            copyButton = made
            action = made
        }
        stack.add(AccountTitleRow(title: subject.title, button: action, paint: paint))
        switch subject.kind {
        case .command:
            stack.add(commandView(subject), before: 4)
        case .path:
            let combined = NSMutableAttributedString(
                string: subject.directory ?? "", attributes: AccountType.attributes(.toolDetail, paint.dim))
            var bold = AccountType.attributes(.toolDetail, paint.text)
            bold[.font] = NSFont.monospacedSystemFont(ofSize: AccountType.font(.toolDetail).pointSize, weight: .bold)
            combined.append(NSAttributedString(string: subject.fileName ?? subject.primary, attributes: bold))
            stack.add(textBlock(combined), before: 4)
        case .pattern:
            stack.add(textBlock(AccountType.string(subject.primary, .toolDetail, paint.text)), before: 4)
            if let scope = subject.secondary, !scope.isEmpty {
                let line = NSMutableAttributedString(
                    string: Localized.text("in") + " ", attributes: AccountType.attributes(.toolDetail, paint.dim))
                line.append(NSAttributedString(string: scope, attributes: AccountType.attributes(.toolDetail, paint.text)))
                stack.add(textBlock(line), before: 2)
            }
        case .url, .other:
            stack.add(textBlock(AccountType.string(subject.primary, .toolDetail, paint.text)), before: 4)
        case .agent:
            stack.add(textBlock(AccountType.string(subject.primary, .cardBody, paint.text)), before: 4)
            if let kind = subject.secondary, !kind.isEmpty {
                stack.add(textBlock(AccountType.string(kind, .rowStamp, paint.dim)), before: 2)
            }
        case .thought, .note:
            stack.add(textBlock(AccountType.string(subject.primary, .thought, paint.text)), before: 4)
        }
        return stack
    }

    private func textBlock(_ text: NSAttributedString, maxLines: Int = 0) -> AccountTextBlock {
        let block = AccountTextBlock(text: text, host: host, paint: paint)
        block.maxLines = maxLines
        return block
    }

    /// A shell command wrapped, never cut: its first four lines, and the rest behind Show all.
    private func commandView(_ subject: R.Subject) -> AccountClampBlock {
        let prompt = NSMutableAttributedString(
            string: "$ ", attributes: AccountType.attributes(.toolDetail, paint.zone(.shell)))
        prompt.append(NSAttributedString(string: subject.primary, attributes: AccountType.attributes(.toolDetail, paint.text)))
        return AccountClampBlock(
            text: textBlock(prompt), limit: subject.collapsedLines, linkTitle: NeuralReading.showAllLabel,
            host: host, paint: paint)
    }

    /// "It failed here ('...') and passed at step 12.": what a fixed step did, with the passing
    /// step a link.
    private func fixedSentence(_ step: AccountStepParts) -> AccountBlock? {
        let chip = step.header.chip
        guard chip.kind == .fixed || chip.kind == .retried, let detail = chip.detail else { return nil }
        let text = NSMutableAttributedString(string: detail, attributes: AccountType.attributes(.rowTitle, paint.text))
        if let fixedBy = chip.fixedBy, let number = owner.model.verdict(ofStep: step.stepID)?.fixedByNumber,
            let range = detail.range(of: String(number), options: .backwards)
        {
            let nsRange = NSRange(range, in: detail)
            var start = nsRange.location
            let head = detail[detail.startIndex..<range.lowerBound]
            if head.hasSuffix(" "), let space = head.dropLast().lastIndex(of: " ") {
                start = NSRange(detail.index(after: space)..<range.lowerBound, in: detail).location
            }
            let span = NSRange(location: start, length: nsRange.location + nsRange.length - start)
            text.addAttributes(
                [.link: "step:" + fixedBy, .font: NSFont.systemFont(ofSize: AccountType.font(.rowTitle).pointSize, weight: .semibold)],
                range: span)
        }
        let body = textBlock(text)
        body.view.onLink = { [weak owner] link in
            guard link.hasPrefix("step:") else { return }
            owner?.choose(String(link.dropFirst(5)), fromAccount: false)
        }
        return AccountNoteBlock(text: body, glyph: .fixed, paint: paint)
    }

    private func relationRow(_ relations: [R.Relation]) -> AccountButtonFlow {
        let buttons = relations.map { relation -> AccountButton in
            let numbers = relation.numbers.map(String.init).joined(separator: ", ")
            let label = relation.label.replacingOccurrences(of: numbers, with: "")
                .trimmingCharacters(in: .whitespaces)
            let made = AccountButton(title: label, style: .relation(retry: relation.kind == .retriedAt), paint: paint)
            made.emphasis = numbers
            made.host = host
            let ids = relation.stepIDs
            made.onTap = { [weak owner] in
                if let first = ids.first { owner?.choose(first, fromAccount: false) }
            }
            made.onHover = { [weak owner] entered in owner?.relationHover(entered ? ids : nil) }
            made.setAccessibilityLabel(relation.label)
            return made
        }
        return buttonRow(buttons)
    }

    private func whySection(_ why: R.Why) -> AccountStack {
        let stack = AccountStack()
        stack.add(
            AccountQuoteBlock(
                label: why.label, tone: zoneTone, words: why.text, full: why.isTruncated ? why.full : nil,
                host: host, paint: paint))
        return stack
    }

    private func lines(_ lines: [R.OutputLine]) -> [AccountOutputBlock.Line] {
        lines.map { AccountOutputBlock.Line(text: $0.text, tone: $0.tone) }
    }

    private func resultSection(_ result: R.Result, step: AccountStepParts) -> AccountStack {
        let stack = AccountStack()
        let failed = step.header.chip.kind == .failed
        let id = step.stepID
        switch result {
        case .shell(let output):
            let label = AccountLabelRow(AccountWords.output, paint: paint)
            label.rightWords = AccountWords.lines(output.total)
            stack.add(label)
            let block = AccountOutputBlock(
                lines: lines(output.lines), hidden: output.hiddenCount, moreLabel: output.moreLabel,
                failed: failed,
                allLines: { [weak owner] in
                    guard let held = owner?.model.step(id: id) else { return [] }
                    return NeuralReadout.fullOutput(of: held).map {
                        AccountOutputBlock.Line(text: $0.text, tone: $0.tone)
                    }
                }, host: host, paint: paint)
            outputs.append(block)
            stack.add(block, before: 6)
        case .edit(let edit):
            let label = AccountLabelRow(AccountWords.diff, paint: paint)
            label.right = tally(added: edit.added, removed: edit.removed)
            stack.add(label)
            stack.add(diffBlock(edit, stepID: id), before: 6)
        case .read(let read):
            let label = AccountLabelRow(AccountWords.readLabel, paint: paint)
            label.rightWords = read.lines.map { AccountWords.lines($0) }
            stack.add(label)
        case .search(let search):
            let label = AccountLabelRow(AccountWords.matches, paint: paint)
            label.rightWords = String(search.total)
            stack.add(label)
            let block = AccountOutputBlock(
                lines: search.matches.map { AccountOutputBlock.Line(text: $0, tone: .dim) },
                hidden: 0, moreLabel: nil, failed: false, allLines: nil, host: host, paint: paint)
            stack.add(block, before: 6)
        case .subagent(let agent):
            stack.add(AccountLabelRow(Localized.text("RESULT"), paint: paint))
            let block = AccountOutputBlock(
                lines: agent.summary.map { AccountOutputBlock.Line(text: $0, tone: .dim) }, hidden: 0,
                moreLabel: nil, failed: false, allLines: nil, host: host, paint: paint)
            stack.add(block, before: 6)
        case .text(let text):
            if step.subject.kind != .thought, step.subject.kind != .note {
                stack.add(textBlock(AccountType.string(text.text, .thought, paint.text)))
            } else {
                stack.isHidden = true
            }
        }
        return stack
    }

    /// The first lines of an edit with the way to read the rest: the whole of it comes from the
    /// model's step when the link is pressed, never before, so a step nobody opened costs nothing.
    private func diffBlock(_ edit: R.Edit, stepID id: String) -> AccountDiffBlock {
        let block = AccountDiffBlock(
            edit: edit,
            full: { [weak owner] in owner?.model.step(id: id).map { R.fullDiff(of: $0) } },
            copyText: { [weak owner] in
                owner?.model.step(id: id).map { NeuralReading.pasteText(of: R.fullDiff(of: $0)) }
            }, host: host, paint: paint)
        block.readerHeight = { [weak self] in self?.readerHeight() ?? 300 }
        block.onToggle = { [weak self, weak block] expanded in
            guard let self, let block else { return }
            self.diffToggled(block, expanded: expanded, stepID: id)
        }
        diffs.append(block)
        if expandedDiffStep == id { block.setExpanded(true) }
        return block
    }

    func copySubject(_ text: String) {
        host?.copyToPasteboard(text)
        guard let copyButton else { return }
        copyButton.title = AccountWords.copied
        flowChanged()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak copyButton] in
            copyButton?.title = NeuralReading.copyLabel
        }
    }


    func buildNow(_ now: R.Now) {
        if let step = now.step {
            buildStep(
                AccountStepParts(
                    stepID: step.stepID, header: step.header, subject: step.subject, relations: [],
                    why: step.why, result: nil, facts: step.facts))
        }
        if !now.tail.lines.isEmpty {
            let box = AccountStack()
            let label = AccountLabelRow(AccountWords.output, paint: paint)
            label.rightWords = AccountWords.lastLines(now.tail.lines.count)
            box.add(label)
            let block = AccountOutputBlock(
                lines: lines(now.tail.lines), hidden: 0, moreLabel: nil, failed: false, caret: true,
                allLines: nil, host: host, paint: paint)
            nowTail = block
            box.add(block, before: 6)
            flow.add(box, before: 16)
        }
        flow.add(soFar(headline: now.soFar.headline, chips: now.soFar.chips), before: 16)
    }

    func buildAsk(_ ask: R.Ask) {
        let step = ask.step
        let card = AccountStack()
        card.add(textBlock(AccountType.string(ask.sentence, .cardTitle, paint.text)))
        let subject = step.subject
        if !subject.primary.isEmpty {
            let text = NSMutableAttributedString()
            if subject.kind == .command {
                text.append(NSAttributedString(string: "$ ", attributes: AccountType.attributes(.toolDetail, paint.warn)))
            }
            text.append(NSAttributedString(string: subject.primary, attributes: AccountType.attributes(.toolDetail, paint.text)))
            card.add(textBlock(text), before: 8)
        }
        if let why = step.why { card.add(textBlock(AccountType.string(why.text, .thought, paint.text)), before: 8) }
        let go = button(ask.actionLabel + " \u{2193}", style: .filled) { [weak owner] in owner?.goToApproval() }
        go.tone = paint.warn
        let row = buttonRow([go])
        card.add(row, before: 12)
        flow.add(card, before: 8)
        if let clock = step.facts.clock {
            let note = section(AccountWords.waitingSince(clock).uppercased())
            flow.add(note, before: 16)
        }
        let model = owner.model
        let brain = model.brainCard(now: Date())
        flow.add(soFar(headline: NeuralReading.headline(for: model.turn), chips: brain.chips), before: 16)
    }

    private func soFar(headline: String, chips: [NeuralBrainCard.ZoneChip]) -> AccountStack {
        let outer = AccountStack()
        outer.add(AccountLabelRow(AccountWords.soFar, paint: paint))
        outer.add(textBlock(AccountType.string(headline, .rowTitleStrong, paint.text)), before: 8)
        if !chips.isEmpty { outer.add(AccountZoneChips(chips: chips, paint: paint), before: 8) }
        return outer
    }


    func buildDigest(_ digest: R.Digest) {
        let model = owner.model
        let card = model.brainCard(now: Date())
        let sentence = card.digest.isEmpty ? digest.headline : card.digest
        let headline = NSMutableAttributedString(string: sentence, attributes: AccountType.attributes(.headline, paint.text))
        if let clause = card.headline.piece(.failure)?.text {
            let word = clause.prefix(1).uppercased() + clause.dropFirst() + "."
            headline.append(NSAttributedString(string: " " + word, attributes: AccountType.attributes(.headline, paint.warn)))
        }
        flow.add(textBlock(headline), before: 8)

        let bars = section(AccountWords.whereTheWorkWent, right: AccountWords.steps(digest.ticks.count))
        for bar in digest.zoneBars {
            let row = AccountZoneBarRow(bar: bar, paint: paint)
            let zone = bar.zone
            row.onPress = { [weak owner] in owner?.dive(into: zone) }
            bars.add(row, before: 6)
        }
        let strip = AccountTimelineBlock(digest: digest, paint: paint)
        strip.onHover = { [weak owner] id in owner?.hover(id) }
        strip.onPress = { [weak owner] id in owner?.choose(id, fromAccount: false) }
        strip.onScrub = { [weak owner] id in owner?.scrub(toStep: id) }
        strip.onScrubEnd = { [weak owner] in owner?.scrubEnded() }
        bars.add(strip, before: 8)
        flow.add(bars, before: 16)

        let limit = 6
        if !digest.failures.isEmpty {
            let box = section(digest.failuresTitle.uppercased(), right: String(digest.failures.count))
            for failure in digest.failures.prefix(limit) {
                let row = AccountFailureRow(failure: failure, paint: paint)
                let id = failure.stepID
                row.onPress = { [weak owner] in owner?.choose(id, fromAccount: false) }
                box.add(row, before: 6)
            }
            if digest.failures.count > limit {
                let count = digest.failures.count - limit
                let more = button(AccountWords.moreFailures(count), style: .link) { [weak owner] in
                    owner?.host?.browse(.failedToggle, grabFocus: false)
                }
                box.add(buttonRow([more]), before: 6)
            }
            flow.add(box, before: 16)
        }
        if !digest.changed.isEmpty {
            let box = AccountStack()
            let label = AccountLabelRow(AccountWords.changed, paint: paint)
            let added = model.steps.reduce(0) { $0 + ($1.added ?? 0) }
            let removed = model.steps.reduce(0) { $0 + ($1.removed ?? 0) }
            label.right = tally(added: added, removed: removed)
            box.add(label)
            for change in digest.changed.prefix(limit) {
                let row = AccountChangedRow(
                    shortDirectory: change.shortDirectory, fileName: change.fileName, added: change.added,
                    removed: change.removed, paint: paint)
                let id = change.stepID
                row.onPress = { [weak owner] in owner?.choose(id, fromAccount: false) }
                box.add(row, before: 6)
            }
            if digest.changed.count > limit {
                box.add(
                    textBlock(AccountType.string(AccountWords.moreFiles(digest.changed.count - limit), .rowStamp, paint.dim)),
                    before: 6)
            }
            flow.add(box, before: 16)
        }
        if let answer = digest.answer, !answer.isEmpty {
            let box = section(AccountWords.answer)
            box.add(textBlock(AccountType.string(answer, .cardBody, paint.text)), before: 6)
            flow.add(box, before: 16)
        }
    }


    private func listRow(_ row: R.ZoneRow, selected: Bool) -> AccountListRow {
        let verdict = owner.model.verdict(ofStep: row.stepID)?.verdict
        let ink: NSColor = verdict == .failed ? paint.danger : (verdict == .fixed ? paint.warn : paint.text)
        let content = AccountListRow.Content(
            number: String(row.number), title: row.title, detail: row.argument,
            titleInk: ink, numberInk: verdict == .failed || verdict == .fixed ? ink : paint.dim,
            dot: paint.tone(row.tone), selected: selected, titleWidth: 64)
        let made = AccountListRow(content: content, paint: paint)
        let id = row.stepID
        made.onPress = { [weak owner] in owner?.choose(id, fromAccount: false) }
        return made
    }

    func buildZone(_ list: R.ZoneList) {
        let box = section(AccountWords.zoneSteps(list.label))
        let pinned = owner.model.pinnedStep
        for row in list.rows { box.add(listRow(row, selected: row.stepID == pinned), before: 0) }
        flow.add(box, before: 8)
    }

    func buildReplay(_ replay: R.Replay) {
        let hasCurrent = replay.current != nil
        if let current = replay.current { buildStep(AccountStepParts(current)) }
        if !replay.log.isEmpty {
            let box = section(AccountWords.earlier)
            for row in replay.log { box.add(listRow(row, selected: false), before: 0) }
            if replay.hiddenBefore > 0 {
                box.add(
                    textBlock(AccountType.string(AccountWords.earlier(replay.hiddenBefore), .rowStamp, paint.dim)),
                    before: 6)
            }
            flow.add(box, before: hasCurrent ? 16 : 8)
        }
    }
}
