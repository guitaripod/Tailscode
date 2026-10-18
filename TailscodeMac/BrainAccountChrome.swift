import AppKit
import TailscodeCore

/// The entity and how it is getting on, on one 40 point row: who it is (the family's dot, the
/// name, the effort bars), the verdict as a pill, the sentence that says how it went (the amber
/// clause carries what it fixed, never the pill), and the counts at the right. In a narrow
/// account the same facts wrap onto rows. It sits above a rule and never scrolls with the story.
@MainActor
final class AccountHeaderView: AccountBlock {
    struct Content {
        var header: NeuralAccount.Header
        var vitals: NeuralAccount.Vitals
        var filterWord: String?
        var paint: AccountPaint
        var multiline: Bool
        var padLeft: CGFloat
    }

    private var content: Content?
    private let pill = AccountPill()
    private let pillDot = AccountPulseDot()
    private let filtered = AccountPill()
    private var identityOrigin = CGPoint.zero
    private var sentenceRect = CGRect.zero
    private var countsRect = CGRect.zero
    private var layoutKey = ""
    private var laidWidth: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(pill)
        addSubview(pillDot)
        addSubview(filtered)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Takes the new facts; true when the words that decide the room they need changed, so the
    /// account lays out again. A sentence that only ticked is redrawn in the room it has.
    @discardableResult
    func show(_ next: Content) -> Bool {
        let header = next.header
        let key = [
            header.speaker, header.pillWord, header.clause ?? "", next.vitals.counts, "\(header.verdict)",
            "\(header.face.effort)", next.filterWord ?? "", "\(next.multiline)", next.paint.inks.palette.name,
            "\(header.isRunning)", "\(header.face.hollow)", "\(header.face.rainbow)",
        ].joined(separator: "|")
        let relayout = key != layoutKey
        content = next
        layoutKey = key
        pill.role = .badge
        pill.height = 22
        pill.color = next.paint.tone(header.tone)
        pill.verdict = NeuralVerdict.Step.forTurn(header.verdict)
        pill.hidesGlyph = header.verdict == .working
        pill.word = header.pillWord.uppercased()
        pillDot.isHidden = header.verdict != .working
        if header.verdict == .working {
            pillDot.configure(color: next.paint.accent, motion: .breath, diameter: 7)
        }
        filtered.isHidden = next.filterWord == nil
        if let word = next.filterWord {
            filtered.role = .badge
            filtered.height = 18
            filtered.color = next.paint.warn
            filtered.verdict = nil
            filtered.word = word
        }
        setAccessibilityLabel(
            "\(header.speaker), \(header.pillWord), \(next.vitals.sentence), \(next.vitals.counts)")
        needsDisplay = true
        return relayout
    }

    private func identityWidth(_ header: NeuralAccount.Header) -> CGFloat {
        10 + 8 + AccountType.width(header.speaker, .cardTitle) + 8 + 24
    }

    private func sentenceWords(_ content: Content) -> (time: String?, clause: String?, plain: String) {
        let header = content.header
        if !header.isRunning, let clause = header.clause {
            let elapsed = content.vitals.elapsedWords.map { Localized.text("in %@", $0) + " \u{00B7}" }
            return (elapsed, clause, "")
        }
        return (nil, nil, content.vitals.sentence)
    }

    private func sentenceWidth(_ content: Content) -> CGFloat {
        let words = sentenceWords(content)
        if let clause = words.clause {
            return (words.time.map { AccountType.width($0, .rowTitle) + 6 } ?? 0) + 19
                + AccountType.width(clause, .rowTitle)
        }
        return AccountType.width(words.plain, .rowTitle)
    }

    override func fit(width: CGFloat) -> CGFloat {
        guard let content else { return 40 }
        let padLeft = content.padLeft
        let padRight: CGFloat = 12
        let avail = max(width - padLeft - padRight, 40)
        let identity = identityWidth(content.header)
        let pillSize = pill.fittingSize
        let counts = AccountType.width(content.vitals.counts, .rowStamp)
        let chip = filtered.isHidden ? 0 : filtered.fittingSize.width + 10
        let sentence = sentenceWidth(content)
        let single = !content.multiline && identity + 12 + pillSize.width + 12 + min(sentence, 160) + 12 + chip + counts <= avail
        var height: CGFloat
        if single {
            height = 40
            identityOrigin = CGPoint(x: padLeft, y: height / 2)
            pill.frame.origin = CGPoint(x: padLeft + identity + 12, y: (height - pillSize.height) / 2)
            var x = pill.frame.maxX + 12
            if chip > 0 {
                filtered.frame.origin = CGPoint(x: x, y: (height - filtered.frame.height) / 2)
                x = filtered.frame.maxX + 10
            }
            countsRect = CGRect(x: width - padRight - counts, y: 0, width: counts, height: height)
            sentenceRect = CGRect(x: x, y: 0, width: max(countsRect.minX - 12 - x, 20), height: height)
        } else {
            var y: CGFloat = 8
            identityOrigin = CGPoint(x: padLeft, y: y + 12)
            pill.frame.origin = CGPoint(x: padLeft + identity + 12, y: y + (24 - pillSize.height) / 2)
            var x = pill.frame.maxX + 12
            if chip > 0 {
                filtered.frame.origin = CGPoint(x: x, y: y + (24 - filtered.frame.height) / 2)
                x = filtered.frame.maxX + 10
            }
            if x + sentence <= padLeft + avail {
                sentenceRect = CGRect(x: x, y: y, width: padLeft + avail - x, height: 24)
                y += 24
            } else {
                y += 24 + 4
                sentenceRect = CGRect(x: padLeft, y: y, width: avail, height: 18)
                y += 18
            }
            y += 2
            countsRect = CGRect(x: padLeft, y: y, width: avail, height: 16)
            y += 16 + 8
            height = y
        }
        pillDot.frame.origin = CGPoint(
            x: pill.frame.minX + 14 - pillDot.frame.width / 2,
            y: pill.frame.midY - pillDot.frame.height / 2)
        laidWidth = width
        setFrameSize(NSSize(width: width, height: height))
        needsDisplay = true
        return height
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let content else { return }
        let paint = content.paint
        let header = content.header
        let mid = identityOrigin.y
        var x = identityOrigin.x
        AccountGlyphs.familyDot(cx: x + 5, cy: mid, radius: 5, color: paint.family(header.family))
        x += 10 + 8
        let name = AccountType.draw(header.speaker, .cardTitle, paint.text, x: x, midY: mid)
        x += name + 8
        AccountGlyphs.effortBars(header.face, x: x, midY: mid, paint: paint)
        let words = sentenceWords(content)
        let rect = sentenceRect
        if let clause = words.clause {
            var sx = rect.minX
            if let time = words.time {
                sx += AccountType.draw(time, .rowTitle, paint.dim, x: sx, midY: rect.midY, maxWidth: rect.width) + 6
            }
            AccountGlyphs.verdict(.fixed, cx: sx + 7, cy: rect.midY, size: 13, color: paint.warn)
            AccountType.draw(clause, .rowTitle, paint.warn, x: sx + 19, midY: rect.midY, maxWidth: max(rect.maxX - sx - 19, 1))
        } else {
            let warn = header.verdict == .needsYou || header.verdict == .stuck
            AccountType.draw(words.plain, .rowTitle, warn ? paint.warn : paint.dim, x: rect.minX, midY: rect.midY, maxWidth: rect.width)
        }
        AccountType.draw(content.vitals.counts, .rowStamp, paint.dim, x: countsRect.minX, midY: countsRect.midY, maxWidth: countsRect.width)
        paint.rule.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

extension NeuralVerdict.Step {
    /// The step verdict whose mark stands for a turn's: a done turn wears the check, one that
    /// waits the pause bars, one that works the dot, a stuck one the dashed clock.
    static func forTurn(_ turn: NeuralVerdict.Turn) -> NeuralVerdict.Step {
        switch turn {
        case .done, .doneAfterRetries: return .done
        case .needsYou: return .waiting
        case .working: return .running
        case .stuck: return .stalled
        case .stopped, .didntAnswer: return .stopped
        case .failed: return .failed
        }
    }
}

/// What a narrow account carries of the list's header, because it is the list there: the search
/// field, how many steps are shown, and the failed toggle.
@MainActor
final class AccountNarrowBar: NSView, NSTextFieldDelegate {
    weak var host: BrainSurfaceHost?
    private let searchButton: AccountButton
    private let field = NSTextField()
    private let failed: AccountButton
    private var countWords = ""
    private var countAccent = false
    private var paint: AccountPaint
    private var padLeft: CGFloat = 16
    private(set) var fieldOpen = false

    init(paint: AccountPaint) {
        self.paint = paint
        searchButton = AccountButton(title: AccountWords.search, style: .pill, paint: paint)
        failed = AccountButton(title: AccountWords.failedWord.lowercased(), style: .pill, paint: paint)
        super.init(frame: .zero)
        addSubview(searchButton)
        addSubview(failed)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.placeholderString = AccountWords.search
        field.isHidden = true
        addSubview(field)
        searchButton.onTap = { [weak self] in self?.openField() }
        failed.onTap = { [weak self] in self?.host?.browse(.failedToggle, grabFocus: false) }
        setAccessibilityRole(.group)
        setAccessibilityLabel(AccountWords.search)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    func configure(
        host: BrainSurfaceHost?, paint next: AccountPaint, list: NeuralStepList, padLeft: CGFloat
    ) {
        self.host = host
        paint = next
        self.padLeft = padLeft
        searchButton.paint = next
        searchButton.host = host
        failed.paint = next
        failed.host = host
        countWords = list.countLabel
        countAccent = list.isFiltered
        failed.isHidden = !list.offersFailedFilter
        failed.isLit = list.filter.failedOnly
        failed.title = "\u{2715} " + AccountWords.failedCount(list.failedCount)
        let state = host?.model.browseState
        let open = (state?.searchOpen ?? false) || !list.filter.query.isEmpty
        if open != fieldOpen {
            fieldOpen = open
            field.isHidden = !open
            if !open { field.stringValue = "" }
        }
        if open, field.currentEditor() == nil, field.stringValue != list.filter.search {
            field.stringValue = list.filter.search
        }
        searchButton.isHidden = fieldOpen
        if open, state?.focus == .search, let window, window.firstResponder !== field.currentEditor() {
            window.makeFirstResponder(field)
        }
        needsLayout = true
        needsDisplay = true
    }

    func openField() {
        fieldOpen = true
        field.isHidden = false
        searchButton.isHidden = true
        needsLayout = true
        host?.updateModel { $0.setBrowseSearchOpen(true) }
        focusField()
    }

    func focusField() {
        if field.isHidden {
            fieldOpen = true
            field.isHidden = false
            searchButton.isHidden = true
            needsLayout = true
        }
        host?.updateModel { $0.setBrowseFocus(.search) }
        window?.makeFirstResponder(field)
    }

    func closeField() {
        fieldOpen = false
        field.isHidden = true
        field.stringValue = ""
        searchButton.isHidden = false
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let size = searchButton.fittingSize
        searchButton.frame = CGRect(x: padLeft, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        field.font = AccountType.font(.control)
        field.frame = CGRect(x: padLeft + 18, y: (bounds.height - 20) / 2, width: min(240, bounds.width - padLeft - 100), height: 20)
        var right = bounds.width - 12
        if !failed.isHidden {
            let fsize = failed.fittingSize
            failed.frame = CGRect(x: right - fsize.width, y: (bounds.height - fsize.height) / 2, width: fsize.width, height: fsize.height)
            right = failed.frame.minX - 10
        }
        countRight = right
    }

    private var countRight: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        if fieldOpen {
            AccountGlyphs.magnifier(x: padLeft, midY: bounds.midY, color: paint.dim)
            paint.rule2.setFill()
            NSRect(x: padLeft + 18, y: bounds.midY + 11, width: field.frame.width, height: 1).fill()
        }
        AccountType.draw(
            countWords, .rowStamp, countAccent ? paint.accent : paint.dim, x: countRight, midY: bounds.midY,
            rightAligned: true)
    }

    func controlTextDidChange(_ notification: Notification) {
        host?.browse(.searchText(field.stringValue), grabFocus: false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            host?.updateModel { $0.setBrowseFocus(.search) }
            host?.browse(.key(.enter), grabFocus: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            host?.updateModel { $0.setBrowseFocus(.search) }
            host?.browse(.key(.escape), grabFocus: true)
            closeField()
            return true
        case #selector(NSResponder.moveUp(_:)):
            host?.browse(.key(.up), grabFocus: false)
            return true
        case #selector(NSResponder.moveDown(_:)):
            host?.browse(.key(.down), grabFocus: false)
            return true
        default:
            return false
        }
    }
}

/// The key hints under a wide account, and when the turn began at its right.
@MainActor
final class AccountFooterStrip: NSView {
    var paint: AccountPaint { didSet { needsDisplay = true } }
    var began: String? { didSet { needsDisplay = true } }
    var padLeft: CGFloat = 20

    init(paint: AccountPaint) {
        self.paint = paint
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func keyCap(_ key: String, x: CGFloat, midY: CGFloat) -> CGFloat {
        let width = max(16, AccountType.width(key, .rowNote) + 8)
        let rect = NSRect(x: x + 0.5, y: midY - 8 + 0.5, width: width - 1, height: 15)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        paint.rule2.setStroke()
        path.lineWidth = 1
        path.stroke()
        AccountType.draw(key, .rowNote, paint.dim, x: x + width / 2 - AccountType.width(key, .rowNote) / 2, midY: midY)
        return width
    }

    override func draw(_ dirtyRect: NSRect) {
        paint.rule.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        let mid = bounds.midY
        var x = padLeft
        func hint(_ keys: [String], _ verb: String) {
            for key in keys { x += keyCap(key, x: x, midY: mid) + 3 }
            x += 3
            x += AccountType.draw(verb, .rowStamp, paint.dim, x: x, midY: mid) + 14
        }
        hint(["s", "S"], AccountWords.saidVerb)
        hint(["a"], AccountWords.askVerb)
        hint(["\u{2191}", "\u{2193}"], AccountWords.itemsVerb)
        hint(["Enter"], AccountWords.detailVerb)
        if let began {
            AccountType.draw(began, .rowStamp, paint.dim, x: bounds.width - 12, midY: mid, rightAligned: true)
        }
    }
}

/// The step in flight, under the header: its plain title, its argument, the last lines it
/// printed with a caret, and how long since it last spoke. After 40 seconds of silence it turns
/// to the attention tone and says so.
@MainActor
final class AccountNowView: AccountBlock {
    private let paint: AccountPaint
    private let live: NeuralAccount.LiveStep
    private let vitals: NeuralAccount.Vitals
    private let pulse = AccountPulseDot()
    private let tail: AccountTextView
    private let tailLines: [NeuralReadout.OutputLine]
    private var tailRect = CGRect.zero
    private var argumentY: CGFloat = 0

    init(live: NeuralAccount.LiveStep, vitals: NeuralAccount.Vitals, host: BrainSurfaceHost?, paint: AccountPaint) {
        self.live = live
        self.vitals = vitals
        self.paint = paint
        tail = AccountTextView()
        tailLines = Array(live.tail.suffix(2))
        super.init(frame: .zero)
        wantsLayer = true
        tail.host = host
        tail.isSelectable = false
        addSubview(pulse)
        addSubview(tail)
        pulse.configure(
            color: vitals.isSilent ? paint.warn : paint.accent, motion: vitals.isSilent ? .still : .breath,
            diameter: 7)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(NeuralReading.nowLabel). \(live.title)")
        let words = NSMutableAttributedString()
        for (index, line) in tailLines.enumerated() {
            var attributes = AccountType.attributes(.toolOutput, paint.dim)
            switch line.tone {
            case .dim: break
            case .danger: attributes[.foregroundColor] = paint.dangerText
            case .emphasis: attributes[.foregroundColor] = paint.text
            }
            words.append(NSAttributedString(string: (line.text.isEmpty ? " " : line.text) + "\n", attributes: attributes))
            _ = index
        }
        var caret = AccountType.attributes(.toolOutput, paint.dim)
        caret[.backgroundColor] = paint.accent
        words.append(NSAttributedString(string: " ", attributes: caret))
        tailAttributed = tailLines.isEmpty ? nil : words
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var tailAttributed: NSAttributedString?

    override func fit(width: CGFloat) -> CGFloat {
        var y: CGFloat = 10
        y += 22
        pulse.frame.origin = CGPoint(x: 12, y: 10 + (22 - pulse.frame.height) / 2)
        if !live.argument.isEmpty {
            argumentY = y + 4
            y += 4 + AccountType.lineHeight(.toolDetail)
        } else {
            argumentY = 0
        }
        if let words = tailAttributed {
            y += 6
            let height = tail.set(words, width: max(width - 24 - 12 - 8, 20))
            tailRect = CGRect(x: 12, y: y, width: width - 24, height: height + 16)
            tail.frame = CGRect(x: 12 + 12, y: y + 8, width: width - 24 - 12 - 8, height: height)
            y += height + 16
            tail.isHidden = false
        } else {
            tail.isHidden = true
        }
        y += 10
        setFrameSize(NSSize(width: width, height: y))
        needsDisplay = true
        return y
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let silent = vitals.isSilent
        let tone = silent ? paint.warn : paint.accent
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        tone.withAlphaComponent(silent ? 0.08 : 0.05).setFill()
        shape.fill()
        tone.withAlphaComponent(silent ? 0.55 : 0.4).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        let mid: CGFloat = 10 + 11
        var x: CGFloat = 12 + 7 + 8
        x += AccountType.draw(NeuralReading.nowLabel, .sectionLabel, tone, x: x, midY: mid) + 10
        var right = bounds.width - 12
        if silent, let words = vitals.silentWords {
            let used = AccountType.draw(words, .rowStamp, paint.warn, x: right, midY: mid, rightAligned: true)
            AccountGlyphs.verdict(.stalled, cx: right - used - 12, cy: mid, size: 12, color: paint.warn)
            right -= used + 22
        } else if let words = vitals.lastOutputWords {
            right -= AccountType.draw(words, .rowStamp, paint.dim, x: right, midY: mid, rightAligned: true) + 10
        }
        AccountType.draw(live.title, .cardTitle, paint.text, x: x, midY: mid, maxWidth: max(right - x, 20))
        if argumentY > 0 {
            AccountType.draw(
                live.argument, .toolDetail, paint.text.withAlphaComponent(0.85), x: 12,
                midY: argumentY + AccountType.lineHeight(.toolDetail) / 2, maxWidth: bounds.width - 24)
        }
        if tailAttributed != nil {
            paint.well.setFill()
            NSBezierPath(roundedRect: tailRect, xRadius: 6, yRadius: 6).fill()
        }
    }
}

/// What the agent is waiting on you for, in its own words: the loudest thing on the page by colour
/// and position alone. The command it wants to run sits in a recessed box and the button goes to
/// the card that carries the real approval.
@MainActor
final class AccountAskView: AccountBlock {
    private let ask: NeuralAccount.Ask
    private let paint: AccountPaint
    private let pulse = AccountPulseDot()
    private let words: AccountTextView
    private let command: AccountTextView?
    private let go: AccountButton
    private let show: AccountButton
    private var options: [AccountPill] = []
    private var metaText = ""
    private var commandRect = CGRect.zero

    init(ask: NeuralAccount.Ask, step: NeuralStep?, owner: BrainAccountView, paint: AccountPaint) {
        self.ask = ask
        self.paint = paint
        words = AccountTextView()
        go = AccountButton(title: ask.actionLabel + " \u{2193}", style: .filled, paint: paint)
        show = AccountButton(title: AccountWords.showStep(ask.number), style: .ghost, paint: paint)
        if ask.subjectKind == .command, !ask.subject.isEmpty {
            command = AccountTextView()
        } else {
            command = nil
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        layer?.masksToBounds = false
        addSubview(pulse)
        pulse.configure(color: paint.warn, motion: .heartbeat, diameter: 7)
        var meta = step.map { $0.zone.displayLabel } ?? ""
        if let clock = step?.at.map({ NeuralReading.clock($0) }) {
            meta += (meta.isEmpty ? "" : " \u{00B7} ") + Localized.text("waiting since %@", clock)
        }
        metaText = meta
        let sentence = ask.why?.text ?? ask.sentence
        words.host = owner.host
        words.setSelectionLook(paint.warn)
        words.onPress = { [weak owner] in owner?.choose(ask.stepID, fromAccount: true) }
        addSubview(words)
        words.set(AccountType.string(sentence, .answer, paint.text), width: 100)
        if let command {
            command.host = owner.host
            command.setSelectionLook(paint.warn)
            addSubview(command)
        }
        for option in ask.options {
            let pill = AccountPill()
            pill.role = .chip
            pill.height = 22
            pill.color = paint.text
            pill.verdict = nil
            pill.word = option
            options.append(pill)
            addSubview(pill)
        }
        go.host = owner.host
        show.host = owner.host
        go.onTap = { [weak owner] in owner?.goToApproval() }
        show.onTap = { [weak owner] in owner?.choose(ask.stepID, fromAccount: false) }
        addSubview(go)
        addSubview(show)
        questionText = ask.subject != sentence && ask.subjectKind != .command && !ask.subject.isEmpty ? ask.subject : nil
        if questionText != nil {
            question = AccountTextView()
            question?.host = owner.host
            question?.setSelectionLook(paint.warn)
            addSubview(question!)
        }
        setAccessibilityElement(false)
        setAccessibilityLabel("\(AccountWords.needsYou). \(sentence)")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var questionText: String?
    private var question: AccountTextView?

    override func fit(width: CGFloat) -> CGFloat {
        let left: CGFloat = 19
        let right: CGFloat = 16
        let inner = max(width - left - right, 40)
        var y: CGFloat = 14
        pulse.frame.origin = CGPoint(x: left, y: y + (20 - pulse.frame.height) / 2)
        y += 20 + 8
        let sentence = ask.why?.text ?? ask.sentence
        let wordsHeight = words.set(AccountType.string(sentence, .answer, paint.text), width: inner)
        words.frame = CGRect(x: left, y: y, width: inner, height: wordsHeight)
        y += wordsHeight
        if let command {
            y += 10
            let prompt = NSMutableAttributedString(string: "$ ", attributes: AccountType.attributes(.toolDetail, paint.warn))
            prompt.append(NSAttributedString(string: ask.subject, attributes: AccountType.attributes(.toolDetail, paint.text)))
            let height = command.set(prompt, width: inner - 24)
            commandRect = CGRect(x: left, y: y, width: inner, height: height + 16)
            command.frame = CGRect(x: left + 12, y: y + 8, width: inner - 24, height: height)
            y += height + 16
        } else if let question, let text = questionText {
            let height = question.set(AccountType.string(text, .cardTitle, paint.text), width: inner)
            question.frame = CGRect(x: left, y: y + 8, width: inner, height: height)
            y += 8 + height
        }
        if !options.isEmpty {
            y += 10
            var x = left
            var rowHeight: CGFloat = 0
            for pill in options {
                let size = pill.fittingSize
                if x > left, x + size.width > left + inner {
                    x = left
                    y += rowHeight + 6
                    rowHeight = 0
                }
                pill.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
                x += size.width + 6
                rowHeight = max(rowHeight, size.height)
            }
            y += rowHeight
        }
        y += 12
        let goSize = go.fittingSize
        go.frame = CGRect(x: left, y: y, width: goSize.width, height: goSize.height)
        let showSize = show.fittingSize
        show.frame = CGRect(x: left + goSize.width + 8, y: y, width: showSize.width, height: showSize.height)
        y += goSize.height + 14
        setFrameSize(NSSize(width: width, height: y))
        needsDisplay = true
        return y
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        paint.canvas.setFill()
        shape.fill()
        paint.warn.withAlphaComponent(0.09).setFill()
        shape.fill()
        paint.warn.withAlphaComponent(0.55).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        paint.warn.setFill()
        NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let mid: CGFloat = 14 + 10
        var x: CGFloat = 19 + 7 + 9
        x += AccountType.draw(AccountWords.needsYou, .sectionLabel, paint.warn, x: x, midY: mid) + 10
        AccountType.draw(
            metaText, .rowStamp, paint.dim, x: bounds.width - 16, midY: mid, maxWidth: max(bounds.width - 16 - x, 20),
            rightAligned: true)
        if command != nil {
            paint.canvas.withAlphaComponent(0.7).setFill()
            let box = NSBezierPath(roundedRect: commandRect, xRadius: 6, yRadius: 6)
            box.fill()
            paint.rule2.setStroke()
            box.lineWidth = 1
            box.stroke()
        }
    }
}

/// The agent's own task list as a block: its header with how many are done and a four point bar,
/// and below it each item with its state. A finished plan folds to its header; a running turn's
/// plan compacts to segments and the item in progress when the Now line is up.
@MainActor
final class AccountPlanView: AccountBlock {
    private let plan: NeuralAccount.Plan
    private let paint: AccountPaint
    private let compact: Bool
    private let open: Bool
    var onToggle: (() -> Void)?
    private static let itemLimit = 24
    private var textWidth: CGFloat = 0

    init(plan: NeuralAccount.Plan, compact: Bool, open: Bool, paint: AccountPaint) {
        self.plan = plan
        self.compact = compact
        self.open = open
        self.paint = paint
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(AccountWords.plan) \(plan.label)")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var showsItems: Bool { open && !compact }

    private var shownItems: [NeuralAccount.PlanItem] { Array(plan.items.prefix(Self.itemLimit)) }

    private func itemText(_ item: NeuralAccount.PlanItem) -> NSAttributedString {
        let words = item.isCurrent ? (item.activeForm ?? item.text) : item.text
        var attributes = AccountType.attributes(.rowTitle, item.state == .done ? paint.dim : paint.text)
        if item.isCurrent {
            attributes[.font] = NSFont.systemFont(ofSize: AccountType.font(.rowTitle).pointSize, weight: .semibold)
        }
        return NSAttributedString(string: words, attributes: attributes)
    }

    private var rowHeights: [CGFloat] = []

    override func fit(width: CGFloat) -> CGFloat {
        textWidth = max(width - 14 - 16 - 10 - 14, 40)
        var y: CGFloat = 6 + 24
        rowHeights = []
        if showsItems {
            y += 4
            for item in shownItems {
                let h = max(24, AccountType.height(itemText(item), width: textWidth) + 4)
                rowHeights.append(h)
                y += h
            }
            if plan.items.count > Self.itemLimit { y += 20 }
        }
        y += 8
        setFrameSize(NSSize(width: width, height: y))
        needsDisplay = true
        return y
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.y <= 6 + 24 + 4 { onToggle?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onToggle?()
        return true
    }

    override func resetCursorRects() {
        addCursorRect(CGRect(x: 0, y: 0, width: bounds.width, height: 34), cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        paint.raised.withAlphaComponent(0.7).setFill()
        shape.fill()
        let mid: CGFloat = 6 + 12
        var x: CGFloat = 14
        AccountType.draw(showsItems ? "\u{25BE}" : "\u{25B8}", .rowStamp, paint.dim, x: x, midY: mid)
        x += 14
        x += AccountType.draw(AccountWords.plan, .sectionLabel, paint.dim, x: x, midY: mid) + 10
        x += AccountType.draw(plan.label, .rowTitleStrong, paint.text, x: x, midY: mid) + 12
        let fraction = plan.total == 0 ? 0 : CGFloat(plan.done) / CGFloat(plan.total)
        if compact {
            let count = max(1, plan.items.count)
            let total = min(110, max(40, CGFloat(count) * 16))
            let gap: CGFloat = 3
            let w = (total - gap * CGFloat(count - 1)) / CGFloat(count)
            for (index, item) in plan.items.enumerated() {
                let rect = NSRect(x: x + CGFloat(index) * (w + gap), y: mid - 2, width: w, height: 4)
                let color: NSColor
                switch item.state {
                case .done: color = paint.accent
                case .inProgress: color = paint.accent.withAlphaComponent(0.6)
                case .pending: color = paint.mix(paint.canvas, paint.dim, 0.4)
                }
                color.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            }
            x += total + 12
            if let current = plan.current {
                paint.accent.setFill()
                AccountGlyphs.dot(cx: x + 4, cy: mid, radius: 3.4)
                AccountType.draw(
                    current.activeForm ?? current.text, .rowTitle, paint.text, x: x + 14, midY: mid,
                    maxWidth: max(bounds.width - x - 14 - 14, 20))
            }
        } else {
            let track = NSRect(x: x, y: mid - 2, width: 160, height: 4)
            paint.mix(paint.canvas, paint.accent, 0.16).setFill()
            NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
            if fraction > 0 {
                paint.accent.setFill()
                NSBezierPath(
                    roundedRect: NSRect(x: x, y: mid - 2, width: max(4, 160 * fraction), height: 4), xRadius: 2,
                    yRadius: 2
                ).fill()
            }
        }
        guard showsItems else { return }
        var y: CGFloat = 6 + 24 + 4
        for (index, item) in shownItems.enumerated() {
            let h = rowHeights.indices.contains(index) ? rowHeights[index] : 24
            AccountGlyphs.planMark(item.state, cx: 14 + 8, cy: y + 12, paint: paint)
            itemText(item).draw(
                with: NSRect(x: 14 + 16 + 10, y: y + 2, width: textWidth, height: h - 2),
                options: [.usesLineFragmentOrigin], context: nil)
            y += h
        }
        if plan.items.count > Self.itemLimit {
            AccountType.draw(
                AccountWords.moreClauses(plan.items.count - Self.itemLimit), .rowStamp, paint.dim, x: 14 + 26,
                midY: y + 10)
        }
    }
}
