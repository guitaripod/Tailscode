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

    private let textView = PastingTextView()
    private let scrollView = NSScrollView()
    private let fieldContainer = NSView()
    private let placeholderLabel = NSTextField(labelWithString: "")
    private var fieldHeight: NSLayoutConstraint?
    private var isMeasuring = false
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

    init(placeholder: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.stringValue = placeholder
        build()
        refreshMode()
        scheduleMeasure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        textView.isRichText = false
        textView.font = MacTheme.Ramp.font(.toolDetail)
        textView.textContainerInset = NSSize(width: MacTheme.Spacing.s, height: MacTheme.Spacing.s)
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.delegate = self
        textView.onPaste = { [weak self] in self?.onPaste?() ?? false }
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

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        placeholderLabel.font = MacTheme.Ramp.font(.toolDetail)
        placeholderLabel.textColor = MacTheme.Color.tertiaryLabel
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        fieldContainer.wantsLayer = true
        fieldContainer.layer?.cornerRadius = MacTheme.Radius.control
        fieldContainer.layer?.borderWidth = 1
        fieldContainer.layer?.borderColor = MacTheme.Color.separator.cgColor
        fieldContainer.translatesAutoresizingMaskIntoConstraints = false
        fieldContainer.addSubview(scrollView)
        fieldContainer.addSubview(placeholderLabel)
        addSubview(fieldContainer)

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
            scrollView.bottomAnchor.constraint(equalTo: fieldContainer.bottomAnchor),
            placeholderLabel.leadingAnchor.constraint(
                equalTo: fieldContainer.leadingAnchor, constant: MacTheme.Spacing.s + 5),
            placeholderLabel.topAnchor.constraint(
                equalTo: fieldContainer.topAnchor, constant: MacTheme.Spacing.s),
        ])
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
        get { placeholderLabel.stringValue }
        set { placeholderLabel.stringValue = newValue }
    }

    var text: String { textView.string }

    var isEditable: Bool {
        get { textView.isEditable }
        set { textView.isEditable = newValue }
    }

    var hasFocus: Bool { window?.firstResponder === textView }

    /// Where the popover that completes a command hangs from, and where a surface measures the
    /// box for anything it draws beside it.
    var fieldView: NSView { fieldContainer }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    func setText(_ text: String, caretAtEnd: Bool) {
        textView.string = text
        if caretAtEnd {
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        contentChanged()
    }

    func insertAtEnd(_ text: String) {
        setText(textView.string + text, caretAtEnd: true)
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
            fieldContainer.layer?.borderColor = MacTheme.Color.separator.cgColor
            return
        }
        textView.insertionPointColor = vim.mode == .insert ? .textInsertionPointColor : .clear
        let border: NSColor =
            switch vim.mode {
            case .insert: MacTheme.Color.separator
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
        refreshMode()
        scheduleMeasure()
    }

    func auraActive(effort: String?, inFlight: Bool) -> Bool {
        Ultracode.auraActive(effort: effort, draft: textView.string, inFlightInvoked: inFlight)
    }

    func setAura(_ active: Bool) {
        aura.setActive(active)
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

    private func measureField() {
        guard let font = textView.font else { return }
        let line = ceil(font.ascender - font.descender + font.leading)
        let inset = textView.textContainerInset.height * 2 + 2
        let floor = line + inset
        let ceiling = line * CGFloat(Self.composerLines) + inset
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
}

/// A text view whose paste is asked about first. AppKit routes ⌘V and the Edit menu's Paste to
/// `paste(_:)`, so one override covers both, and the composer answers whether it took the
/// clipboard for itself — a paste that was words is handed straight back to AppKit rather than
/// re-implemented, which is what keeps undo, selection and the system's own behaviour intact.
final class PastingTextView: NSTextView {
    var onPaste: (() -> Bool)?

    override func paste(_ sender: Any?) {
        guard onPaste?() != true else { return }
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        guard onPaste?() != true else { return }
        super.pasteAsPlainText(sender)
    }
}
