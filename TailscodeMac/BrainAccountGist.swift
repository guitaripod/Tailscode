import AppKit
import TailscodeCore

/// The two parts of the header's switch: the turn in short, and what the agent told with how much
/// of it is showing. It is there only while a telling is, so a turn nobody told keeps its header.
@MainActor
final class AccountGistSwitch: NSView {
    private var paint: AccountPaint
    private var short = ""
    private var told = ""
    private var showsShort = true
    private var shortWidth: CGFloat = 0
    var onChoose: ((Bool) -> Void)?

    init(paint: AccountPaint) {
        self.paint = paint
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    /// Takes the words and answers with the width they need.
    @discardableResult
    func configure(short: String, told: String, showsShort: Bool, tip: String, paint: AccountPaint) -> CGFloat {
        self.short = short
        self.told = told
        self.showsShort = showsShort
        self.paint = paint
        toolTip = tip
        shortWidth = AccountType.width(short, .control) + 24
        let width = shortWidth + AccountType.width(told, .control) + 24
        setFrameSize(NSSize(width: width, height: 24))
        setAccessibilityLabel(showsShort ? short : told)
        needsDisplay = true
        return width
    }

    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        paint.rule2.setStroke()
        outline.lineWidth = 1
        outline.stroke()
        let chosen = showsShort
            ? NSRect(x: 1, y: 1, width: shortWidth - 1, height: bounds.height - 2)
            : NSRect(x: shortWidth, y: 1, width: bounds.width - shortWidth - 1, height: bounds.height - 2)
        let tone = showsShort ? paint.special : paint.accent
        tone.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: chosen, xRadius: 11, yRadius: 11).fill()
        AccountType.draw(short, .control, showsShort ? paint.special : paint.dim, x: 12, midY: bounds.midY)
        AccountType.draw(told, .control, showsShort ? paint.dim : paint.accent, x: shortWidth + 12, midY: bounds.midY)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onChoose?(point.x < shortWidth)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// The turn in short, standing where the story would be: the model's title and sentence, the step
/// in flight on one line, the rail, and a row a stage with what the turn counts there. While a
/// stage is open it is the way back instead: the rail with that stage lit, and the stage's words.
/// Every word and number is `NeuralGistPane`'s; this draws them and says which row was pressed.
@MainActor
final class AccountGistView: AccountBlock {
    struct Content: Equatable {
        var pane: NeuralGistPane
        /// The stage that is open, by its place; nil while the telling stands in the story's place.
        var open: Int?
        var cursor: Int?
        /// What the turn's own counts say, shown while the first telling is written.
        var fallback: String
        var liveTitle: String?
        var liveArgument = ""
        var liveSince: String?
        var liveSilent = false
        var result = ""
        /// Only the title and the sentence, for an account too narrow to hold the stages.
        var headOnly = false
        var palette: String
    }

    private var content: Content
    private var paint: AccountPaint
    private var sentence: NSAttributedString?
    private var sentenceRect = CGRect.zero
    private var liveY: CGFloat?
    private var railRect = CGRect.zero
    private var rowRects: [CGRect] = []
    private var backRect = CGRect.zero
    private var resultY: CGFloat?
    private var hovered: Int?
    private let pulse = AccountPulseDot()
    var onOpen: ((Int) -> Void)?
    var onBack: (() -> Void)?

    static let rowHeight: CGFloat = 34

    init(content: Content, paint: AccountPaint) {
        self.content = content
        self.paint = paint
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(pulse)
        pulse.isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        describe()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Takes what there is to say now; true when the room it needs may have changed.
    @discardableResult
    func show(_ next: Content, paint: AccountPaint) -> Bool {
        guard next != content else { return false }
        let before = content
        content = next
        self.paint = paint
        describe()
        needsDisplay = true
        var same = before
        same.cursor = next.cursor
        same.liveSince = next.liveSince
        same.liveArgument = next.liveArgument
        same.liveTitle = next.liveTitle == nil ? before.liveTitle : next.liveTitle
        return same != next || (before.liveTitle == nil) != (next.liveTitle == nil)
    }

    private func describe() {
        let pane = content.pane
        var words = [NeuralGistWords.title, pane.title, pane.now]
        words += pane.rows.map { "\($0.says). \($0.facts(of: pane.rows.count))" }
        words.append(NeuralGistWords.provenance(writer: pane.byline, place: ""))
        setAccessibilityLabel(words.filter { !$0.isEmpty }.joined(separator: ". "))
    }

    override func fit(width: CGFloat) -> CGFloat {
        let pane = content.pane
        rowRects = []
        backRect = .zero
        sentence = nil
        liveY = nil
        resultY = nil
        var y: CGFloat = 4
        if let open = content.open, pane.rows.indices.contains(open) {
            railRect = CGRect(x: 0, y: y, width: width, height: 22)
            y += 22
            let back = "\u{2039} \(NeuralGistWords.backToShort)"
            backRect = CGRect(x: 0, y: y, width: AccountType.width(back, .control) + 8, height: 24)
            y += 24 + 2
            pulse.isHidden = true
            setFrameSize(NSSize(width: width, height: y))
            needsDisplay = true
            return y
        }
        y += 18 + 6
        let words = pane.isWriting ? content.fallback : pane.now
        let text = AccountType.string(words, .lead, pane.isWriting ? paint.dim : paint.text)
        let height = AccountType.height(text, width: width, maxLines: content.headOnly ? 2 : 3)
        sentence = text
        sentenceRect = CGRect(x: 0, y: y, width: width, height: height)
        y += height
        if content.liveTitle != nil {
            y += 8
            liveY = y
            pulse.isHidden = false
            pulse.configure(
                color: content.liveSilent ? paint.warn : paint.accent, motion: content.liveSilent ? .still : .breath,
                diameter: 7)
            pulse.frame.origin = CGPoint(x: 0, y: y + (22 - pulse.frame.height) / 2)
            y += 22
        } else {
            pulse.isHidden = true
        }
        if content.headOnly {
            railRect = .zero
            y += 4
            setFrameSize(NSSize(width: width, height: y))
            needsDisplay = true
            return y
        }
        y += 10
        railRect = CGRect(x: 0, y: y, width: width, height: 22)
        y += 22
        let count = pane.isWriting ? 3 : pane.rows.count
        for _ in 0..<count {
            rowRects.append(CGRect(x: -10, y: y, width: width + 20, height: Self.rowHeight))
            y += Self.rowHeight
        }
        if !content.result.isEmpty {
            y += 10
            resultY = y
            y += 10 + 20
        }
        y += 4
        setFrameSize(NSSize(width: width, height: y))
        needsDisplay = true
        return y
    }

    override func draw(_ dirtyRect: NSRect) {
        let pane = content.pane
        if let open = content.open, pane.rows.indices.contains(open) {
            drawRail(selected: open)
            let row = pane.rows[open]
            let mid = backRect.midY
            let back = "\u{2039} \(NeuralGistWords.backToShort)"
            var x = AccountType.draw(back, .control, paint.special, x: 0, midY: mid) + 12
            let facts = row.facts(of: pane.rows.count)
            let factsWidth = AccountType.width(facts, .rowStamp)
            AccountType.draw(facts, .rowStamp, paint.dim, x: bounds.width, midY: mid, rightAligned: true)
            x += AccountType.draw(
                "\(NeuralGistWords.mark) \(row.says)", .rowTitleStrong, paint.text, x: x, midY: mid,
                maxWidth: max(bounds.width - x - factsWidth - 12, 20))
            return
        }
        let byWidth = AccountType.draw(pane.byline, .rowStamp, paint.dim, x: bounds.width, midY: 4 + 9, rightAligned: true)
        AccountType.draw(
            "\(NeuralGistWords.mark) \(pane.title.uppercased())", .sectionLabel,
            pane.isWriting ? paint.dim : paint.special, x: 0, midY: 4 + 9, maxWidth: max(bounds.width - byWidth - 16, 40))
        sentence?.draw(
            with: sentenceRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        if let liveY, let title = content.liveTitle {
            let mid = liveY + 11
            let tone = content.liveSilent ? paint.warn : paint.accent
            var x: CGFloat = 7 + 8
            x += AccountType.draw(NeuralReading.nowLabel, .sectionLabel, tone, x: x, midY: mid) + 10
            var right = bounds.width
            if let since = content.liveSince {
                right -= AccountType.draw(since, .rowStamp, content.liveSilent ? paint.warn : paint.dim, x: right, midY: mid, rightAligned: true) + 12
            }
            x += AccountType.draw(title, .rowTitleStrong, paint.text, x: x, midY: mid, maxWidth: max(right - x, 20)) + 8
            if !content.liveArgument.isEmpty, right - x > 40 {
                AccountType.draw(content.liveArgument, .toolDetail, paint.dim, x: x, midY: mid, maxWidth: right - x)
            }
        }
        if content.headOnly { return }
        drawRail(selected: nil)
        if pane.isWriting {
            for (index, rect) in rowRects.enumerated() {
                paint.dim.withAlphaComponent(0.16).setFill()
                NSBezierPath(ovalIn: NSRect(x: 0, y: rect.midY - 9, width: 18, height: 18)).fill()
                let share: CGFloat = [0.62, 0.48, 0.55][index % 3]
                NSBezierPath(
                    roundedRect: NSRect(x: 30, y: rect.midY - 6, width: max(120, bounds.width * share), height: 12),
                    xRadius: 6, yRadius: 6
                ).fill()
            }
            return
        }
        for (index, row) in pane.rows.enumerated() where rowRects.indices.contains(index) {
            drawRow(row, in: rowRects[index], lit: content.cursor == index, hovered: hovered == index)
        }
        if let resultY {
            paint.rule.setFill()
            NSRect(x: 0, y: resultY, width: bounds.width, height: 1).fill()
            AccountType.draw(content.result, .rowTitle, paint.dim, x: 0, midY: resultY + 10 + 10, maxWidth: bounds.width)
        }
    }

    private func drawRow(_ row: NeuralGistPane.Row, in rect: CGRect, lit: Bool, hovered: Bool) {
        if lit || hovered {
            paint.accent.withAlphaComponent(lit ? 0.12 : 0.08).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        }
        let mid = rect.midY
        let mark = NSRect(x: 0, y: mid - 9, width: 18, height: 18)
        switch row.mark {
        case .done:
            paint.info.setFill()
            NSBezierPath(ovalIn: mark).fill()
            AccountGlyphs.verdict(.done, cx: mark.midX, cy: mid, size: 12, color: paint.canvas)
        case .now:
            paint.accent.withAlphaComponent(0.18).setFill()
            NSBezierPath(ovalIn: mark).fill()
            paint.accent.setFill()
            NSBezierPath(ovalIn: NSRect(x: mark.midX - 3.5, y: mid - 3.5, width: 7, height: 7)).fill()
        }
        var right = bounds.width
        let steps = AccountType.draw(row.stepsWords, .rowStamp, paint.dim, x: right, midY: mid, rightAligned: true)
        right -= max(steps, 64) + 12
        if let cost = row.costWords {
            right -= max(AccountType.draw(cost, .rowStamp, paint.text, x: right, midY: mid, rightAligned: true), 56) + 12
        }
        if let tally = row.tally {
            right -= AccountType.draw(tally, .rowStamp, paint.dim, x: right, midY: mid, rightAligned: true) + 12
        }
        if let fixed = row.fixedWords {
            right -= AccountType.draw(fixed, .rowStamp, paint.warn, x: right, midY: mid, rightAligned: true) + 12
        }
        if let failed = row.failedWords {
            right -= AccountType.draw(failed, .rowStamp, paint.danger, x: right, midY: mid, rightAligned: true) + 12
        }
        if row.mark == .now {
            right -= AccountType.draw(NeuralReading.nowLabel, .sectionLabel, paint.accent, x: right, midY: mid, rightAligned: true) + 12
        }
        AccountType.draw(
            row.says, row.mark == .now ? .rowTitleStrong : .rowTitle, paint.text, x: 30, midY: mid,
            maxWidth: max(right - 30, 40))
    }

    /// The rail: a stretch a stage, as long as its share of the steps, with a tick where an error
    /// was fixed and a taller one where it stayed.
    private func drawRail(selected: Int?) {
        let pane = content.pane
        let thick: CGFloat = 6
        let top = railRect.midY - thick / 2
        guard !pane.rows.isEmpty else {
            paint.dim.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: top, width: railRect.width, height: thick), xRadius: 3, yRadius: 3).fill()
            return
        }
        let gap: CGFloat = 3
        let usable = railRect.width - gap * CGFloat(pane.rows.count - 1)
        var x: CGFloat = 0
        for row in pane.rows {
            let length = max(4, usable * CGFloat(row.weight))
            if let selected {
                (selected == row.index ? paint.special : paint.dim.withAlphaComponent(0.22)).setFill()
            } else {
                (row.mark == .now ? paint.accent : paint.info.withAlphaComponent(0.6)).setFill()
            }
            NSBezierPath(roundedRect: NSRect(x: x, y: top, width: length, height: thick), xRadius: 3, yRadius: 3).fill()
            if selected == nil || selected == row.index {
                for tick in row.ticks {
                    let tall: CGFloat = tick.failed ? 16 : 12
                    (tick.failed ? paint.danger : paint.warn).setFill()
                    NSBezierPath(
                        roundedRect: NSRect(
                            x: x + length * CGFloat(tick.at) - 1, y: railRect.midY - tall / 2, width: 2, height: tall),
                        xRadius: 1, yRadius: 1
                    ).fill()
                }
            }
            x += length + gap
        }
    }

    private func row(at point: NSPoint) -> Int? {
        guard content.open == nil, !content.pane.isWriting else { return nil }
        return rowRects.firstIndex { $0.contains(point) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        if content.open != nil { return backRect.contains(local) ? self : nil }
        return row(at: local) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if content.open != nil {
            if backRect.contains(point) { onBack?() }
            return
        }
        if let index = row(at: point) { onOpen?(index) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let next = row(at: convert(event.locationInWindow, from: nil))
        guard next != hovered else { return }
        hovered = next
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard hovered != nil else { return }
        hovered = nil
        needsDisplay = true
    }

    override func resetCursorRects() {
        if content.open != nil {
            addCursorRect(backRect, cursor: .pointingHand)
            return
        }
        guard !content.pane.isWriting else { return }
        for rect in rowRects { addCursorRect(rect, cursor: .pointingHand) }
    }
}

/// The turn in short on the account's side of an open Megatron: what the desk holds for the turn,
/// which stage the keys are on, and a stage's part of the account when one is opened.
extension BrainAccountView {
    var gistTurnKey: String { host?.turnID ?? "" }

    /// The telling leads the account: its title and sentence stand above everything else.
    var gistLeads: Bool { gistPane != nil && !gistTold && gistScope == nil }

    /// The telling stands in the story's place, stages and all. A narrow account has no room for
    /// that: there the telling only leads, and the story stays under it.
    var showsShort: Bool { gistLeads && !isAccordion }

    func observeGist() {
        gistObserver = NotificationCenter.default.addObserver(
            forName: NeuralGistDesk.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainThread.call { self?.gistChanged() }
        }
        syncGistPane()
    }

    /// Says the turn is on screen as it stands, and takes what the desk holds for it.
    func gistWant() {
        guard let host else { return }
        NeuralGistDemo.placeIfNeeded(key: gistTurnKey, model: host.model)
        NeuralGistDesk.shared.want(key: gistTurnKey, model: host.model, answer: answerOrNil, prompt: promptText)
        syncGistPane()
    }

    func gistChanged() {
        guard syncGistPane() else { return }
        readStamp = nil
        refresh(immediate: true)
    }

    @discardableResult
    func syncGistPane() -> Bool {
        guard let host else { return false }
        let next = NeuralGistPane.make(reading: NeuralGistDesk.shared.reading(for: gistTurnKey), model: host.model)
        guard next != gistPane else { return false }
        gistPane = next
        if let next {
            if let scope = gistScope { gistScope = next.row(containing: scope.lowerBound)?.numbers }
            if let cursor = gistCursor { gistCursor = next.rows.isEmpty ? nil : min(cursor, next.rows.count - 1) }
        } else {
            gistScope = nil
            gistCursor = nil
        }
        return true
    }

    /// The header's switch and the room it takes: none while nothing is told.
    func refreshGistSwitch() -> CGFloat {
        guard let pane = gistPane, !isAccordion else {
            gistSwitch?.removeFromSuperview()
            gistSwitch = nil
            return 0
        }
        let view: AccountGistSwitch
        if let held = gistSwitch {
            view = held
        } else {
            view = AccountGistSwitch(paint: paint)
            view.onChoose = { [weak self] short in self?.gistShow(short: short) }
            addSubview(view)
            gistSwitch = view
        }
        let total = fullAccount.utteranceCount
        let shown = gistScope == nil ? total : account.utteranceCount
        return view.configure(
            short: "\(NeuralGistWords.mark) \(NeuralGistWords.title)",
            told: NeuralGistWords.told(shown, of: gistScope == nil ? nil : total), showsShort: showsShort,
            tip: NeuralGistWords.provenance(writer: pane.byline, place: ""), paint: paint)
    }

    /// Makes the telling's block say what there is to say now, or takes it away.
    func refreshGistPin(vitals: NeuralAccount.Vitals, hasAsk: Bool) {
        guard let pane = gistPane, gistLeads || gistScope != nil else {
            if gistView != nil {
                gistView?.removeFromSuperview()
                gistView = nil
                needsLayout = true
            }
            return
        }
        var content = AccountGistView.Content(
            pane: pane, open: gistScope.flatMap { pane.row(containing: $0.lowerBound)?.index }, cursor: gistCursor,
            fallback: fullAccount.vitals(now: Date(), lastActivity: lastActivityAt).counts,
            palette: paint.inks.palette.name)
        content.headOnly = gistLeads && !showsShort
        if gistLeads {
            if !hasAsk, let live = fullAccount.live {
                content.liveTitle = live.title
                content.liveArgument = live.argument
                content.liveSilent = vitals.isSilent
                content.liveSince = vitals.isSilent ? vitals.silentWords : vitals.lastOutputWords
            }
            if showsShort { content.result = gistResultWords() }
        }
        if let view = gistView {
            if view.show(content, paint: paint) { needsLayout = true }
            return
        }
        let view = AccountGistView(content: content, paint: paint)
        view.onOpen = { [weak self] index in self?.gistOpen(index) }
        view.onBack = { [weak self] in self?.gistBack() }
        view.alphaValue = bodyAlpha
        addSubview(view, positioned: .above, relativeTo: scroll)
        gistView = view
        needsLayout = true
    }

    private func gistResultWords() -> String { NeuralGistWords.result(of: fullAccount) }

    func gistShow(short: Bool) {
        guard gistPane != nil else { return }
        gistTold = !short
        gistScope = nil
        gistApplied()
    }

    func gistToggle() {
        guard gistPane != nil else { return }
        gistShow(short: !gistLeads)
    }

    /// Opens a stage: the account's part of it, with the cursor on its first step so the list and
    /// the head show where it is.
    func gistOpen(_ index: Int) {
        guard let pane = gistPane, pane.rows.indices.contains(index) else { return }
        let row = pane.rows[index]
        gistCursor = index
        gistScope = row.numbers
        gistApplied()
        if let step = host?.model.firstVisibleStep(in: row.numbers) { choose(step, fromAccount: true) }
    }

    func gistBack() {
        guard gistScope != nil else { return }
        gistScope = nil
        gistTold = false
        gistApplied()
    }

    func gistNeighbour(_ delta: Int) {
        guard let pane = gistPane, let scope = gistScope, let row = pane.row(containing: scope.lowerBound),
            let next = pane.index(moving: delta, from: row.index), next != row.index
        else { return }
        gistOpen(next)
    }

    func gistMove(_ delta: Int) {
        guard let pane = gistPane, showsShort, let next = pane.index(moving: delta, from: gistCursor) else { return }
        gistCursor = next
        refreshPins()
    }

    private func gistApplied() {
        readStamp = nil
        scroll.contentView.scroll(to: .zero)
        refresh(immediate: true)
        refreshChrome()
        needsLayout = true
        window?.makeFirstResponder(self)
    }

    /// What a key does to the telling, before the account sees it. False for a key that is the
    /// account's.
    func gistKey(_ key: NeuralBrowse.Key) -> Bool {
        guard gistPane != nil else { return false }
        if key == .character("i") {
            gistToggle()
            return true
        }
        if showsShort {
            switch key {
            case .up, .character("k"): gistMove(-1)
            case .down, .character("j"): gistMove(1)
            case .home: gistMove(-NeuralGistPolicy.mostStages)
            case .end: gistMove(NeuralGistPolicy.mostStages)
            case .enter, .right:
                guard let pane = gistPane, !pane.rows.isEmpty else { return true }
                gistOpen(gistCursor ?? pane.rows.count - 1)
            default: return false
            }
            return true
        }
        guard gistScope != nil else { return false }
        switch key {
        case .escape: gistBack()
        case .character("["): gistNeighbour(-1)
        case .character("]"): gistNeighbour(1)
        default: return false
        }
        return true
    }
}
