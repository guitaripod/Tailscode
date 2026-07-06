import UIKit

final class PrimaryButton: UIButton {
    init(title: String) {
        super.init(frame: .zero)
        var config = UIButton.Configuration.filled()
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
