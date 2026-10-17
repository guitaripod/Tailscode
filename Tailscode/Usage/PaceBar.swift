import TailscodeCore
import UIKit

/// A quota window, a conversation's context or a balance's runway as one bar in the range
/// grammar: a solid fill for what has been used, a tick where an even burn would be by now, and a
/// hatched tail where the fill lands at the pace so far.
///
/// Everything it draws is the row's: this decides only how wide each piece is. A glance (Home's
/// strip) draws the tail only when it is news; an opened surface (the usage board, the Range
/// sheet) draws every tail. The bar is as tall as the plain bar it replaces — the tick reaches past
/// it into the spacing around it, so a row on pace takes no more room than a row with no pace.
@MainActor
final class PaceBar: UIView {
    static let height: CGFloat = 6
    private static let tickOverhang: CGFloat = 4
    private static let tickWidth: CGFloat = 2

    /// A tick is outlined in the colour of what the bar sits on, so it reads over the fill.
    var outline: UIColor = Theme.Color.groupedSurface {
        didSet { refreshColors() }
    }

    var trackColor: UIColor = Theme.Color.separator {
        didSet { refreshColors() }
    }

    /// Whether the bar is its own accessibility element. A row that speaks for itself turns it off.
    var speaks = true {
        didSet { isAccessibilityElement = speaks }
    }

    private let track = UIView()
    private let fill = UIView()
    private let tail = HatchView()
    private let tick = UIView()
    private var row: PaceRow?
    private var glance = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        track.layer.cornerRadius = Self.height / 2
        track.layer.cornerCurve = .continuous
        track.clipsToBounds = true
        fill.layer.cornerRadius = Self.height / 2
        fill.layer.cornerCurve = .continuous
        track.addSubview(fill)
        track.addSubview(tail)
        addSubview(track)
        tick.layer.borderWidth = 1
        tick.isUserInteractionEnabled = false
        addSubview(tick)
        isAccessibilityElement = true
        accessibilityTraits = .image
        refreshColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (bar: PaceBar, _: UITraitCollection) in
            bar.refreshColors()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.height)
    }

    func configure(_ row: PaceRow, glance: Bool = false) {
        guard self.row != row || self.glance != glance else { return }
        self.row = row
        self.glance = glance
        accessibilityLabel = row.accessibilityLabel
        refreshColors()
        setNeedsLayout()
    }

    /// The colour a provider wears while its window is quiet.
    static func brand(slug: String?) -> UIColor {
        switch slug {
        case "claude": return Theme.Color.claude
        case "grok": return Theme.Color.grok
        case "opencode": return Theme.Color.opencode
        case "deepseek": return Theme.Color.modelFamily(.deepseek)
        case "ollama-cloud": return Theme.Color.ollamaCloud
        default: return Theme.Color.accent
        }
    }

    static func color(for tone: ContextFill.Tone) -> UIColor {
        switch tone {
        case .quiet: return Theme.Color.secondaryLabel
        case .attention: return Theme.Color.warning
        case .danger: return Theme.Color.danger
        }
    }

    private var isWall: Bool { (row?.fill ?? 0) >= QuotaSurface.exhaustedFloor }

    private var fillColor: UIColor {
        guard let row else { return Theme.Color.accent }
        if isWall { return Theme.Color.danger }
        switch row.tone {
        case .quiet: return row.kind == .context ? Theme.Color.accent : Self.brand(slug: row.slug)
        case .attention: return Theme.Color.warning
        case .danger: return Theme.Color.danger
        }
    }

    private var tailColor: UIColor {
        guard let row else { return Theme.Color.accent }
        switch row.tailTone {
        case .quiet: return fillColor
        case .attention: return Theme.Color.warning
        case .danger: return Theme.Color.danger
        }
    }

    private func refreshColors() {
        let traits = traitCollection
        track.backgroundColor = trackColor.resolvedColor(with: traits)
        fill.backgroundColor = fillColor.resolvedColor(with: traits)
        tail.color = tailColor.resolvedColor(with: traits)
        tick.backgroundColor = Theme.Color.label.resolvedColor(with: traits)
        tick.layer.borderColor = outline.resolvedColor(with: traits).cgColor
        tick.alpha = row?.tickApproximate == true ? 0.55 : 1
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let height = Self.height
        let barY = (bounds.height - height) / 2
        track.frame = CGRect(x: 0, y: barY, width: width, height: height)
        guard let row else { return }

        let filled = isWall ? 1 : min(1, max(0.02, row.fill))
        let fillWidth = width * CGFloat(filled)
        fill.frame = CGRect(x: 0, y: 0, width: fillWidth, height: height)

        let showsTail = row.tailEnd.map { $0 > filled } == true && (!glance || row.tailIsNews)
        if showsTail, let end = row.tailEnd {
            let edge = width * CGFloat(min(1, end))
            tail.frame = CGRect(x: fillWidth, y: 0, width: max(0, edge - fillWidth), height: height)
            tail.isHidden = false
        } else {
            tail.isHidden = true
        }

        if let at = row.tick {
            let x = min(max(width * CGFloat(at), 1), width - 1) - Self.tickWidth / 2
            tick.frame = CGRect(
                x: x - 1, y: barY - Self.tickOverhang, width: Self.tickWidth + 2,
                height: height + Self.tickOverhang * 2)
            tick.isHidden = false
        } else {
            tick.isHidden = true
        }
    }
}

/// Diagonal stripes, drawn rather than tiled from an image so they stay crisp at any scale and
/// take the colour of whatever they stand for.
@MainActor
final class HatchView: UIView {
    var color: UIColor = Theme.Color.warning {
        didSet { setNeedsDisplay() }
    }

    var alphaOfStripes: CGFloat = 0.6 {
        didSet { setNeedsDisplay() }
    }

    private static let stripe: CGFloat = 2.5
    private static let gap: CGFloat = 3

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), bounds.width > 0 else { return }
        Self.stripes(in: context, rect: bounds, color: color.withAlphaComponent(alphaOfStripes))
    }

    /// Fills `rect` with the stripes, clipped to it.
    static func stripes(in context: CGContext, rect: CGRect, color: UIColor) {
        context.saveGState()
        context.clip(to: rect)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(stripe)
        let step = (stripe + gap) * 2.0.squareRoot()
        var x = rect.minX - rect.height
        while x < rect.maxX + rect.height {
            context.move(to: CGPoint(x: x, y: rect.maxY))
            context.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            context.strokePath()
            x += step
        }
        context.restoreGState()
    }
}

/// The words a pace row owes under its bar: the lead in small bold capitals in the tone's colour,
/// then the rest in the quiet ink — or the quiet remark alone when there is no news.
enum PaceWords {
    @MainActor
    static func news(_ news: PaceRow.News) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: news.lead.uppercased(),
            attributes: [
                .font: Theme.Ramp.font(.sectionLabel),
                .foregroundColor: PaceBar.color(for: news.tone),
            ])
        text.append(
            NSAttributedString(
                string: "  " + news.body,
                attributes: [
                    .font: Theme.Ramp.font(.panelFootnote),
                    .foregroundColor: Theme.Color.secondaryLabel,
                ]))
        return text
    }

    @MainActor
    static func note(_ note: String) -> NSAttributedString {
        NSAttributedString(
            string: note,
            attributes: [
                .font: Theme.Ramp.font(.panelFootnote),
                .foregroundColor: Theme.Color.secondaryLabel,
            ])
    }

    /// One label for a row's line of words, hidden when there are none. `opened` surfaces also
    /// carry the quiet remark.
    @MainActor
    static func line(for row: PaceRow, opened: Bool) -> UILabel? {
        let words: NSAttributedString
        if let item = row.news {
            words = news(item)
        } else if opened, let remark = row.note {
            words = note(remark)
        } else {
            return nil
        }
        let label = UILabel()
        label.attributedText = words
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        return label
    }
}
