import TailscodeCore
import UIKit

/// The turn in short where a phone's open Megatron lists its steps: the model's title and
/// sentence, the rail, and a row a stage. It never scrolls, like the list it stands in for: its
/// height is what its words need at the row's width, and the row is laid out for that. Every word
/// and number is `NeuralGistPane`'s; this draws them and says which stage was pressed.
@MainActor
final class BrainGistView: UIView {
    var onOpen: ((Int) -> Void)?
    var onSteps: (() -> Void)?

    private var pane: NeuralGistPane?
    private var sentence: NSAttributedString?
    private var sentenceRect = CGRect.zero
    private var railRect = CGRect.zero
    private var rowRects: [CGRect] = []
    private var stepsRect = CGRect.zero
    private var pressed: Int?
    private var elements: [UIAccessibilityElement] = []

    static let rowHeight: CGFloat = 34
    static let sideInset: CGFloat = 14
    private static let titleHeight: CGFloat = 20

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        isAccessibilityElement = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self, UITraitPreferredContentSizeCategory.self]) {
            (view: BrainGistView, _) in
            view.setNeedsLayout()
            view.setNeedsDisplay()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private static func sentenceText(_ pane: NeuralGistPane, fallback: String) -> NSAttributedString {
        NSAttributedString(
            string: pane.isWriting ? fallback : pane.now,
            attributes: Theme.Ramp.attributes(
                .lead, color: pane.isWriting ? Theme.Color.secondaryLabel : Theme.Color.label))
    }

    private static func sentenceHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        let font = (text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont) ?? Theme.Ramp.font(.lead)
        let whole = ceil(
            text.boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
            ).height)
        return min(whole, ceil(font.lineHeight * 3.3))
    }

    /// How tall the telling is at a width: what the open row is laid out for.
    static func height(pane: NeuralGistPane, fallback: String, width: CGFloat) -> CGFloat {
        let inner = max(width - 2 * sideInset, 80)
        let text = sentenceText(pane, fallback: fallback)
        guard text.length > 0 else { return titleHeight + 22 + CGFloat(max(pane.rows.count, 3)) * rowHeight + 14 }
        let rows = pane.isWriting ? 3 : pane.rows.count
        return 6 + titleHeight + 4 + sentenceHeight(text, width: inner) + 8 + 22 + CGFloat(rows) * rowHeight + 6
    }

    func show(pane next: NeuralGistPane, fallback: String) {
        pane = next
        sentence = Self.sentenceText(next, fallback: fallback)
        setNeedsLayout()
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let pane, let sentence else { return }
        let inset = Self.sideInset
        let inner = max(bounds.width - 2 * inset, 80)
        var y: CGFloat = 6
        let steps = NSAttributedString(
            string: Localized.text("Steps"), attributes: Theme.Ramp.attributes(.control, color: Theme.Color.accent))
        let stepsWidth = ceil(steps.size().width) + 18
        stepsRect = CGRect(x: bounds.width - inset - stepsWidth, y: y - 6, width: stepsWidth + inset, height: Self.titleHeight + 12)
        y += Self.titleHeight + 4
        let height = sentence.length > 0 ? Self.sentenceHeight(sentence, width: inner) : 0
        sentenceRect = CGRect(x: inset, y: y, width: inner, height: height)
        y += height + 8
        railRect = CGRect(x: inset, y: y, width: inner, height: 22)
        y += 22
        rowRects = []
        let count = pane.isWriting ? 3 : pane.rows.count
        for _ in 0..<count {
            rowRects.append(CGRect(x: 0, y: y, width: bounds.width, height: Self.rowHeight))
            y += Self.rowHeight
        }
        rebuildElements()
    }

    private func rebuildElements() {
        guard let pane else {
            elements = []
            return
        }
        var made: [UIAccessibilityElement] = []
        let head = UIAccessibilityElement(accessibilityContainer: self)
        head.accessibilityLabel = [
            NeuralGistWords.title, pane.title, pane.now, NeuralGistWords.provenance(writer: pane.byline, place: ""),
        ].filter { !$0.isEmpty }.joined(separator: ". ")
        head.accessibilityFrameInContainerSpace = CGRect(x: 0, y: 0, width: bounds.width, height: railRect.minY)
        head.accessibilityTraits = .staticText
        made.append(head)
        if !pane.isWriting {
            for (index, row) in pane.rows.enumerated() where rowRects.indices.contains(index) {
                let element = UIAccessibilityElement(accessibilityContainer: self)
                element.accessibilityLabel = "\(row.says). \(row.facts(of: pane.rows.count))"
                element.accessibilityHint = NeuralGistWords.openStageHint
                element.accessibilityFrameInContainerSpace = rowRects[index]
                element.accessibilityTraits = .button
                made.append(element)
            }
        }
        let steps = UIAccessibilityElement(accessibilityContainer: self)
        steps.accessibilityLabel = Localized.text("Steps")
        steps.accessibilityFrameInContainerSpace = stepsRect
        steps.accessibilityTraits = .button
        made.append(steps)
        elements = made
    }

    override var accessibilityElements: [Any]? {
        get { elements }
        set {}
    }

    override func accessibilityActivate() -> Bool { false }

    private func drawLine(
        _ text: String, _ role: TypeRole, _ color: UIColor, x: CGFloat, midY: CGFloat, maxWidth: CGFloat,
        rightAligned: Bool = false
    ) -> CGFloat {
        guard maxWidth > 1, !text.isEmpty else { return 0 }
        var attributes = Theme.Ramp.attributes(role, color: color)
        let paragraph =
            ((attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle)
            ?? NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        attributes[.paragraphStyle] = paragraph
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let used = min(ceil(size.width), maxWidth)
        let left = rightAligned ? x - used : x
        string.draw(
            with: CGRect(x: left, y: midY - size.height / 2, width: used + 1, height: ceil(size.height)),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        return used
    }

    override func draw(_ rect: CGRect) {
        guard let pane, let sentence else { return }
        let inset = Self.sideInset
        let titleMid: CGFloat = 6 + Self.titleHeight / 2
        let stepsUsed = drawLine(
            Localized.text("Steps") + " \u{203A}", .control, Theme.Color.accent, x: bounds.width - inset, midY: titleMid,
            maxWidth: 120, rightAligned: true)
        _ = drawLine(
            "\(NeuralGistWords.mark) \(pane.title.uppercased())", .sectionLabel,
            pane.isWriting ? Theme.Color.secondaryLabel : Theme.Color.special, x: inset, midY: titleMid,
            maxWidth: max(bounds.width - 2 * inset - stepsUsed - 12, 60))
        sentence.draw(
            with: sentenceRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        drawRail(pane)
        if pane.isWriting {
            for (index, row) in rowRects.enumerated() {
                Theme.Color.secondaryLabel.withAlphaComponent(0.16).setFill()
                UIBezierPath(ovalIn: CGRect(x: inset, y: row.midY - 9, width: 18, height: 18)).fill()
                let share: CGFloat = [0.62, 0.48, 0.55][index % 3]
                UIBezierPath(
                    roundedRect: CGRect(x: inset + 28, y: row.midY - 6, width: max(100, bounds.width * share), height: 12),
                    cornerRadius: 6
                ).fill()
            }
            return
        }
        for (index, row) in pane.rows.enumerated() where rowRects.indices.contains(index) {
            drawRow(row, in: rowRects[index], pressed: pressed == index)
        }
    }

    private func drawRow(_ row: NeuralGistPane.Row, in rect: CGRect, pressed: Bool) {
        let inset = Self.sideInset
        if pressed {
            Theme.Color.accent.withAlphaComponent(0.1).setFill()
            UIBezierPath(rect: rect).fill()
        }
        let mid = rect.midY
        let mark = CGRect(x: inset, y: mid - 9, width: 18, height: 18)
        switch row.mark {
        case .done:
            Theme.Color.info.setFill()
            UIBezierPath(ovalIn: mark).fill()
            let tick = UIBezierPath()
            tick.move(to: CGPoint(x: mark.minX + 5, y: mid + 0.5))
            tick.addLine(to: CGPoint(x: mark.minX + 8, y: mid + 3.5))
            tick.addLine(to: CGPoint(x: mark.minX + 13, y: mid - 3))
            tick.lineWidth = 1.8
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            Theme.Color.background.setStroke()
            tick.stroke()
        case .now:
            Theme.Color.accent.withAlphaComponent(0.18).setFill()
            UIBezierPath(ovalIn: mark).fill()
            Theme.Color.accent.setFill()
            UIBezierPath(ovalIn: CGRect(x: mark.midX - 3.5, y: mid - 3.5, width: 7, height: 7)).fill()
        }
        var right = bounds.width - inset
        if row.mark == .now {
            right -= drawLine(NeuralReading.nowLabel, .sectionLabel, Theme.Color.accent, x: right, midY: mid, maxWidth: 80, rightAligned: true) + 8
        } else {
            right -= max(drawLine("\(row.stepCount)", .rowStamp, Theme.Color.secondaryLabel, x: right, midY: mid, maxWidth: 60, rightAligned: true), 22) + 8
        }
        if row.unfixed > 0 {
            Theme.Color.danger.setFill()
            UIBezierPath(ovalIn: CGRect(x: right - 7, y: mid - 3.5, width: 7, height: 7)).fill()
            right -= 7 + 6
        }
        if row.fixed > 0 {
            Theme.Color.warning.setFill()
            UIBezierPath(ovalIn: CGRect(x: right - 7, y: mid - 3.5, width: 7, height: 7)).fill()
            right -= 7 + 6
        }
        _ = drawLine(
            row.says, row.mark == .now ? .rowTitleStrong : .rowTitle, Theme.Color.label, x: inset + 28, midY: mid,
            maxWidth: max(right - inset - 28, 40))
    }

    /// The rail: a stretch a stage, as long as its share of the steps, with a tick where an error
    /// was fixed and a taller one where it stayed.
    private func drawRail(_ pane: NeuralGistPane) {
        let thick: CGFloat = 5
        let top = railRect.midY - thick / 2
        guard !pane.rows.isEmpty else {
            Theme.Color.secondaryLabel.withAlphaComponent(0.22).setFill()
            UIBezierPath(roundedRect: CGRect(x: railRect.minX, y: top, width: railRect.width, height: thick), cornerRadius: 2.5).fill()
            return
        }
        let gap: CGFloat = 3
        let usable = railRect.width - gap * CGFloat(pane.rows.count - 1)
        var x = railRect.minX
        for row in pane.rows {
            let length = max(4, usable * CGFloat(row.weight))
            (row.mark == .now ? Theme.Color.accent : Theme.Color.info.withAlphaComponent(0.6)).setFill()
            UIBezierPath(roundedRect: CGRect(x: x, y: top, width: length, height: thick), cornerRadius: 2.5).fill()
            for tick in row.ticks {
                let tall: CGFloat = tick.failed ? 15 : 11
                (tick.failed ? Theme.Color.danger : Theme.Color.warning).setFill()
                UIBezierPath(
                    roundedRect: CGRect(x: x + length * CGFloat(tick.at) - 1, y: railRect.midY - tall / 2, width: 2, height: tall),
                    cornerRadius: 1
                ).fill()
            }
            x += length + gap
        }
    }

    private func row(at point: CGPoint) -> Int? {
        guard let pane, !pane.isWriting else { return nil }
        return rowRects.firstIndex { $0.contains(point) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self) else { return }
        pressed = row(at: point)
        if pressed != nil { setNeedsDisplay() }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self), let held = pressed, row(at: point) != held else { return }
        pressed = nil
        setNeedsDisplay()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard pressed != nil else { return }
        pressed = nil
        setNeedsDisplay()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self) else { return }
        let held = pressed
        pressed = nil
        setNeedsDisplay()
        if stepsRect.contains(point) {
            Theme.Haptics.selection()
            onSteps?()
            return
        }
        if let held, row(at: point) == held {
            Theme.Haptics.selection()
            onOpen?(held)
        }
    }

    override func accessibilityElementDidBecomeFocused() {}

    /// A screen reader's double tap on a stage or on the way to the steps.
    func activate(elementAt index: Int) {
        guard let pane else { return }
        if index >= 1, index <= pane.rows.count, !pane.isWriting { onOpen?(index - 1) } else if index == elements.count - 1 { onSteps?() }
    }
}
