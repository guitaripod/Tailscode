import AppKit
import TailscodeCore

/// One tank in the range's grammar: a solid fill for what has been used, a hatched tail for where
/// it lands at the pace so far, and a tick for where an even burn would be by now. Every number is
/// `PaceRow`'s; this decides only how a stroke is painted.
///
/// A glance draws the tail only when it is news — a strip is for what changed, not for what is
/// fine — and an opened surface always draws it. The tick is read against the fill and the tail
/// alone, never against each other. The bar is exactly as tall as the plain bar it replaces: the
/// tick's overhang is a sublayer that spills past the bounds rather than height the row has to
/// make room for.
@MainActor
final class PaceBarView: NSView {
    enum Surface {
        case glance
        case opened
    }

    private struct Reading {
        var fill: Double
        var tick: Double?
        var tickApproximate: Bool
        var tailEnd: Double?
        var fillTone: ContextFill.Tone
        var tailTone: ContextFill.Tone
        var slug: String?
    }

    private let barHeight: CGFloat
    private let fixedWidth: CGFloat?
    private let trackInk: () -> NSColor
    private let surround: () -> NSColor
    private var reading: Reading
    private var showsTail: Bool

    private let trackLayer = CALayer()
    private let hatchClip = CALayer()
    private let hatchLayer = CAShapeLayer()
    private let hatchRange = CALayer()
    private let fillLayer = CALayer()
    private let tickHalo = CALayer()
    private let tickInk = CALayer()

    private static let stripeWidth: CGFloat = 2.5
    private static let stripePitch: CGFloat = 5.5 * 2.0.squareRoot()
    private static let tailAlpha: Float = 0.6
    private static let approximateAlpha: Float = 0.55
    private static let tickWidth: CGFloat = 2

    /// - Parameters:
    ///   - row: the tank, as Core read it.
    ///   - surface: whether the tail shows only as news or always.
    ///   - height: the bar's own height.
    ///   - width: a fixed width, or nil to be as wide as whatever holds the bar.
    ///   - fillTone: a register for the fill that is not the row's, for a strip whose dot already
    ///     says one and whose bar must agree with it.
    ///   - track: the colour behind the fill, which is whatever the surface underneath is not.
    ///   - surround: the colour the tick is outlined in so it reads over the fill, which is the
    ///     surface the bar sits on.
    init(
        row: PaceRow, surface: Surface, height: CGFloat, width: CGFloat? = nil,
        fillTone: ContextFill.Tone? = nil,
        track: @escaping @autoclosure () -> NSColor = MacTheme.Color.canvasRaised,
        surround: @escaping @autoclosure () -> NSColor = MacTheme.Color.canvasRaised
    ) {
        reading = Reading(
            fill: row.fill, tick: row.tick, tickApproximate: row.tickApproximate,
            tailEnd: row.tailEnd, fillTone: fillTone ?? row.tone, tailTone: row.tailTone,
            slug: row.slug)
        showsTail = surface == .opened || row.tailIsNews
        barHeight = height
        fixedWidth = width
        trackInk = track
        self.surround = surround
        super.init(frame: .zero)
        build()
        setAccessibilityLabel(row.accessibilityLabel)
    }

    /// A bar with only a level, for a tank that has no clock: the plain fill every surface drew
    /// before there was a pace.
    init(
        fraction: Double, slug: String?, tone: ContextFill.Tone, height: CGFloat,
        width: CGFloat? = nil,
        track: @escaping @autoclosure () -> NSColor = MacTheme.Color.canvasRaised,
        surround: @escaping @autoclosure () -> NSColor = MacTheme.Color.canvasRaised
    ) {
        reading = Reading(
            fill: fraction, tick: nil, tickApproximate: false, tailEnd: nil, fillTone: tone,
            tailTone: .quiet, slug: slug)
        showsTail = false
        barHeight = height
        fixedWidth = width
        trackInk = track
        self.surround = surround
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: fixedWidth ?? NSView.noIntrinsicMetric, height: barHeight)
    }

    override var isFlipped: Bool { false }

    /// A bar standing in a column is a level indicator to a screen reader, and its label is the
    /// whole of the row's words rather than a bare percentage.
    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        clipsToBounds = false
        layer?.masksToBounds = false
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.init(100), for: .horizontal)
        if let fixedWidth {
            widthAnchor.constraint(equalToConstant: fixedWidth).isActive = true
        }
        heightAnchor.constraint(equalToConstant: barHeight).isActive = true

        hatchClip.masksToBounds = true
        hatchLayer.fillColor = nil
        hatchLayer.lineWidth = Self.stripeWidth
        hatchLayer.opacity = Self.tailAlpha
        hatchLayer.mask = hatchRange
        hatchRange.backgroundColor = NSColor.black.cgColor
        hatchClip.addSublayer(hatchLayer)
        tickHalo.cornerRadius = 1.5

        for sublayer in [trackLayer, hatchClip, fillLayer, tickHalo, tickInk] {
            layer?.addSublayer(sublayer)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(restyle), name: MacTheme.Chrome.didRepaint, object: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    override func layout() {
        super.layout()
        lay()
        restyle()
    }

    private var tickOverhang: CGFloat { max(2, min(4, (barHeight / 2).rounded())) }

    private func lay() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let width = bounds.width
        let height = barHeight
        let radius = height / 2
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        trackLayer.frame = frame
        trackLayer.cornerRadius = radius

        let fill = min(max(reading.fill, 0), 1)
        let fillWidth = fill > 0 ? max((fill * width).rounded(), height) : 0
        fillLayer.frame = CGRect(x: 0, y: 0, width: min(fillWidth, width), height: height)
        fillLayer.cornerRadius = radius
        fillLayer.isHidden = fill <= 0

        let tail = showsTail ? reading.tailEnd.map { min(max($0, 0), 1) } : nil
        if let tail, tail * width > fillWidth {
            hatchClip.isHidden = false
            hatchClip.frame = frame
            hatchClip.cornerRadius = radius
            hatchLayer.frame = CGRect(x: 0, y: 0, width: width, height: height)
            hatchLayer.path = Self.stripes(width: width, height: height)
            let start = min(fillWidth, width)
            hatchRange.frame = CGRect(x: start, y: 0, width: max(0, tail * width - start), height: height)
        } else {
            hatchClip.isHidden = true
        }

        if let tick = reading.tick {
            let x = min(max(tick, 0), 1) * width
            let overhang = tickOverhang
            tickInk.frame = CGRect(
                x: x - Self.tickWidth / 2, y: -overhang, width: Self.tickWidth,
                height: height + 2 * overhang)
            tickHalo.frame = tickInk.frame.insetBy(dx: -1, dy: -1)
            tickInk.isHidden = false
            tickHalo.isHidden = false
            let alpha: Float = reading.tickApproximate ? Self.approximateAlpha : 1
            tickInk.opacity = alpha
            tickHalo.opacity = alpha
        } else {
            tickInk.isHidden = true
            tickHalo.isHidden = true
        }
    }

    /// Diagonal strokes at 45 degrees across the whole track, leaving it to the range mask to say
    /// where the tail begins and ends.
    private static func stripes(width: CGFloat, height: CGFloat) -> CGPath {
        let path = CGMutablePath()
        var x = -height
        while x < width + height {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x + height, y: height))
            x += stripePitch
        }
        return path
    }

    @objc private func restyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            trackLayer.backgroundColor = trackInk().cgColor
            fillLayer.backgroundColor = Self.ink(reading.fillTone, slug: reading.slug).cgColor
            hatchLayer.strokeColor = Self.ink(reading.tailTone, slug: reading.slug).cgColor
            tickInk.backgroundColor = MacTheme.Color.label.cgColor
            tickHalo.backgroundColor = surround().cgColor
            CATransaction.commit()
        }
    }

    /// Where a register's colour comes from: a quiet tank wears its provider's colour, or the
    /// accent where it has none, and the other two are the app's own meanings.
    private static func ink(_ tone: ContextFill.Tone, slug: String?) -> NSColor {
        switch tone {
        case .quiet: return UsageFormat.brandColor(slug) ?? MacTheme.Color.accent
        case .attention: return MacTheme.Color.warning
        case .danger: return MacTheme.Color.danger
        }
    }
}

/// The one line of words a pace row owes under its bar: the lead in small caps and the tone's
/// colour, the body in secondary ink; or, on an opened surface, the quiet remark that is not news.
@MainActor
enum PaceWords {
    static func line(for row: PaceRow, opened: Bool) -> NSView? {
        if let news = row.news {
            let text = NSMutableAttributedString(
                string: news.lead.uppercased() + " ",
                attributes: MacTheme.Ramp.attributes(.metricLabel, color: ink(news.tone)))
            text.append(
                NSAttributedString(
                    string: news.body,
                    attributes: MacTheme.Ramp.attributes(
                        .panelFootnote, color: MacTheme.Color.secondaryLabel)))
            return wrapping(text)
        }
        guard opened, let note = row.note else { return nil }
        return wrapping(
            NSAttributedString(
                string: note,
                attributes: MacTheme.Ramp.attributes(
                    .panelFootnote, color: MacTheme.Color.secondaryLabel)))
    }

    static func ink(_ tone: ContextFill.Tone) -> NSColor {
        switch tone {
        case .quiet: return MacTheme.Color.secondaryLabel
        case .attention: return MacTheme.Color.warning
        case .danger: return MacTheme.Color.danger
        }
    }

    private static func wrapping(_ text: NSAttributedString) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.attributedStringValue = text
        label.isSelectable = false
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}
