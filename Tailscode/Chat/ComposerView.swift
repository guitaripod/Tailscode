import UIKit

@MainActor
protocol ComposerViewDelegate: AnyObject {
    func composerDidSend(_ text: String)
    func composerTextDidChange(_ text: String)
    func composerDidLongPressSend(from view: UIView)
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
    private let enhanceBadge = UIImageView()
    private var heightConstraint: NSLayoutConstraint!
    private var isBusy = false

    var showsAttach = true {
        didSet {
            attachButton.isHidden = !showsAttach
            if showsAttach {
                textViewLeadingToBar?.isActive = false
                textViewLeadingToAttach?.isActive = true
            } else {
                textViewLeadingToAttach?.isActive = false
                textViewLeadingToBar?.isActive = true
            }
        }
    }
    private var textViewLeadingToAttach: NSLayoutConstraint?
    private var textViewLeadingToBar: NSLayoutConstraint?
    private var lastMeasuredWidth: CGFloat = 0

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
        textView.spellCheckingType = .yes
        textView.inlinePredictionType = .yes
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
        attachButton.accessibilityLabel = "Attach image"

        var send = UIButton.Configuration.filled()
        send.cornerStyle = .capsule
        send.baseBackgroundColor = Theme.Color.accent
        sendButton.configuration = send
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        let longPress = UILongPressGestureRecognizer(
            target: self, action: #selector(sendLongPressed))
        sendButton.addGestureRecognizer(longPress)

        enhanceBadge.image = UIImage(
            systemName: "sparkles",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        enhanceBadge.tintColor = .white
        enhanceBadge.backgroundColor = Theme.Color.accent
        enhanceBadge.contentMode = .center
        enhanceBadge.layer.cornerRadius = 8
        enhanceBadge.layer.borderWidth = 1.5
        enhanceBadge.layer.borderColor = Theme.Color.background.cgColor
        enhanceBadge.alpha = 0
        enhanceBadge.isUserInteractionEnabled = false
        enhanceBadge.translatesAutoresizingMaskIntoConstraints = false

        [attachButton, textView, placeholder, sendButton, enhanceBadge].forEach(addSubview)

        heightConstraint = textView.heightAnchor.constraint(equalToConstant: 22)
        let leading = textView.leadingAnchor.constraint(
            equalTo: attachButton.trailingAnchor, constant: Theme.Spacing.xs)
        textViewLeadingToAttach = leading
        textViewLeadingToBar = textView.leadingAnchor.constraint(
            equalTo: bar.leadingAnchor, constant: Theme.Spacing.m)

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

            enhanceBadge.widthAnchor.constraint(equalToConstant: 16),
            enhanceBadge.heightAnchor.constraint(equalToConstant: 16),
            enhanceBadge.centerXAnchor.constraint(equalTo: sendButton.trailingAnchor, constant: -1),
            enhanceBadge.centerYAnchor.constraint(equalTo: sendButton.topAnchor, constant: 1),
        ])

        let focusTap = UITapGestureRecognizer(target: self, action: #selector(focusInput))
        focusTap.cancelsTouchesInView = false
        focusTap.delegate = self
        addGestureRecognizer(focusTap)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ComposerView, _) in
            view.enhanceBadge.layer.borderColor = Theme.Color.background.cgColor
        }

        updateSendButton()
    }

    @objc private func focusInput() { textView.becomeFirstResponder() }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
    ) -> Bool {
        !(touch.view is UIControl)
    }

    /// While a turn runs the button is Stop, unless the user has typed —
    /// then it becomes a queue-send (steering) button; Stop returns on clear.
    private func updateSendButton() {
        let hasText = !trimmed.isEmpty
        let showStop = isBusy && !hasText
        let symbol = showStop ? "stop.fill" : "arrow.up"
        var config = sendButton.configuration ?? .filled()
        config.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold))
        config.baseBackgroundColor =
            showStop ? Theme.Color.danger : (hasText ? Theme.Color.accent : Theme.Color.separator)
        config.baseForegroundColor = .white
        sendButton.configuration = config
        sendButton.isEnabled = isBusy || hasText
        sendButton.accessibilityLabel = showStop ? "Stop" : (isBusy ? "Queue message" : "Send")
    }

    func setBusy(_ busy: Bool) {
        guard isBusy != busy else { return }
        isBusy = busy
        placeholder.text = busy ? "Queue a message…" : "Message your agent…"
        UIView.transition(with: sendButton, duration: 0.2, options: .transitionCrossDissolve) {
            self.updateSendButton()
        }
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if textView.bounds.width != lastMeasuredWidth {
            updateHeight()
        }
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
        if text == "\n", AppPreferences.sendOnReturn, !trimmed.isEmpty {
            sendTapped()
            return false
        }
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        placeholder.isHidden = !textView.text.isEmpty
        updateHeight()
        updateSendButton()
        delegate?.composerTextDidChange(textView.text)
    }

    private func updateHeight() {
        lastMeasuredWidth = textView.bounds.width
        let size = textView.sizeThatFits(
            CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude))
        heightConstraint.constant = min(max(22, size.height), 132)
        textView.isScrollEnabled = size.height > 132
    }

    @objc private func sendTapped() {
        let text = trimmed
        if text.isEmpty {
            if isBusy { delegate?.composerDidTapStop() }
            return
        }
        Theme.Haptics.send()
        delegate?.composerDidSend(text)
        textView.text = ""
        textViewDidChange(textView)
        resyncKeyboard()
    }

    /// Programmatic `text` mutations while the keyboard is up leave its
    /// autocorrect/prediction context pointing at stale content, which shows up
    /// as auto-correction silently stopping. Reloading the input views makes
    /// the keyboard re-read the traits and current text.
    private func resyncKeyboard() {
        guard textView.isFirstResponder else { return }
        textView.reloadInputViews()
    }

    @objc private func attachTapped() { delegate?.composerDidTapAttach() }

    @objc private func sendLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, !trimmed.isEmpty else { return }
        Theme.Haptics.tap()
        delegate?.composerDidLongPressSend(from: sendButton)
    }

    /// Fades in a small sparkle on the send button when refined prompts are
    /// waiting, so the hold-to-enhance gesture is discoverable.
    func setEnhanceHint(_ visible: Bool) {
        let target: CGFloat = visible ? 1 : 0
        guard enhanceBadge.alpha != target else { return }
        sendButton.accessibilityHint = visible ? "Hold to enhance your prompt" : nil
        if visible {
            enhanceBadge.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
            UIView.animate(
                withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0.5
            ) {
                self.enhanceBadge.alpha = 1
                self.enhanceBadge.transform = .identity
            }
        } else {
            UIView.animate(withDuration: 0.2) { self.enhanceBadge.alpha = 0 }
        }
    }

    var currentText: String { trimmed }

    /// The Send button, so the enhance bubble can grow out of and retract into it.
    var sendControlAnchor: UIView { sendButton }

    func clear() {
        textView.text = ""
        UIView.animate(
            withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0.3
        ) {
            self.textViewDidChange(self.textView)
            self.superview?.layoutIfNeeded()
        }
        resyncKeyboard()
    }

    func insertQuote(_ text: String) {
        let quoted = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }.joined(separator: "\n")
        let existing = textView.text ?? ""
        textView.text = existing.isEmpty ? "\(quoted)\n\n" : "\(existing)\n\(quoted)\n\n"
        textViewDidChange(textView)
        resyncKeyboard()
        textView.becomeFirstResponder()
    }

    func setDraft(_ text: String, focus: Bool = true) {
        textView.text = text
        textViewDidChange(textView)
        resyncKeyboard()
        if focus { textView.becomeFirstResponder() }
    }

    func deleteSelection() {
        if let selection = textView.selectedTextRange, !selection.isEmpty {
            textView.replace(selection, withText: "")
            textViewDidChange(textView)
            resyncKeyboard()
        }
    }

    func insertText(_ text: String) {
        if let selection = textView.selectedTextRange {
            textView.replace(selection, withText: text)
        } else {
            textView.text = (textView.text ?? "") + text
        }
        textViewDidChange(textView)
        resyncKeyboard()
    }

    func appendPath(_ path: String) {
        let existing = textView.text ?? ""
        let sep = existing.isEmpty || existing.hasSuffix(" ") ? "" : " "
        textView.text = existing + sep + path
        textViewDidChange(textView)
        resyncKeyboard()
        textView.becomeFirstResponder()
    }
}
