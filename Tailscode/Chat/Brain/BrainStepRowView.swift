import TailscodeCore
import UIKit

/// One row of the step list, drawn once for every place that lists steps: the list beside the head
/// and the rows a work line of the account unfolds into are the same pixels, because they are this
/// one view given a row and what the pointer and the cursor are doing.
///
/// The row is drawn rather than assembled: a zone edge, the bracket of calls made together, the
/// zone's glyph, the step's number, what it did in a sentence, its argument cut to the room there
/// is, and the mark of how it stands. A note the agent said is two lines tall and wears the quote
/// glyph in the accent; a thought is one muted line. The cursor row washes in the accent and keeps
/// its zone's edge; a failed row washes in danger and a fixed one does not.
@MainActor
final class BrainStepRowView: UIControl {
    struct Context {
        var previous: NeuralStepList.Row?
        var next: NeuralStepList.Row?
        var isCursor = false
        var isHovered = false
        var query = ""
        var input: ChatInput = .touch
        var total = 0
    }

    var onClick: ((String, Bool) -> Void)?
    var onHover: ((String?) -> Void)?
    var onMenu: ((NeuralBrowse.MenuItem, String) -> Void)?
    var onCopy: ((String) -> Void)?

    private(set) var row: NeuralStepList.Row?
    private var context = Context()
    private let copyButton = UIButton(type: .system)
    private var pointerInside = false
    private var copiedUntil: CFTimeInterval = 0
    private let menuDelegate = RowMenuDelegate()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        addTarget(self, action: #selector(touchUp(_:event:)), for: .touchUpInside)
        addInteraction(UIContextMenuInteraction(delegate: menuDelegate))
        menuDelegate.row = self
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        addGestureRecognizer(hover)
        copyButton.isHidden = true
        copyButton.addAction(
            UIAction { [weak self] _ in
                guard let self, let row = self.row else { return }
                self.onCopy?(row.id)
                self.flashCopied()
            }, for: .touchUpInside)
        addSubview(copyButton)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(row new: NeuralStepList.Row, context newContext: Context) {
        let changed = row != new || context.isCursor != newContext.isCursor
            || context.isHovered != newContext.isHovered || context.query != newContext.query
            || context.previous?.group != newContext.previous?.group
            || context.next?.group != newContext.next?.group
        row = new
        context = newContext
        accessibilityLabel = spoken(new)
        accessibilityTraits = newContext.isCursor ? [.button, .selected] : .button
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: NeuralReading.copyLabel) { [weak self] _ in
                guard let self, let row = self.row else { return false }
                self.onCopy?(row.id)
                return true
            }
        ]
        if changed { setNeedsDisplay() }
    }

    private func spoken(_ row: NeuralStepList.Row) -> String {
        var parts = [Localized.text("%1$lld, %2$@", row.number, row.title)]
        if !row.argument.isEmpty { parts.append(row.argument) }
        if let word = row.markWord { parts.append(word) }
        return parts.joined(separator: ", ")
    }

    @objc private func touchUp(_ sender: BrainStepRowView, event: UIEvent) {
        guard let row, let touch = event.allTouches?.first else { return }
        Theme.Haptics.selection()
        onClick?(row.id, touch.tapCount >= 2)
    }

    @objc private func hovered(_ gesture: UIHoverGestureRecognizer) {
        guard let row else { return }
        switch gesture.state {
        case .began, .changed:
            guard !pointerInside else { return }
            pointerInside = true
            showCopy(true)
            onHover?(row.id)
        default:
            guard pointerInside else { return }
            pointerInside = false
            showCopy(false)
            onHover?(nil)
        }
    }

    private func showCopy(_ visible: Bool) {
        guard let row else { return }
        copyButton.isHidden = !visible && copiedUntil < CACurrentMediaTime()
        guard visible || copiedUntil > CACurrentMediaTime() else { return }
        var config = UIButton.Configuration.plain()
        config.attributedTitle = AttributedString(
            NSAttributedString(
                string: copiedUntil > CACurrentMediaTime() ? Localized.text("Copied") : NeuralReading.copyLabel,
                attributes: Theme.Ramp.attributes(.control, color: Theme.Color.label)))
        config.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 9, bottom: 2, trailing: 9)
        config.background.backgroundColor = Theme.Color.secondaryBackground
        config.background.strokeColor = BrainCanvas.rule
        config.background.strokeWidth = 1
        config.background.cornerRadius = 12
        copyButton.configuration = config
        let size = copyButton.sizeThatFits(CGSize(width: 200, height: 24))
        copyButton.frame = CGRect(
            x: bounds.width - 6 - size.width,
            y: (rowHeight(row) - 24) / 2, width: size.width, height: 24)
    }

    private func flashCopied() {
        copiedUntil = CACurrentMediaTime() + 1
        showCopy(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.showCopy(self.pointerInside)
            }
        }
    }

    private func rowHeight(_ row: NeuralStepList.Row) -> CGFloat {
        CGFloat(row.height(input: context.input))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if pointerInside { showCopy(true) }
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        setNeedsDisplay()
    }

    static let titleX: CGFloat = 83
    private static let glyphX: CGFloat = 34
    private static let numberRight: CGFloat = 75

    /// How wide the mark on the right is, for the room the argument has.
    private func markWidth(_ row: NeuralStepList.Row) -> CGFloat {
        guard let mark = markText(row) else { return 0 }
        return ceil(mark.text.size().width) + (mark.symbol == nil ? 0 : 18) + 10
    }

    private func markText(_ row: NeuralStepList.Row) -> (text: NSAttributedString, symbol: String?, tone: UIColor)? {
        let font = BrainFonts.rowStatus
        func make(_ words: String, _ ink: UIColor) -> NSAttributedString {
            NSAttributedString(string: words, attributes: [.font: font, .foregroundColor: ink])
        }
        switch row.verdict {
        case .done: return nil
        case .fixed:
            let number = row.related?.number
            let words = number.map { "\u{2192} \($0)" } ?? Localized.text("fixed")
            return (make(words, Theme.Color.warning), BrainCanvas.symbol(for: .fixed), Theme.Color.warning)
        case .failed:
            return (make(NeuralReading.statusWord(.failed), Theme.Color.danger), "xmark", Theme.Color.danger)
        case .tryingAgain:
            return (
                make(NeuralReading.verdictHitError, Theme.Color.warning),
                BrainCanvas.symbol(for: .tryingAgain), Theme.Color.warning
            )
        case .running:
            return (make(NeuralReading.statusWord(.running), Theme.Color.secondaryLabel), "circle.fill", Theme.Color.accent)
        case .waiting:
            return (make(NeuralReading.statusWord(row.status), Theme.Color.secondaryLabel), "pause.fill", Theme.Color.warning)
        case .stalled:
            return (make(NeuralReading.verdictStuck, Theme.Color.secondaryLabel), BrainCanvas.symbol(for: .stalled), Theme.Color.warning)
        case .stopped:
            return (make(NeuralReading.statusWord(.stopped), Theme.Color.secondaryLabel), "stop.fill", Theme.Color.secondaryLabel)
        }
    }

    override func draw(_ rect: CGRect) {
        guard let row, let cg = UIGraphicsGetCurrentContext() else { return }
        let traits = traitCollection
        func color(_ ink: UIColor) -> UIColor { ink.resolvedColor(with: traits) }
        let height = bounds.height
        let width = bounds.width
        let accent = color(Theme.Color.accent)
        let zoneInk = color(BrainCanvas.zone(row.zone))
        let dim = color(Theme.Color.secondaryLabel)
        let ink = color(Theme.Color.label)

        if row.verdict == .failed {
            cg.setFillColor(color(Theme.Color.danger).withAlphaComponent(0.08).cgColor)
            cg.fill(bounds)
        }
        if context.isCursor {
            cg.setFillColor(accent.withAlphaComponent(0.14).cgColor)
            cg.fill(bounds)
        } else if context.isHovered || pointerInside {
            cg.setFillColor(ink.withAlphaComponent(0.06).cgColor)
            cg.fill(bounds)
        }
        cg.setFillColor(zoneInk.cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: 3, height: height))
        if context.isCursor {
            cg.setFillColor(accent.cgColor)
            cg.fill(CGRect(x: 3, y: 0, width: 2, height: height))
            cg.setStrokeColor(accent.withAlphaComponent(0.9).cgColor)
            cg.setLineWidth(1)
            cg.stroke(bounds.insetBy(dx: 0.5, dy: 0.5))
        }
        drawBracket(cg, row: row, color: dim)

        let said = row.isSaid
        let band: CGFloat = said ? (context.input == .touch ? 30 : 28) : height
        let mid = band / 2
        if said {
            drawQuote(cg, at: CGPoint(x: Self.glyphX, y: (context.input == .touch ? 17 : 15)), color: accent)
        } else {
            drawGlyph(cg, row.zone.shape, at: CGPoint(x: Self.glyphX, y: mid), color: zoneInk)
        }
        let numberFont = BrainFonts.rowNumber
        let number = NSAttributedString(
            string: "\(row.number)", attributes: [.font: numberFont, .foregroundColor: dim])
        let numberSize = number.size()
        number.draw(at: CGPoint(x: Self.numberRight - numberSize.width, y: (band - numberSize.height) / 2))

        let markRoom = markWidth(row)
        let showsCopy = pointerInside || copiedUntil > CACurrentMediaTime()
        let limit = width - (showsCopy ? 74 : markRoom + 4) - 6
        if !showsCopy { drawMark(cg, row: row, right: width - 10, mid: band / 2) }
        if row.kind == .tool {
            let titleFont = BrainFonts.rowTitle
            let title = NSAttributedString(
                string: row.title,
                attributes: [
                    .font: titleFont, .foregroundColor: ink, .paragraphStyle: Self.truncating,
                ])
            let titleWidth = min(ceil(title.size().width), 168, max(60, (limit - Self.titleX) * 0.62))
            let titleSize = title.size()
            title.draw(
                in: CGRect(
                    x: Self.titleX, y: (height - titleSize.height) / 2, width: titleWidth,
                    height: titleSize.height))
            let argumentX = Self.titleX + titleWidth + 8
            let room = max(0, limit - argumentX)
            let characters = max(0, Int(room / BrainFonts.argumentCharacterWidth))
            let shown = row.argument(fittingChars: characters)
            let argument = highlighted(shown, font: BrainFonts.rowArgument, ink: dim)
            let argumentSize = argument.size()
            argument.draw(
                in: CGRect(
                    x: argumentX, y: (height - argumentSize.height) / 2, width: room + 2,
                    height: argumentSize.height))
        } else if said {
            let text = NSAttributedString(
                string: row.lines.joined(separator: " "),
                attributes: [.font: BrainFonts.rowSaid, .foregroundColor: ink])
            text.draw(
                with: CGRect(x: Self.titleX, y: 4, width: max(0, limit - Self.titleX), height: height - 6),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        } else {
            let text = highlighted(row.argument, font: BrainFonts.rowNote, ink: dim)
            let size = text.size()
            text.draw(
                in: CGRect(
                    x: Self.titleX, y: (height - size.height) / 2, width: max(0, limit - Self.titleX),
                    height: size.height))
        }
    }

    private func highlighted(_ text: String, font: UIFont, ink: UIColor) -> NSAttributedString {
        let out = NSMutableAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: ink])
        guard !context.query.isEmpty, let range = text.range(of: context.query, options: .caseInsensitive)
        else {
            out.addAttribute(.paragraphStyle, value: Self.truncating, range: NSRange(location: 0, length: out.length))
            return out
        }
        out.addAttribute(
            .backgroundColor,
            value: Theme.Color.warning.resolvedColor(with: traitCollection).withAlphaComponent(0.34),
            range: NSRange(range, in: text))
        out.addAttribute(.paragraphStyle, value: Self.truncating, range: NSRange(location: 0, length: out.length))
        return out
    }

    private static let truncating: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    private func drawGlyph(_ cg: CGContext, _ shape: NeuralShape, at center: CGPoint, color: UIColor) {
        cg.saveGState()
        cg.translateBy(x: center.x, y: center.y)
        cg.addPath(BrainShapes.path(shape, radius: 6.2))
        cg.setFillColor(color.withAlphaComponent(0.18).cgColor)
        cg.setStrokeColor(color.cgColor)
        cg.setLineWidth(1.4)
        cg.setLineJoin(.round)
        cg.drawPath(using: .fillStroke)
        cg.restoreGState()
    }

    private func drawQuote(_ cg: CGContext, at center: CGPoint, color: UIColor) {
        cg.saveGState()
        cg.setFillColor(color.cgColor)
        cg.setStrokeColor(color.cgColor)
        cg.setLineCap(.round)
        for offset in [-4.2, 3.2] as [CGFloat] {
            let x = center.x + offset
            cg.fillEllipse(in: CGRect(x: x - 2.6, y: center.y + 2.2 - 2.6, width: 5.2, height: 5.2))
            cg.setLineWidth(2.2)
            cg.beginPath()
            cg.move(to: CGPoint(x: x + 2.3, y: center.y + 1.6))
            cg.addCurve(
                to: CGPoint(x: x - 0.6, y: center.y - 5.6),
                control1: CGPoint(x: x + 2.9, y: center.y - 2.4),
                control2: CGPoint(x: x + 1.8, y: center.y - 4.4))
            cg.strokePath()
        }
        cg.restoreGState()
    }

    private func drawBracket(_ cg: CGContext, row: NeuralStepList.Row, color: UIColor) {
        guard row.bracket != .none else { return }
        let joinsAbove = context.previous.map { $0.group == row.group && $0.bracket != .none } ?? false
        let joinsBelow = context.next.map { $0.group == row.group && $0.bracket != .none } ?? false
        guard joinsAbove || joinsBelow else { return }
        let mid = bounds.height / 2
        cg.saveGState()
        cg.setStrokeColor(color.withAlphaComponent(0.75).cgColor)
        cg.setLineWidth(1)
        let x: CGFloat = 9.5
        cg.beginPath()
        cg.move(to: CGPoint(x: x, y: joinsAbove ? 0 : mid))
        cg.addLine(to: CGPoint(x: x, y: joinsBelow ? bounds.height : mid))
        cg.move(to: CGPoint(x: x, y: mid))
        cg.addLine(to: CGPoint(x: x + 6, y: mid))
        cg.strokePath()
        cg.restoreGState()
    }

    private func drawMark(_ cg: CGContext, row: NeuralStepList.Row, right: CGFloat, mid: CGFloat) {
        guard let mark = markText(row) else { return }
        let size = mark.text.size()
        let left = right - ceil(size.width)
        mark.text.draw(at: CGPoint(x: left, y: mid - size.height / 2))
        guard let symbol = mark.symbol,
            let image = BrainCanvas.image(symbol, size: symbol == "circle.fill" ? 7 : 10)?
                .withTintColor(mark.tone.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal)
        else { return }
        image.draw(at: CGPoint(x: left - 5 - image.size.width, y: mid - image.size.height / 2))
    }
}

/// The menu a long press on a row opens: the entries Core's reducer offers for it.
@MainActor
final class RowMenuDelegate: NSObject, UIContextMenuInteractionDelegate {
    weak var row: BrainStepRowView?

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let row, let step = row.row else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak row] _ in
            guard let row else { return nil }
            let items = NeuralBrowse.menuItems(for: step).map { item in
                UIAction(title: NeuralBrowse.title(of: item), image: Self.icon(item)) { _ in
                    row.onMenu?(item, step.id)
                }
            }
            return UIMenu(children: items)
        }
    }

    private static func icon(_ item: NeuralBrowse.MenuItem) -> UIImage? {
        switch item {
        case .copySubject: return UIImage(systemName: "terminal")
        case .copyOutput: return UIImage(systemName: "doc.on.doc")
        case .copyMarkdown: return UIImage(systemName: "doc.richtext")
        case .showOnlyThisZone: return UIImage(systemName: "line.3.horizontal.decrease")
        case .goToRelated: return UIImage(systemName: "arrow.turn.down.right")
        case .showInRows: return UIImage(systemName: "list.bullet")
        }
    }
}
