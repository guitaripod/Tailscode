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
