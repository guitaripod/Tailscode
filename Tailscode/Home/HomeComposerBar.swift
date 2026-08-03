import TailscodeCore
import UIKit

@MainActor
protocol HomeComposerBarDelegate: AnyObject {
    func homeComposer(_ bar: HomeComposerBar, didSend text: String)
    func homeComposerDidBeginEditing(_ bar: HomeComposerBar)
}

/// Home's docked "start a chat" bar: a glass surface carrying two retargetable
/// chips — where the first message goes (server and project) and what will
/// answer it (model and reasoning effort) — above a growing text view. No
/// session exists until the user commits a message, so aiming and typing cost
/// the server nothing.
@MainActor
final class HomeComposerBar: UIView, UITextViewDelegate, UIGestureRecognizerDelegate {
    weak var delegate: HomeComposerBarDelegate?

    private let bar = Theme.Glass.view(interactive: false)
    private let chipButton = UIButton(type: .system)
    private let chevron = UIImageView()
    private let modelButton = UIButton(type: .system)
    private let modelChevron = UIImageView()
    private let destinationRow = UIStackView()
    private let modelRow = UIStackView()
    private let topRow = UIStackView()
    private let textView = UITextView()
    private let placeholder = UILabel()
    private let sendButton = UIButton(type: .system)
    private var heightConstraint: NSLayoutConstraint!
    private var lastMeasuredWidth: CGFloat = 0
    private var isSending = false
    private let auraHost = UIView()
    private lazy var aura = UltracodeAura(around: auraHost, cornerRadius: 23)

    var ultracodeEffort: String? {
        didSet { refreshAura() }
    }

    private func refreshAura() {
        aura.setActive(
            Ultracode.auraActive(effort: ultracodeEffort, draft: textView.text ?? ""))
    }

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

        auraHost.translatesAutoresizingMaskIntoConstraints = false
        auraHost.isUserInteractionEnabled = false
        addSubview(auraHost)

        var chip = UIButton.Configuration.plain()
        chip.contentInsets = .zero
        chip.imagePadding = 5
        chip.titleLineBreakMode = .byTruncatingTail
        chip.baseForegroundColor = Theme.Color.secondaryLabel
        chipButton.configuration = chip
        chipButton.showsMenuAsPrimaryAction = true
        chipButton.contentHorizontalAlignment = .leading
        chipButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var model = UIButton.Configuration.plain()
        model.contentInsets = .zero
        model.imagePadding = 4
        model.titleLineBreakMode = .byTruncatingTail
        model.baseForegroundColor = Theme.Color.secondaryLabel
        model.image = UIImage(
            systemName: "cpu",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        modelButton.configuration = model
        modelButton.showsMenuAsPrimaryAction = true
        modelButton.contentHorizontalAlignment = .trailing
        modelButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        configureChevron(chevron)
        configureChevron(modelChevron)
        configureChipRow(destinationRow, button: chipButton, chevron: chevron)
        configureChipRow(modelRow, button: modelButton, chevron: modelChevron)
        modelRow.isHidden = true

        let spacer = UIView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        topRow.axis = .horizontal
        topRow.alignment = .center
        topRow.spacing = Theme.Spacing.s
        [destinationRow, spacer, modelRow].forEach(topRow.addArrangedSubview)
        topRow.translatesAutoresizingMaskIntoConstraints = false

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

        placeholder.text = String(localized: "Start a new chat…")
        placeholder.font = Theme.Font.body()
        placeholder.textColor = Theme.Color.tertiaryLabel
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        var send = UIButton.Configuration.filled()
        send.cornerStyle = .capsule
        send.baseBackgroundColor = Theme.Color.accent
        sendButton.configuration = send
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)

        [topRow, textView, placeholder, sendButton].forEach(addSubview)

        heightConstraint = textView.heightAnchor.constraint(equalToConstant: 22)
        NSLayoutConstraint.activate([
            auraHost.topAnchor.constraint(equalTo: bar.topAnchor),
            auraHost.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            auraHost.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            auraHost.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.xs),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.l),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.l),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.s),

            topRow.topAnchor.constraint(equalTo: bar.topAnchor, constant: Theme.Spacing.s + 2),
            topRow.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: Theme.Spacing.m),
            topRow.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -Theme.Spacing.m),
            topRow.heightAnchor.constraint(equalToConstant: 20),

            textView.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 8),
            textView.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -11),
            textView.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: Theme.Spacing.m),
            textView.trailingAnchor.constraint(
                equalTo: sendButton.leadingAnchor, constant: -Theme.Spacing.xs),
            heightConstraint,

            sendButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -Theme.Spacing.xs),
            sendButton.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -5),
            sendButton.widthAnchor.constraint(equalToConstant: 34),
            sendButton.heightAnchor.constraint(equalToConstant: 34),

            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 2),
            placeholder.centerYAnchor.constraint(equalTo: textView.centerYAnchor),
        ])

        let focusTap = UITapGestureRecognizer(target: self, action: #selector(focusInput))
        focusTap.cancelsTouchesInView = false
        focusTap.delegate = self
        addGestureRecognizer(focusTap)

        updateSendButton()
    }

    private func configureChevron(_ view: UIImageView) {
        view.image = UIImage(
            systemName: "chevron.up.chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        view.tintColor = Theme.Color.tertiaryLabel
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func configureChipRow(_ row: UIStackView, button: UIButton, chevron: UIImageView) {
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 3
        row.addArrangedSubview(button)
        row.addArrangedSubview(chevron)
    }

    func setContext(icon: UIImage?, title: String, menu: UIMenu) {
        var config = chipButton.configuration ?? .plain()
        config.image = icon
        config.attributedTitle = Self.chipTitle(title)
        chipButton.configuration = config
        chipButton.menu = menu
        chipButton.accessibilityLabel = String(localized: "Chat destination: \(title)")
    }

    /// Passing no title hides the chip entirely — a backend without model
    /// selection must not show an affordance that does nothing.
    func setModel(title: String?, menu: UIMenu?) {
        guard let title, let menu else {
            modelRow.isHidden = true
            return
        }
        modelRow.isHidden = false
        var config = modelButton.configuration ?? .plain()
        config.attributedTitle = Self.chipTitle(title)
        modelButton.configuration = config
        modelButton.menu = menu
        modelButton.accessibilityLabel = String(localized: "Model: \(title)")
    }

    private static func chipTitle(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.font = UIFont.preferredFont(forTextStyle: .caption1).withTraits(.traitBold)
        return attributed
    }

    /// Locks input while the session is being created; the text stays put so
    /// a failed create loses nothing.
    func setSending(_ sending: Bool) {
        guard isSending != sending else { return }
        isSending = sending
        textView.isEditable = !sending
        chipButton.isEnabled = !sending
        modelButton.isEnabled = !sending
        updateSendButton()
    }

    func clearText() {
        textView.text = ""
        textViewDidChange(textView)
    }

    func focus() {
        textView.becomeFirstResponder()
    }

    func unfocus() {
        textView.resignFirstResponder()
    }

    var isEditing: Bool { textView.isFirstResponder }

    var isEditingText: Bool { textView.isFirstResponder }

    #if DEBUG
        var tourText: String { textView.text }

        func tourSetText(_ text: String) {
            textView.text = text
            textViewDidChange(textView)
        }
    #endif

    @objc private func focusInput() { textView.becomeFirstResponder() }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
    ) -> Bool {
        !(touch.view is UIControl)
    }

    private var trimmed: String {
        textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updateSendButton() {
        let hasText = !trimmed.isEmpty
        var config = sendButton.configuration ?? .filled()
        config.showsActivityIndicator = isSending
        config.image = isSending
            ? nil
            : UIImage(
                systemName: "arrow.up",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold))
        config.baseBackgroundColor =
            hasText || isSending ? Theme.Color.accent : Theme.Color.separator
        config.baseForegroundColor = .white
        sendButton.configuration = config
        sendButton.isEnabled = hasText && !isSending
        sendButton.accessibilityLabel = String(localized: "Send")
    }

    @objc private func sendTapped() {
        let text = trimmed
        guard !text.isEmpty, !isSending else { return }
        Theme.Haptics.send()
        delegate?.homeComposer(self, didSend: text)
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        delegate?.homeComposerDidBeginEditing(self)
    }

    func textView(
        _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
    ) -> Bool {
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
        refreshAura()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        aura.layout()
        if textView.bounds.width != lastMeasuredWidth {
            updateHeight()
        }
    }

    private func updateHeight() {
        lastMeasuredWidth = textView.bounds.width
        let size = textView.sizeThatFits(
            CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude))
        heightConstraint.constant = min(max(22, size.height), 132)
        textView.isScrollEnabled = size.height > 132
    }
}
