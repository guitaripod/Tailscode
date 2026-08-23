import TailscodeCore
import UIKit

@MainActor
protocol HomeComposerBarDelegate: AnyObject {
    func homeComposer(_ bar: HomeComposerBar, didSend text: String)
    func homeComposerDidBeginEditing(_ bar: HomeComposerBar)
    func homeComposerTextDidChange(_ text: String)
    /// The switch was thrown. Which lane it landed in is already on the bar; what the lane means —
    /// where the words go, which memory aims them, which draft comes back — is the host's.
    func homeComposerDidToggleLane(_ bar: HomeComposerBar)
    /// Built when the attach menu opens, so it always reflects what the aim can actually accept.
    func homeComposerAttachOptions() -> [UIMenuElement]
    func homeComposerDidPasteImage(_ data: Data, mime: String)
    func homeComposerDidPasteLargeText(_ text: String)
    func homeComposerDidLongPressSend(from view: UIView)
}

/// Home's docked prompt box: a glass surface carrying the switch between its two lanes and two
/// retargetable chips — where the first message goes and what will answer it — above a growing
/// text view. No session exists until the user commits a message, so aiming and typing cost the
/// server nothing.
///
/// The two lanes are one box because they differ by one fact. A chat is started in a project; a
/// question is not started anywhere — so the switch takes the project half off the destination
/// chip, hands the model chip the ask's own memory, and changes what the empty box says. Nothing
/// else about the bar moves: the same keys send it, the same paperclip fills it, the same hold on
/// Send sharpens it. A summoned sheet would have had to teach all of that again.
@MainActor
final class HomeComposerBar: UIView, UITextViewDelegate, UIGestureRecognizerDelegate {
    weak var delegate: HomeComposerBarDelegate?

    private let bar = Theme.Glass.view(interactive: false)
    private let laneButton = UIButton(type: .system)
    private let chipButton = UIButton(type: .system)
    private let chevron = UIImageView()
    private let modelButton = UIButton(type: .system)
    private let modelChevron = UIImageView()
    private let destinationRow = UIStackView()
    private let modelRow = UIStackView()
    private let topRow = UIStackView()
    private let textView = PastingTextView()
    private let placeholder = UILabel()
    private let sendButton = UIButton(type: .system)
    private lazy var sendWork = ButtonWorkMark(
        on: sendButton, pointSize: 13, tint: Theme.Color.onAccent)
    private let attachButton = UIButton(type: .system)
    private let enhanceBadge = UIImageView()
    private var heightConstraint: NSLayoutConstraint!
    private var textViewLeadingToAttach: NSLayoutConstraint?
    private var textViewLeadingToBar: NSLayoutConstraint?
    private var lastMeasuredWidth: CGFloat = 0
    private var isSending = false
    private let auraHost = UIView()
    private lazy var aura = UltracodeAura(around: auraHost, cornerRadius: 23)

    /// Which lane the box is in. Setting it draws the switch and the placeholder; everything the
    /// lane implies about aim, drafts and destination belongs to the host.
    private(set) var lane: QuickAskLane = .chat

    var ultracodeEffort: String? {
        didSet { refreshAura() }
    }

    /// Whether the power is visibly on — the same fact the aura draws, offered outward so the
    /// presence orb can wear the rainbow the moment the word is typed.
    private(set) var auraIsActive = false
    var onAuraChanged: (() -> Void)?

    /// Whether the paperclip is offered at all. A lane that cannot carry a picture must not show
    /// an affordance that does nothing.
    var showsAttach = false {
        didSet {
            guard showsAttach != oldValue else { return }
            attachButton.isHidden = !showsAttach
            textViewLeadingToBar?.isActive = !showsAttach
            textViewLeadingToAttach?.isActive = showsAttach
        }
    }

    /// A picture handed over with no words is still a question, so a box with something in its
    /// strip is a box that can send. The strip belongs to whoever owns the attachments, which is
    /// why the fact is told rather than counted here.
    var carriesAttachments = false {
        didSet {
            guard carriesAttachments != oldValue else { return }
            updateSendButton()
        }
    }

    private func refreshAura() {
        let active = Ultracode.auraActive(effort: ultracodeEffort, draft: textView.text ?? "")
        aura.setActive(active)
        if active != auraIsActive {
            auraIsActive = active
            onAuraChanged?()
        }
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

        buildLaneSwitch()

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
        [laneButton, destinationRow, spacer, modelRow].forEach(topRow.addArrangedSubview)
        topRow.translatesAutoresizingMaskIntoConstraints = false

        textView.font = Theme.Ramp.font(.answer)
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
        textView.onPasteImage = { [weak self] data, mime in
            self?.delegate?.homeComposerDidPasteImage(data, mime: mime)
        }
        textView.translatesAutoresizingMaskIntoConstraints = false

        placeholder.text = lane.placeholder
        placeholder.font = Theme.Ramp.font(.answer)
        placeholder.textColor = Theme.Color.tertiaryLabel
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        attachButton.setImage(
            UIImage(
                systemName: "plus",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)),
            for: .normal)
        attachButton.tintColor = Theme.Color.secondaryLabel
        attachButton.translatesAutoresizingMaskIntoConstraints = false
        attachButton.showsMenuAsPrimaryAction = true
        attachButton.isHidden = true
        attachButton.menu = UIMenu(
            title: String(localized: "Attach"),
            children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    completion(self?.delegate?.homeComposerAttachOptions() ?? [])
                }
            ])
        attachButton.accessibilityLabel = String(localized: "Attach")

        var send = UIButton.Configuration.filled()
        send.cornerStyle = .capsule
        send.baseBackgroundColor = Theme.Color.accent
        sendButton.configuration = send
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        sendButton.addGestureRecognizer(
            UILongPressGestureRecognizer(target: self, action: #selector(sendLongPressed)))

        enhanceBadge.image = UIImage(
            systemName: "sparkles",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        enhanceBadge.tintColor = Theme.Color.onAccent
        enhanceBadge.backgroundColor = Theme.Color.accent
        enhanceBadge.contentMode = .center
        enhanceBadge.layer.cornerRadius = 8
        enhanceBadge.layer.borderWidth = 1.5
        enhanceBadge.layer.borderColor = Theme.Color.background.cgColor
        enhanceBadge.alpha = 0
        enhanceBadge.isUserInteractionEnabled = false
        enhanceBadge.translatesAutoresizingMaskIntoConstraints = false

        [topRow, attachButton, textView, placeholder, sendButton, enhanceBadge]
            .forEach(addSubview)

        heightConstraint = textView.heightAnchor.constraint(equalToConstant: 22)
        let toAttach = textView.leadingAnchor.constraint(
            equalTo: attachButton.trailingAnchor, constant: Theme.Spacing.xs)
        textViewLeadingToAttach = toAttach
        let toBar = textView.leadingAnchor.constraint(
            equalTo: bar.leadingAnchor, constant: Theme.Spacing.m)
        textViewLeadingToBar = toBar
        toBar.isActive = true

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

            attachButton.leadingAnchor.constraint(
                equalTo: bar.leadingAnchor, constant: Theme.Spacing.s),
            attachButton.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -7),
            attachButton.widthAnchor.constraint(equalToConstant: 32),
            attachButton.heightAnchor.constraint(equalToConstant: 32),

            textView.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 8),
            textView.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -11),
            textView.trailingAnchor.constraint(
                equalTo: sendButton.leadingAnchor, constant: -Theme.Spacing.xs),
            heightConstraint,

            sendButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -Theme.Spacing.xs),
            sendButton.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -5),
            sendButton.widthAnchor.constraint(equalToConstant: 34),
            sendButton.heightAnchor.constraint(equalToConstant: 34),

            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 2),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor),
            placeholder.centerYAnchor.constraint(equalTo: textView.centerYAnchor),

            enhanceBadge.widthAnchor.constraint(equalToConstant: 16),
            enhanceBadge.heightAnchor.constraint(equalToConstant: 16),
            enhanceBadge.centerXAnchor.constraint(equalTo: sendButton.trailingAnchor, constant: -1),
            enhanceBadge.centerYAnchor.constraint(equalTo: sendButton.topAnchor, constant: 1),
        ])

        let focusTap = UITapGestureRecognizer(target: self, action: #selector(focusInput))
        focusTap.cancelsTouchesInView = false
        focusTap.delegate = self
        addGestureRecognizer(focusTap)

        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (view: HomeComposerBar, _) in
            view.enhanceBadge.layer.borderColor = Theme.Color.background.cgColor
            view.paintLaneSwitch()
        }

        paintLaneSwitch()
        updateSendButton()
    }

    /// The switch is a chip rather than a `UISwitch`: it sits in a row of chips, it is thrown with
    /// the same tap the chips beside it answer, and a chip can wear the accent outright, which is
    /// the one state a person has to be able to read without stopping to look.
    private func buildLaneSwitch() {
        var config = UIButton.Configuration.plain()
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(
            top: 2, leading: Theme.Spacing.s, bottom: 2, trailing: Theme.Spacing.s + 1)
        config.imagePadding = 4
        config.image = UIImage(
            systemName: "sparkle",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        laneButton.configuration = config
        laneButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        laneButton.setContentHuggingPriority(.required, for: .horizontal)
        laneButton.addAction(
            UIAction { [weak self] _ in self?.laneTapped() }, for: .touchUpInside)
        laneButton.accessibilityTraits = [.button]
    }

    private func laneTapped() {
        setLane(lane.toggled, animated: true)
        Theme.Haptics.selection()
        delegate?.homeComposerDidToggleLane(self)
    }

    /// Thrown by hand or restored on launch — the same drawing either way, and the animation is
    /// the only difference, because a bar that pops into its lane while the screen is being built
    /// is a bar that looks like it changed its mind.
    func setLane(_ next: QuickAskLane, animated: Bool) {
        guard lane != next else { return }
        lane = next
        guard animated else {
            paintLaneSwitch()
            placeholder.text = lane.placeholder
            return
        }
        UIView.transition(with: placeholder, duration: 0.22, options: .transitionCrossDissolve) {
            self.placeholder.text = self.lane.placeholder
        }
        laneButton.imageView?.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        UIView.animate(
            withDuration: 0.34, delay: 0, usingSpringWithDamping: 0.62, initialSpringVelocity: 0.6
        ) {
            self.paintLaneSwitch()
            self.laneButton.imageView?.transform = .identity
            self.layoutIfNeeded()
        }
    }

    private func paintLaneSwitch() {
        var config = laneButton.configuration ?? .plain()
        var title = AttributedString(QuickAskLane.switchTitle)
        title.font = Theme.Ramp.font(.sectionLabel)
        config.attributedTitle = title
        let on = lane == .ask
        config.baseForegroundColor = on ? Theme.Color.onAccent : Theme.Color.tertiaryLabel
        config.background.backgroundColor = on ? Theme.Color.accent : .clear
        config.background.strokeColor = on ? .clear : Theme.Color.separator
        config.background.strokeWidth = on ? 0 : 1
        laneButton.configuration = config
        laneButton.accessibilityLabel = QuickAskLane.switchTitle
        laneButton.accessibilityValue = lane.spoken
        laneButton.accessibilityTraits = on ? [.button, .selected] : [.button]
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
        chipButton.accessibilityLabel =
            lane == .ask
            ? String(localized: "Asking: \(title)")
            : String(localized: "Chat destination: \(title)")
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
        attributed.font = Theme.Ramp.font(.sectionLabel)
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
        laneButton.isEnabled = !sending
        attachButton.isEnabled = !sending
        updateSendButton()
    }

    func clearText() {
        textView.text = ""
        textViewDidChange(textView)
    }

    var currentText: String { trimmed }

    /// Exactly what is in the bar, indentation and trailing newlines included. A draft stashed on
    /// the way to another destination has to come back as the keystrokes it was, not as the message
    /// `currentText` would have sent.
    var rawText: String { textView.text }

    /// Puts text in the bar without asking for the keyboard: handing back what was left unsent is
    /// not the same gesture as starting to type.
    func setText(_ text: String) {
        textView.text = text
        textViewDidChange(textView)
        resyncKeyboard()
    }

    /// Words landed in the box by a starter or an enhancement: the caret goes to their end and the
    /// keyboard comes up, because the sentence is half-written and the person finishes it.
    func setDraft(_ text: String, focus: Bool) {
        setText(text)
        if focus { textView.becomeFirstResponder() }
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

    func deleteSelection() {
        guard let selection = textView.selectedTextRange, !selection.isEmpty else { return }
        textView.replace(selection, withText: "")
        textViewDidChange(textView)
        resyncKeyboard()
    }

    /// The Send button, so the enhance deck can grow out of and retract into it.
    var sendControlAnchor: UIView { sendButton }

    func triggerSend() { sendTapped() }

    /// Fades in a small sparkle on the send button when refined prompts are waiting, so the
    /// hold-to-enhance gesture is discoverable.
    func setEnhanceHint(_ visible: Bool) {
        let target: CGFloat = visible ? 1 : 0
        guard enhanceBadge.alpha != target else { return }
        sendButton.accessibilityHint =
            visible ? String(localized: "Hold to enhance your prompt") : nil
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

        func tourSetText(_ text: String) { setText(text) }
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

    /// Programmatic `text` mutations while the keyboard is up leave its autocorrect context
    /// pointing at stale content, which shows up as auto-correction silently stopping.
    private func resyncKeyboard() {
        guard textView.isFirstResponder else { return }
        textView.reloadInputViews()
    }

    private func updateSendButton() {
        let hasText = !trimmed.isEmpty || carriesAttachments
        var config = sendButton.configuration ?? .filled()
        config.image = isSending
            ? nil
            : UIImage(
                systemName: "arrow.up",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold))
        config.baseBackgroundColor =
            hasText || isSending ? Theme.Color.accent : Theme.Color.separator
        config.baseForegroundColor = Theme.Color.onAccent
        sendButton.configuration = config
        sendWork.show(isSending, on: sendButton)
        sendButton.isEnabled = hasText && !isSending
        sendButton.accessibilityLabel = String(localized: "Send")
    }

    @objc private func sendTapped() {
        let text = trimmed
        guard !text.isEmpty || carriesAttachments, !isSending else { return }
        Theme.Haptics.send()
        delegate?.homeComposer(self, didSend: text)
    }

    @objc private func sendLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, !trimmed.isEmpty else { return }
        Theme.Haptics.tap()
        delegate?.homeComposerDidLongPressSend(from: sendButton)
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        delegate?.homeComposerDidBeginEditing(self)
    }

    func textView(
        _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
    ) -> Bool {
        if text.count > 6000 {
            delegate?.homeComposerDidPasteLargeText(text)
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
        refreshAura()
        delegate?.homeComposerTextDidChange(textView.text)
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
