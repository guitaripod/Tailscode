import UIKit

@MainActor
protocol ComposerViewDelegate: AnyObject {
    func composerDidSend(_ text: String)
    func composerDidTapAttach()
    func composerDidTapStop()
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
        backgroundColor = Theme.Color.secondaryBackground
        let separator = UIView()
        separator.backgroundColor = Theme.Color.separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        textView.font = Theme.Font.body()
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = Theme.Color.background
        textView.layer.cornerRadius = Theme.Radius.control
        textView.layer.cornerCurve = .continuous
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        textView.isScrollEnabled = false
        textView.delegate = self
        textView.translatesAutoresizingMaskIntoConstraints = false

        placeholder.text = "Message your agent…"
        placeholder.font = Theme.Font.body()
        placeholder.textColor = Theme.Color.tertiaryLabel
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        attachButton.setImage(UIImage(systemName: "paperclip"), for: .normal)
        attachButton.tintColor = Theme.Color.secondaryLabel
        attachButton.translatesAutoresizingMaskIntoConstraints = false
        attachButton.addTarget(self, action: #selector(attachTapped), for: .touchUpInside)

        sendButton.setImage(sendImage(), for: .normal)
        sendButton.tintColor = Theme.Color.accent
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        sendButton.isEnabled = false

        addSubview(separator)
        addSubview(attachButton)
        addSubview(textView)
        addSubview(placeholder)
        addSubview(sendButton)

        heightConstraint = textView.heightAnchor.constraint(equalToConstant: 38)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),

            attachButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.m),
            attachButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor, constant: -6),
            attachButton.widthAnchor.constraint(equalToConstant: 28),

            textView.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.s),
            textView.bottomAnchor.constraint(
                equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -Theme.Spacing.s),
            textView.leadingAnchor.constraint(equalTo: attachButton.trailingAnchor, constant: Theme.Spacing.s),
            heightConstraint,

            sendButton.leadingAnchor.constraint(equalTo: textView.trailingAnchor, constant: Theme.Spacing.s),
            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.m),
            sendButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor, constant: -4),
            sendButton.widthAnchor.constraint(equalToConstant: 30),

            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 12),
            placeholder.topAnchor.constraint(equalTo: textView.topAnchor, constant: 8),
        ])
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

    func textViewDidChange(_ textView: UITextView) {
        placeholder.isHidden = !textView.text.isEmpty
        let size = textView.sizeThatFits(
            CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude))
        heightConstraint.constant = min(max(38, size.height), 132)
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
