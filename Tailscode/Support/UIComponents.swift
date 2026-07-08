import UIKit

final class PrimaryButton: UIButton {
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
        configuration?.showsActivityIndicator = loading
        isEnabled = !loading
    }

    func setTitle(_ title: String) {
        configuration?.title = title
    }
}

final class FormField: UIView {
    let textField = UITextField()
    private let titleLabel = UILabel()

    init(
        title: String,
        placeholder: String,
        secure: Bool = false,
        keyboard: UIKeyboardType = .default
    ) {
        super.init(frame: .zero)
        titleLabel.text = title.uppercased()
        titleLabel.font = .preferredFont(forTextStyle: .caption2)
        titleLabel.textColor = Theme.Color.secondaryLabel
        titleLabel.adjustsFontForContentSizeCategory = true

        textField.placeholder = placeholder
        textField.borderStyle = .roundedRect
        textField.isSecureTextEntry = secure
        textField.keyboardType = keyboard
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.font = Theme.Font.body()
        textField.adjustsFontForContentSizeCategory = true

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
        titleLabel.font = Theme.Font.headline()
        titleLabel.textColor = Theme.Color.label
        titleLabel.textAlignment = .center

        let messageLabel = UILabel()
        messageLabel.text = message
        messageLabel.font = Theme.Font.subheadline()
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
    private let label = UILabel()

    init() {
        super.init(frame: .zero)
        isHidden = true
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.s),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.s),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.l),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.l),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String, color: UIColor) {
        label.text = text
        backgroundColor = color
        isHidden = false
    }

    func hide() { isHidden = true }
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
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = Theme.Color.label
        label.textAlignment = .center
        label.numberOfLines = 2
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
        titleLabel.font = .preferredFont(forTextStyle: .caption2)
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
