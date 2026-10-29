import TailscodeCore
import UIKit

/// The capsule of controls the wall shows for three seconds after a tap on the ground: Done, Dim and
/// Style on glass. On a laptop base it stays on the stable half and carries the hold to approve of
/// whatever asks, so an ask is never answerable only from the screen above the fold.
@MainActor
final class WatchControlsView: UIView {
    static let height: CGFloat = 48

    var onDone: (() -> Void)?
    var onDim: (() -> Void)?
    var onStyle: (() -> Void)?

    let glass: UIVisualEffectView
    let doneButton = UIButton(type: .system)
    let dimButton = UIButton(type: .system)
    let styleButton = UIButton(type: .system)
    let holdPill = WatchPillView()
    private(set) var holdTile: String?

    override init(frame: CGRect) {
        glass = Self.makeGlass()
        super.init(frame: frame)
        overrideUserInterfaceStyle = .dark
        clipsToBounds = true
        layer.cornerCurve = .continuous
        addSubview(glass)
        for button in [doneButton, dimButton, styleButton] { glass.contentView.addSubview(button) }
        glass.contentView.addSubview(holdPill)
        holdPill.isHidden = true
        configure(doneButton, symbol: "xmark", title: String(localized: "Done")) { [weak self] in self?.onDone?() }
        configure(dimButton, symbol: "moon", title: String(localized: "Dim")) { [weak self] in self?.onDim?() }
        configure(styleButton, symbol: "slider.horizontal.3", title: String(localized: "Style")) { [weak self] in self?.onStyle?() }
        doneButton.accessibilityIdentifier = "watch.done"
        dimButton.accessibilityIdentifier = "watch.dim"
        styleButton.accessibilityIdentifier = "watch.style"
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private static func makeGlass() -> UIVisualEffectView {
        if #available(iOS 26.0, *) {
            let effect = UIGlassEffect(style: .regular)
            effect.isInteractive = true
            return UIVisualEffectView(effect: effect)
        }
        return UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    }

    private func configure(_ button: UIButton, symbol: String, title: String, action: @escaping () -> Void) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol)
        configuration.title = title
        configuration.imagePadding = 6
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14)
        configuration.baseForegroundColor = .white
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var attributes = $0
            attributes.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
            return attributes
        }
        button.configuration = configuration
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    }

    func update(dimmed: Bool, ask: WallTile?, palette: WallPalette) {
        var configuration = dimButton.configuration
        configuration?.title = dimmed ? String(localized: "Undim") : String(localized: "Dim")
        configuration?.image = UIImage(systemName: dimmed ? "sun.max" : "moon")
        dimButton.configuration = configuration
        if let ask {
            holdTile = ask.id
            holdPill.apply(
                String(localized: "Hold to approve · \(ask.title)"), size: 14, ink: palette.needs, style: .hold)
            holdPill.isHidden = false
        } else {
            holdTile = nil
            holdPill.isHidden = true
        }
        setNeedsLayout()
    }

    /// Where the hold pill is, in the coordinates of the view that holds the capsule.
    var holdFrame: CGRect? {
        guard !holdPill.isHidden, let parent = superview else { return nil }
        return glass.contentView.convert(holdPill.frame, to: parent)
    }

    func contentWidth(limit: CGFloat) -> CGFloat {
        var width: CGFloat = 8
        for button in [dimButton, styleButton, doneButton] {
            width += button.sizeThatFits(CGSize(width: 400, height: Self.height)).width + 4
        }
        if !holdPill.isHidden { width += min(limit * 0.5, holdPill.naturalWidth() + 8) + 4 }
        return min(limit, width + 4)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        layer.cornerRadius = bounds.height / 2
        var right = bounds.width - 8
        for button in [doneButton, styleButton, dimButton] {
            let width = button.sizeThatFits(CGSize(width: 400, height: bounds.height)).width
            button.frame = CGRect(x: right - width, y: 0, width: width, height: bounds.height)
            right -= width + 4
        }
        if !holdPill.isHidden {
            let height = min(36, bounds.height - 8)
            let width = min(right - 8, holdPill.naturalWidth() + 8)
            holdPill.frame = CGRect(x: 8, y: (bounds.height - height) / 2, width: max(60, width), height: height)
        }
    }
}
