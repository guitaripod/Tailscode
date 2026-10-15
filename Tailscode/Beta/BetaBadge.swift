import TailscodeCore
import UIKit

/// The mark a feature wears while it is in beta, as a control: the capsule is the whole
/// announcement and a tap opens the card behind it. Every word is the catalog's.
///
/// A mark nobody has opened, or whose card has something newer than the version it was last opened
/// at, is announced once by a single pass of light across the capsule and then holds perfectly
/// still. The pass is read from absolute time off the display's clock, at most once per process per
/// feature, and the clock comes off the moment the pass ends; a settled mark runs none.
@MainActor
final class BetaBadge: UIControl {
    private static var announced: Set<BetaFeature> = []

    let feature: BetaFeature
    private let reportLines: () -> [String]
    private let interactive: Bool
    private let label = UILabel()
    private let symbol = UIImageView(image: UIImage(systemName: "sparkles"))
    private let sheen = CAGradientLayer()
    private var link: CADisplayLink?
    private var passStart: CFTimeInterval = 0
    private var hasCheckedFreshness = false

    init(feature: BetaFeature, reportLines: @escaping () -> [String], interactive: Bool = true) {
        self.feature = feature
        self.reportLines = reportLines
        self.interactive = interactive
        super.init(frame: .zero)
        isAccessibilityElement = interactive
        accessibilityLabel = feature.card.spoken
        accessibilityTraits = .button
        isUserInteractionEnabled = interactive
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.masksToBounds = true
        label.attributedText = NSAttributedString(
            string: BetaWords.badge, attributes: [.font: Self.font, .kern: 1.1])
        label.adjustsFontForContentSizeCategory = true
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        symbol.contentMode = .center
        let stack = UIStackView(arrangedSubviews: [symbol, label])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 3
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
        ])
        sheen.startPoint = CGPoint(x: 0, y: 0.5)
        sheen.endPoint = CGPoint(x: 1, y: 0.5)
        sheen.isHidden = true
        layer.addSublayer(sheen)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        addAction(UIAction { [weak self] _ in self?.tapped() }, for: .touchUpInside)
        paint()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (badge: BetaBadge, _) in badge.paint()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(settle), name: BetaSeenStore.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(settle), name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.55 : 1 }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        TouchSlop.area(of: bounds).contains(point)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        sheen.bounds = CGRect(x: 0, y: 0, width: bounds.width * Self.sheenShare, height: bounds.height)
        if !hasCheckedFreshness, isOnScreen { announceIfFresh() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        hasCheckedFreshness = false
        guard window != nil else {
            endPass()
            return
        }
        setNeedsLayout()
    }

    /// A mark worn by something that is not drawn yet — a dock waiting for a call — is not on
    /// screen, and light played for nobody would use up the one announcement it gets.
    private var isOnScreen: Bool {
        guard window != nil, !bounds.isEmpty else { return false }
        var view: UIView? = self
        while let current = view {
            if current.isHidden || current.alpha == 0 { return false }
            view = current.superview
        }
        return true
    }

    private static let sheenShare: CGFloat = 0.7

    /// The footnote weight of the ramp, set bold and rounded: a badge is read in one glance.
    private static var font: UIFont {
        let base = Theme.Ramp.font(.panelFootnote)
        var descriptor = base.fontDescriptor.withSymbolicTraits(.traitBold) ?? base.fontDescriptor
        descriptor = descriptor.withDesign(.rounded) ?? descriptor
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }

    /// Whether a mark is announced by light: only a fresh one, only the first time this process
    /// draws it, and never where the reader asked for less motion.
    static func announces(_ freshness: BetaFreshness, already: Bool, reducedMotion: Bool) -> Bool {
        freshness.isFresh && !already && !reducedMotion
    }

    private func paint() {
        let tint = Theme.Color.special
        backgroundColor = tint.withAlphaComponent(0.14)
        layer.borderColor = tint.withAlphaComponent(0.45).cgColor
        label.textColor = tint
        symbol.tintColor = tint
        let ink = tint.resolvedColor(with: traitCollection)
        sheen.colors = [
            ink.withAlphaComponent(0).cgColor, ink.withAlphaComponent(0.4).cgColor,
            ink.withAlphaComponent(0).cgColor,
        ]
    }

    private func announceIfFresh() {
        hasCheckedFreshness = true
        guard interactive else { return }
        let freshness = BetaSeenStore.freshness(feature, current: BetaEnvironment.appVersion)
        guard
            Self.announces(
                freshness, already: Self.announced.contains(feature),
                reducedMotion: UIAccessibility.isReduceMotionEnabled)
        else { return }
        Self.announced.insert(feature)
        startPass()
    }

    private func startPass() {
        guard link == nil else { return }
        passStart = CACurrentMediaTime()
        sheen.isHidden = false
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.runAtActivityTempo()
        link.add(to: .main, forMode: .common)
        self.link = link
        place(progress: 0)
    }

    @objc private func step(_ link: CADisplayLink) {
        let elapsed = max(0, link.timestamp - passStart)
        guard
            let progress = BetaSheen.progress(
                elapsed: elapsed, reducedMotion: UIAccessibility.isReduceMotionEnabled)
        else {
            endPass()
            return
        }
        place(progress: progress)
    }

    private func place(progress: Double) {
        let width = sheen.bounds.width
        let travel = bounds.width + width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sheen.position = CGPoint(x: -width / 2 + travel * CGFloat(progress), y: bounds.midY)
        CATransaction.commit()
    }

    private func endPass() {
        link?.invalidate()
        link = nil
        sheen.isHidden = true
    }

    @objc private func settle() {
        guard link != nil else { return }
        endPass()
    }

    private func tapped() {
        Theme.Haptics.tap()
        endPass()
        guard let presenter = presenter else { return }
        BetaCardViewController.present(feature: feature, reportLines: reportLines, from: presenter)
    }

    /// The topmost screen above this mark, found through the responder chain so the mark opens its
    /// card wherever it is worn: a bar, a dock, a title.
    private var presenter: UIViewController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let controller = next as? UIViewController {
                var top = controller
                while let above = top.presentedViewController, !above.isBeingDismissed { top = above }
                return top is BetaCardViewController ? nil : top
            }
            responder = next
        }
        return nil
    }
}
