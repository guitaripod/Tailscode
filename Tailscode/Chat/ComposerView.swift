import UIKit

@MainActor
protocol ComposerViewDelegate: AnyObject {
    func composerDidSend(_ text: String)
    func composerDidTapAttach()
    func composerDidTapStop()
    func composerDidBeginEditing()
}

@MainActor
final class ComposerView: UIView, UITextViewDelegate {
    weak var delegate: ComposerViewDelegate?

    private let textView = UITextView()
    private let placeholder = UILabel()
    private let sendButton = UIButton(type: .system)
    private let attachButton = UIButton(type: .system)
    private var heightConstraint: NSLayoutConstraint!
    private var isBusy = false

    var showsAttach = true {
        didSet { attachButton.isHidden = !showsAttach }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        backgroundColor = .clear

        let glass = Theme.Glass.view()
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        let hairline = UIView()
        hairline.backgroundColor = Theme.Color.separator.withAlphaComponent(0.6)
        hairline.translatesAutoresizingMaskIntoConstraints = false

        textView.font = Theme.Font.body()
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = Theme.Color.background.withAlphaComponent(0.6)
        textView.layer.cornerRadius = 20
        textView.layer.cornerCurve = .continuous
        textView.layer.borderWidth = 0.5
        textView.layer.borderColor = Theme.Color.separator.cgColor
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        textView.isScrollEnabled = false
        textView.delegate = self
        textView.translatesAutoresizingMaskIntoConstraints = false

        placeholder.text = "Message your agent…"
        placeholder.font = Theme.Font.body()
        placeholder.textColor = Theme.Color.tertiaryLabel
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        attachButton.setImage(
            UIImage(systemName: "paperclip", withConfiguration:
                UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)), for: .normal)
        attachButton.tintColor = Theme.Color.secondaryLabel
        attachButton.translatesAutoresizingMaskIntoConstraints = false
        attachButton.addTarget(self, action: #selector(attachTapped), for: .touchUpInside)

        sendButton.setImage(sendImage(), for: .normal)
        sendButton.tintColor = Theme.Color.accent
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        sendButton.isEnabled = false

        addSubview(hairline)
        addSubview(attachButton)
        addSubview(textView)
        addSubview(placeholder)
        addSubview(sendButton)

        heightConstraint = textView.heightAnchor.constraint(equalToConstant: 40)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),

            hairline.topAnchor.constraint(equalTo: topAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 0.5),

            attachButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.m),
            attachButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor, constant: -8),
            attachButton.widthAnchor.constraint(equalToConstant: 32),
            attachButton.heightAnchor.constraint(equalToConstant: 32),

            textView.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.s),
            textView.bottomAnchor.constraint(
                equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -Theme.Spacing.s),
            textView.leadingAnchor.constraint(equalTo: attachButton.trailingAnchor, constant: Theme.Spacing.s),
            heightConstraint,

            sendButton.leadingAnchor.constraint(equalTo: textView.trailingAnchor, constant: Theme.Spacing.s),
            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.m),
            sendButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor, constant: -4),
            sendButton.widthAnchor.constraint(equalToConstant: 32),

            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 14),
            placeholder.topAnchor.constraint(equalTo: textView.topAnchor, constant: 8),
        ])
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        textView.layer.borderColor = Theme.Color.separator.cgColor
    }

    private func sendImage() -> UIImage? {
        UIImage(
            systemName: isBusy ? "stop.circle.fill" : "arrow.up.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 28))
    }

    func setBusy(_ busy: Bool) {
        isBusy = busy
        sendButton.setImage(sendImage(), for: .normal)
        sendButton.isEnabled = busy || !trimmed.isEmpty
        sendButton.tintColor = busy ? Theme.Color.danger : Theme.Color.accent
    }

    private var trimmed: String {
        textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        delegate?.composerDidBeginEditing()
    }

    func textViewDidChange(_ textView: UITextView) {
        placeholder.isHidden = !textView.text.isEmpty
        let size = textView.sizeThatFits(
            CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude))
        heightConstraint.constant = min(max(40, size.height), 132)
        textView.isScrollEnabled = size.height > 132
        if !isBusy { sendButton.isEnabled = !trimmed.isEmpty }
    }

    @objc private func sendTapped() {
        if isBusy {
            delegate?.composerDidTapStop()
            return
        }
        let text = trimmed
        guard !text.isEmpty else { return }
        Theme.Haptics.tap()
        delegate?.composerDidSend(text)
        textView.text = ""
        textViewDidChange(textView)
    }

    @objc private func attachTapped() { delegate?.composerDidTapAttach() }
}
