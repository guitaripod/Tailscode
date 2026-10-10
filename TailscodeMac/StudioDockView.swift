import AppKit
import ImageIO
import TailscodeCore
import UniformTypeIdentifiers

/// The brief, read left to right like a sentence: where to start from, the words, how, and go. It is
/// the one floating glass layer of the Studio — the stage under it is opaque canvas and the picture
/// is never covered by it — two rows tall: the start-from slot, the words box with Enhance at its
/// trailing edge and Generate beside it, then the chips, which are Core's `ImageGenField` list
/// wearing the pill look the chat composer's own row does, so the composer's Image lane and the
/// Studio can never disagree about what a picture is made from. The estimate sits quietly at the
/// foot. A rewrite rises out of the top edge as a card over the stage and never moves it.
@MainActor
final class StudioDockView: NSView, StudioDocking {
    var foldsChips = false {
        didSet {
            guard foldsChips != oldValue else { return }
            chipRow.folded = foldsChips
            needsLayout = true
        }
    }

    var onHeightChange: (() -> Void)?
    var onOpenMachine: ((NSView) -> Void)?
    var onNotice: ((String) -> Void)?

    private let studio: MacImageStudio
    private let glass = NSGlassEffectView()
    private let content = NSView()
    private let slotView: StudioStartSlot
    private let words = PromptEditor(placeholder: StudioDockView.placeholder)
    private let enhance = StudioEnhanceControl()
    private let go = StudioGoButton()
    private let chipRow: StudioChipRow
    private let card = StudioRewriteCard()
    private var lastDraft = ""
    private var lastHeight: CGFloat = 0
    private var popover: NSPopover?

    static var placeholder: String { Localized.text("Describe a picture, or drop one here to edit") }

    static let baseHeight: CGFloat = StudioTheme.dockBase
    var baseHeight: CGFloat { Self.baseHeight }

    init(studio: MacImageStudio) {
        self.studio = studio
        slotView = StudioStartSlot(studio: studio)
        chipRow = StudioChipRow(studio: studio)
        super.init(frame: .zero)
        glass.cornerRadius = 24
        glass.contentView = content
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        addSubview(glass)
        card.isHidden = true

        words.minimumLines = 2
        words.minimumHeight = 56
        words.maximumLines = 6
        words.translatesAutoresizingMaskIntoConstraints = false
        words.setAccessibilityLabel(ImageGenStudioWords.wordsTitle)
        words.onChanged = { [weak self] in self?.wordsChanged() }
        words.onPaste = { [weak self] in self?.takePastedPicture() ?? false }
        slotView.translatesAutoresizingMaskIntoConstraints = false
        enhance.translatesAutoresizingMaskIntoConstraints = false
        go.translatesAutoresizingMaskIntoConstraints = false
        chipRow.translatesAutoresizingMaskIntoConstraints = false
        for view in [slotView, words, go, chipRow] { content.addSubview(view) }
        words.addSubview(enhance)

        let pad: CGFloat = 14
        let rowGap: CGFloat = 10
        NSLayoutConstraint.activate([
            slotView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            slotView.topAnchor.constraint(equalTo: content.topAnchor, constant: pad),
            slotView.widthAnchor.constraint(equalToConstant: 56),
            slotView.heightAnchor.constraint(equalToConstant: 56),
            words.leadingAnchor.constraint(equalTo: slotView.trailingAnchor, constant: 12),
            words.topAnchor.constraint(equalTo: content.topAnchor, constant: pad),
            go.leadingAnchor.constraint(equalTo: words.trailingAnchor, constant: 12),
            go.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            go.centerYAnchor.constraint(equalTo: slotView.centerYAnchor),
            go.widthAnchor.constraint(equalToConstant: 148),
            go.heightAnchor.constraint(equalToConstant: 44),
            chipRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            chipRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            chipRow.heightAnchor.constraint(equalToConstant: 28),
            chipRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -pad),
            chipRow.topAnchor.constraint(greaterThanOrEqualTo: slotView.bottomAnchor, constant: rowGap),
            chipRow.topAnchor.constraint(greaterThanOrEqualTo: words.bottomAnchor, constant: rowGap),
            enhance.trailingAnchor.constraint(equalTo: words.trailingAnchor, constant: -8),
            enhance.bottomAnchor.constraint(equalTo: words.bottomAnchor, constant: -7),
        ])
        let rowTop = chipRow.topAnchor.constraint(equalTo: content.topAnchor, constant: pad + 56 + rowGap)
        rowTop.priority = .defaultLow
        rowTop.isActive = true

        slotView.onPickLibrary = { [weak self] anchor in self?.presentLibrary(from: anchor) }
        enhance.onEnhance = { [weak self] in self?.startEnhance() }
        enhance.onPicker = { [weak self] anchor in self?.openHelperMenu(from: anchor) }
        go.onPress = { [weak self] in self?.goPressed() }
        chipRow.onAvoid = { [weak self] anchor in self?.presentAvoid(from: anchor) }
        chipRow.onPickLibrary = { [weak self] anchor in self?.presentLibrary(from: anchor) }
        card.onUse = { [weak self] in self?.useRewrite() }
        card.onKeep = { [weak self] in self?.studio.dismissRewrite() }
        card.onAgain = { [weak self] in self?.rewriteAgain() }
        card.onRevise = { [weak self] instruction in
            guard let self else { return }
            self.studio.enhance(self.words.text, instruction: instruction)
        }
        studio.noticeHandler = { [weak self] line in self?.onNotice?(line) }
        registerForDraggedTypes(StudioDrop.registered)

        if !studio.slot.promptDraft.isEmpty {
            words.setText(studio.slot.promptDraft, caretAtEnd: true)
            lastDraft = studio.slot.promptDraft
        }
        syncControls()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged), name: MacTheme.Chrome.didRepaint, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    @objc private func themeChanged() { needsLayout = true }

    var wordsAreFocused: Bool { words.hasFocus }

    func focusWords() { words.focus() }

    /// Starter words and a note from a surface: they land in the box with the caret at the end, and
    /// nothing is sent by it.
    func take(brief text: String) {
        words.setText(text, caretAtEnd: true)
        words.focus()
    }

    var text: String { words.text }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !studio.isPainting, StudioDrop.accepts(sender.draggingPasteboard) else { return [] }
        slotView.lightUp(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { slotView.lightUp(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        slotView.lightUp(false)
        guard let drop = StudioDrop.read(sender.draggingPasteboard) else { return false }
        StudioDrop.hold(drop, in: studio) { _ in }
        return true
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        layoutCard()
    }

    func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        let row = max(56, words.fittingSize.height)
        return max(Self.baseHeight, 14 + row + 10 + 28 + 14)
    }

    private func layoutCard() {
        guard !card.isHidden else { return }
        card.frame = cardFrame
    }

    private var cardFrame: NSRect {
        let width = min(bounds.width - 32, 640)
        let height = card.fitting(width: width)
        return NSRect(x: (bounds.width - width) / 2, y: -height - 8, width: width, height: height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if !card.isHidden, card.frame.contains(local), let hit = card.hitTest(convert(local, to: card.superview)) {
            return hit
        }
        return super.hitTest(point)
    }

    /// The studio changed: the words follow it only where it wrote them (a render that landed keeps
    /// its words in the box, a refused one hands them back) and never over what is being typed.
    func studioChanged(_ change: StudioLaneChange) {
        switch change {
        case .everything:
            syncWords()
            syncControls()
            chipRow.reload()
            slotView.reload()
        case .shelf, .tile, .progress, .sketch:
            return
        }
        updateRewriteCard()
        let height = preferredHeight(forWidth: bounds.width)
        if abs(height - lastHeight) > 0.5 {
            lastHeight = height
            onHeightChange?()
        }
    }

    func rewriteChanged() {
        updateRewriteCard()
    }

    private func syncWords() {
        let draft = studio.slot.promptDraft
        guard draft != lastDraft else { return }
        lastDraft = draft
        guard words.text.trimmingCharacters(in: .whitespacesAndNewlines) != draft else { return }
        guard !words.hasFocus || words.text.isEmpty else { return }
        words.setText(draft, caretAtEnd: true)
    }

    private func syncControls() {
        let busy = studio.isPainting
        words.isEditable = !busy
        words.alphaValue = busy ? 0.55 : 1
        go.mode = busy ? .stop : .generate
        go.isEnabled = busy || canGenerate
        enhance.state = enhanceState
        chipRow.isEnabled = !busy
        slotView.isEnabled = !busy
    }

    private var canGenerate: Bool {
        !words.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var enhanceState: StudioEnhanceControl.Mode {
        if studio.enhancing { return .writing }
        if studio.isPainting { return .disabled }
        guard let helper = studio.helper else {
            return studio.surveying ? .looking : .find
        }
        return helper.enabled ? .ready(helper) : .off(helper)
    }

    private func wordsChanged() {
        studio.rememberDraft(words.text)
        lastDraft = studio.slot.promptDraft
        go.isEnabled = studio.isPainting || canGenerate
        enhance.state = enhanceState
        let height = preferredHeight(forWidth: bounds.width)
        if abs(height - lastHeight) > 0.5 {
            lastHeight = height
            onHeightChange?()
        }
    }

    private func takePastedPicture() -> Bool {
        let pasteboard = NSPasteboard.general
        guard pasteboard.string(forType: .string) == nil,
            let drop = StudioDrop.read(pasteboard)
        else { return false }
        StudioDrop.hold(drop, in: studio) { _ in }
        return true
    }

    func submit() {
        if studio.isPainting { return }
        let text = words.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        studio.submit(prompt: text)
    }

    func stopOrDismiss() {
        if studio.enhancing || studio.draft != nil {
            studio.dismissRewrite()
            return
        }
        studio.stop()
    }

    var hasRewriteCard: Bool { studio.draft != nil }

    func startEnhance() {
        let text = words.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !studio.isPainting else { return }
        studio.enhance(text)
    }

    private func goPressed() {
        if studio.isPainting { studio.stop() } else { submit() }
    }

    private func useRewrite() {
        guard let draft = studio.draft, draft.isUsable else { return }
        words.replaceAll(with: draft.written)
        studio.followWriter(aspect: draft.aspect)
        studio.dismissRewrite()
        words.focus()
    }

    private func rewriteAgain() {
        let source = studio.draft?.original ?? words.text
        studio.enhance(source)
    }

    private func updateRewriteCard() {
        guard let draft = studio.draft else {
            guard !card.isHidden else { return }
            card.dismiss(animated: StudioTheme.motionAllowed)
            return
        }
        let wasHidden = card.isHidden
        card.show(draft)
        let final = cardFrame
        guard wasHidden else {
            card.frame = final
            return
        }
        card.isHidden = false
        guard StudioTheme.motionAllowed else {
            card.alphaValue = 1
            card.frame = final
            return
        }
        card.alphaValue = 0
        card.frame = final.offsetBy(dx: 0, dy: StudioRewriteCard.riseDistance)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = StudioTheme.rewriteRise
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            card.animator().alphaValue = 1
            card.animator().frame = final
        }
    }

    private func presentAvoid(from anchor: NSView) {
        closePopover()
        let field = StudioAvoidPopover(current: studio.slot.negative) { [weak self] words in
            self?.studio.setNegative(words)
            self?.closePopover()
        } cancel: { [weak self] in
            self?.closePopover()
        }
        show(field, from: anchor)
    }

    private func presentLibrary(from anchor: NSView) {
        closePopover()
        let picker = StudioLibraryPicker(studio: studio) { [weak self] item in
            self?.studio.hold(kept: item)
            self?.closePopover()
        }
        show(picker, from: anchor)
        studio.library.refresh()
    }

    private func show(_ controller: NSViewController, from anchor: NSView) {
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = controller
        pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        popover = pop
    }

    private func closePopover() {
        popover?.close()
        popover = nil
    }

    private func openHelperMenu(from anchor: NSView) {
        if studio.helperServers.isEmpty, !studio.surveying { studio.surveyHelpers() }
        let menu = NSMenu()
        let current = studio.helper
        for server in studio.helperServers {
            let heading = NSMenuItem(title: server.heading, action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
            for model in server.models {
                let item = ClosureMenuItem(title: model.label) { [weak self] in
                    self?.studio.setHelper(ImageGenHelper(address: server.address, model: model))
                }
                item.subtitle = model.detail ?? ""
                item.state = current?.address == server.address && current?.model == model.id ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        if studio.surveying {
            let looking = NSMenuItem(title: ImageGenRewriteWords.lookingTitle, action: nil, keyEquivalent: "")
            looking.isEnabled = false
            menu.addItem(looking)
        } else {
            if studio.helperServers.isEmpty {
                let none = NSMenuItem(title: ImageGenRewriteWords.noneFoundTitle, action: nil, keyEquivalent: "")
                none.isEnabled = false
                none.toolTip = ImageGenRewriteWords.noneFoundHint
                menu.addItem(none)
            }
            let again = ClosureMenuItem(title: ImageGenRewriteWords.lookAgainTitle) { [weak self] in
                self?.studio.surveyHelpers()
            }
            again.toolTip = ImageGenRewriteWords.lookAgainHint
            menu.addItem(again)
        }
        if let current {
            let toggle = ClosureMenuItem(
                title: current.enabled ? ImageGenRewriteWords.offTitle : ImageGenRewriteWords.onTitle
            ) { [weak self] in
                self?.studio.toggleHelper()
            }
            toggle.toolTip = current.enabled ? ImageGenWords.helperOffHint : current.displayHost
            menu.addItem(toggle)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

}
