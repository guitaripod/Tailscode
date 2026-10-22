import AppKit
import TailscodeCore

/// A piece of the detail card or the detail column: it is laid out at a width and answers with the
/// height it needs, so a page is a stack of blocks and nothing in it is placed by constraints.
@MainActor
class AccountBlock: NSView {
    /// A block that changed its own height (a link unfolded it) asks the page to lay out again.
    var onHeight: (() -> Void)?

    nonisolated override var isFlipped: Bool { true }

    func fit(width: CGFloat) -> CGFloat {
        setFrameSize(NSSize(width: width, height: frame.height))
        return frame.height
    }
}

/// Blocks one under another, each with the air it asks for above it.
@MainActor
final class AccountStack: AccountBlock {
    private(set) var entries: [(view: AccountBlock, before: CGFloat)] = []

    func add(_ block: AccountBlock, before: CGFloat = 0) {
        entries.append((block, before))
        addSubview(block)
        block.onHeight = { [weak self] in self?.onHeight?() }
    }

    func removeAll() {
        for entry in entries { entry.view.removeFromSuperview() }
        entries = []
    }

    var isEmpty: Bool { entries.isEmpty }

    override func fit(width: CGFloat) -> CGFloat {
        var y: CGFloat = 0
        for entry in entries where !entry.view.isHidden {
            y += entry.before
            let height = entry.view.fit(width: width)
            entry.view.frame = CGRect(x: 0, y: y, width: width, height: height)
            y += height
        }
        setFrameSize(NSSize(width: width, height: y))
        return y
    }
}

/// Words that wrap, selectable, with room kept at the left for a mark drawn beside them.
@MainActor
final class AccountTextBlock: AccountBlock {
    let view = AccountTextView()
    var text: NSAttributedString { didSet { dirty = true } }
    var maxLines = 0 { didSet { dirty = true } }
    var inset: CGFloat = 0 { didSet { dirty = true } }
    private var dirty = true

    init(text: NSAttributedString, host: BrainSurfaceHost?, paint: AccountPaint) {
        self.text = text
        super.init(frame: .zero)
        view.host = host
        view.setLinkLook(paint.accent)
        view.setSelectionLook(paint.accent)
        addSubview(view)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func fit(width: CGFloat) -> CGFloat {
        let room = max(width - inset, 1)
        let height = view.set(text, width: room, maxLines: maxLines)
        view.frame = CGRect(x: inset, y: 0, width: room, height: height)
        setFrameSize(NSSize(width: width, height: height))
        return height
    }
}

/// The small caps label over a section, with a quieter value at its right.
@MainActor
final class AccountLabelRow: AccountBlock {
    var label: String { didSet { needsDisplay = true } }
    var tone: NSColor
    var right: NSAttributedString? { didSet { needsDisplay = true } }
    var rightWords: String? { didSet { needsDisplay = true } }
    var dimColor: NSColor

    init(_ label: String, paint: AccountPaint, tone: NSColor? = nil) {
        self.label = label
        self.tone = tone ?? paint.dim
        dimColor = paint.dim
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(label)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func fit(width: CGFloat) -> CGFloat {
        setFrameSize(NSSize(width: width, height: 16))
        return 16
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let used = AccountType.draw(label, .sectionLabel, tone, x: 0, midY: bounds.midY, maxWidth: bounds.width)
        var rightWidth: CGFloat = 0
        if let right {
            rightWidth = ceil(right.size().width)
            let line = AccountType.lineHeight(.rowMeta)
            right.draw(at: NSPoint(x: bounds.width - rightWidth, y: bounds.midY - line / 2))
        } else if let rightWords {
            rightWidth = AccountType.draw(
                rightWords, .rowMeta, dimColor, x: bounds.width, midY: bounds.midY,
                maxWidth: max(bounds.width - used - 12, 1), rightAligned: true)
        }
        _ = rightWidth
    }
}

/// Buttons that wrap onto as many rows as they need.
@MainActor
final class AccountButtonFlow: AccountBlock {
    private(set) var buttons: [AccountButton] = []
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func set(_ next: [AccountButton]) {
        for button in buttons { button.removeFromSuperview() }
        buttons = next
        for button in next { addSubview(button) }
    }

    override func fit(width: CGFloat) -> CGFloat {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for button in buttons {
            let size = button.fittingSize
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            button.frame = CGRect(x: x, y: y, width: min(size.width, width), height: size.height)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        let total = buttons.isEmpty ? 0 : y + rowHeight
        setFrameSize(NSSize(width: width, height: total))
        return total
    }
}

/// A call's printed lines in a box with a rule at its left, and the link that opens all of them
/// in a region that scrolls when it is taller than the card.
@MainActor
final class AccountOutputBlock: AccountBlock {
    struct Line {
        let text: String
        let tone: NeuralReadout.LineTone
    }

    private let paint: AccountPaint
    private let text: AccountTextView
    private var scroller: HandoffScrollView?
    private let link: AccountButton
    private let failed: Bool
    private let caret: Bool
    private var shownLines: [Line]
    private let hiddenCount: Int
    private let moreLabel: String?
    private let allLines: (() -> [Line])?
    private(set) var expanded = false
    static let maxExpanded: CGFloat = 280

    init(
        lines: [Line], hidden: Int, moreLabel: String?, failed: Bool, caret: Bool = false,
        allLines: (() -> [Line])?, host: BrainSurfaceHost?, paint: AccountPaint
    ) {
        self.paint = paint
        self.failed = failed
        self.caret = caret
        shownLines = lines
        self.hiddenCount = hidden
        self.moreLabel = moreLabel
        self.allLines = allLines
        text = AccountTextView()
        link = AccountButton(title: moreLabel ?? "", style: .link, paint: paint)
        super.init(frame: .zero)
        text.host = host
        text.setSelectionLook(paint.accent)
        addSubview(text)
        addSubview(link)
        link.host = host
        link.isHidden = !canExpand
        link.onTap = { [weak self] in self?.toggle() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var canExpand: Bool { hiddenCount > 0 && moreLabel != nil && allLines != nil }

    func toggle() {
        guard canExpand else { return }
        expanded.toggle()
        link.title = expanded ? Localized.text("Show fewer lines") : (moreLabel ?? "")
        onHeight?()
    }

    func setExpanded(_ value: Bool) {
        guard value != expanded, canExpand else { return }
        toggle()
    }

    /// Replaces the lines a running call has printed so far, in place.
    func update(lines: [Line]) {
        shownLines = lines
        onHeight?()
    }

    private var lines: [Line] { expanded ? (allLines?() ?? shownLines) : shownLines }

    private func attributed(_ lines: [Line]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            var attributes = AccountType.attributes(.toolOutput, paint.dim)
            switch line.tone {
            case .dim: attributes[.foregroundColor] = failed ? paint.dangerText : paint.dim
            case .danger: attributes[.foregroundColor] = paint.dangerText
            case .emphasis:
                attributes[.foregroundColor] = paint.text
                attributes[.font] = NSFont.monospacedSystemFont(
                    ofSize: AccountType.font(.toolOutput).pointSize, weight: .bold)
            }
            let value = line.text.isEmpty ? " " : line.text
            result.append(NSAttributedString(string: value + (index < lines.count - 1 || caret ? "\n" : ""), attributes: attributes))
        }
        if caret {
            var attributes = AccountType.attributes(.toolOutput, paint.dim)
            attributes[.backgroundColor] = paint.accent
            result.append(NSAttributedString(string: " ", attributes: attributes))
        }
        return result
    }

    override func fit(width: CGFloat) -> CGFloat {
        let inner = max(width - 12, 1)
        let words = attributed(lines)
        scroller?.removeFromSuperview()
        scroller = nil
        let textHeight = text.set(words, width: inner)
        var box = textHeight + 16
        if expanded, textHeight > Self.maxExpanded - 16 {
            let region = Self.maxExpanded - 16
            let scroll = HandoffScrollView(frame: CGRect(x: 12, y: 8, width: inner, height: region))
            text.removeFromSuperview()
            text.frame = CGRect(x: 0, y: 0, width: inner, height: textHeight)
            scroll.documentView = text
            addSubview(scroll)
            scroller = scroll
            box = Self.maxExpanded
        } else {
            if text.superview !== self { addSubview(text) }
            text.frame = CGRect(x: 12, y: 8, width: inner, height: textHeight)
        }
        var total = box
        if !link.isHidden {
            let size = link.fittingSize
            link.frame = CGRect(x: 0, y: box + 6, width: size.width, height: size.height)
            total = box + 6 + size.height
        }
        setFrameSize(NSSize(width: width, height: total))
        boxHeight = box
        needsDisplay = true
        return total
    }

    private var boxHeight: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        (failed ? paint.danger : paint.rule2).setFill()
        NSRect(x: 0, y: 0, width: 1, height: boxHeight).fill()
    }
}

/// The first lines of an edit as a diff: removed lines on a danger wash, added on an accent wash,
/// the sign in a narrow column, long lines wrapped and never cut.
@MainActor
final class AccountDiffLinesView: NSView {
    private let lines: [NeuralReadout.DiffLine]
    private let paint: AccountPaint
    private var heights: [CGFloat] = []

    init(lines: [NeuralReadout.DiffLine], paint: AccountPaint) {
        self.lines = lines
        self.paint = paint
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(
            lines.map { ($0.kind == .add ? "+ " : $0.kind == .remove ? "- " : "") + $0.text }.joined(separator: "\n"))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    private func attributed(_ line: NeuralReadout.DiffLine) -> NSAttributedString {
        AccountType.string(line.text.isEmpty ? " " : line.text, .diff, paint.text)
    }

    func fit(width: CGFloat) -> CGFloat {
        let room = max(width - 22 - 8, 1)
        heights = lines.map { max(AccountType.lineHeight(.diff), AccountType.height(attributed($0), width: room)) }
        let total = heights.reduce(0, +) + 2
        setFrameSize(NSSize(width: width, height: total))
        needsDisplay = true
        return total
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(
            roundedRect: NSRect(x: 0.5, y: 0.5, width: bounds.width - 1, height: bounds.height - 1), xRadius: 6, yRadius: 6)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        var y: CGFloat = 1
        for (index, line) in lines.enumerated() {
            let height = heights[index]
            switch line.kind {
            case .add:
                paint.accent.withAlphaComponent(0.14).setFill()
                NSRect(x: 0, y: y, width: bounds.width, height: height).fill()
            case .remove:
                paint.danger.withAlphaComponent(0.14).setFill()
                NSRect(x: 0, y: y, width: bounds.width, height: height).fill()
            case .context: break
            }
            let mark = line.kind == .add ? "+" : line.kind == .remove ? "\u{2212}" : " "
            let markInk = line.kind == .add ? paint.accent : line.kind == .remove ? paint.danger : paint.dim
            AccountType.draw(mark, .diff, markInk, x: 11 - AccountType.width(mark, .diff) / 2, midY: y + AccountType.lineHeight(.diff) / 2)
            attributed(line).draw(
                with: NSRect(x: 22, y: y, width: bounds.width - 22 - 8, height: height),
                options: [.usesLineFragmentOrigin], context: nil)
            y += height
        }
        NSGraphicsContext.restoreGraphicsState()
        paint.rule.setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
}

/// An edit as a diff, and when it is longer than the first lines, the way to read all of it: a
/// link under the block opens the whole file in a reader that scrolls and draws only what is in
/// view, and Copy all puts the whole of it on the pasteboard. The reader is made when the link is
/// pressed and not before, and what the block asks of its surroundings goes through `readerHeight`
/// (how tall the whole file may stand) and `onToggle` (the page scrolls it into view).
@MainActor
final class AccountDiffBlock: AccountBlock {
    private let edit: NeuralReadout.Edit
    private let paint: AccountPaint
    private let linesView: AccountDiffLinesView
    let link: AccountButton
    let copyAll: AccountButton
    private let fullLines: (() -> [NeuralReadout.DiffLine]?)?
    private let copyText: (() -> String?)?
    private weak var host: BrainSurfaceHost?
    private(set) var reader: AccountDiffReader?
    private(set) var expanded = false
    var readerHeight: (() -> CGFloat)?
    var onToggle: ((Bool) -> Void)?
    private static let barGap: CGFloat = 6

    init(
        edit: NeuralReadout.Edit, full: (() -> [NeuralReadout.DiffLine]?)?, copyText: (() -> String?)?,
        host: BrainSurfaceHost?, paint: AccountPaint
    ) {
        self.edit = edit
        self.paint = paint
        self.host = host
        fullLines = full
        self.copyText = copyText
        linesView = AccountDiffLinesView(lines: edit.lines, paint: paint)
        link = AccountButton(title: NeuralReading.showAllLines(edit.total), style: .link, paint: paint)
        copyAll = AccountButton(title: NeuralReading.copyAllLabel, style: .pill, paint: paint)
        super.init(frame: .zero)
        setAccessibilityElement(false)
        addSubview(linesView)
        addSubview(link)
        addSubview(copyAll)
        link.host = host
        copyAll.host = host
        link.isHidden = !canExpand
        copyAll.isHidden = !canExpand
        link.onTap = { [weak self] in self?.toggle() }
        copyAll.onTap = { [weak self] in self?.copyEverything() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var canExpand: Bool { edit.hiddenCount > 0 && fullLines != nil }

    /// What Copy all puts on the pasteboard: the whole file, or the whole diff with its marks.
    var allText: String? { copyText.flatMap { $0() } }

    func toggle() {
        guard canExpand else { return }
        setExpanded(!expanded, silently: false)
    }

    /// Opens or closes the reader. A page that is rebuilt around a reader the person left open
    /// puts it back silently: nothing scrolls and nothing is told.
    func setExpanded(_ value: Bool, silently: Bool = true) {
        guard value != expanded, canExpand else { return }
        expanded = value
        if value, let lines = fullLines.flatMap({ $0() }) {
            let made = AccountDiffReader(lines: lines, paint: paint)
            addSubview(made, positioned: .below, relativeTo: link)
            reader = made
        } else {
            reader?.removeFromSuperview()
            reader = nil
            expanded = false
        }
        linesView.isHidden = expanded
        link.title = expanded ? NeuralReading.showFewerLines : NeuralReading.showAllLines(edit.total)
        guard !silently else { return }
        onToggle?(expanded)
        onHeight?()
    }

    private func copyEverything() {
        guard let text = allText else { return }
        host?.copyToPasteboard(text)
        copyAll.title = AccountWords.copied
        onHeight?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.copyAll.title = NeuralReading.copyAllLabel
            self?.onHeight?()
        }
    }

    override func fit(width: CGFloat) -> CGFloat {
        var box: CGFloat
        if let reader {
            let whole = reader.contentHeight + 2
            box = min(whole, max(readerHeight?() ?? 300, 80))
            reader.frame = CGRect(x: 0, y: 0, width: width, height: box)
        } else {
            box = linesView.fit(width: width)
            linesView.frame = CGRect(x: 0, y: 0, width: width, height: box)
        }
        var total = box
        if canExpand {
            let linkSize = link.fittingSize
            let copySize = copyAll.fittingSize
            let bar = max(linkSize.height, copySize.height)
            let top = box + Self.barGap
            link.frame = CGRect(x: 0, y: top + (bar - linkSize.height) / 2, width: linkSize.width, height: linkSize.height)
            copyAll.frame = CGRect(
                x: max(width - copySize.width, linkSize.width + 12), y: top + (bar - copySize.height) / 2,
                width: copySize.width, height: copySize.height)
            total = top + bar
        }
        setFrameSize(NSSize(width: width, height: total))
        needsDisplay = true
        return total
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let found = super.hitTest(point)
        return found === self ? nil : found
    }
}

/// A line of the readout that is a row you can press: a number, a title, what it said and a dot
/// for how it stands.
@MainActor
final class AccountListRow: AccountBlock {
    struct Content {
        var number: String
        var title: String
        var detail: String
        var titleInk: NSColor
        var numberInk: NSColor
        var dot: NSColor?
        var trailing: String?
        var trailingInk: NSColor?
        var selected = false
        var titleWidth: CGFloat = 64
        var detailMono = true
    }

    var content: Content { didSet { needsDisplay = true } }
    private let paint: AccountPaint
    var onPress: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    private var hovered = false
    private var tracking: NSTrackingArea?
    let height: CGFloat

    init(content: Content, paint: AccountPaint, height: CGFloat = 32) {
        self.content = content
        self.paint = paint
        self.height = height
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(content.number) \(content.title) \(content.detail)")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func fit(width: CGFloat) -> CGFloat {
        setFrameSize(NSSize(width: width, height: height))
        return height
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

    override func resetCursorRects() { addCursorRect(bounds, cursor: onPress == nil ? .arrow : .pointingHand) }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
        onHover?(false)
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        if content.selected {
            paint.accent.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        } else if hovered {
            paint.text.withAlphaComponent(0.05).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let mid = bounds.midY
        AccountType.draw(content.number, .rowMeta, content.numberInk, x: 28, midY: mid, maxWidth: 28, rightAligned: true)
        var x: CGFloat = 38
        let titleWidth = min(content.titleWidth, bounds.width * 0.4)
        AccountType.draw(content.title, .rowTitleStrong, content.titleInk, x: x, midY: mid, maxWidth: titleWidth)
        x += titleWidth + 8
        var right = bounds.width - 12
        if let dot = content.dot {
            dot.setFill()
            AccountGlyphs.dot(cx: right - 4, cy: mid, radius: 4)
            right -= 16
        }
        if let trailing = content.trailing {
            let used = AccountType.draw(
                trailing, .rowMeta, content.trailingInk ?? paint.dim, x: right, midY: mid,
                maxWidth: bounds.width * 0.35, rightAligned: true)
            right -= used + 10
        }
        AccountType.draw(
            content.detail, content.detailMono ? .rowDetail : .rowTitle, paint.dim, x: x, midY: mid,
            maxWidth: max(right - x, 1))
    }
}

/// A horizontal bar: a quiet track and the fill, both in one colour.
@MainActor
final class AccountBarView: NSView {
    var fraction: Double { didSet { needsDisplay = true } }
    var color: NSColor { didSet { needsDisplay = true } }
    var ground: NSColor { didSet { needsDisplay = true } }

    init(fraction: Double, color: NSColor, ground: NSColor) {
        self.fraction = fraction
        self.color = color
        self.ground = ground
        super.init(frame: .zero)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height
        let track = ground.blended(withFraction: 0.12, of: color) ?? ground
        track.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: h / 2, yRadius: h / 2).fill()
        guard fraction > 0 else { return }
        color.setFill()
        let width = max(h, bounds.width * CGFloat(fraction))
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: h), xRadius: h / 2, yRadius: h / 2).fill()
    }
}

/// A +/- meter: the share of a change that added, in the accent, and the share that removed,
/// in the danger tone.
@MainActor
final class AccountMeterView: NSView {
    let added: Int
    let removed: Int
    let paint: AccountPaint

    init(added: Int, removed: Int, paint: AccountPaint) {
        self.added = added
        self.removed = removed
        self.paint = paint
        super.init(frame: .zero)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let total = CGFloat(max(1, added + removed))
        let width = bounds.width
        let addWidth = width * CGFloat(added) / total
        let top = (bounds.height - 6) / 2
        paint.accent.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 0, y: top, width: max(0, addWidth - (removed > 0 ? 0.5 : 0)), height: 6),
            xRadius: 1, yRadius: 1
        ).fill()
        if removed > 0 {
            paint.danger.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: addWidth + 0.5, y: top, width: max(0, width - addWidth - 0.5), height: 6),
                xRadius: 1, yRadius: 1
            ).fill()
        }
    }
}
