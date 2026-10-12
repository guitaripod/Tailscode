import TailscodeCore
import UIKit

final class PrimaryButton: UIButton {
    private lazy var work = ButtonWorkMark(on: self, tint: Theme.Color.onAccent)

    init(title: String) {
        super.init(frame: .zero)
        var config = Theme.Glass.buttonConfiguration(prominent: true)
        config.title = title
        config.baseBackgroundColor = Theme.Color.accent
        config.cornerStyle = .large
        config.buttonSize = .large
        configuration = config
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func setLoading(_ loading: Bool) {
        work.show(loading, on: self)
        isEnabled = !loading
    }

    func setTitle(_ title: String) {
        configuration?.title = title
    }
}

/// The same shape as ``PrimaryButton`` without the claim: only one action on a
/// screen can be the primary one.
final class SecondaryButton: UIButton {
    private lazy var work = ButtonWorkMark(on: self, tint: Theme.Color.label)

    init(title: String) {
        super.init(frame: .zero)
        var config = Theme.Glass.buttonConfiguration()
        config.title = title
        config.baseForegroundColor = Theme.Color.label
        config.cornerStyle = .large
        config.buttonSize = .large
        configuration = config
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func setLoading(_ loading: Bool) {
        work.show(loading, on: self)
        isEnabled = !loading
    }

    func setTitle(_ title: String) {
        configuration?.title = title
    }
}

final class FormField: UIView {
    let textField = UITextField()
    /// Fired by the keyboard's return key, so a form can be submitted without
    /// dismissing the keyboard and hunting for the button.
    var onSubmit: (() -> Void)?
    private let titleLabel = UILabel()
    private let revealButton = UIButton(type: .system)

    init(
        title: String,
        placeholder: String,
        secure: Bool = false,
        keyboard: UIKeyboardType = .default,
        contentType: UITextContentType? = nil,
        capitalization: UITextAutocapitalizationType = .none,
        returnKey: UIReturnKeyType = .done
    ) {
        super.init(frame: .zero)
        titleLabel.text = title.localizedUppercase
        titleLabel.font = Theme.Ramp.font(.panelFootnote)
        titleLabel.textColor = Theme.Color.secondaryLabel
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityLabel = title

        textField.placeholder = placeholder
        textField.borderStyle = .roundedRect
        textField.isSecureTextEntry = secure
        textField.keyboardType = keyboard
        textField.textContentType = contentType
        textField.autocapitalizationType = capitalization
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.returnKeyType = returnKey
        textField.enablesReturnKeyAutomatically = false
        textField.clearButtonMode = secure ? .never : .whileEditing
        textField.font = Theme.Ramp.font(.answer)
        textField.adjustsFontForContentSizeCategory = true
        textField.accessibilityLabel = title
        textField.addAction(UIAction { [weak self] _ in self?.onSubmit?() }, for: .primaryActionTriggered)

        let stack = UIStackView(arrangedSubviews: [titleLabel, textField])
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.xs
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        if secure { installRevealButton() }
    }

    /// A password typed blind on a phone is the most common reason a correct
    /// password is reported wrong, so a secure field can always show itself.
    private func installRevealButton() {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: "eye",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        config.baseForegroundColor = Theme.Color.secondaryLabel
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: Theme.Spacing.s, bottom: 0, trailing: Theme.Spacing.s)
        revealButton.configuration = config
        revealButton.accessibilityLabel = String(localized: "Show password")
        revealButton.frame = CGRect(x: 0, y: 0, width: 44, height: 34)
        revealButton.addAction(UIAction { [weak self] _ in self?.toggleReveal() }, for: .touchUpInside)
        textField.rightView = revealButton
        textField.rightViewMode = .always
    }

    private func toggleReveal() {
        Theme.Haptics.selection()
        let revealing = textField.isSecureTextEntry
        textField.isSecureTextEntry = !revealing
        revealButton.configuration?.image = UIImage(
            systemName: revealing ? "eye.slash" : "eye",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        revealButton.accessibilityLabel =
            revealing ? String(localized: "Hide password") : String(localized: "Show password")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var text: String { textField.text ?? "" }
    func setText(_ value: String) { textField.text = value }
}

final class EmptyStateView: UIView {
    init(symbol: String, title: String, message: String) {
        super.init(frame: .zero)
        let image = UIImageView(
            image: UIImage(systemName: symbol, withConfiguration:
                UIImage.SymbolConfiguration(pointSize: 44, weight: .regular)))
        image.tintColor = Theme.Color.tertiaryLabel
        image.contentMode = .scaleAspectFit

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = Theme.Ramp.font(.cardTitle)
        titleLabel.textColor = Theme.Color.label
        titleLabel.textAlignment = .center

        let messageLabel = UILabel()
        messageLabel.text = message
        messageLabel.font = Theme.Ramp.font(.panelLabel)
        messageLabel.textColor = Theme.Color.secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [image, titleLabel, messageLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Theme.Spacing.m
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Theme.Spacing.xl),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Theme.Spacing.xl),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

final class BannerView: UIView {
    private let glass = Theme.Glass.view()
    private let icon = UIImageView()
    private let label = UILabel()
    private var visible = false
    private var announced: String?

    init() {
        super.init(frame: .zero)
        isHidden = true
        isAccessibilityElement = true
        accessibilityTraits = .button

        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.layer.cornerRadius = Theme.Radius.card
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true
        glass.isUserInteractionEnabled = false
        addSubview(glass)

        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        label.font = Theme.Ramp.font(.panelDetail)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .left
        label.numberOfLines = 3
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.xs),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.xs),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.l),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.l),

            icon.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: Theme.Spacing.m),
            icon.centerYAnchor.constraint(equalTo: glass.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),

            label.topAnchor.constraint(equalTo: glass.topAnchor, constant: Theme.Spacing.s),
            label.bottomAnchor.constraint(equalTo: glass.bottomAnchor, constant: -Theme.Spacing.s),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Theme.Spacing.s),
            label.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -Theme.Spacing.m),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// - Parameter hint: what a press on the banner does, spoken after the words, because the
    ///   banner is a button and a screen reader cannot see that.
    func show(
        _ text: String, color: UIColor, symbol: String = "wifi.exclamationmark",
        hint: String? = nil
    ) {
        label.text = text
        accessibilityLabel = text
        accessibilityHint = hint
        if announced != text {
            announced = text
            UIAccessibility.post(notification: .announcement, argument: text)
        }
        label.textColor = color
        icon.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        icon.tintColor = color
        Theme.Glass.tint(glass, with: color)
        guard !visible else { return }
        visible = true
        isHidden = false
        guard !UIAccessibility.isReduceMotionEnabled else {
            alpha = 1
            transform = .identity
            return
        }
        alpha = 0
        transform = CGAffineTransform(translationX: 0, y: -12)
        UIView.animate(
            withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0.4
        ) {
            self.alpha = 1
            self.transform = .identity
        }
    }

    func hide() {
        guard visible else { return }
        visible = false
        announced = nil
        guard !UIAccessibility.isReduceMotionEnabled else {
            alpha = 0
            isHidden = true
            transform = .identity
            return
        }
        UIView.animate(
            withDuration: 0.2,
            animations: {
                self.alpha = 0
                self.transform = CGAffineTransform(translationX: 0, y: -12)
            },
            completion: { _ in
                guard !self.visible else { return }
                self.isHidden = true
                self.transform = .identity
            })
    }
}

/// Empty-chat hero with tappable glass prompt-starter chips.
final class ChatEmptyStateView: UIView {
    var onSuggestion: ((String) -> Void)?

    private let scroll = UIScrollView()
    private var contentHeights: [NSLayoutConstraint] = []

    /// How much of the bottom edge the chat's own chrome covers, so the starters are centred in
    /// what can be seen and a large type size can scroll the last one clear of the facts row.
    var bottomClearance: CGFloat = 0 {
        didSet {
            guard abs(bottomClearance - oldValue) > 0.5 else { return }
            scroll.contentInset.bottom = bottomClearance
            contentHeights.forEach { $0.constant = -bottomClearance }
        }
    }

    init() {
        super.init(frame: .zero)
        let image = UIImageView(
            image: UIImage(
                systemName: "sparkles",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 40, weight: .regular)))
        image.tintColor = Theme.Color.accent
        image.contentMode = .scaleAspectFit

        let titleLabel = UILabel()
        titleLabel.text = ChatSuggestion.headline
        titleLabel.font = Theme.Ramp.font(.cardTitle)
        titleLabel.textColor = Theme.Color.label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.adjustsFontForContentSizeCategory = true

        let stack = UIStackView(arrangedSubviews: [image, titleLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Theme.Spacing.m
        stack.setCustomSpacing(Theme.Spacing.xl, after: titleLabel)

        for suggestion in ChatSuggestion.all {
            var config = Theme.Glass.buttonConfiguration()
            config.image = UIImage(
                systemName: suggestion.symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium))
            config.title = suggestion.title
            config.imagePadding = Theme.Spacing.s
            config.baseForegroundColor = Theme.Color.label
            let metrics = UIFontMetrics(forTextStyle: .body)
            let vertical = metrics.scaledValue(for: 10)
            let horizontal = metrics.scaledValue(for: 14)
            config.contentInsets = NSDirectionalEdgeInsets(
                top: vertical, leading: horizontal, bottom: vertical, trailing: horizontal)
            let button = UIButton(configuration: config)
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: TouchSlop.hit).isActive = true
            button.addAction(
                UIAction { [weak self] _ in
                    Theme.Haptics.selection()
                    self?.onSuggestion?(suggestion.prompt)
                }, for: .touchUpInside)
            stack.addArrangedSubview(button)
            stack.setCustomSpacing(Theme.Spacing.s, after: button)
        }

        arrange(stack)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (view: ChatEmptyStateView, _) in view.arrange(stack)
        }
        scroll.alwaysBounceVertical = false
        scroll.showsVerticalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        addSubview(scroll)
        let content = scroll.contentLayoutGuide
        let frame = scroll.frameLayoutGuide
        let floor = content.heightAnchor.constraint(greaterThanOrEqualTo: frame.heightAnchor)
        let settled = content.heightAnchor.constraint(equalTo: frame.heightAnchor)
        settled.priority = .defaultLow
        contentHeights = [floor, settled]
        NSLayoutConstraint.activate([
            floor,
            settled,
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.widthAnchor.constraint(equalTo: frame.widthAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: Theme.Spacing.xl),
            stack.bottomAnchor.constraint(
                lessThanOrEqualTo: content.bottomAnchor, constant: -Theme.Spacing.xl),
            content.heightAnchor.constraint(
                greaterThanOrEqualTo: stack.heightAnchor, constant: 2 * Theme.Spacing.xl),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: -Theme.Spacing.xl)
                .withPriority(.defaultHigh),
            stack.leadingAnchor.constraint(
                greaterThanOrEqualTo: content.leadingAnchor, constant: Theme.Spacing.xl),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: content.trailingAnchor, constant: -Theme.Spacing.xl),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Starters are centred while their words fit on a line each, and take the full width once the
    /// reader's type is large enough that a centred capsule would wrap a title into a circle.
    private func arrange(_ stack: UIStackView) {
        stack.alignment =
            traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? .fill : .center
    }
}

final class ToastView: UIView {
    private let glass = Theme.Glass.view()
    private let label = UILabel()
    private var autoHideTask: Task<Void, Never>?

    init(message: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true

        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.layer.cornerRadius = Theme.Radius.control
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true
        glass.isUserInteractionEnabled = false
        addSubview(glass)

        label.text = message
        label.font = Theme.Ramp.font(.panelLabel)
        label.textColor = Theme.Color.onGlass
        label.textAlignment = .center
        label.numberOfLines = 4
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),

            label.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.m),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.m),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.l),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.l),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func flash(in parent: UIView, above anchor: NSLayoutYAxisAnchor, duration: TimeInterval = 2.0) {
        autoHideTask?.cancel()
        parent.addSubview(self)
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.centerXAnchor),
            bottomAnchor.constraint(equalTo: anchor, constant: -Theme.Spacing.m),
            widthAnchor.constraint(
                lessThanOrEqualTo: parent.safeAreaLayoutGuide.widthAnchor,
                constant: -2 * Theme.Spacing.l),
        ])
        alpha = 0
        transform = CGAffineTransform(translationX: 0, y: 10)
        isHidden = false
        UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseOut) {
            self.alpha = 1
            self.transform = .identity
        }
        autoHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            UIView.animate(withDuration: 0.2, animations: {
                self.alpha = 0
                self.transform = CGAffineTransform(translationX: 0, y: 10)
            }, completion: { _ in
                self.removeFromSuperview()
            })
        }
    }
}

final class AttachmentChip: UIView {
    let onRemove: () -> Void

    init(label: String, image: UIImage? = nil, onRemove: @escaping () -> Void) {
        self.onRemove = onRemove
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = Theme.Color.secondaryBackground
        layer.cornerRadius = Theme.Radius.control
        layer.cornerCurve = .continuous

        let iconView: UIView
        if let image {
            let iv = UIImageView(image: image)
            iv.contentMode = .scaleAspectFill
            iv.clipsToBounds = true
            iv.layer.cornerRadius = 4
            iv.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                iv.widthAnchor.constraint(equalToConstant: 28),
                iv.heightAnchor.constraint(equalToConstant: 28),
            ])
            iconView = iv
        } else {
            let iv = UIImageView(image: UIImage(
                systemName: "doc",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)))
            iv.tintColor = Theme.Color.secondaryLabel
            iv.contentMode = .scaleAspectFit
            iv.translatesAutoresizingMaskIntoConstraints = false
            iconView = iv
        }

        let titleLabel = UILabel()
        titleLabel.text = label
        titleLabel.font = Theme.Ramp.font(.panelFootnote)
        titleLabel.textColor = Theme.Color.label
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let removeButton = UIButton(type: .system)
        var removeConfig = UIButton.Configuration.plain()
        removeConfig.image = UIImage(
            systemName: "xmark.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        removeConfig.baseForegroundColor = Theme.Color.tertiaryLabel
        removeConfig.contentInsets = .zero
        removeButton.configuration = removeConfig
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.addAction(UIAction { [weak self] _ in self?.onRemove() }, for: .touchUpInside)

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(removeButton)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.s),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Theme.Spacing.s),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: removeButton.leadingAnchor, constant: -Theme.Spacing.xs),

            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.s),
            removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 20),
            removeButton.heightAnchor.constraint(equalToConstant: 20),

            heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}
