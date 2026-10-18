import AppKit
import CodingAgentKit
import TailscodeCore

/// The title of a step with the one button that belongs to it: Copy for a command or a path, Open
/// agent for a subagent.
@MainActor
final class AccountTitleRow: AccountBlock {
    private let title: String
    private let paint: AccountPaint
    let button: AccountButton?

    init(title: String, button: AccountButton?, paint: AccountPaint) {
        self.title = title
        self.button = button
        self.paint = paint
        super.init(frame: .zero)
        if let button { addSubview(button) }
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func fit(width: CGFloat) -> CGFloat {
        let height = max(24, AccountType.lineHeight(.cardTitle))
        setFrameSize(NSSize(width: width, height: height))
        if let button {
            let size = button.fittingSize
            button.frame = CGRect(x: width - size.width, y: (height - size.height) / 2, width: size.width, height: size.height)
        }
        needsDisplay = true
        return height
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let found = super.hitTest(point)
        return found === self ? nil : found
    }

    override func draw(_ dirtyRect: NSRect) {
        let room = bounds.width - (button?.frame.width ?? 0) - 12
        AccountType.draw(title, .cardTitle, paint.text, x: 0, midY: bounds.midY, maxWidth: room)
    }
}

/// Words limited to a few lines, with the link that lets the rest out in place, shown only when
/// the words really were cut at the width they are laid out in.
@MainActor
final class AccountClampBlock: AccountBlock {
    let text: AccountTextBlock
    private let link = AccountButtonFlow()
    private let limit: Int
    private(set) var expanded = false

    init(text: AccountTextBlock, limit: Int, linkTitle: String, host: BrainSurfaceHost?, paint: AccountPaint) {
        self.text = text
        self.limit = limit
        super.init(frame: .zero)
        addSubview(text)
        addSubview(link)
        let button = AccountButton(title: linkTitle, style: .link, paint: paint)
        button.host = host
        button.onTap = { [weak self] in
            self?.expanded = true
            self?.onHeight?()
        }
        link.set([button])
        link.isHidden = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func fit(width: CGFloat) -> CGFloat {
        text.maxLines = expanded ? 0 : limit
        let height = text.fit(width: width)
        text.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let natural = AccountType.height(text.text, width: max(width - text.inset, 1))
        let clamped = !expanded && natural > height + 1
        link.isHidden = !clamped
        var total = height
        if clamped {
            let linkHeight = link.fit(width: width)
            link.frame = CGRect(x: 0, y: height + 2, width: width, height: linkHeight)
            total = height + 2 + linkHeight
        }
        setFrameSize(NSSize(width: width, height: total))
        return total
    }
}

/// A sentence with a verdict's mark before it: what a fixed step says it did.
@MainActor
final class AccountNoteBlock: AccountBlock {
    let text: AccountTextBlock
    private let glyph: NeuralVerdict.Step
    private let paint: AccountPaint

    init(text: AccountTextBlock, glyph: NeuralVerdict.Step, paint: AccountPaint) {
        self.text = text
        self.glyph = glyph
        self.paint = paint
        super.init(frame: .zero)
        text.inset = 0
        addSubview(text)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func fit(width: CGFloat) -> CGFloat {
        let height = text.fit(width: max(width - 22, 20))
        text.frame = CGRect(x: 22, y: 0, width: max(width - 22, 20), height: height)
        setFrameSize(NSSize(width: width, height: height))
        needsDisplay = true
        return height
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let found = super.hitTest(point)
        return found === self ? nil : found
    }

    override func draw(_ dirtyRect: NSRect) {
        let line = AccountType.lineHeight(.toolDetail)
        AccountGlyphs.verdict(glyph, cx: 8, cy: line / 2 + 1, size: 13, color: paint.verdict(glyph))
    }
}

/// A quotation: a rule at the left in the zone's tone, a small label, the words, and the link that
/// opens the rest of them in place.
@MainActor
final class AccountQuoteBlock: AccountBlock {
    private let label: String
    private let tone: NSColor
    private let paint: AccountPaint
    private let text: AccountTextBlock
    private let link: AccountButtonFlow
    private var full: NSAttributedString?

    init(
        label: String, tone: NSColor, words: String, full: String?, host: BrainSurfaceHost?,
        paint: AccountPaint
    ) {
        self.label = label
        self.tone = tone
        self.paint = paint
        text = AccountTextBlock(
            text: AccountType.string(words, .thought, paint.text), host: host, paint: paint)
        link = AccountButtonFlow()
        self.full = full.map { AccountType.string($0, .thought, paint.text) }
        super.init(frame: .zero)
        addSubview(text)
        addSubview(link)
        if full != nil {
            let button = AccountButton(title: NeuralReading.showMoreLabel, style: .link, paint: paint)
            button.host = host
            button.onTap = { [weak self] in
                guard let self, let full = self.full else { return }
                self.text.text = full
                self.link.isHidden = true
                self.full = nil
                self.onHeight?()
            }
            link.set([button])
        } else {
            link.isHidden = true
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func fit(width: CGFloat) -> CGFloat {
        let inner = max(width - 14, 20)
        var y: CGFloat = 16 + 2
        let textHeight = text.fit(width: inner)
        text.frame = CGRect(x: 14, y: y, width: inner, height: textHeight)
        y += textHeight
        if !link.isHidden {
            let height = link.fit(width: inner)
            link.frame = CGRect(x: 14, y: y + 2, width: inner, height: height)
            y += 2 + height
        }
        setFrameSize(NSSize(width: width, height: y))
        needsDisplay = true
        return y
    }

    override func draw(_ dirtyRect: NSRect) {
        tone.setFill()
        NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
        AccountType.draw(label, .sectionLabel, tone, x: 14, midY: 8, maxWidth: bounds.width - 14)
    }
}

/// The chips of the zones a turn used, in the card's own order.
@MainActor
final class AccountZoneChips: AccountBlock {
    private let chips: [NeuralBrainCard.ZoneChip]
    private let paint: AccountPaint
    private var frames: [CGRect] = []

    init(chips: [NeuralBrainCard.ZoneChip], paint: AccountPaint) {
        self.chips = chips
        self.paint = paint
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(chips.map { "\($0.label) \($0.count)" }.joined(separator: ", "))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func words(_ chip: NeuralBrainCard.ZoneChip) -> String {
        chip.zone == .say ? "\(chip.label) \(chip.count)" : "\(chip.count)"
    }

    override func fit(width: CGFloat) -> CGFloat {
        var x: CGFloat = 0
        var y: CGFloat = 0
        frames = []
        for chip in chips {
            let w = 8 + 14 + 5 + AccountType.width(words(chip), .rowStamp) + 9
            if x > 0, x + w > width {
                x = 0
                y += 22 + 6
            }
            frames.append(CGRect(x: x, y: y, width: w, height: 22))
            x += w + 6
        }
        let height = chips.isEmpty ? 0 : y + 22
        setFrameSize(NSSize(width: width, height: height))
        needsDisplay = true
        return height
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        for (index, chip) in chips.enumerated() where index < frames.count {
            let rect = frames[index].insetBy(dx: 0.5, dy: 0.5)
            let tone: NSColor
            switch chip.tone {
            case .danger: tone = paint.danger
            case .attention: tone = paint.warn
            default: tone = paint.zone(chip.zone)
            }
            let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
            (chip.zone == .say ? paint.accent : paint.rule2).setStroke()
            path.lineWidth = 1
            path.stroke()
            AccountGlyphs.zone(chip.zone, cx: rect.minX + 8 + 7, cy: rect.midY, color: tone, radius: 5)
            AccountType.draw(
                words(chip), .rowStamp, chip.zone == .say ? paint.accent : paint.text, x: rect.minX + 8 + 14 + 5,
                midY: rect.midY)
        }
    }
}

/// A row of the digest's zone bars: a name, a bar as long as the zone is busy, a count; a press
/// dives the head into the zone.
@MainActor
final class AccountZoneBarRow: AccountBlock {
    private let bar: NeuralReadout.ZoneBar
    private let paint: AccountPaint
    private let track: AccountBarView
    var onPress: (() -> Void)?
    private var hovered = false
    private var tracking: NSTrackingArea?

    init(bar: NeuralReadout.ZoneBar, paint: AccountPaint) {
        self.bar = bar
        self.paint = paint
        track = AccountBarView(fraction: bar.fraction, color: paint.zone(bar.zone), ground: paint.canvas)
        super.init(frame: .zero)
        addSubview(track)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(bar.label) \(bar.count)")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func fit(width: CGFloat) -> CGFloat {
        setFrameSize(NSSize(width: width, height: 18))
        track.frame = CGRect(x: 82, y: 6, width: max(width - 82 - 38, 20), height: 6)
        needsDisplay = true
        return 18
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self,
            userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }

    override func draw(_ dirtyRect: NSRect) {
        AccountType.draw(bar.label, .sectionLabel, hovered ? paint.text : paint.dim, x: 0, midY: bounds.midY, maxWidth: 74)
        AccountType.draw(
            String(bar.count), .rowStamp, paint.dim, x: bounds.width, midY: bounds.midY, rightAligned: true)
    }
}

/// One tick per step in order, coloured by its zone, failures taller; the answer's end marked.
/// Hovering a tick hovers its step, a press sets the cursor, and a drag across it scrubs.
@MainActor
final class AccountTimelineBlock: AccountBlock {
    private let digest: NeuralReadout.Digest
    private let paint: AccountPaint
    private var hovered: Int?
    private var scrubbing = false
    private var tracking: NSTrackingArea?
    var onHover: ((String?) -> Void)?
    var onPress: ((String) -> Void)?
    var onScrub: ((String) -> Void)?
    var onScrubEnd: (() -> Void)?

    init(digest: NeuralReadout.Digest, paint: AccountPaint) {
        self.digest = digest
        self.paint = paint
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(AccountWords.timeline(digest.ticks.count))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var slots: CGFloat { CGFloat(digest.ticks.count) + (digest.answerBegins == nil ? 0 : 1.6) }

    private func x(_ index: Int) -> CGFloat { (CGFloat(index) + 0.5) / max(1, slots) * bounds.width }

    private func index(at point: CGFloat) -> Int? {
        guard !digest.ticks.isEmpty, bounds.width > 0 else { return nil }
        let raw = Int((point / bounds.width * slots - 0.5).rounded())
        let clamped = min(max(0, raw), digest.ticks.count - 1)
        return abs(x(clamped) - point) <= 7 ? clamped : nil
    }

    override func fit(width: CGFloat) -> CGFloat {
        setFrameSize(NSSize(width: width, height: 32))
        needsDisplay = true
        return 32
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let found = index(at: point.x)
        guard found != hovered else { return }
        hovered = found
        onHover?(found.map { digest.ticks[$0].stepID })
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard hovered != nil, !scrubbing else { return }
        hovered = nil
        onHover?(nil)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        scrubbing = true
        scrub(to: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseDragged(with event: NSEvent) {
        scrub(to: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) {
        guard scrubbing else { return }
        scrubbing = false
        onScrubEnd?()
    }

    private func scrub(to point: CGFloat) {
        guard !digest.ticks.isEmpty, bounds.width > 0 else { return }
        let raw = Int((point / bounds.width * slots - 0.5).rounded())
        let target = min(max(0, raw), digest.ticks.count - 1)
        hovered = target
        onScrub?(digest.ticks[target].stepID)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let baseline = bounds.height - 4
        paint.rule2.setFill()
        NSRect(x: 0, y: baseline, width: bounds.width, height: 1).fill()
        for tick in digest.ticks {
            let center = x(tick.index)
            let tall = tick.isFailure && !tick.isRecovered
            let h: CGFloat = tick.isFailure ? 28 : 14
            let color = tick.isFailure ? (tick.isRecovered ? paint.warn : paint.danger) : paint.zone(tick.zone)
            color.withAlphaComponent(tall || !tick.isFailure ? 1 : 0.85).setFill()
            NSBezierPath(
                roundedRect: NSRect(x: center - 2, y: baseline - h, width: 4, height: h), xRadius: 2, yRadius: 2
            ).fill()
            if hovered == tick.index {
                paint.text.setStroke()
                let ring = NSBezierPath(
                    roundedRect: NSRect(x: center - 3, y: baseline - h - 1, width: 6, height: h + 2), xRadius: 3,
                    yRadius: 3)
                ring.lineWidth = 2
                ring.stroke()
            }
        }
        if let begins = digest.answerBegins {
            let center = x(begins)
            paint.dim.setFill()
            NSRect(x: center, y: 0, width: 1, height: bounds.height).fill()
            AccountType.draw(
                AccountWords.answer, .sectionLabel, paint.dim, x: center - 6, midY: 7, rightAligned: true)
        }
    }
}

/// A failure of the digest: its number, what it was, the first line it printed and whether it
/// was retried.
@MainActor
final class AccountFailureRow: AccountBlock {
    private let failure: NeuralReadout.Failure
    private let paint: AccountPaint
    var onPress: (() -> Void)?
    private var hovered = false
    private var tracking: NSTrackingArea?

    init(failure: NeuralReadout.Failure, paint: AccountPaint) {
        self.failure = failure
        self.paint = paint
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(failure.number) \(failure.title) \(failure.firstLine) \(failure.label)")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func fit(width: CGFloat) -> CGFloat {
        setFrameSize(NSSize(width: width, height: 46))
        return 46
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self,
            userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            paint.text.withAlphaComponent(0.04).setFill()
            bounds.fill()
        }
        paint.rule.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        let numberInk = failure.verdict == .fixed ? paint.warn : paint.danger
        AccountType.draw(String(failure.number), .rowMeta, numberInk, x: 0, midY: 15, maxWidth: 28)
        let label = failure.label
        let labelInk = failure.retriedAt == nil ? paint.danger : paint.accent
        let labelWidth = AccountType.draw(label, .rowMeta, labelInk, x: bounds.width, midY: bounds.midY, rightAligned: true)
        let room = bounds.width - 38 - labelWidth - 12
        AccountType.draw(failure.title, .toolDetail, paint.text, x: 38, midY: 15, maxWidth: room)
        AccountType.draw(failure.firstLine, .rowDetail, paint.dim, x: 38, midY: 32, maxWidth: room)
    }
}

/// A file the turn changed: its path with the file name emphasised, a meter and the tally.
@MainActor
final class AccountChangedRow: AccountBlock {
    private let path: NSAttributedString
    private let tally: NSAttributedString
    private let meter: AccountMeterView
    private let meterWidth: CGFloat
    var onPress: (() -> Void)?
    private var hovered = false
    private var tracking: NSTrackingArea?
    private let paint: AccountPaint

    init(shortDirectory: String, fileName: String, added: Int, removed: Int, paint: AccountPaint) {
        self.paint = paint
        let directory = AccountType.attributes(.toolDetail, paint.dim, lineBreak: .byTruncatingHead)
        let combined = NSMutableAttributedString(string: shortDirectory, attributes: directory)
        var bold = AccountType.attributes(.toolDetail, paint.text, lineBreak: .byTruncatingHead)
        bold[.font] = NSFont.monospacedSystemFont(ofSize: AccountType.font(.toolDetail).pointSize, weight: .bold)
        combined.append(NSAttributedString(string: fileName, attributes: bold))
        path = combined
        let numbers = NSMutableAttributedString(
            string: "+\(added)", attributes: AccountType.attributes(.rowMeta, paint.accent))
        numbers.append(
            NSAttributedString(string: " \u{2212}\(removed)", attributes: AccountType.attributes(.rowMeta, paint.danger)))
        tally = numbers
        meterWidth = CGFloat(min(72, max(12, (added + removed) * 6)))
        meter = AccountMeterView(added: added, removed: removed, paint: paint)
        super.init(frame: .zero)
        addSubview(meter)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(shortDirectory + fileName + " +\(added) -\(removed)")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func fit(width: CGFloat) -> CGFloat {
        setFrameSize(NSSize(width: width, height: 28))
        meter.frame = CGRect(x: width - 56 - 10 - meterWidth, y: 0, width: meterWidth, height: 28)
        needsDisplay = true
        return 28
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self,
            userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            paint.text.withAlphaComponent(0.04).setFill()
            bounds.fill()
        }
        paint.rule.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        let line = AccountType.lineHeight(.toolDetail)
        path.draw(
            with: NSRect(x: 0, y: bounds.midY - line / 2, width: meter.frame.minX - 12, height: line),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        let width = ceil(tally.size().width)
        tally.draw(at: NSPoint(x: bounds.width - width, y: bounds.midY - AccountType.lineHeight(.rowMeta) / 2))
    }
}

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
