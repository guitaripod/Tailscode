import AppKit
import TailscodeCore

/// The whole of a file the agent wrote, or of an edit, laid out to be read: one canvas that draws
/// only the lines inside the rectangle it is asked for, inside a scroll view that is bounded in
/// height and scrolls sideways for a long line, so a two-thousand-line file costs what thirty do.
/// A file written whole carries a gutter of line numbers; an edit carries the `+` and `-` of what
/// changed and the same washes the clipped block above it wears.
@MainActor
final class AccountDiffReader: NSView {
    let lines: [NeuralReadout.DiffLine]
    let numbered: Bool
    let canvas: AccountDiffCanvas
    let scroll = NSScrollView()

    /// How many readers have been made, for the check that a step nobody opened builds none.
    private(set) static var built = 0

    init(lines: [NeuralReadout.DiffLine], paint: AccountPaint) {
        self.lines = lines
        numbered = NeuralReading.isWholeFile(lines)
        canvas = AccountDiffCanvas(lines: lines, numbered: numbered, paint: paint)
        super.init(frame: .zero)
        Self.built += 1
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
        scroll.usesPredominantAxisScrolling = true
        scroll.documentView = canvas
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 5.5
        scroll.layer?.masksToBounds = true
        addSubview(scroll)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Localized.text("%lld lines", lines.count))
        canvas.setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    var lineCount: Int { lines.count }

    /// The whole file's height, which is what the canvas is however little of it is drawn.
    var contentHeight: CGFloat { canvas.contentHeight }

    /// The lines in the window the scroll view shows, with a line of margin either side.
    func visibleRange() -> Range<Int> {
        canvas.range(in: scroll.contentView.bounds.minY, height: max(scroll.contentView.bounds.height, canvas.lineHeight * 8))
    }

    /// The lines the canvas drew the last time it was asked to, for the harness.
    var drawnRange: Range<Int> { canvas.drawnRange }

    func showLine(_ index: Int) {
        let clip = scroll.contentView
        let target = min(max(CGFloat(index) * canvas.lineHeight, 0), max(0, canvas.contentHeight - clip.bounds.height))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: target))
        scroll.reflectScrolledClipView(clip)
    }

    func retheme(_ paint: AccountPaint) {
        canvas.paint = paint
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds.insetBy(dx: 1, dy: 1)
        canvas.fit(clipWidth: scroll.contentSize.width)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let found = super.hitTest(point)
        return found === self ? nil : found
    }

    override func draw(_ dirtyRect: NSRect) {
        let paint = canvas.paint
        let frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)
        paint.rule.setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
}

/// The document of a reader: a view as tall as the whole file that draws the lines in the
/// rectangle AppKit asks for and nothing else.
@MainActor
final class AccountDiffCanvas: NSView {
    private let lines: [NeuralReadout.DiffLine]
    private let numbered: Bool
    var paint: AccountPaint { didSet { needsDisplay = true } }
    let lineHeight: CGFloat
    private let gutter: CGFloat
    private let textLeft: CGFloat
    private let contentWidth: CGFloat
    private(set) var drawnRange: Range<Int> = 0..<0

    private static let characterCap = 600
    private static let pad: CGFloat = 8
    private static let markWidth: CGFloat = 18

    init(lines: [NeuralReadout.DiffLine], numbered: Bool, paint: AccountPaint) {
        self.lines = lines
        self.numbered = numbered
        self.paint = paint
        lineHeight = ceil(AccountType.lineHeight(.diff)) + 1
        let digits = numbered ? String(lines.count).count : 0
        gutter = numbered ? ceil(CGFloat(max(digits, 2)) * AccountType.monoWidth(.diff)) + 12 : 0
        textLeft = Self.pad + gutter + Self.markWidth
        let longest = lines.max { Self.expanded($0.text).count < Self.expanded($1.text).count }
        let widest = longest.map { AccountType.width(Self.shown($0.text), .diff) } ?? 0
        contentWidth = textLeft + widest + Self.pad * 2
        super.init(frame: .zero)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    var contentHeight: CGFloat { CGFloat(lines.count) * lineHeight + 2 }

    func fit(clipWidth: CGFloat) {
        let size = NSSize(width: max(clipWidth, contentWidth), height: contentHeight)
        if frame.size != size { setFrameSize(size) }
    }

    func range(in top: CGFloat, height: CGFloat) -> Range<Int> {
        let first = max(0, Int((top / lineHeight).rounded(.down)) - 1)
        let last = min(lines.count, Int(((top + height) / lineHeight).rounded(.up)) + 1)
        return first..<max(first, last)
    }

    static func expanded(_ text: String) -> String {
        text.contains("\t") ? text.replacingOccurrences(of: "\t", with: "    ") : text
    }

    /// A line as it is drawn: tabs as four spaces, and a line of a minified bundle cut where the
    /// canvas would otherwise be a mile wide.
    static func shown(_ text: String) -> String {
        let spaced = expanded(text)
        return spaced.count > characterCap ? String(spaced.prefix(characterCap)) + "\u{2026}" : spaced
    }

    override func draw(_ dirtyRect: NSRect) {
        let range = range(in: dirtyRect.minY, height: dirtyRect.height)
        drawnRange = range
        let accent = paint.accent
        let danger = paint.danger
        let ink = paint.text
        let dim = paint.dim.withAlphaComponent(0.7)
        let wide = bounds.width
        for index in range {
            let line = lines[index]
            let y = CGFloat(index) * lineHeight + 1
            let mid = y + lineHeight / 2
            switch line.kind {
            case .add:
                accent.withAlphaComponent(0.14).setFill()
                NSRect(x: 0, y: y, width: wide, height: lineHeight).fill()
            case .remove:
                danger.withAlphaComponent(0.14).setFill()
                NSRect(x: 0, y: y, width: wide, height: lineHeight).fill()
            case .context: break
            }
            if numbered {
                AccountType.draw(
                    String(index + 1), .diff, dim, x: Self.pad + gutter - 8, midY: mid, rightAligned: true)
            }
            let markX = Self.pad + gutter + Self.markWidth / 2
            switch line.kind {
            case .add:
                AccountType.draw("+", .diff, accent, x: markX - AccountType.width("+", .diff) / 2, midY: mid)
            case .remove:
                AccountType.draw(
                    "\u{2212}", .diff, danger, x: markX - AccountType.width("\u{2212}", .diff) / 2, midY: mid)
            case .context: break
            }
            AccountType.draw(Self.shown(line.text), .diff, ink, x: textLeft, midY: mid)
        }
        if numbered {
            paint.rule2.withAlphaComponent(0.8).setFill()
            NSRect(x: Self.pad + gutter - 4, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
        }
    }
}

extension AccountReadoutPage {
    /// The reader a diff on this page has open now.
    var openReader: AccountDiffReader? { diffs.lazy.compactMap(\.reader).first }
}

extension BrainAccountView {
    /// The reader the open card or the detail column holds now, for the harness and the drive.
    var openReader: AccountDiffReader? {
        for cell in cells.values {
            if let reader = (cell as? AccountWorkCell)?.cursorPage?.openReader { return reader }
        }
        return detail?.openReader
    }
}
