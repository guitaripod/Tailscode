import AppKit
import TailscodeCore

/// The prompt box, as one thing rather than as a habit each surface repeats. A question typed to
/// start a conversation and a question typed inside one are the same act, so they are the same
/// view: a text view as tall as what is in it that stops at the height the settings window sets,
/// wrapping instead of scrolling sideways, carrying the vim engine that shadows it, the ultracode
/// aura that says the powers are on, and the placeholder that says what the box is for.
///
/// It owns composition and nothing else — where the words go, what may ride with them and which
/// keys mean send are the surface's to decide, because a chat has a conversation to send into and
/// a quick ask has a machine to mint one on.
@MainActor
final class PromptEditor: NSView {
    let vim = VimEngine()

    /// Every path that changes what is in the box lands here — a keystroke, a vim edit, a
    /// completion accepted — so a surface can record its draft in one place.
    var onChanged: (() -> Void)?
    /// Whether the box took the pasteboard for itself. Words are handed back to AppKit rather
    /// than re-implemented, which is what keeps undo, selection and the system's own behaviour.
    var onPaste: (() -> Bool)?
    /// The mode the engine is in changed without a key: a press in the box meant typing.
    var onModeChanged: (() -> Void)?
    /// The person changed the box with their own hands while a take was writing into it.
    var onEditDuringDictation: (() -> Void)?
    /// The person changed the box with their own hands while no take was writing into it.
    var onEditOutsideDictation: (() -> Void)?
    /// The field took a new height. A surface sized to its contents asks for that size again.
    var onFieldHeightChanged: (() -> Void)?
    let dictationEdge = MacDictationEdge()
    private(set) var dictating = false
    private var writingDictation = false
    private var restingPlaceholder = ""

    private let textView = PastingTextView()
    private let scrollView = NSScrollView()
    private let fieldContainer = FocusingField()
    private let placeholderLabel = NSTextField(labelWithString: "")
    private var fieldHeight: NSLayoutConstraint?
    private var isMeasuring = false
    private var scrollBottom: NSLayoutConstraint?
    private var footer: NSView?
    private var footerRoom: CGFloat = 0
    private(set) var footerShown = false
    private var footerToken = 0
    static let footerHeight: CGFloat = 18
    private lazy var aura = UltracodeAura(
        around: fieldContainer, cornerRadius: MacTheme.Radius.control)

    static var sendOnReturn: Bool {
        UserDefaults.standard.object(forKey: "tailscode.sendOnReturn") as? Bool ?? true
    }

    static var vimPreferred: Bool {
        UserDefaults.standard.bool(forKey: "tailscode.vimComposer")
    }

    private static var composerLines: Int {
        let stored = UserDefaults.standard.integer(forKey: "tailscode.composerLines")
        return stored == 0 ? 12 : min(20, max(1, stored))
    }

    /// How many lines tall the box is when empty, for a surface whose box is the main thing on it:
    /// the Studio's words open on two. One for every other surface, which is what it always was.
    var minimumLines = 1 {
        didSet { scheduleMeasure() }
    }

    /// A floor in points under the box's height, for a surface that lines it up beside something of
    /// a fixed size. Zero leaves the height to the lines.
    var minimumHeight: CGFloat = 0 {
        didSet { scheduleMeasure() }
    }

    /// Where the box stops growing and scrolls, for a surface that has its own ceiling. Nil leaves
    /// it to the setting every other prompt box in the app answers to.
    var maximumLines: Int? {
        didSet { scheduleMeasure() }
    }

    /// A box that is the largest thing on its surface — the quick ask's — draws no edge at rest
    /// and sets its words a size up; the vim modes still colour the edge, since that is the mode
    /// speaking rather than the box.
    var isBare = false {
        didSet {
            applyRamp()
            refreshMode()
            scheduleMeasure()
        }
    }

    private var resting: NSColor { isBare ? .clear : Self.restingBorder }

    init(placeholder: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.stringValue = placeholder
        build()
        textView.setAccessibilityLabel(placeholder)
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged), name: MacTheme.Chrome.didRepaint, object: nil)
        refreshMode()
        scheduleMeasure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func themeChanged() {
        refreshMode()
    }

    private func build() {
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: MacTheme.Spacing.s, height: MacTheme.Spacing.s)
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.delegate = self
        textView.onPaste = { [weak self] in self?.onPaste?() ?? false }
        textView.onPointerFocus = { [weak self] in self?.pointerFocused() }
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.unregisterDraggedTypes()

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        placeholderLabel.textColor = MacTheme.Color.onGlassSecondary
        placeholderLabel.lineBreakMode = .byTruncatingTail
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        applyRamp()

        fieldContainer.target = textView
        fieldContainer.wantsLayer = true
        fieldContainer.layer?.cornerRadius = MacTheme.Radius.control
        fieldContainer.layer?.borderWidth = 1
        fieldContainer.layer?.borderColor = resting.cgColor
        fieldContainer.translatesAutoresizingMaskIntoConstraints = false
        fieldContainer.addSubview(scrollView)
        fieldContainer.addSubview(placeholderLabel)
        addSubview(fieldContainer)
        dictationEdge.cornerRadius = MacTheme.Radius.control
        addSubview(dictationEdge)

        let height = fieldContainer.heightAnchor.constraint(equalToConstant: 34)
        fieldHeight = height
        NSLayoutConstraint.activate([
            height,
            fieldContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            fieldContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            fieldContainer.topAnchor.constraint(equalTo: topAnchor),
            fieldContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: fieldContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: fieldContainer.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: fieldContainer.topAnchor),
            scrollBottomConstraint(),
            placeholderLabel.leadingAnchor.constraint(
                equalTo: fieldContainer.leadingAnchor, constant: MacTheme.Spacing.s + 5),
            placeholderLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: fieldContainer.trailingAnchor,
                constant: -(MacTheme.Spacing.s + 5)),
            placeholderLabel.topAnchor.constraint(
                equalTo: fieldContainer.topAnchor, constant: MacTheme.Spacing.s),
            dictationEdge.leadingAnchor.constraint(equalTo: fieldContainer.leadingAnchor),
            dictationEdge.trailingAnchor.constraint(equalTo: fieldContainer.trailingAnchor),
            dictationEdge.topAnchor.constraint(equalTo: fieldContainer.topAnchor),
            dictationEdge.bottomAnchor.constraint(equalTo: fieldContainer.bottomAnchor),
        ])
    }

    /// The ramp is read rather than remembered: the box is set in the role that exists for what a
    /// person types, and what that role is worth changes with the window's type scale.
    private func applyRamp() {
        let base = MacTheme.Ramp.font(.composer)
        let font = isBare ? NSFont(descriptor: base.fontDescriptor, size: base.pointSize * 1.25) ?? base : base
        textView.font = font
        placeholderLabel.font = font
    }

    /// The edge of the field at rest. The box floats inside the composer's glass, and glass
    /// resolves its own light or dark register from whatever is behind it — only a system colour
    /// follows it there, so a palette hex would sit on the material without flipping with it.
    private static var restingBorder: NSColor {
        MacTheme.Color.onGlassSecondary.withAlphaComponent(0.35)
    }

    override func layout() {
        super.layout()
        scheduleMeasure()
        aura.layout()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshMode()
    }

    var placeholder: String {
        get { dictating ? restingPlaceholder : placeholderLabel.stringValue }
        set {
            restingPlaceholder = newValue
            placeholderLabel.stringValue = dictating ? DictationReading.listeningPlaceholder : newValue
            textView.setAccessibilityLabel(newValue)
        }
    }

    /// Where a take's words would go: the text before the selection and the text after it, and the
    /// selection itself so a cancel can put the caret back.
    func dictationAnchor() -> (insertion: DictationInsertion, selection: NSRange) {
        let text = textView.string as NSString
        let range = textView.selectedRange()
        let start = min(range.location, text.length)
        let end = min(range.location + range.length, text.length)
        return (DictationInsertion(before: text.substring(to: start), after: text.substring(from: end)), range)
    }

    /// Opens or closes the box to a take: the placeholder says it is listening, the ultracode
    /// aura steps aside for the lit edge, and the words the take writes are not the person's typing.
    func setDictating(_ value: Bool) {
        guard value != dictating else { return }
        if value { restingPlaceholder = placeholderLabel.stringValue }
        dictating = value
        placeholderLabel.stringValue = value ? DictationReading.listeningPlaceholder : restingPlaceholder
        aura.setParked(value)
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: textView.font ?? MacTheme.Ramp.font(.composer), .foregroundColor: NSColor.textColor]
    }

    /// The box with a take in it, outside the undo history: only the take's last state becomes an
    /// undo step, in `commitDictation`.
    func showDictation(_ composition: DictationComposition, struck: Bool) {
        writingDictation = true
        let storage = textView.textStorage
        let text = NSMutableAttributedString(string: composition.text, attributes: baseAttributes)
        text.addAttribute(
            .foregroundColor, value: MacTheme.Color.accent.withAlphaComponent(0.9), range: composition.heardUTF16)
        if struck {
            text.addAttributes(
                [.foregroundColor: NSColor.tertiaryLabelColor, .strikethroughStyle: NSUnderlineStyle.single.rawValue],
                range: composition.takeUTF16)
        }
        storage?.setAttributedString(text)
        textView.typingAttributes = baseAttributes
        textView.setSelectedRange(NSRange(location: composition.caretUTF16, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        writingDictation = false
        contentChanged()
    }

    /// The take's words as one undo step back to the box as it was before the take.
    func commitDictation(_ composition: DictationComposition, from original: String) {
        writingDictation = true
        textView.textStorage?.setAttributedString(NSAttributedString(string: original, attributes: baseAttributes))
        let whole = NSRange(location: 0, length: (original as NSString).length)
        if composition.text != original, textView.shouldChangeText(in: whole, replacementString: composition.text) {
            textView.breakUndoCoalescing()
            textView.textStorage?.replaceCharacters(
                in: whole, with: NSAttributedString(string: composition.text, attributes: baseAttributes))
            textView.didChangeText()
            textView.undoManager?.setActionName(DictationReading.undoActionName)
        }
        textView.typingAttributes = baseAttributes
        textView.setSelectedRange(NSRange(location: composition.caretUTF16, length: 0))
        writingDictation = false
        setDictating(false)
        vim.reset(to: textView.string, cursor: cursor, mode: vim.mode)
        contentChanged()
    }

    /// The box exactly as it was before a take that was thrown away.
    func restoreDictation(_ original: String, selection: NSRange) {
        writingDictation = true
        textView.textStorage?.setAttributedString(NSAttributedString(string: original, attributes: baseAttributes))
        let length = (original as NSString).length
        let location = min(selection.location, length)
        textView.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        textView.typingAttributes = baseAttributes
        writingDictation = false
        setDictating(false)
        vim.reset(to: textView.string, cursor: cursor, mode: vim.mode)
        contentChanged()
    }

    /// The words stay exactly as shown, in ink: a take stopped by typing or by leaving the chat.
    func keepDictationAsShown() {
        if let storage = textView.textStorage {
            storage.setAttributes(baseAttributes, range: NSRange(location: 0, length: storage.length))
        }
        textView.typingAttributes = baseAttributes
        setDictating(false)
    }

    var text: String { textView.string }

    var isEditable: Bool {
        get { textView.isEditable }
        set { textView.isEditable = newValue }
    }

    var hasFocus: Bool { window?.firstResponder === textView }

    /// Whether an input method is still composing in the box — a Japanese or Chinese candidate
    /// open, a Korean syllable not yet committed. Return, Escape, Tab and the arrows belong to the
    /// input method until then: a Return that sent the message instead of committing the
    /// candidate made the box unusable in three of the languages the app speaks.
    var isComposing: Bool { textView.hasMarkedText() }

    /// Where the popover that completes a command hangs from, and where a surface measures the
    /// box for anything it draws beside it.
    var fieldView: NSView { fieldContainer }

    var focusTarget: NSView { textView }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    /// A press that took the keyboard for the box is a person who means to type: in the vim
    /// composer's normal or visual mode the caret is drawn clear, so the box looked focused and
    /// showed nothing, and stayed that way until the chat was left and entered again — which resets
    /// the mode. Focus the keyboard gave without a press, by Tab or a chord, keeps the mode it had.
    func pointerFocused(vimEnabled: Bool = PromptEditor.vimPreferred) {
        guard vimEnabled, vim.mode != .insert else { return }
        vim.reset(to: textView.string, cursor: cursor, mode: .insert)
        refreshMode()
        onModeChanged?()
    }

    func setText(_ text: String, caretAtEnd: Bool) {
        textView.string = text
        if caretAtEnd {
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        contentChanged()
    }

    /// Puts the caret at a character offset, for words written with a place left for the person.
    func placeCaret(at offset: Int) {
        let text = textView.string
        let index = text.index(text.startIndex, offsetBy: max(0, min(offset, text.count)))
        let location = NSRange(index..<index, in: text).location
        textView.setSelectedRange(NSRange(location: location, length: 0))
        vim.reset(to: text, cursor: cursor, mode: vim.mode)
    }

    /// A path clicked in the file tree, or a command picked from a menu, lands where the caret is
    /// standing rather than at the end of whatever sentence is half-written — and it goes through
    /// the text view, so it replaces the selection and joins AppKit's own undo.
    func insertAtCaret(_ text: String) {
        textView.insertText(text, replacementRange: textView.selectedRange())
        contentChanged()
        focus()
    }

    /// Puts other words in the box through the text view rather than around it, so the sentence that
    /// was there is one ⌘Z away: a rewrite taken is never a rewrite that cannot be taken back.
    func replaceAll(with text: String) {
        let whole = NSRange(location: 0, length: (textView.string as NSString).length)
        textView.insertText(text, replacementRange: whole)
        contentChanged()
        focus()
    }

    func selectedText() -> String? {
        let range = textView.selectedRange()
        guard range.length > 0 else { return nil }
        return (textView.string as NSString).substring(with: range)
    }

    /// The engine's own cursor is the truth while a visual selection is painted — the text
    /// view's insertion point sits at the selection's edge, which is not where vim is standing.
    var cursor: Int {
        if Self.vimPreferred, vim.mode == .visual || vim.mode == .visualLine {
            return vim.document.cursor
        }
        return Self.characterOffset(fromUTF16: textView.selectedRange().location, in: textView.string)
    }

    func write(_ document: VimDocument, selection: Range<Int>?) {
        let text = document.text
        if textView.string != text {
            textView.string = text
        }
        if let selection {
            let lower = Self.utf16Offset(fromCharacter: selection.lowerBound, in: text)
            let upper = Self.utf16Offset(fromCharacter: selection.upperBound, in: text)
            textView.setSelectedRange(NSRange(location: lower, length: upper - lower))
        } else {
            let caret = Self.utf16Offset(fromCharacter: document.cursor, in: text)
            textView.setSelectedRange(NSRange(location: caret, length: 0))
        }
        textView.scrollRangeToVisible(textView.selectedRange())
        contentChanged()
    }

    /// Alongside any badge a surface keeps, the caret itself says which mode this is: it blinks
    /// only in insert — the letters belong to commands, and a blinking beam would promise typing
    /// the box will not do. The field's border carries the mode too.
    func refreshMode() {
        guard Self.vimPreferred else {
            textView.insertionPointColor = .textInsertionPointColor
            fieldContainer.layer?.borderColor = resting.cgColor
            return
        }
        textView.insertionPointColor = vim.mode == .insert ? .textInsertionPointColor : .clear
        let border: NSColor =
            switch vim.mode {
            case .insert: resting
            case .normal: MacTheme.Color.accent
            case .visual, .visualLine: MacTheme.Color.warning
            }
        fieldContainer.layer?.borderColor = border.cgColor
    }

    /// Settings changed underneath a live box: a vim toggle must move the caret and the border to
    /// the truth right now — leaving normal mode when the engine is switched off, so no draft
    /// ends up trapped behind a hidden caret — and a new height ceiling re-measures the field.
    func applyPreferences() {
        if !Self.vimPreferred, vim.mode != .insert {
            vim.reset(to: textView.string, cursor: cursor, mode: .insert)
        }
        applyRamp()
        refreshMode()
        scheduleMeasure()
    }

    func auraActive(effort: String?, inFlight: Bool) -> Bool {
        Ultracode.auraActive(effort: effort, draft: textView.string, inFlightInvoked: inFlight)
    }

    func setAura(_ active: Bool) {
        aura.setActive(active)
    }

    func setAuraParked(_ parked: Bool) {
        aura.setParked(parked)
    }

    private func scrollBottomConstraint() -> NSLayoutConstraint {
        let constraint = scrollView.bottomAnchor.constraint(equalTo: fieldContainer.bottomAnchor)
        scrollBottom = constraint
        return constraint
    }

    /// The box's last line: what a take says about itself, inside the field under the words rather
    /// than a label outside it, set trailing so it ends beside the microphone. While it shows, the
    /// words stop a line short of the field's bottom and the field grows by that line, so the caret
    /// and the last words are never under it.
    /// Types as a person would, through the text view's own path, for the self-test.
    func harnessType(_ words: String) {
        textView.insertText(words, replacementRange: textView.selectedRange())
    }

    func mountDictationFooter(_ view: NSView) {
        guard footer == nil else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        view.alphaValue = 0
        view.isHidden = true
        fieldContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.trailingAnchor.constraint(equalTo: fieldContainer.trailingAnchor, constant: -(MacTheme.Spacing.s + 2)),
            view.leadingAnchor.constraint(greaterThanOrEqualTo: fieldContainer.leadingAnchor, constant: MacTheme.Spacing.s),
            view.widthAnchor.constraint(
                lessThanOrEqualTo: fieldContainer.widthAnchor, constant: -(MacTheme.Spacing.s * 2 + 2)),
            view.bottomAnchor.constraint(equalTo: fieldContainer.bottomAnchor, constant: -3),
            view.heightAnchor.constraint(equalToConstant: Self.footerHeight),
        ])
        footer = view
    }

    func setDictationFooterShown(_ shown: Bool, animated: Bool) {
        guard let footer, shown != footerShown else { return }
        footerShown = shown
        footerToken += 1
        let token = footerToken
        footerRoom = shown ? Self.footerHeight + 3 : 0
        if shown { footer.isHidden = false }
        let motion = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? (motion ? 0.2 : 0.12) : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            footer.alphaValue = shown ? 1 : 0
            self.scrollBottom?.constant = -self.footerRoom
            self.measureField(animated: motion)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.footerToken == token, !self.footerShown else { return }
                footer.isHidden = true
            }
        }
    }

    private func contentChanged() {
        placeholderLabel.isHidden = !textView.string.isEmpty
        scheduleMeasure()
        onChanged?()
    }

    /// The prompt box is as tall as what is in it: one line when empty, taller as the text wraps
    /// or a paragraph is pasted, and it stops growing at `tailscode.composerLines` — after which
    /// it scrolls, so nothing beside it is squeezed off the screen. Measured on the next runloop
    /// pass, never inline: a text view that was just emptied still reports the height it had
    /// until the next layout.
    private func scheduleMeasure() {
        guard !isMeasuring else { return }
        isMeasuring = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isMeasuring = false
            self.measureField()
        }
    }

    private func measureField(animated: Bool = false) {
        guard let font = textView.font else { return }
        let line = ceil(font.ascender - font.descender + font.leading)
        let inset = textView.textContainerInset.height * 2 + 2 + footerRoom
        let floor = max(line * CGFloat(max(1, minimumLines)) + inset, minimumHeight + footerRoom)
        let ceiling = max(floor, line * CGFloat(maximumLines ?? Self.composerLines) + inset)
        var wanted = floor
        if !textView.string.isEmpty {
            var used = floor
            if let layout = textView.textLayoutManager {
                layout.ensureLayout(for: layout.documentRange)
                used = layout.usageBoundsForTextContainer.height + inset
            } else if let manager = textView.layoutManager, let container = textView.textContainer {
                manager.ensureLayout(for: container)
                used = manager.usedRect(for: container).height + inset
            }
            wanted = max(floor, min(ceiling, ceil(used)))
        }
        guard let fieldHeight, abs(fieldHeight.constant - wanted) > 0.5 else { return }
        fieldHeight.constant = wanted
        if animated { superview?.layoutSubtreeIfNeeded() }
        onFieldHeightChanged?()
    }

    /// One reading of a key press for the vim engine, shared by every surface that hands it
    /// keys, so the chat's box and the quick ask never disagree about what a keystroke was.
    static func vimKey(for event: NSEvent) -> VimKey {
        var character: Character?
        if let raw = event.charactersIgnoringModifiers?.first,
            let scalar = raw.unicodeScalars.first?.value, scalar >= 0x20,
            !(0xF700...0xF8FF).contains(scalar)
        {
            character = raw
        }
        return VimKey(
            character: character,
            isEscape: event.keyCode == 53,
            isEnter: event.keyCode == 36 || event.keyCode == 76,
            isBackspace: event.keyCode == 51,
            control: event.modifierFlags.contains(.control))
    }

    private static func characterOffset(fromUTF16 location: Int, in text: String) -> Int {
        guard let range = Range(NSRange(location: location, length: 0), in: text) else {
            return text.count
        }
        return text.distance(from: text.startIndex, to: range.lowerBound)
    }

    private static func utf16Offset(fromCharacter offset: Int, in text: String) -> Int {
        let index = text.index(text.startIndex, offsetBy: min(max(0, offset), text.count))
        return NSRange(index..<index, in: text).location
    }
}

extension PromptEditor: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        contentChanged()
    }

    func textView(
        _ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?
    ) -> Bool {
        if !writingDictation {
            if dictating { onEditDuringDictation?() } else { onEditOutsideDictation?() }
        }
        return true
    }
}

/// The visible box of the prompt, every point of which is the text view's. The words sit inside a
/// scroll view that can be a point or two shorter than the box, a placeholder label is drawn over
/// the field, and a press on either used to land on something that takes no keyboard — the box
/// looked clicked and showed no caret until the chat was left and entered again. A scroller keeps
/// its own presses, so a long draft can still be scrolled by hand.
@MainActor
final class FocusingField: NSView {
    weak var target: NSView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSScroller || hit is NSButton ? hit : target ?? hit
    }
}

/// A text view whose paste is asked about first. AppKit routes ⌘V and the Edit menu's Paste to
/// `paste(_:)`, so one override covers both, and the composer answers whether it took the
/// clipboard for itself — a paste that was words is handed straight back to AppKit rather than
/// re-implemented, which is what keeps undo, selection and the system's own behaviour intact.
final class PastingTextView: NSTextView {
    var onPaste: (() -> Bool)?
    var onPointerFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took, NSApp.currentEvent?.type == .leftMouseDown { onPointerFocus?() }
        return took
    }

    override func paste(_ sender: Any?) {
        guard onPaste?() != true else { return }
        super.paste(sender)
    }

    /// A file dragged onto the prompt box is an attachment, not a path pasted into the draft, so
    /// the box takes no drag at all and the drop falls through to the surface that registered for
    /// it. AppKit re-registers a text view's drag types whenever its editability changes, which is
    /// why the refusal has to be an override rather than one call at build time.
    override func updateDragTypeRegistration() {
        unregisterDraggedTypes()
    }

    override func pasteAsPlainText(_ sender: Any?) {
        guard onPaste?() != true else { return }
        super.pasteAsPlainText(sender)
    }

    /// ⌘⌫ is delete-to-line-start in every text field on the Mac, and it is also the chord of the
    /// menu's Delete conversation. A key equivalent reaches the view under the cursor before the
    /// menu bar, so the box takes it here and the menu never sees a person editing a draft.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command, event.keyCode == 51, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        deleteToBeginningOfLine(nil)
        return true
    }
}
