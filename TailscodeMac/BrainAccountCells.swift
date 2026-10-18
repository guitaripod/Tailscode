import AppKit
import CodingAgentKit
import TailscodeCore

/// One item of the account as it exists while it is near the viewport: its view, what it was made
/// for (so a change of that is a rebuild and anything else is not), and the parts a press and the
/// pointer reach.
@MainActor
class AccountCell: NSView {
    let entryID: String
    let key: String
    unowned let owner: BrainAccountView
    var stale = false
    var measuredHeight: CGFloat = 0
    /// The step a press anywhere in the item sets the cursor to.
    var pressStepID: String?
    /// The step the pointer previews while it is over the item.
    var hoverStepID: String?
    private var tracking: NSTrackingArea?
    private(set) var hovered = false

    init(entryID: String, key: String, owner: BrainAccountView) {
        self.entryID = entryID
        self.key = key
        self.owner = owner
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    var paint: AccountPaint { owner.paint }
    var host: BrainSurfaceHost? { owner.host }
    var drawnWords: [String] { [] }

    /// Lays the item out for `width` and answers with the height it needs.
    func fit(width: CGFloat) -> CGFloat { measuredHeight }

    /// The part of the document the reader can see, in document coordinates.
    func visibleChanged(_ rect: CGRect) {}

    func teardown() {}

    func hoverChanged(_ hovered: Bool) {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        guard hoverStepID != nil else { return }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self,
            userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        hoverChanged(true)
        if let id = hoverStepID { owner.hover(id) }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        hoverChanged(false)
        if hoverStepID != nil { owner.hover(nil) }
    }

    override func mouseDown(with event: NSEvent) {
        if let id = pressStepID { owner.choose(id, fromAccount: true, double: event.clickCount >= 2) }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let id = pressStepID else { return }
        host?.presentMenu(forStep: id, event: event, in: self)
    }

    /// A small flat button that sets the cursor to a step: the number a reader presses to go where
    /// the item is in the list and the head.
    func stepChip(_ text: String, stepID: String?) -> AccountButton {
        let chip = AccountButton(title: text, style: .step, paint: paint)
        chip.host = host
        chip.setAccessibilityLabel(Localized.text("Step %@", text))
        if let stepID {
            chip.onTap = { [weak owner] in owner?.choose(stepID, fromAccount: true) }
        }
        return chip
    }

    func linkButton(_ title: String, _ tap: @escaping () -> Void) -> AccountButton {
        let link = AccountButton(title: title, style: .link, paint: paint)
        link.host = host
        link.onTap = tap
        return link
    }
}


@MainActor
final class AccountSaidCell: AccountCell {
    private let said: NeuralAccount.Said
    private let isCursor: Bool
    private let text = AccountTextView()
    private var link: AccountButton?
    private var chip: AccountButton
    private let copy: AccountButton
    private let reply: AccountButton
    private let showsJustNow: Bool
    private var speakerMid: CGFloat = 0
    private var actionsStacked = true

    init(entry: AccountEntry, said: NeuralAccount.Said, key: String, owner: BrainAccountView) {
        self.said = said
        isCursor = owner.model.pinnedStep == said.stepID
        showsJustNow = owner.justNow[entry.id] != nil
        let paint = owner.paint
        chip = AccountButton(title: "#\(said.number)", style: .step, paint: paint)
        copy = AccountButton(title: owner.copyWord(for: said.stepID), style: .pill, paint: paint)
        reply = AccountButton(title: NeuralReading.replyLabel, style: .pill, paint: paint)
        super.init(entryID: entry.id, key: key, owner: owner)
        pressStepID = said.stepID
        hoverStepID = said.stepID
        text.host = owner.host
        text.setSelectionLook(paint.accent)
        text.onPress = { [weak owner, stepID = said.stepID] in owner?.choose(stepID, fromAccount: true) }
        text.keys = { [weak owner] event in owner?.handleKey(event) ?? false }
        text.setAccessibilityLabel(said.speaker)
        addSubview(text)
        chip.host = owner.host
        chip.setAccessibilityLabel(Localized.text("Step %@", "#\(said.number)"))
        chip.onTap = { [weak owner, stepID = said.stepID] in owner?.choose(stepID, fromAccount: true) }
        copy.host = owner.host
        reply.host = owner.host
        copy.setAccessibilityLabel(NeuralReading.copyLabel)
        reply.setAccessibilityLabel(NeuralReading.replyLabel)
        copy.onTap = { [weak owner, stepID = said.stepID] in owner?.copyItem(stepID) }
        reply.onTap = { [weak owner, stepID = said.stepID] in owner?.replyItem(stepID) }
        for view in [chip, copy, reply] { addSubview(view) }
        copy.isHidden = !isCursor
        reply.isHidden = !isCursor
        layer?.zPosition = isCursor ? 2 : 0
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel([said.speaker, said.clock].compactMap { $0 }.joined(separator: " "))
    }

    func setCopyTitle(_ title: String) {
        copy.title = title
        needsLayout = true
    }

    override var drawnWords: [String] { [said.speaker, said.clock ?? ""] }

    override func hoverChanged(_ hovered: Bool) {
        let show = hovered || isCursor
        copy.isHidden = !show
        reply.isHidden = !show
        layer?.zPosition = show ? 2 : 0
        needsDisplay = true
    }

    override func fit(width: CGFloat) -> CGFloat {
        let paint = paint
        let em = owner.proseProbe.em
        let measure = max(120, min(em * 36, width - 19 - 56))
        var y: CGFloat = 2
        if said.showsSpeaker {
            speakerMid = y + 8
            y += 16 + 4
        }
        let words = AccountType.prose(said.text, role: .answer, paint: paint)
        let natural = AccountType.height(words, width: measure)
        let line = owner.proseProbe.line
        let lines = Int((natural / max(1, line)).rounded())
        let clamp = lines > NeuralAccount.saidCollapsedLines
        let expanded = owner.expandedText.contains(entryID)
        let height = text.set(words, width: measure, maxLines: clamp && !expanded ? NeuralAccount.saidCollapsedLines : 0)
        text.frame = CGRect(x: 19, y: y, width: measure, height: height)
        y += height
        link?.removeFromSuperview()
        link = nil
        if clamp {
            let made = linkButton(expanded ? AccountWords.hide : NeuralReading.showAllLabel) { [weak owner, id = entryID] in
                owner?.toggleText(id)
            }
            let size = made.fittingSize
            made.frame = CGRect(x: 19, y: y + 2, width: size.width, height: size.height)
            addSubview(made)
            link = made
            y += 2 + size.height
        }
        y += 2
        let chipSize = chip.fittingSize
        let copySize = copy.fittingSize
        let replySize = reply.fittingSize
        actionsStacked = y >= 2 + chipSize.height + 4 + copySize.height + 4 + replySize.height
        let right = width - 6
        if actionsStacked {
            chip.frame = CGRect(x: right - chipSize.width, y: 2, width: chipSize.width, height: chipSize.height)
            copy.frame = CGRect(
                x: right - copySize.width, y: 2 + chipSize.height + 4, width: copySize.width, height: copySize.height)
            reply.frame = CGRect(
                x: right - replySize.width, y: copy.frame.maxY + 4, width: replySize.width, height: replySize.height)
        } else {
            chip.frame = CGRect(x: right - chipSize.width, y: 2, width: chipSize.width, height: chipSize.height)
            reply.frame = CGRect(x: chip.frame.minX - 6 - replySize.width, y: 0, width: replySize.width, height: replySize.height)
            copy.frame = CGRect(x: reply.frame.minX - 6 - copySize.width, y: 0, width: copySize.width, height: copySize.height)
        }
        let result = max(y, actionsStacked ? y : 26)
        setFrameSize(NSSize(width: width, height: result))
        needsDisplay = true
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        let paint = paint
        let body = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        if isCursor || hovered {
            paint.accent.withAlphaComponent(isCursor ? 0.07 : 0.04).setFill()
            let path = NSBezierPath()
            path.appendRoundedRect(body, xRadius: 8, yRadius: 8)
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height).clip()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        paint.accent.setFill()
        NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
        guard said.showsSpeaker else { return }
        var x: CGFloat = 19
        AccountGlyphs.familyDot(cx: x + 4, cy: speakerMid, radius: 4, color: paint.family(said.family))
        x += 8 + 8
        x += AccountType.draw(said.speaker.uppercased(), .sectionLabel, paint.text, x: x, midY: speakerMid) + 8
        if let clock = said.clock {
            x += AccountType.draw(clock, .rowStamp, paint.dim, x: x, midY: speakerMid) + 8
        }
        if showsJustNow {
            AccountType.draw(AccountWords.justNow.uppercased(), .sectionLabel, paint.accent, x: x, midY: speakerMid)
        }
    }
}


@MainActor
final class AccountThoughtCell: AccountCell {
    private let thought: NeuralAccount.Thought
    private let isCursor: Bool
    private let text = AccountTextView()
    private var link: AccountButton?
    private let chip: AccountButton
    private let glyphZone = NeuralZone.think

    init(entry: AccountEntry, thought: NeuralAccount.Thought, key: String, owner: BrainAccountView) {
        self.thought = thought
        isCursor = owner.model.pinnedStep == thought.stepID
        chip = AccountButton(title: "#\(thought.number)", style: .step, paint: owner.paint)
        super.init(entryID: entry.id, key: key, owner: owner)
        pressStepID = thought.stepID
        hoverStepID = thought.stepID
        text.host = owner.host
        text.isSelectable = owner.expandedText.contains(entry.id)
        text.setSelectionLook(owner.paint.accent)
        text.onPress = { [weak owner, stepID = thought.stepID] in owner?.choose(stepID, fromAccount: true) }
        text.keys = { [weak owner] event in owner?.handleKey(event) ?? false }
        addSubview(text)
        chip.host = owner.host
        chip.onTap = { [weak owner, stepID = thought.stepID] in owner?.choose(stepID, fromAccount: true) }
        chip.setAccessibilityLabel(Localized.text("Step %@", "#\(thought.number)"))
        addSubview(chip)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(thought.firstLine)
    }

    override var drawnWords: [String] { [thought.firstLine] }

    override func hoverChanged(_ hovered: Bool) { needsDisplay = true }

    override func fit(width: CGFloat) -> CGFloat {
        let paint = paint
        let expanded = owner.expandedText.contains(entryID)
        let chipSize = chip.fittingSize
        let linkTitle = expanded ? AccountWords.hide : AccountWords.show
        let room = width - 19 - 18 - 10 - 44 - 10 - 8
        let truncated = AccountType.width(thought.firstLine, .thought) > room
        link?.removeFromSuperview()
        link = nil
        var textRoom = width - 19 - 18 - 10 - chipSize.width - 8 - 8
        var linkSize = CGSize.zero
        if thought.canUnfold || truncated {
            let made = linkButton(linkTitle) { [weak owner, id = entryID] in owner?.toggleText(id) }
            linkSize = made.fittingSize
            textRoom -= linkSize.width + 10
            addSubview(made)
            link = made
        }
        let words = AccountType.string(
            expanded ? thought.text : thought.firstLine, .thought, paint.dim,
            lineBreak: expanded ? .byWordWrapping : .byTruncatingTail)
        let height = text.set(words, width: max(textRoom, 40), maxLines: expanded ? 0 : 1)
        let row = max(24, height + 6)
        text.frame = CGRect(x: 19 + 18 + 10, y: (row - height) / 2, width: max(textRoom, 40), height: height)
        if expanded { text.frame.origin.y = 3 }
        chip.frame = CGRect(x: width - 8 - chipSize.width, y: expanded ? 3 : (row - chipSize.height) / 2, width: chipSize.width, height: chipSize.height)
        if let link {
            link.frame = CGRect(
                x: chip.frame.minX - 10 - linkSize.width, y: expanded ? 3 : (row - linkSize.height) / 2,
                width: linkSize.width, height: linkSize.height)
        }
        setFrameSize(NSSize(width: width, height: row))
        needsDisplay = true
        return row
    }

    override func draw(_ dirtyRect: NSRect) {
        let paint = paint
        if isCursor || hovered {
            paint.accent.withAlphaComponent(isCursor ? 0.07 : 0.04).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let expanded = owner.expandedText.contains(entryID)
        AccountGlyphs.zone(glyphZone, cx: 19 + 9, cy: expanded ? 3 + 10 : bounds.midY, color: paint.zone(glyphZone))
    }
}


@MainActor
final class AccountAskedCell: AccountCell {
    private let asked: NeuralAccount.Asked
    private let text = AccountTextView()
    private var link: AccountButton?

    init(entry: AccountEntry, asked: NeuralAccount.Asked, key: String, owner: BrainAccountView) {
        self.asked = asked
        super.init(entryID: entry.id, key: key, owner: owner)
        text.host = owner.host
        text.setSelectionLook(owner.paint.accent)
        text.keys = { [weak owner] event in owner?.handleKey(event) ?? false }
        addSubview(text)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(AccountWords.asked)
    }

    override var drawnWords: [String] { [AccountWords.asked] }

    override func fit(width: CGFloat) -> CGFloat {
        let paint = paint
        let expanded = owner.expandedText.contains(entryID)
        let measure = max(120, min(owner.proseProbe.em * 36, width - 8))
        let words = AccountType.string(asked.text, .cardBody, paint.text.withAlphaComponent(0.78))
        let natural = AccountType.lineCount(words, width: measure, role: .cardBody)
        var y: CGFloat = 16 + 2
        let height = text.set(words, width: measure, maxLines: natural > 2 && !expanded ? 2 : 0)
        text.frame = CGRect(x: 0, y: y, width: measure, height: height)
        y += height
        link?.removeFromSuperview()
        link = nil
        if natural > 2 {
            let made = linkButton(expanded ? AccountWords.hide : NeuralReading.showAllLabel) { [weak owner, id = entryID] in
                owner?.toggleText(id)
            }
            let size = made.fittingSize
            made.frame = CGRect(x: 0, y: y + 2, width: size.width, height: size.height)
            addSubview(made)
            link = made
            y += 2 + size.height
        }
        setFrameSize(NSSize(width: width, height: y))
        needsDisplay = true
        return y
    }

    override func draw(_ dirtyRect: NSRect) {
        AccountType.draw(AccountWords.asked, .sectionLabel, paint.dim, x: 0, midY: 8)
    }
}


@MainActor
final class AccountPlanCell: AccountCell {
    private let view: AccountPlanView

    init(entry: AccountEntry, plan: NeuralAccount.Plan, key: String, owner: BrainAccountView) {
        view = AccountPlanView(
            plan: plan, compact: false, open: owner.planStoryOpen(entry, plan), paint: owner.paint)
        super.init(entryID: entry.id, key: key, owner: owner)
        view.onToggle = { [weak owner, id = entry.id] in owner?.togglePlan(id) }
        addSubview(view)
    }

    override func fit(width: CGFloat) -> CGFloat {
        let height = view.fit(width: width)
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        setFrameSize(NSSize(width: width, height: height))
        return height
    }
}


/// What came of the turn: the files it changed, the checks it ran with their own verdicts, what is
/// still failing, and then its answer; nothing the transcript does not show.
@MainActor
final class AccountResultCell: AccountCell {
    private let result: NeuralAccount.Result
    private var drawing: [() -> Void] = []
    private var buttons: [AccountButton] = []
    private var answerText: AccountTextView?
    private var answerRect = CGRect.zero

    init(entry: AccountEntry, result: NeuralAccount.Result, key: String, owner: BrainAccountView) {
        self.result = result
        super.init(entryID: entry.id, key: key, owner: owner)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(AccountWords.result)
    }

    override var drawnWords: [String] {
        var words = [AccountWords.result]
        if !result.changes.isEmpty { words.append(AccountWords.changed) }
        if !result.checks.isEmpty { words.append(AccountWords.checks) }
        if !result.unfixed.isEmpty { words.append(AccountWords.stillFailing) }
        words.append(contentsOf: result.checks.map { "\($0.label) \($0.verdictWords)" })
        if let words2 = result.changedWords { words.append(words2) }
        if let answer = result.answer ?? result.answerWords {
            words.append(NeuralReading.thenItAnswered.uppercased())
            words.append(answer)
        }
        return words
    }

    private func numberChips(_ numbers: [Int], right: CGFloat, midY: CGFloat) -> CGFloat {
        var x = right
        let steps = owner.model.steps
        for number in numbers.prefix(4).reversed() {
            guard number >= 1, number <= steps.count else { continue }
            let chip = stepChip("#\(number)", stepID: steps[number - 1].id)
            let size = chip.fittingSize
            x -= size.width
            chip.frame = CGRect(x: x, y: midY - size.height / 2, width: size.width, height: size.height)
            addSubview(chip)
            buttons.append(chip)
            x -= 2
        }
        return x
    }

    override func fit(width: CGFloat) -> CGFloat {
        let paint = paint
        for button in buttons { button.removeFromSuperview() }
        buttons = []
        for meter in meterViews { meter.removeFromSuperview() }
        meterViews = []
        answerText?.removeFromSuperview()
        answerText = nil
        drawing = []
        let left: CGFloat = 12
        let right = width - 12
        var y: CGFloat = 12
        drawing.append { [paint] in AccountType.draw(AccountWords.result, .sectionLabel, paint.dim, x: left, midY: 8 + 12) }
        y += 16
        var firstGroup = true
        func startGroup(_ title: String?, tone: NSColor? = nil, answerLink: Bool = false) {
            y += 12
            if !firstGroup {
                let ruleY = y
                drawing.append { [paint, width] in
                    paint.rule.setFill()
                    NSRect(x: 12, y: ruleY, width: width - 24, height: 1).fill()
                }
                y += 1 + 10
            }
            firstGroup = false
            if let title {
                let top = y
                drawing.append { [paint] in
                    AccountType.draw(title, .sectionLabel, tone ?? paint.dim, x: left, midY: top + 8)
                    if answerLink {
                        AccountType.draw(Localized.text("answer") + " \u{2193}", .rowStamp, paint.dim, x: right, midY: top + 8, rightAligned: true)
                    }
                }
                y += 16 + 4
            }
        }
        if !result.changes.isEmpty {
            startGroup(AccountWords.changed)
            for change in result.changes.prefix(8) {
                let mid = y + 14
                var edge = numberChips(change.numbers, right: right, midY: mid)
                let tallyText = NSMutableAttributedString(
                    string: "+\(change.added)", attributes: AccountType.attributes(.rowMeta, paint.accent))
                tallyText.append(
                    NSAttributedString(
                        string: " \u{2212}\(change.removed)", attributes: AccountType.attributes(.rowMeta, paint.danger)))
                let tallyWidth = max(48, ceil(tallyText.size().width))
                edge -= 8
                let tallyX = edge - tallyWidth
                let meterWidth = CGFloat(min(64, max(12, (change.added + change.removed) * 6)))
                let meterX = tallyX - 10 - meterWidth
                let pathRoom = meterX - left - 12
                let directory = NSMutableAttributedString(
                    string: change.shortDirectory,
                    attributes: AccountType.attributes(.toolDetail, paint.dim, lineBreak: .byTruncatingHead))
                var bold = AccountType.attributes(.toolDetail, paint.text, lineBreak: .byTruncatingHead)
                bold[.font] = NSFont.monospacedSystemFont(ofSize: AccountType.font(.toolDetail).pointSize, weight: .bold)
                directory.append(NSAttributedString(string: change.fileName, attributes: bold))
                let line = AccountType.lineHeight(.toolDetail)
                let meter = AccountMeterView(added: change.added, removed: change.removed, paint: paint)
                meter.frame = CGRect(x: meterX, y: y, width: meterWidth, height: 28)
                addSubview(meter)
                meterViews.append(meter)
                drawing.append {
                    directory.draw(
                        with: NSRect(x: left, y: mid - line / 2, width: max(pathRoom, 20), height: line),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
                    tallyText.draw(at: NSPoint(x: tallyX + tallyWidth - ceil(tallyText.size().width), y: mid - AccountType.lineHeight(.rowMeta) / 2))
                }
                y += 28
            }
            if result.changes.count > 8 {
                let top = y
                let count = result.changes.count - 8
                drawing.append { [paint] in
                    AccountType.draw(AccountWords.moreFiles(count), .rowStamp, paint.dim, x: left, midY: top + 10)
                }
                y += 20
            }
        } else if let words = result.changedWords {
            y += 12
            firstGroup = false
            let attributed = AccountType.string(words, .rowTitle, paint.dim)
            let height = AccountType.height(attributed, width: right - left)
            let top = y
            drawing.append {
                attributed.draw(
                    with: NSRect(x: left, y: top, width: right - left, height: height),
                    options: [.usesLineFragmentOrigin], context: nil)
            }
            y += height
        }
        if !result.checks.isEmpty {
            startGroup(AccountWords.checks)
            for check in result.checks {
                let mid = y + 14
                var edge = numberChips(check.numbers, right: right, midY: mid)
                edge -= 8
                let tone: NSColor = check.verdict == .failed ? paint.danger : (check.verdict == .fixed ? paint.warn : paint.accent)
                let verdictWidth = AccountType.width(check.verdictWords, .rowMeta)
                let verdictX = edge - verdictWidth
                let commandX = left + 24 + 52
                let commandRoom = verdictX - 12 - commandX
                drawing.append { [paint] in
                    AccountGlyphs.verdict(check.verdict, cx: left + 7, cy: mid, size: 14, color: paint.verdict(check.verdict))
                    AccountType.draw(check.label, .rowTitleStrong, paint.text, x: left + 24, midY: mid, maxWidth: 48)
                    AccountType.draw(check.command, .rowDetail, paint.dim, x: commandX, midY: mid, maxWidth: max(commandRoom, 20))
                    AccountType.draw(check.verdictWords, .rowMeta, tone, x: verdictX, midY: mid, maxWidth: verdictWidth + 2)
                }
                y += 28
            }
        }
        if !result.unfixed.isEmpty {
            startGroup(AccountWords.stillFailing, tone: paint.danger)
            for item in result.unfixed.prefix(6) {
                let mid = y + 14
                let edge = numberChips([item.number], right: right, midY: mid) - 8
                drawing.append { [paint] in
                    AccountGlyphs.verdict(.failed, cx: left + 7, cy: mid, size: 14, color: paint.danger)
                    let titleWidth = AccountType.draw(item.title, .rowTitleStrong, paint.text, x: left + 24, midY: mid, maxWidth: 160)
                    AccountType.draw(
                        item.firstLine, .rowDetail, paint.dim, x: left + 24 + titleWidth + 10, midY: mid,
                        maxWidth: max(edge - (left + 24 + titleWidth + 10), 20))
                }
                y += 28
            }
        }
        if let answer = result.answer ?? result.answerWords {
            startGroup(NeuralReading.thenItAnswered.uppercased(), answerLink: true)
            let view = AccountTextView()
            view.host = host
            view.isSelectable = false
            let measure = max(120, min(owner.proseProbe.em * 36, width - 24))
            let height = view.set(AccountType.string(answer, .answer, paint.text), width: measure)
            view.frame = CGRect(x: left, y: y, width: measure, height: height)
            addSubview(view)
            answerText = view
            answerRect = CGRect(x: 0, y: y - 20, width: width, height: height + 20)
            y += height
        }
        y += 12
        setFrameSize(NSSize(width: width, height: y))
        needsDisplay = true
        return y
    }

    private var meterViews: [AccountMeterView] = []

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if answerText != nil, answerRect.contains(point) { owner.host?.revealAnswer() }
    }

    override func resetCursorRects() {
        if answerText != nil { addCursorRect(answerRect, cursor: .pointingHand) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let paint = paint
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        paint.raised.withAlphaComponent(0.7).setFill()
        shape.fill()
        paint.rule.setStroke()
        shape.lineWidth = 1
        shape.stroke()
        for op in drawing { op() }
    }

    override func teardown() {
        for meter in meterViews { meter.removeFromSuperview() }
        meterViews = []
    }
}
