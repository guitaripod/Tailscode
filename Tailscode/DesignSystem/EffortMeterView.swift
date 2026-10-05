import TailscodeCore
import UIKit

/// How hard a model is asked to think, drawn as the five bars every effort surface shares.
///
/// Heat is a magnitude, so it is drawn as one: a known tier lights its rank, ultracode lights
/// every bar in the rainbow it owns, the server deciding is five hollow bars rather than a blank,
/// and a level under low is one dim ember. The colour sits on the bars and never on a word, so a
/// reading is told by shape and still correct where the ink is flattened.
final class EffortMeterView: UIView {
    struct Reading: Equatable {
        var heat: Int
        var level: String?
        var isPower: Bool
        var isServer: Bool
        var isEmber: Bool

        static let hidden = Reading(heat: 0, level: nil, isPower: false, isServer: true, isEmber: false)

        init(heat: Int, level: String?, isPower: Bool, isServer: Bool, isEmber: Bool) {
            self.heat = heat
            self.level = level
            self.isPower = isPower
            self.isServer = isServer
            self.isEmber = isEmber
        }

        init(face: DialFace, level: String?) {
            self.init(
                heat: face.heat, level: level, isPower: face.isPower, isServer: face.isServer,
                isEmber: face.isEmber)
        }

        init(rung: EffortRung) {
            self.init(
                heat: rung.heat, level: rung.level, isPower: rung.isPower, isServer: rung.isServer,
                isEmber: rung.isEmber)
        }

        init(level: String?, options: [String]) {
            self.init(
                heat: ModelDial.heat(level, options: options), level: level,
                isPower: ModelDial.isPower(level),
                isServer: level.map(EffortVocabulary.isAutomatic) ?? true,
                isEmber: ModelDial.isEmber(level))
        }
    }

    static let barWidth: CGFloat = 4
    static let gap: CGFloat = 2
    static let heights: [CGFloat] = [5, 7, 9, 11, 14]
    static let size = CGSize(
        width: CGFloat(EffortMeter.bars) * barWidth + CGFloat(EffortMeter.bars - 1) * gap,
        height: heights.last ?? 14)

    var reading = Reading.hidden {
        didSet {
            guard reading != oldValue else { return }
            setNeedsDisplay()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (view: EffortMeterView, _) in view.setNeedsDisplay()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    convenience init(reading: Reading) {
        self.init(frame: CGRect(origin: .zero, size: Self.size))
        self.reading = reading
    }

    override var intrinsicContentSize: CGSize { Self.size }

    override func draw(_ rect: CGRect) {
        Self.paint(reading, in: bounds, traits: traitCollection)
    }

    /// The bars at their own size, for a menu row that can only take an image.
    static func image(for reading: Reading, dot: UIColor? = nil) -> UIImage {
        let dotSize: CGFloat = dot == nil ? 0 : 9
        let spacing: CGFloat = dot == nil ? 0 : 7
        let canvas = CGSize(width: dotSize + spacing + size.width, height: size.height)
        let traits = UITraitCollection.current
        return UIGraphicsImageRenderer(size: canvas).image { _ in
            if let dot {
                dot.resolvedColor(with: traits).setFill()
                UIBezierPath(
                    ovalIn: CGRect(x: 0, y: (canvas.height - dotSize) / 2, width: dotSize, height: dotSize)
                ).fill()
            }
            paint(
                reading, in: CGRect(x: dotSize + spacing, y: 0, width: size.width, height: size.height),
                traits: traits)
        }.withRenderingMode(.alwaysOriginal)
    }

    /// A filled circle in a family's hue, for a menu row that names a model and nothing else.
    static func dotImage(_ color: UIColor) -> UIImage {
        let traits = UITraitCollection.current
        let side: CGFloat = 9
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            color.resolvedColor(with: traits).setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: side, height: side)).fill()
        }.withRenderingMode(.alwaysOriginal)
    }

    private static func paint(_ reading: Reading, in rect: CGRect, traits: UITraitCollection) {
        let unlit = UIColor.label.withAlphaComponent(0.17).resolvedColor(with: traits)
        let hollow = Theme.Color.tertiaryLabel.resolvedColor(with: traits)
        for index in 0..<EffortMeter.bars {
            let height = heights[index]
            let bar = CGRect(
                x: rect.minX + CGFloat(index) * (barWidth + gap), y: rect.maxY - height,
                width: barWidth, height: height)
            let path = UIBezierPath(roundedRect: bar, cornerRadius: 1.5)
            if reading.isServer {
                hollow.setStroke()
                let inset = UIBezierPath(
                    roundedRect: bar.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 1.2)
                inset.lineWidth = 1
                inset.stroke()
                continue
            }
            guard index < reading.heat else {
                unlit.setFill()
                path.fill()
                continue
            }
            heat(for: reading, bar: index, traits: traits).setFill()
            path.fill()
        }
    }

    private static func heat(for reading: Reading, bar: Int, traits: UITraitCollection) -> UIColor {
        if reading.isPower {
            return Theme.Color.modelRainbowLetter(bar, of: EffortMeter.bars).resolvedColor(with: traits)
        }
        let base = reading.level.flatMap { Theme.Color.modelEffort($0) } ?? Theme.Color.secondaryLabel
        let color = base.resolvedColor(with: traits)
        return reading.isEmber ? color.withAlphaComponent(0.55) : color
    }
}
