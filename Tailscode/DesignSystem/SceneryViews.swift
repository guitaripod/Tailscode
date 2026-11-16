import TailscodeCore
import UIKit

extension UITraitCollection {
    /// What the theme in force draws besides its colours. Nothing under "System" and nothing for
    /// a theme that is only a palette, which is nearly all of them.
    var scenery: Scenery? { palette?.scenery }
}

/// The sky behind a conversation: the canvas, and on it the stars or the dunes of the theme the
/// window is wearing.
///
/// It is the transcript's own ground rather than a picture over it, so it sits under the list,
/// is opaque, holds perfectly still and is drawn once for a size. Under a theme with no scenery
/// it is hidden and the list keeps the ground it always had.
@MainActor
final class SkyView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = true
        contentMode = .redraw
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (view: SkyView, _) in view.refresh()
        }
        refresh()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        isHidden = traitCollection.scenery == nil
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let palette = traitCollection.palette, let scenery = palette.scenery,
            let context = UIGraphicsGetCurrentContext()
        else { return }
        SceneryPainter.drawSky(scenery, canvas: palette.canvas, in: context, sky: bounds)
    }
}

/// The two suns of a theme whose day has them, standing on the lower edge of whatever holds this
/// view. In a chat that is the conversation's own title in the bar: the bar is glass and takes
/// no paint, but a title is content, and a sun beside it is never behind a card that scrolls
/// past.
@MainActor
final class HorizonSunsView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isAccessibilityElement = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (view: HorizonSunsView, _) in view.refresh()
        }
        refresh()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var suns: TwinSuns? {
        guard case .suns(let suns) = traitCollection.scenery?.sky else { return nil }
        return suns
    }

    private func refresh() {
        isHidden = suns == nil
        invalidateIntrinsicContentSize()
        setNeedsDisplay()
    }

    /// As wide as the pair with its coronas and as tall as the highest corona stands above the
    /// horizon, so no sun's light is cut by the view that draws it.
    override var intrinsicContentSize: CGSize {
        guard let suns else { return .zero }
        let room = SceneryPainter.span(of: suns)
        let height = suns.suns.map { $0.rise + $0.radius * 3.4 }.max() ?? 0
        return CGSize(width: room.upperBound - room.lowerBound, height: CGFloat(height.rounded(.up)))
    }

    override func draw(_ rect: CGRect) {
        guard let suns, let context = UIGraphicsGetCurrentContext() else { return }
        let room = SceneryPainter.span(of: suns)
        SceneryPainter.drawSuns(
            suns, in: context, horizon: bounds.maxY, leading: bounds.minX - room.lowerBound,
            width: bounds.width)
    }
}

/// A signal drawn as a bar. Under a theme that lights its blades the bar is a core lifted toward
/// white inside its own colour's light; under any other it is the plain bar it always was. A
/// card's rail is its leading edge and the card clips at that edge, so the light falls into the
/// card and not out of it, which is how a pane of glass lit from its edge looks.
@MainActor
final class BladeRailView: UIView {
    var tone: UIColor = Theme.Color.accent {
        didSet { refresh() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (view: BladeRailView, _) in view.refresh()
        }
        refresh()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        let glow = traitCollection.scenery?.bladeGlow ?? 0
        let resolved = tone.resolvedColor(with: traitCollection)
        guard glow > 0 else {
            backgroundColor = tone
            layer.shadowOpacity = 0
            return
        }
        backgroundColor = resolved.liftedTowardWhite(0.55)
        layer.shadowColor = resolved.cgColor
        layer.shadowOffset = .zero
        layer.shadowRadius = CGFloat(glow) * 0.6
        layer.shadowOpacity = 0.95
    }
}

/// The scan lines over what the agent delegated: its card is work happening somewhere else,
/// projected here, in the colour the card's own edge is wearing. Drawn only under a theme that
/// asks for them, and never in daylight.
@MainActor
final class ScanLinesView: UIView {
    /// The colour of the card's edge, told again whenever the edge changes its own.
    var tone: UIColor = Theme.Color.accent {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isAccessibilityElement = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (view: ScanLinesView, _) in view.refresh()
        }
        refresh()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        isHidden = (traitCollection.scenery?.scanLines ?? 0) <= 0
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let scenery = traitCollection.scenery, let context = UIGraphicsGetCurrentContext()
        else { return }
        SceneryPainter.drawScanLines(
            tone: tone.resolvedColor(with: traitCollection).cgColor, share: scenery.scanLines,
            in: context, rect: bounds)
    }

    /// Lays the lines over a card's ground and under everything it says.
    func install(in container: UIView, above ground: UIView) {
        translatesAutoresizingMaskIntoConstraints = false
        container.insertSubview(self, aboveSubview: ground)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: container.topAnchor),
            bottomAnchor.constraint(equalTo: container.bottomAnchor),
            leadingAnchor.constraint(equalTo: container.leadingAnchor),
            trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }
}

/// The place a theme is, on its card in the picker: a few of its stars, or its two suns going
/// down behind a horizon that clears the card's row of signals, in the face the card is showing.
@MainActor
final class SkyCardView: UIView {
    /// The card's inset and its row of signals, which the suns' horizon stands above.
    private static let footing: CGFloat = 34

    var scenery: Scenery? {
        didSet {
            isHidden = scenery == nil
            setNeedsDisplay()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isAccessibilityElement = false
        isHidden = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let scenery, let context = UIGraphicsGetCurrentContext() else { return }
        SceneryPainter.drawCard(scenery, in: context, rect: bounds, footing: Self.footing)
    }
}

/// The edge of the box being typed in, which strikes across from the leading side when the
/// keyboard arrives and withdraws when it leaves. It is the one motion scenery has, it is a
/// transition and never a loop, and it stands aside for a line that means something: a hot
/// effort level already owns that edge, and when it is lit this one is not drawn.
@MainActor
final class StrikeLine {
    let layer = CAGradientLayer()
    private var struck = false

    init() {
        layer.startPoint = CGPoint(x: 0, y: 0.5)
        layer.endPoint = CGPoint(x: 1, y: 0.5)
        layer.anchorPoint = CGPoint(x: 0, y: 0.5)
        layer.shadowOffset = .zero
        layer.transform = CATransform3DMakeScale(0.0001, 1, 1)
        layer.isHidden = true
    }

    /// Dresses the line for the theme in force, or hides it under one with no scenery.
    func wear(_ traits: UITraitCollection) {
        guard let scenery = traits.scenery else {
            layer.isHidden = true
            return
        }
        let accent = Theme.Color.accent.resolvedColor(with: traits)
        let lit = scenery.bladeGlow > 0
        let core = lit ? accent.liftedTowardWhite(0.55) : accent
        layer.colors = [core.cgColor, accent.cgColor]
        layer.shadowColor = accent.cgColor
        layer.shadowRadius = CGFloat(scenery.bladeGlow) * 0.7
        layer.shadowOpacity = lit ? 0.9 : 0
        layer.isHidden = false
    }

    func place(_ frame: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.bounds = CGRect(origin: .zero, size: frame.size)
        layer.position = CGPoint(x: frame.minX, y: frame.midY)
        CATransaction.commit()
    }

    func set(struck: Bool, animated: Bool) {
        guard struck != self.struck else { return }
        self.struck = struck
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.42 : 0)
        CATransaction.setAnimationTimingFunction(
            CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.2, 1))
        CATransaction.setDisableActions(!animated)
        layer.transform = CATransform3DMakeScale(struck ? 1 : 0.0001, 1, 1)
        CATransaction.commit()
    }
}

extension UIColor {
    /// This colour walked toward white, for the core of a bar that is lit.
    func liftedTowardWhite(_ amount: CGFloat) -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return UIColor(
            red: red + (1 - red) * amount, green: green + (1 - green) * amount,
            blue: blue + (1 - blue) * amount, alpha: alpha)
    }
}
