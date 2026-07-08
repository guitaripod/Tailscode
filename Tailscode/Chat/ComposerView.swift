import UIKit

@MainActor
protocol ComposerViewDelegate: AnyObject {
    func composerDidSend(_ text: String)
    func composerTextDidChange(_ text: String)
    func composerDidRequestSendOptions(from view: UIView)
    func composerDidPasteLargeText(_ text: String)
    func composerDidTapAttach()
    func composerDidTapStop()
    func composerDidBeginEditing()
}

@MainActor
final class ComposerView: UIView, UITextViewDelegate, UIGestureRecognizerDelegate {
    weak var delegate: ComposerViewDelegate?

    private let bar = Theme.Glass.view(interactive: false)
    private let textView = UITextView()
    private let placeholder = UILabel()
    private let sendButton = UIButton(type: .system)
    private let attachButton = UIButton(type: .system)
    private var heightConstraint: NSLayoutConstraint!
    private var isBusy = false

    var showsAttach = true {
        didSet {
            attachButton.isHidden = !showsAttach
            textViewLeading?.constant = showsAttach ? Theme.Spacing.xs : Theme.Spacing.m
        }
    }
    private var textViewLeading: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        backgroundColor = .clear

        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.layer.cornerRadius = 23
        bar.layer.cornerCurve = .continuous
        bar.clipsToBounds = true
        bar.isUserInteractionEnabled = false
        addSubview(bar)

        textView.font = Theme.Font.body()
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 1, left: 0, bottom: 1, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.autocorrectionType = .yes
        textView.isScrollEnabled = false
        textView.delegate = self
        textView.translatesAutoresizingMaskIntoConstraints = false

        placeholder.text = "Message your agent…"
        placeholder.font = Theme.Font.body()
        placeholder.textColor = Theme.Color.tertiaryLabel
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        attachButton.setImage(
            UIImage(systemName: "plus", withConfiguration:
                UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
        attachButton.tintColor = Theme.Color.secondaryLabel
        attachButton.translatesAutoresizingMaskIntoConstraints = false
        attachButton.addTarget(self, action: #selector(attachTapped), for: .touchUpInside)

        var send = UIButton.Configuration.filled()
        send.cornerStyle = .capsule
        send.baseBackgroundColor = Theme.Color.accent
        sendButton.configuration = send
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        let longPress = UILongPressGestureRecognizer(
            target: self, action: #selector(sendLongPressed))
        sendButton.addGestureRecognizer(longPress)

        [attachButton, textView, placeholder, sendButton].forEach(addSubview)

        heightConstraint = textView.heightAnchor.constraint(equalToConstant: 22)
        let leading = textView.leadingAnchor.constraint(
            equalTo: attachButton.trailingAnchor, constant: Theme.Spacing.xs)
        textViewLeading = leading

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.xs),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.l),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.l),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.s),

            attachButton.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: Theme.Spacing.s),
            attachButton.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -7),
            attachButton.widthAnchor.constraint(equalToConstant: 32),
            attachButton.heightAnchor.constraint(equalToConstant: 32),

            textView.topAnchor.constraint(equalTo: bar.topAnchor, constant: 11),
            textView.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -11),
            leading,
            heightConstraint,

            sendButton.leadingAnchor.constraint(equalTo: textView.trailingAnchor, constant: Theme.Spacing.xs),
            sendButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -Theme.Spacing.xs),
            sendButton.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -5),
            sendButton.widthAnchor.constraint(equalToConstant: 34),
            sendButton.heightAnchor.constraint(equalToConstant: 34),

            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 2),
            placeholder.centerYAnchor.constraint(equalTo: attachButton.centerYAnchor),
        ])

        let focusTap = UITapGestureRecognizer(target: self, action: #selector(focusInput))
        focusTap.cancelsTouchesInView = false
        focusTap.delegate = self
        addGestureRecognizer(focusTap)

        updateSendButton()
    }

    @objc private func focusInput() { textView.becomeFirstResponder() }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
    ) -> Bool {
        !(touch.view is UIControl)
    }

    private func updateSendButton() {
        let symbol = isBusy ? "stop.fill" : "arrow.up"
        let hasText = !trimmed.isEmpty
        let enabled = isBusy || hasText
        var config = sendButton.configuration ?? .filled()
        config.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold))
        config.baseBackgroundColor =
            isBusy ? Theme.Color.danger : (hasText ? Theme.Color.accent : Theme.Color.separator)
        config.baseForegroundColor = .white
        sendButton.configuration = config
        sendButton.isEnabled = enabled
    }

    func setBusy(_ busy: Bool) {
        isBusy = busy
        updateSendButton()
    }

    private var trimmed: String {
        textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        delegate?.composerDidBeginEditing()
    }

    func textView(
        _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
    ) -> Bool {
        if text.count > 6000 {
            delegate?.composerDidPasteLargeText(text)
            return false
        }
        if text == "\n", AppPreferences.sendOnReturn, !isBusy, !trimmed.isEmpty {
            sendTapped()
            return false
        }
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        placeholder.isHidden = !textView.text.isEmpty
        let size = textView.sizeThatFits(
            CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude))
        heightConstraint.constant = min(max(22, size.height), 132)
        textView.isScrollEnabled = size.height > 132
        updateSendButton()
        delegate?.composerTextDidChange(textView.text)
    }

    @objc private func sendTapped() {
        if isBusy {
            delegate?.composerDidTapStop()
            return
        }
        let text = trimmed
        guard !text.isEmpty else { return }
        Theme.Haptics.send()
        delegate?.composerDidSend(text)
        textView.text = ""
        textViewDidChange(textView)
    }

    @objc private func attachTapped() { delegate?.composerDidTapAttach() }

    @objc private func sendLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, !isBusy, !trimmed.isEmpty else { return }
        Theme.Haptics.tap()
        delegate?.composerDidRequestSendOptions(from: sendButton)
    }

    var currentText: String { trimmed }

    func clear() {
        textView.text = ""
        textViewDidChange(textView)
    }

    func insertQuote(_ text: String) {
        let quoted = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }.joined(separator: "\n")
        let existing = textView.text ?? ""
        textView.text = existing.isEmpty ? "\(quoted)\n\n" : "\(existing)\n\(quoted)\n\n"
        textViewDidChange(textView)
        textView.becomeFirstResponder()
    }
}
