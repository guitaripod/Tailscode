import TailscodeCore
import UIKit

/// Lays its subviews out left to right and wraps them at its width, so a row of chips grows by
/// lines as the type size grows rather than scrolling sideways or shrinking a label.
final class ShareFlowView: UIView {
    static let minimumHit: CGFloat = 44

    private let spacing: CGFloat
    private var heightConstraint: NSLayoutConstraint?

    init(items: [UIView], spacing: CGFloat = Theme.Spacing.s) {
        self.spacing = spacing
        super.init(frame: .zero)
        for item in items { addSubview(item) }
        let height = heightAnchor.constraint(equalToConstant: Self.minimumHit)
        height.isActive = true
        heightConstraint = height
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        guard width > 0 else { return }
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for item in subviews where !item.isHidden {
            let wanted = item.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            let size = CGSize(
                width: min(width, max(Self.minimumHit, wanted.width.rounded(.up))),
                height: max(Self.minimumHit, wanted.height.rounded(.up)))
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            item.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        let total = y + rowHeight
        if abs((heightConstraint?.constant ?? 0) - total) > 0.5 {
            heightConstraint?.constant = total
        }
    }
}

/// One module's switch. It reads three facts and draws them three ways that do not lean on colour
/// alone: lit and filled when the module is in the picture, plain when it is not, and, when the
/// account cannot fill it, dimmed with the reason in words under the name. A chip that is merely
/// refused for room stays pressable, because the press is what says why.
final class ShareChipButton: UIButton {
    let module: ShareModule
    private(set) var isOn = false
    private(set) var reason: String?
    private(set) var isUnavailable = false

    init(module: ShareModule) {
        self.module = module
        super.init(frame: .zero)
        accessibilityLabel = module.title
        changesSelectionAsPrimaryAction = false
        configuration = Self.make(module: module, isOn: false, unavailableReason: nil)
        configurationUpdateHandler = { [weak self] button in
            guard let self else { return }
            button.configuration = Self.make(
                module: self.module, isOn: self.isOn,
                unavailableReason: self.isUnavailable ? self.reason : nil)
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func apply(_ state: ShareFit.ChipState, unavailable: Bool) {
        isOn = state == .on
        isUnavailable = unavailable
        if case .blocked(let why) = state { reason = why } else { reason = nil }
        isEnabled = !unavailable
        isSelected = isOn
        accessibilityHint = reason
        accessibilityTraits = isOn ? [.button, .selected] : [.button]
        if unavailable { accessibilityTraits.insert(.notEnabled) }
        setNeedsUpdateConfiguration()
    }

    private static func make(
        module: ShareModule, isOn: Bool, unavailableReason: String?
    ) -> UIButton.Configuration {
        var config: UIButton.Configuration = isOn ? .filled() : .gray()
        config.cornerStyle = .capsule
        config.title = module.title
        config.image = UIImage(systemName: module.symbolName)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(scale: .small)
        config.imagePadding = Theme.Spacing.s
        config.titleAlignment = .leading
        config.contentInsets = NSDirectionalEdgeInsets(
            top: Theme.Spacing.m, leading: Theme.Spacing.l, bottom: Theme.Spacing.m,
            trailing: Theme.Spacing.l)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var attributes = $0
            attributes.font = Theme.Ramp.font(.control)
            return attributes
        }
        if let unavailableReason {
            config.subtitle = unavailableReason
            config.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
                var attributes = $0
                attributes.font = Theme.Ramp.font(.panelFootnote)
                return attributes
            }
        }
        if isOn {
            config.baseBackgroundColor = Theme.Color.accent
            config.baseForegroundColor = Theme.Color.onAccent
        } else {
            config.baseForegroundColor = Theme.Color.label
        }
        return config
    }
}
