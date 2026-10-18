import CodingAgentKit
import TailscodeCore
import UIKit

/// The whole of a file the agent wrote, or of an edit, laid out to be read: one scroll view whose
/// only drawn content is a window's worth of lines, so a two-thousand-line file costs what thirty
/// do. A file written whole carries a gutter of line numbers and an edit carries the `+` and `-` of
/// what changed, with the washes the clipped block above it wears; the gutter and the marks stay
/// where they are when a long line scrolls sideways, and a line is cut at `characterCap` rather
/// than laid out in full.
@MainActor
final class BrainDiffReaderView: UIView, UIScrollViewDelegate {
    /// How many readers have been made in this process, which is how a check tells that a step
    /// nobody opened built none.
    private(set) static var built = 0

    /// The most characters of one line that are drawn; a line of a minified bundle is cut here.
    static let characterCap = 600

    var onScroll: ((CGPoint) -> Void)?

    let lines: [NeuralReadout.DiffLine]
    let isNumbered: Bool

    private let scroll = UIScrollView()
    private let tile = BrainDiffTile()
    private let texts: [String]
    private var metrics: Metrics
    private var heightConstraint: NSLayoutConstraint!
    private var pendingOffset: CGPoint?
    private(set) var drawnLines = 0

    private static let pad: CGFloat = 8
    private static let markWidth: CGFloat = 18
    private static let verticalPad: CGFloat = 4

    /// What the face and the number of lines decide about the layout.
    private struct Metrics {
        let font: UIFont
        let charWidth: CGFloat
        let lineHeight: CGFloat
        let gutter: CGFloat
        let textLeft: CGFloat
        let contentWidth: CGFloat
        let contentHeight: CGFloat
    }

    init(lines source: [NeuralReadout.DiffLine], maxHeight: CGFloat, offset: CGPoint = .zero) {
        lines = source
        isNumbered = NeuralReading.isWholeFile(source)
        texts = source.map(Self.shown)
        metrics = Self.measure(texts: texts, numbered: isNumbered)
        Self.built += 1
        super.init(frame: .zero)
        layer.cornerRadius = 6
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.borderWidth = 1
        scroll.delegate = self
        scroll.alwaysBounceHorizontal = false
        scroll.isDirectionalLockEnabled = true
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.showsHorizontalScrollIndicator = true
        scroll.indicatorStyle = .default
        addSubview(scroll)
        scroll.addSubview(tile)
        tile.reader = self
        tile.isOpaque = false
        tile.backgroundColor = .clear
        tile.contentMode = .redraw
        tile.isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityLabel = Localized.text("%lld lines", source.count)
        heightConstraint = heightAnchor.constraint(
            equalToConstant: min(metrics.contentHeight, max(maxHeight, 0)).rounded(.up))
        heightConstraint.isActive = true
        scroll.contentSize = CGSize(width: metrics.contentWidth, height: metrics.contentHeight)
        let start = CGPoint(
            x: min(max(0, offset.x), max(0, metrics.contentWidth - 1)),
            y: min(max(0, offset.y), max(0, metrics.contentHeight - 1)))
        pendingOffset = start
        applyChrome()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (view: BrainDiffReaderView, _) in view.applyChrome()
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (view: BrainDiffReaderView, _) in view.remeasure()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func applyChrome() {
        backgroundColor = Theme.Color.background
        layer.borderColor = Theme.Color.separator.resolvedColor(with: traitCollection).cgColor
        tile.setNeedsDisplay()
    }

    private func remeasure() {
        metrics = Self.measure(texts: texts, numbered: isNumbered)
        scroll.contentSize = CGSize(width: metrics.contentWidth, height: metrics.contentHeight)
        setNeedsLayout()
        tile.setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        if let start = pendingOffset, bounds.height > 0 {
            pendingOffset = nil
            let limit = CGPoint(
                x: max(0, metrics.contentWidth - bounds.width),
                y: max(0, metrics.contentHeight - bounds.height))
            scroll.contentOffset = CGPoint(x: min(start.x, limit.x), y: min(start.y, limit.y))
        }
        placeTile()
    }

    private func placeTile() {
        tile.frame = CGRect(origin: scroll.contentOffset, size: scroll.bounds.size)
        tile.setNeedsDisplay()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        placeTile()
        onScroll?(scrollView.contentOffset)
    }

    private static func shown(_ line: NeuralReadout.DiffLine) -> String {
        let text = line.text.contains("\t")
            ? line.text.replacingOccurrences(of: "\t", with: "    ") : line.text
        guard text.count > characterCap else { return text }
        return String(text.prefix(characterCap)) + "\u{2026}"
    }

    private static func measure(texts: [String], numbered: Bool) -> Metrics {
        let font = Theme.Ramp.font(.diff)
        let charWidth = max(1, ("MMMMMMMMMM" as NSString).size(withAttributes: [.font: font]).width / 10)
        let lineHeight = ceil(font.lineHeight) + 4
        let digits = numbered ? String(texts.count).count : 0
        let gutter = numbered ? ceil(CGFloat(max(digits, 2)) * charWidth) + 14 : 0
        let textLeft = pad + gutter + markWidth
        let longest = texts.reduce(0) { max($0, $1.count) }
        return Metrics(
            font: font, charWidth: charWidth, lineHeight: lineHeight, gutter: gutter,
            textLeft: textLeft,
            contentWidth: ceil(textLeft + CGFloat(longest) * charWidth + pad * 2),
            contentHeight: ceil(CGFloat(texts.count) * lineHeight + verticalPad * 2))
    }

    /// How many lines the whole file is tall, which is what the reader is bounded against.
    var contentHeight: CGFloat { metrics.contentHeight }

    var lineHeight: CGFloat { metrics.lineHeight }

    var contentOffset: CGPoint {
        get { scroll.contentOffset }
        set { scroll.contentOffset = newValue }
    }

    /// The lines inside the window the reader shows, with a line of margin either side.
    func visibleRange() -> Range<Int> {
        let top = scroll.contentOffset.y - Self.verticalPad
        let height = max(scroll.bounds.height, metrics.lineHeight * 8)
        let first = max(0, Int((top / metrics.lineHeight).rounded(.down)) - 1)
        let last = min(lines.count, Int(((top + height) / metrics.lineHeight).rounded(.up)) + 1)
        return first..<max(first, last)
    }

    /// The words of the lines in view, which is what a screen reader is given of a file it cannot
    /// read whole.
    override var accessibilityValue: String? {
        get {
            let range = visibleRange()
            return range.map { texts[$0] }.joined(separator: "\n")
        }
        set {}
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        let page = max(scroll.bounds.height - metrics.lineHeight * 2, metrics.lineHeight)
        var target = scroll.contentOffset
        switch direction {
        case .down: target.y += page
        case .up: target.y -= page
        case .right: target.x -= scroll.bounds.width * 0.8
        case .left: target.x += scroll.bounds.width * 0.8
        default: return false
        }
        let limit = CGPoint(
            x: max(0, metrics.contentWidth - scroll.bounds.width),
            y: max(0, metrics.contentHeight - scroll.bounds.height))
        scroll.setContentOffset(
            CGPoint(x: min(max(0, target.x), limit.x), y: min(max(0, target.y), limit.y)), animated: true)
        return true
    }

    fileprivate func paint(in rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let m = metrics
        let offset = scroll.contentOffset
        let range = visibleRange()
        drawnLines = range.count
        let accent = Theme.Color.accent
        let danger = Theme.Color.danger
        let dim = Theme.Color.secondaryLabel
        let ink = Theme.Color.label
        let textAttributes: [NSAttributedString.Key: Any] = [.font: m.font, .foregroundColor: ink]
        let numberAttributes: [NSAttributedString.Key: Any] = [
            .font: m.font, .foregroundColor: dim.withAlphaComponent(0.75),
        ]
        let rowInset = (m.lineHeight - ceil(m.font.lineHeight)) / 2
        for index in range {
            let line = lines[index]
            let y = Self.verticalPad + CGFloat(index) * m.lineHeight - offset.y
            let row = CGRect(x: 0, y: y, width: rect.width, height: m.lineHeight)
            switch line.kind {
            case .add:
                accent.wash(0.14).setFill()
                context.fill(row)
            case .remove:
                danger.wash(0.14).setFill()
                context.fill(row)
            case .context:
                break
            }
            if isNumbered {
                let number = NSAttributedString(string: String(index + 1), attributes: numberAttributes)
                let width = number.size().width
                number.draw(at: CGPoint(x: Self.pad + m.gutter - 10 - width, y: y + rowInset))
            }
            switch line.kind {
            case .add:
                NSAttributedString(string: "+", attributes: [.font: m.font, .foregroundColor: accent])
                    .draw(at: CGPoint(x: Self.pad + m.gutter + 2, y: y + rowInset))
            case .remove:
                NSAttributedString(string: "\u{2212}", attributes: [.font: m.font, .foregroundColor: danger])
                    .draw(at: CGPoint(x: Self.pad + m.gutter + 2, y: y + rowInset))
            case .context:
                break
            }
            let text = texts[index]
            guard !text.isEmpty else { continue }
            let textX = m.textLeft - offset.x
            guard textX + CGFloat(text.count) * m.charWidth > m.textLeft - 2, textX < rect.width else { continue }
            context.saveGState()
            context.clip(to: CGRect(x: m.textLeft - 2, y: y, width: max(0, rect.width - m.textLeft + 2), height: m.lineHeight))
            NSAttributedString(string: text, attributes: textAttributes)
                .draw(at: CGPoint(x: textX, y: y + rowInset))
            context.restoreGState()
        }
        if isNumbered {
            BrainCanvas.rule.setFill()
            context.fill(CGRect(x: Self.pad + m.gutter - 4, y: 0, width: 1, height: rect.height))
        }
    }
}

/// The one view the reader draws: as big as the window and moved to where the window is, so what
/// it draws is the lines in view and nothing more.
@MainActor
private final class BrainDiffTile: UIView {
    weak var reader: BrainDiffReaderView?

    override func draw(_ rect: CGRect) {
        reader?.paint(in: bounds)
    }
}
