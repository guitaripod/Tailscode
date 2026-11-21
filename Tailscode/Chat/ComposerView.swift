import TailscodeCore
import UIKit

@MainActor
protocol ComposerViewDelegate: AnyObject {
    func composerDidSend(_ text: String)
    func composerTextDidChange(_ text: String)
    func composerDidLongPressSend(from view: UIView)
    func composerDidPasteLargeText(_ text: String)
    /// A picture on the pasteboard, pasted into the box. A screenshot is the commonest thing a
    /// phone has in hand, and making someone save it to Photos and pick it back up through the
    /// attach menu is a detour the clipboard already answered.
    func composerDidPasteImage(_ data: Data, mime: String)
    /// Built when the attach menu opens, so it always reflects what the model
    /// selected right now can actually accept.
    func composerAttachOptions() -> [UIMenuElement]
    func composerDidTapStop()
    func composerDidBeginEditing()
    /// The caret moved without the words changing, which is enough to walk into or out of a
    /// file's name.
    func composerSelectionDidChange()
    /// The last thing this person sent here, offered back from the empty box's own menu.
    func composerLastPrompt() -> String?
    func composerDidAskForLastPrompt()
}

@MainActor
final class ComposerView: UIView, UITextViewDelegate, UIGestureRecognizerDelegate {
    weak var delegate: ComposerViewDelegate?

    private let bar = Theme.Glass.view(interactive: false)
    private let textView = PastingTextView()
    private let placeholder = UILabel()
    private let sendButton = ComposerSendButton()
    private let attachButton = SlopButton(type: .system)
    private lazy var ink = ComposerInk(textView: textView)
    let handle = ComposerHandle()
    private let doors = ComposerDoors()
    private let fade = ComposerEdgeFade()
    private lazy var liftPan = UIPanGestureRecognizer(target: self, action: #selector(liftPanned))
    /// How far above the box's edge a pull may start and still be the handle's. A thumb aims at
    /// the pill and lands around it, and what floats just above the box has touch room of its
    /// own that reaches down to the edge.
    private static let handleReach: CGFloat = 14
    /// Where the finger came down, which is what decides whether a pull is the handle's: by the
    /// time a pull is recognised as one, the finger has already left the place it started.
    private var liftTouchDown: CGPoint?
    /// Whether the box has been pulled up to the page.
    private(set) var lifted = false
    /// The cap the finger is holding the box at, while the handle is held.
    private var heldCap: CGFloat?
    private var heldFrom: CGFloat = 0
    /// What the words would take with nothing holding them, as last measured.
    private var naturalHeight: CGFloat = 22
    /// How far the box stands above its resting height. The transcript keeps the room it had at
    /// rest and the lifted box rises over it, so pulling the handle never moves the conversation.
    private(set) var liftExtra: CGFloat = 0
    /// The most the whole composer may stand, from its bottom edge to under the bar and whatever
    /// floats above the box. Asked of the screen, which is the only thing that knows, and only
    /// while the box is up or being pulled: at rest the answer is never needed.
    var pageRoom: (() -> CGFloat)?
    private let enhanceBadge = UIImageView()
    private var heightConstraint: NSLayoutConstraint!
    private var isBusy = false

    /// Whether the empty box offers the key that opens the commands, and the one that finds a
    /// file: a chat with no project has no files to find.
    var offersCommandDoor = true {
        didSet { refreshDoors() }
    }
    var offersFileDoor = false {
        didSet { refreshDoors() }
    }

    var knowsCommand: (String) -> Bool {
        get { ink.knowsCommand }
        set { ink.knowsCommand = newValue }
    }
    var knowsPath: (String) -> Bool {
        get { ink.knowsPath }
        set { ink.knowsPath = newValue }
    }

    var showsAttach = true {
        didSet {
            attachButton.isHidden = !showsAttach
            applyLayout()
        }
    }

    /// A control that lives in the box's bottom row, between the paperclip and Send — the pill
    /// for model and effort. With one, the words take the whole width above it and the row below
    /// holds the controls; without, the box is the single line it always was.
    var accessory: UIView? {
        didSet {
            guard accessory !== oldValue else { return }
            oldValue?.removeFromSuperview()
            installAccessory()
            applyLayout()
        }
    }

    /// The colour of a hot level, drawn as a line along the top of the box from xhigh up so the
    /// cost of the next send is felt before it is made. Ultracode has the aura instead.
    var heatColor: UIColor? {
        didSet { refreshHeatLine() }
    }
    /// A picture handed over with no words is still a question, so the composer with something in
    /// its strip is a composer that can send. The strip belongs to whoever owns the attachments,
    /// which is why the fact is told rather than counted here.
    var carriesAttachments = false {
        didSet {
            guard carriesAttachments != oldValue else { return }
            updateSendButton()
        }
    }

    /// What the box says when it is empty. A quick ask is not a chat, and "Message your agent…"
    /// is the wrong sentence in front of a question.
    var placeholderText: String {
        get { placeholder.text ?? "" }
        set {
            restingPlaceholder = newValue
            placeholder.text = dictation.isOpen ? DictationReading.listeningPlaceholder : newValue
            textView.accessibilityLabel = newValue
        }
    }

    private var textViewLeadingToAttach: NSLayoutConstraint?
    private var textViewLeadingToBar: NSLayoutConstraint?
    private var lineConstraints: [NSLayoutConstraint] = []
    private var stackedConstraints: [NSLayoutConstraint] = []
    private var accessoryConstraints: [NSLayoutConstraint] = []
    /// Whether a take's status line holds the row under the words, which makes the box its stacked
    /// shape for as long as the line is there.
    private var statusShown = false
    private lazy var stackedTextBottom = textView.bottomAnchor.constraint(
        equalTo: bar.bottomAnchor, constant: -(accessoryRowHeight + 10))
    private var accessoryToAttach: NSLayoutConstraint?
    private var accessoryToBar: NSLayoutConstraint?
    private let heatLine = CAGradientLayer()
    private let strike = StrikeLine()
    private var lastMeasuredWidth: CGFloat = 0
    private let auraHost = UIView()
    private lazy var aura = UltracodeAura(around: auraHost, cornerRadius: 23)
    private(set) lazy var dictation = DictationController(host: self, key: "chat-\(ObjectIdentifier(self).hashValue)")
    private var restingPlaceholder = String(localized: "Message your agent…")

    var ultracodeEffort: String? {
        didSet { refreshAura() }
    }
    var ultracodeInFlight = false {
        didSet { refreshAura() }
    }

    private func refreshAura() {
        aura.setActive(
            Ultracode.auraActive(
                effort: ultracodeEffort, draft: textView.text ?? "",
                inFlightInvoked: ultracodeInFlight))
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
            self?.delegate?.composerDidPasteImage(data, mime: mime)
        }
        textView.translatesAutoresizingMaskIntoConstraints = false

        placeholder.text = String(localized: "Message your agent…")
        textView.accessibilityLabel = placeholder.text
        placeholder.isAccessibilityElement = false
        placeholder.font = Theme.Ramp.font(.answer)
        placeholder.textColor = Theme.Color.tertiaryLabel
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        attachButton.setImage(
            UIImage(systemName: "plus", withConfiguration:
                UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
        attachButton.tintColor = Theme.Color.secondaryLabel
        attachButton.translatesAutoresizingMaskIntoConstraints = false
        attachButton.showsMenuAsPrimaryAction = true
        attachButton.menu = UIMenu(
            title: String(localized: "Attach"),
            children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    completion(self?.delegate?.composerAttachOptions() ?? [])
                }
            ])
        attachButton.accessibilityLabel = String(localized: "Attach")

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        let longPress = UILongPressGestureRecognizer(
            target: self, action: #selector(sendLongPressed))
        sendButton.addGestureRecognizer(longPress)

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

        [attachButton, textView, placeholder, doors, sendButton, enhanceBadge, handle].forEach(addSubview)
        handle.addTarget(self, action: #selector(handleTapped), for: .touchUpInside)
        doors.onPress = { [weak self] letter in self?.openDoor(letter) }
        liftPan.delegate = self
        addGestureRecognizer(liftPan)

        let mic = dictation.button
        addSubview(mic)
        insertSubview(dictation.edge, aboveSubview: auraHost)

        heightConstraint = textView.heightAnchor.constraint(equalToConstant: 22)
        let leading = textView.leadingAnchor.constraint(
            equalTo: attachButton.trailingAnchor, constant: Theme.Spacing.xs)
        textViewLeadingToAttach = leading
        textViewLeadingToBar = textView.leadingAnchor.constraint(
            equalTo: bar.leadingAnchor, constant: Theme.Spacing.m)

        let textBottom = textView.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -11)
        let sendLeading = mic.leadingAnchor.constraint(
            equalTo: textView.trailingAnchor, constant: Theme.Spacing.xs)
        let placeholderCenter = placeholder.centerYAnchor.constraint(equalTo: attachButton.centerYAnchor)
        lineConstraints = [textBottom, sendLeading, placeholderCenter]
        stackedConstraints = [
            textView.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: Theme.Spacing.l),
            textView.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -Theme.Spacing.l),
            stackedTextBottom,
            placeholder.topAnchor.constraint(equalTo: textView.topAnchor, constant: 1),
        ]

        NSLayoutConstraint.activate([
            auraHost.topAnchor.constraint(equalTo: bar.topAnchor),
            auraHost.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            auraHost.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            auraHost.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.xs),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.l),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.l),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.s),

            attachButton.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: Theme.Spacing.s),
            attachButton.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -7),
            attachButton.widthAnchor.constraint(equalToConstant: 32),
            attachButton.heightAnchor.constraint(equalToConstant: 32),

            textView.topAnchor.constraint(equalTo: bar.topAnchor, constant: 11),
            textBottom,
            leading,
            heightConstraint,

            sendLeading,
            mic.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -Theme.Spacing.xs),
            mic.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
            dictation.edge.topAnchor.constraint(equalTo: bar.topAnchor),
            dictation.edge.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            dictation.edge.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            dictation.edge.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            sendButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -Theme.Spacing.xs),
            sendButton.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -5),
            sendButton.widthAnchor.constraint(equalToConstant: ComposerSendButton.side),
            sendButton.heightAnchor.constraint(equalToConstant: ComposerSendButton.side),

            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 2),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor),
            placeholder.trailingAnchor.constraint(
                lessThanOrEqualTo: doors.leadingAnchor, constant: -Theme.Spacing.s),
            placeholderCenter,

            doors.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -Theme.Spacing.m),
            doors.centerYAnchor.constraint(equalTo: placeholder.centerYAnchor),

            handle.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            handle.topAnchor.constraint(equalTo: topAnchor),

            enhanceBadge.widthAnchor.constraint(equalToConstant: 16),
            enhanceBadge.heightAnchor.constraint(equalToConstant: 16),
            enhanceBadge.centerXAnchor.constraint(equalTo: sendButton.trailingAnchor, constant: -1),
            enhanceBadge.centerYAnchor.constraint(equalTo: sendButton.topAnchor, constant: 1),
        ])

        heatLine.startPoint = CGPoint(x: 0, y: 0.5)
        heatLine.endPoint = CGPoint(x: 1, y: 0.5)
        heatLine.isHidden = true
        layer.addSublayer(heatLine)
        layer.addSublayer(strike.layer)
        strike.wear(traitCollection)

        let focusTap = UITapGestureRecognizer(target: self, action: #selector(focusInput))
        focusTap.cancelsTouchesInView = false
        focusTap.delegate = self
        addGestureRecognizer(focusTap)

        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) { (view: ComposerView, _) in
            view.enhanceBadge.layer.borderColor = Theme.Color.background.cgColor
            view.strike.wear(view.traitCollection)
            view.refreshStrike(animated: false)
            view.paintInk(force: true)
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (view: ComposerView, _) in
            view.stackedTextBottom.constant = -(view.accessoryRowHeight + 10)
            view.paintInk(force: true)
            view.updateHeight()
        }

        updateSendButton()
    }

    /// The row of controls under the words is as tall as the controls in it, which grow with the
    /// reader's type size, so the pill is never clipped by a box that was measured for the default
    /// one and the box is never taller than what it holds.
    private var accessoryRowHeight: CGFloat {
        let held = accessory?.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height ?? 0
        return max(36, ceil(held + 6))
    }

    private func installAccessory() {
        guard let accessory else { return }
        accessory.translatesAutoresizingMaskIntoConstraints = false
        accessory.alpha = statusShown ? 0 : 1
        accessory.isUserInteractionEnabled = !statusShown
        addSubview(accessory)
        stackedTextBottom.constant = -(accessoryRowHeight + 10)
        accessoryToAttach = accessory.leadingAnchor.constraint(
            equalTo: attachButton.trailingAnchor, constant: Theme.Spacing.xs)
        accessoryToBar = accessory.leadingAnchor.constraint(
            equalTo: bar.leadingAnchor, constant: Theme.Spacing.m)
        accessoryConstraints = [
            accessory.centerYAnchor.constraint(equalTo: attachButton.centerYAnchor),
            accessory.trailingAnchor.constraint(
                lessThanOrEqualTo: dictation.button.leadingAnchor, constant: -Theme.Spacing.s),
        ]
    }

    /// One place decides which layout is live, so the box is never half of each: the single line
    /// it was, or the words over a row of controls.
    private func applyLayout() {
        let stacked = accessory != nil || statusShown
        stackedTextBottom.constant = -(accessoryRowHeight + 10)
        let off: [NSLayoutConstraint?] =
            stacked
            ? lineConstraints + [textViewLeadingToAttach, textViewLeadingToBar]
            : stackedConstraints + accessoryConstraints + [accessoryToAttach, accessoryToBar]
        NSLayoutConstraint.deactivate(off.compactMap { $0 })
        if stacked {
            NSLayoutConstraint.activate(
                stackedConstraints + accessoryConstraints
                    + [showsAttach ? accessoryToAttach : accessoryToBar].compactMap { $0 })
        } else {
            NSLayoutConstraint.activate(
                lineConstraints + [showsAttach ? textViewLeadingToAttach : textViewLeadingToBar]
                    .compactMap { $0 })
        }
        refreshDoors()
        setNeedsLayout()
    }

    /// The two keys show only in an empty box that has a line to itself: the words take the
    /// whole width above the controls there, and its far end is free.
    private func refreshDoors() {
        let stacked = accessory != nil || statusShown
        let open = stacked && (textView.text ?? "").isEmpty && !statusShown && !dictation.isOpen
        doors.show(command: open && offersCommandDoor, file: open && offersFileDoor)
    }

    private func openDoor(_ letter: String) {
        Theme.Haptics.selection()
        textView.becomeFirstResponder()
        insertText(letter)
    }

    private func refreshHeatLine() {
        guard let heatColor else {
            heatLine.isHidden = true
            return
        }
        heatLine.colors = [
            heatColor.withAlphaComponent(0).cgColor, heatColor.cgColor, heatColor.withAlphaComponent(0).cgColor,
        ]
        heatLine.isHidden = false
        setNeedsLayout()
        refreshStrike(animated: false)
    }

    /// The box's edge is struck while it holds the keyboard, unless a hot level's line already
    /// has that edge.
    private func refreshStrike(animated: Bool) {
        strike.set(
            struck: textView.isFirstResponder && heatColor == nil,
            animated: animated && !UIAccessibility.isReduceMotionEnabled)
    }

    @objc private func focusInput() { textView.becomeFirstResponder() }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
    ) -> Bool {
        guard gestureRecognizer !== liftPan else {
            liftTouchDown = touch.location(in: self)
            return true
        }
        guard let view = touch.view else { return true }
        return !(view is UIControl) && !(accessory.map(view.isDescendant(of:)) ?? false)
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === liftPan else { return true }
        return liftShouldBegin()
    }

    /// A finger that came down on the handle is asked about first: the row of chips above the box
    /// and the words inside it scroll on a drag of their own, and either would take the pull
    /// before the handle heard of it. A pull that is not the handle's fails at once and they go on.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === liftPan, otherGestureRecognizer is UIPanGestureRecognizer,
            handle.isShown
        else { return false }
        return liftTouchDown.map(onHandle) ?? true
    }

    private func onHandle(_ point: CGPoint) -> Bool {
        let edge = bar.frame.minY
        return point.y >= edge - Self.handleReach && point.y <= edge + 30
            && point.x >= bar.frame.minX && point.x <= bar.frame.maxX
    }

    /// The button wears the verb a press will perform: send, queue behind the running turn, stop
    /// it, or put back the rewrite of a message that was waiting.
    private var sendFace: SendFace {
        SendFace.read(
            holdsWords: !trimmed.isEmpty || carriesAttachments, busy: isBusy,
            editingQueued: isEditingQueued)
    }

    private func updateSendButton() {
        sendButton.show(sendFace, animated: true)
    }

    func setBusy(_ busy: Bool) {
        guard isBusy != busy else { return }
        isBusy = busy
        let words =
            busy ? String(localized: "Queue a message…") : String(localized: "Message your agent…")
        if window != nil, !UIAccessibility.isReduceMotionEnabled {
            UIView.transition(
                with: placeholder, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction]
            ) {
                self.placeholderText = words
            }
        } else {
            placeholderText = words
        }
        updateSendButton()
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        #if DEBUG
            if window != nil { dictation.stageIfAsked() }
        #endif
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        aura.layout()
        let barFrame = bar.frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        heatLine.frame = CGRect(
            x: barFrame.minX + 26, y: barFrame.minY, width: max(0, barFrame.width - 52), height: 1.5)
        CATransaction.commit()
        strike.place(
            CGRect(
                x: barFrame.minX + 26, y: barFrame.minY, width: max(0, barFrame.width - 52),
                height: 1.5))
        if textView.bounds.width != lastMeasuredWidth {
            updateHeight()
        }
        refreshFade()
    }

    private var trimmed: String {
        textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        refreshStrike(animated: true)
        delegate?.composerDidBeginEditing()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        refreshStrike(animated: true)
        if lifted { setLifted(false) }
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        delegate?.composerSelectionDidChange()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        refreshFade()
    }

    func textView(
        _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
    ) -> Bool {
        dictation.userWillEdit()
        ink.holdTypingInk()
        if PasteFold.folds(text) {
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
        refreshDoors()
        paintInk()
        updateHeight(animated: true)
        updateSendButton()
        refreshAura()
        delegate?.composerTextDidChange(textView.text)
    }

    /// A take being heard owns the box's ink: the words still settling are lit by the dictation
    /// itself, and painting over them would put them out.
    private func paintInk(force: Bool = false) {
        guard !dictation.isOpen else { return }
        ink.paint(force: force)
    }

    private var restingCap: CGFloat {
        CGFloat(ComposerLift.restingCap(lineHeight: Double(Theme.Ramp.font(.answer).lineHeight)))
    }

    /// The most the words may take once lifted: the room the screen allows, less everything in
    /// the box that is not words.
    private var pageCap: CGFloat {
        guard let room = pageRoom?() else { return restingCap }
        return max(restingCap, room - (bounds.height - heightConstraint.constant))
    }

    /// The room above the box changed under a lifted box: the keyboard came or went, a chip
    /// landed, the list of files opened. The box takes its new height.
    func roomMoved(animated: Bool) {
        guard lifted, heldCap == nil else { return }
        updateHeight(animated: animated)
    }

    private var liftCeiling: CGFloat {
        CGFloat(
            ComposerLift.ceiling(
                natural: Double(naturalHeight), resting: Double(restingCap), page: Double(pageCap)))
    }

    /// Measures the words and gives them their height: what they need up to six lines at rest,
    /// up to the page once lifted, and wherever the finger holds the cap while the handle is held.
    private func updateHeight(animated: Bool = false) {
        lastMeasuredWidth = textView.bounds.width
        naturalHeight = textView.sizeThatFits(
            CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)
        ).height
        let resting = restingCap
        if lifted, heldCap == nil, naturalHeight <= resting + 0.5 { lifted = false }
        let height: CGFloat
        if let heldCap {
            height = max(22, heldCap)
        } else {
            height = CGFloat(
                ComposerLift.height(
                    natural: Double(naturalHeight), cap: Double(lifted ? liftCeiling : resting),
                    floor: 22))
        }
        textView.isScrollEnabled = naturalHeight > height + 0.5
        liftExtra = max(0, height - min(max(22, naturalHeight), resting))
        handle.show(
            ComposerLift.offersHandle(
                natural: Double(naturalHeight), resting: Double(resting),
                lifted: lifted || heldCap != nil),
            lifted: lifted)
        guard abs(heightConstraint.constant - height) > 0.5 else {
            refreshFade()
            return
        }
        guard animated, heldCap == nil, window != nil, !UIAccessibility.isReduceMotionEnabled else {
            heightConstraint.constant = height
            refreshFade()
            return
        }
        UIView.animate(
            withDuration: ComposerLift.response, delay: 0,
            usingSpringWithDamping: CGFloat(ComposerLift.damping), initialSpringVelocity: 0,
            options: [.allowUserInteraction, .beginFromCurrentState],
            animations: {
                self.heightConstraint.constant = height
                self.superview?.layoutIfNeeded()
                self.refreshFade()
            },
            completion: { _ in self.keepCaretInView() })
    }

    /// A box that changed height under a caret puts the caret back in sight: the text view placed
    /// its page for the height it had, and the line being written is the one that must not be
    /// left half under an edge.
    private func keepCaretInView() {
        guard textView.isScrollEnabled, heldCap == nil else { return }
        textView.scrollRangeToVisible(textView.selectedRange)
        refreshFade()
    }

    private func refreshFade() {
        fade.refresh(on: textView)
    }

    /// Lets the pull on the handle be heard by the screen the box sits in, so one that starts a
    /// little above the box, on the touch room of a chip floating there, is still the handle's.
    func hearHandle(in host: UIView) {
        host.addGestureRecognizer(liftPan)
    }

    /// The handle takes a pull that starts on the box's top edge and goes the way the box can
    /// still move: up from rest, down from the page. Anything else is the words being scrolled.
    private func liftShouldBegin() -> Bool {
        guard handle.isShown, let start = liftTouchDown else { return false }
        let velocity = liftPan.velocity(in: self)
        guard onHandle(start), abs(velocity.y) > abs(velocity.x) else { return false }
        return lifted ? velocity.y > 0 : velocity.y < 0
    }

    @objc private func liftPanned(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            heldFrom = heightConstraint.constant
            heldCap = heldFrom
            Theme.Haptics.selection()
        case .changed:
            heldCap = CGFloat(
                ComposerLift.dragged(
                    from: Double(heldFrom), travel: Double(-pan.translation(in: self).y),
                    resting: Double(restingCap), ceiling: Double(liftCeiling)))
            updateHeight()
        case .ended, .cancelled, .failed:
            guard let cap = heldCap else { return }
            let up = ComposerLift.settlesLifted(
                cap: Double(cap), velocity: Double(-pan.velocity(in: self).y),
                resting: Double(restingCap), ceiling: Double(liftCeiling))
            heldCap = nil
            setLifted(up && pan.state == .ended)
        default:
            break
        }
    }

    @objc private func handleTapped() {
        setLifted(!lifted)
    }

    /// Lifts the box to the page or lets it down to six lines. Lifting takes the keyboard too:
    /// room to write is for writing.
    func setLifted(_ up: Bool) {
        let wanted = up && naturalHeight > restingCap + 0.5
        if wanted != lifted { Theme.Haptics.notch() }
        lifted = wanted
        if wanted, !textView.isFirstResponder { textView.becomeFirstResponder() }
        updateHeight(animated: true)
        UIAccessibility.post(notification: .layoutChanged, argument: handle)
    }

    var isEditing: Bool { textView.isFirstResponder }

    func focus() { textView.becomeFirstResponder() }

    func unfocus() { textView.resignFirstResponder() }

    /// The hardware keyboard's send — the same path as the button, so busy-state and haptics
    /// behave identically.
    /// Whether the chat is holding a waiting message open in this box.
    var isEditingQueued = false {
        didSet {
            guard isEditingQueued != oldValue else { return }
            updateSendButton()
        }
    }

    func triggerSend() { sendTapped() }

    @objc private func sendTapped() {
        if dictation.stopAndSend() { return }
        let text = trimmed
        // Emptying the box is how a message being rewritten is taken back, so a send with nothing
        // in it is a real action while one is open — and the stop button otherwise.
        if text.isEmpty, !carriesAttachments, !isEditingQueued {
            if isBusy { delegate?.composerDidTapStop() }
            return
        }
        Theme.Haptics.send()
        if sendButton.face.launches {
            sendButton.launch { [weak self] in self?.sendFace ?? .idle }
        }
        collapseForSend()
        delegate?.composerDidSend(text)
        textViewDidChange(textView)
        resyncKeyboard()
    }

    /// Empties the box and brings it back to one line before the message is handed on, on the same
    /// spring the prompt rises on, so the transcript's rise is aimed at the page as it will be
    /// rather than at a box about to snap shut under it — one motion, never a jump and a
    /// correction. The delegate hears about the empty box after the send, as it always has.
    private func collapseForSend() {
        textView.text = ""
        placeholder.isHidden = false
        lifted = false
        heldCap = nil
        guard !UIAccessibility.isReduceMotionEnabled, window != nil else {
            updateHeight()
            return
        }
        UIView.animate(
            withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0.3,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.updateHeight()
            self.superview?.layoutIfNeeded()
        }
    }

    /// Programmatic `text` mutations while the keyboard is up leave its
    /// autocorrect/prediction context pointing at stale content, which shows up
    /// as auto-correction silently stopping. Reloading the input views makes
    /// the keyboard re-read the traits and current text.
    private func resyncKeyboard() {
        guard textView.isFirstResponder else { return }
        textView.reloadInputViews()
    }


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
        sendButton.accessibilityHint =
            visible ? String(localized: "Hold to enhance your prompt") : nil
        if UIAccessibility.isReduceMotionEnabled {
            enhanceBadge.transform = .identity
            enhanceBadge.alpha = target
        } else if visible {
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

    /// Exactly what is in the box, indentation and trailing newlines included. A draft being kept
    /// for later is the keystrokes it was, not the message `currentText` would have sent.
    var rawText: String { textView.text ?? "" }

    /// The Send button, so the enhance bubble can grow out of and retract into it.
    var sendControlAnchor: UIView { sendButton }

    func clear() {
        textView.text = ""
        textViewDidChange(textView)
        resyncKeyboard()
    }

    /// Where the caret stands, in UTF-16 offsets.
    var caretOffset: Int { textView.selectedRange.location }

    /// Rewrites one stretch of the draft and leaves the caret after it, through the text view's
    /// own replace so the change can be undone like a typed one.
    func replace(_ range: Range<Int>, with text: String) {
        guard
            let start = textView.position(from: textView.beginningOfDocument, offset: range.lowerBound),
            let end = textView.position(from: start, offset: range.count),
            let span = textView.textRange(from: start, to: end)
        else { return }
        textView.replace(span, withText: text)
        textViewDidChange(textView)
        resyncKeyboard()
    }

    /// The system's own Scan Text, aimed at this box, where the phone can read text through its
    /// camera: an error on another screen is typed by pointing at it.
    func scanTextAction() -> UIMenuElement? {
        guard textView.canPerformAction(#selector(UIResponder.captureTextFromCamera(_:)), withSender: nil)
        else { return nil }
        return UIAction.captureTextFromCamera(responder: textView, identifier: nil)
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

    func setDraft(_ text: String, focus: Bool = true, cursorAtEnd: Bool = false) {
        textView.text = text
        if cursorAtEnd {
            textView.selectedTextRange = textView.textRange(
                from: textView.endOfDocument, to: textView.endOfDocument)
        }
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

extension ComposerView: DictationComposerHost {
    var dictationTextView: UITextView { textView }
    var dictationBox: UIView { bar }
    var dictationSendControl: UIView { sendButton }

    var dictationPresenter: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }

    func dictationDidWrite() {
        textViewDidChange(textView)
        paintInk(force: true)
    }

    func dictationSend() { sendTapped() }

    func dictationSetListening(_ listening: Bool) {
        placeholder.text = listening ? DictationReading.listeningPlaceholder : restingPlaceholder
        UIView.animate(withDuration: 0.2) { self.auraHost.alpha = listening ? 0 : 1 }
        refreshDoors()
        if !listening { paintInk(force: true) }
    }

    func dictationShowStatus(_ status: DictationHintView, shown: Bool) {
        guard shown || status.superview === self else { return }
        if status.superview !== self {
            addSubview(status)
            NSLayoutConstraint.activate([
                status.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: Theme.Spacing.m),
                status.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
                status.trailingAnchor.constraint(
                    lessThanOrEqualTo: dictation.button.leadingAnchor, constant: -Theme.Spacing.s),
            ])
        }
        guard shown != statusShown else { return }
        statusShown = shown
        accessory?.isUserInteractionEnabled = !shown
        attachButton.isUserInteractionEnabled = !shown
        DictationSeat.move {
            self.applyLayout()
            status.alpha = shown ? 1 : 0
            self.accessory?.alpha = shown ? 0 : 1
            self.attachButton.alpha = shown ? 0 : 1
            self.superview?.layoutIfNeeded()
        }
    }
}

extension ComposerView {
    /// A selection has verbs of its own beside the system's, and an empty box offers the last
    /// thing that was sent from it.
    func textView(
        _ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        var verbs: [UIMenuElement] = []
        if range.length > 0 {
            verbs = [
                UIAction(title: DraftVerbs.codeTitle) { [weak self] _ in
                    self?.rewrite(range, by: DraftVerbs.code)
                },
                UIAction(title: DraftVerbs.quoteTitle) { [weak self] _ in
                    self?.rewrite(range, by: DraftVerbs.quote)
                },
            ]
        } else if (textView.text ?? "").isEmpty, delegate?.composerLastPrompt()?.isEmpty == false {
            verbs = [
                UIAction(title: DraftVerbs.lastPromptTitle) { [weak self] _ in
                    self?.delegate?.composerDidAskForLastPrompt()
                }
            ]
        }
        guard !verbs.isEmpty else { return nil }
        return UIMenu(children: Array(suggestedActions.prefix(1)) + verbs + suggestedActions.dropFirst())
    }

    private func rewrite(_ range: NSRange, by verb: (String) -> DraftVerbs.Edit) {
        let whole = (textView.text ?? "") as NSString
        guard range.location + range.length <= whole.length else { return }
        let edit = verb(whole.substring(with: range))
        replace(range.location..<(range.location + range.length), with: edit.text)
        textView.selectedRange = NSRange(
            location: range.location + edit.selectedStart, length: edit.selectedLength)
        Theme.Haptics.selection()
    }

    #if DEBUG
        /// Runs a selection verb over a stretch of the draft, for a run with no finger to open
        /// the menu.
        func stageVerb(_ name: String, over range: NSRange) {
            rewrite(range, by: name == "quote" ? DraftVerbs.quote : DraftVerbs.code)
        }
    #endif
}

/// A text view that is asked about a paste before UIKit takes it. Only a pasteboard holding a
/// picture is intercepted — words, and the overlong paste the delegate turns into a file, stay on
/// UIKit's own path so selection, undo and the system menu keep behaving exactly as they do
/// everywhere else on the phone.
final class PastingTextView: UITextView {
    var onPasteImage: ((Data, String) -> Void)?

    override func paste(_ sender: Any?) {
        let pasteboard = UIPasteboard.general
        if pasteboard.hasImages, !pasteboard.hasStrings {
            if let png = pasteboard.image?.pngData() {
                onPasteImage?(png, "image/png")
                return
            }
        }
        super.paste(sender)
    }
}
