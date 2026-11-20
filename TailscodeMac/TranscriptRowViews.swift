import AppKit
import CodingAgentKit
import TailscodeCore

/// A header you click and a body that appears under it, built lazily the first time it opens —
/// nearly every row is collapsed, and its body must cost nothing until then. The body survives a
/// collapse hidden, so reopening is free. `onToggle` also receives the row itself, because the
/// one thing a caller cannot reconstruct from a key is where on screen the clicked header is.
@MainActor
final class DisclosureRow: NSView, KeyboardPressable {
    private let stack = FillingStack()
    private let header: NSView
    private let press: PressSurface
    private let makeBody: () -> NSView
    private let onToggle: (Bool, DisclosureRow) -> Void
    private var body: NSView?

    /// The header this row was built around, for a restate that writes into its labels.
    var headerView: NSView? { header }
    /// The body, if it has ever been opened — hidden while collapsed, never discarded.
    var bodyView: NSView? { body }
    /// The header's pressable surface, for a harness that proves it answers the pointer.
    var headerSurface: PressSurface { press }

    /// - Parameter lineHeight: how tall the header's line is at the least, from the density's
    ///   table; zero leaves it as tall as its words.
    init(
        header: NSView, expanded: Bool, lineHeight: CGFloat = 0,
        onToggle: @escaping (Bool, DisclosureRow) -> Void,
        makeBody: @escaping () -> NSView
    ) {
        self.header = header
        self.press = PressSurface(content: header, minHeight: lineHeight)
        self.makeBody = makeBody
        self.onToggle = onToggle
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        stack.addArrangedSubview(press)
        press.onPress = { [weak self] in self?.toggle() }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        let spoken = Self.spoken(header)
        if !spoken.isEmpty { setAccessibilityLabel(spoken) }
        setAccessibilityExpanded(false)
        if expanded { reveal() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Every word the header shows, in the order it shows them. A tool's header is a row of labels
    /// — the tool, what it touched, how it ended — and naming the row only when its header was one
    /// label left the commonest row in a transcript unnamed to VoiceOver.
    private static func spoken(_ view: NSView) -> String {
        guard !view.isHidden else { return "" }
        if let field = view as? NSTextField { return field.stringValue }
        let parts = (view as? NSStackView)?.arrangedSubviews ?? view.subviews
        return parts.map(spoken).filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// With Full Keyboard Access on, a row is a stop in the Tab loop and Space or Return opens it;
    /// without it a click keeps meaning what it always meant, and the composer keeps the keyboard.
    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override func keyDown(with event: NSEvent) {
        guard [49, 36, 76].contains(event.keyCode) else { return super.keyDown(with: event) }
        toggle()
    }

    override func accessibilityPerformPress() -> Bool {
        toggle()
        return true
    }

    private func toggle() {
        let interval = Pace.signposter.beginInterval("expand")
        defer { Pace.signposter.endInterval("expand", interval) }
        if let body {
            body.isHidden = !body.isHidden
            setAccessibilityExpanded(!body.isHidden)
            onToggle(!body.isHidden, self)
            return
        }
        reveal()
        onToggle(true, self)
    }

    private func reveal() {
        let built = makeBody()
        stack.addArrangedSubview(built)
        body = built
        setAccessibilityExpanded(true)
    }

    /// The header restated without rebuilding the row — what a thought counting its own words
    /// needs, since tearing the row down twenty times a second is the flicker, not the counting.
    func restate(header text: String) {
        (header as? NSTextField)?.stringValue = text
        setAccessibilityLabel(text)
    }

    /// The body restated, when it happens to be open already.
    func restateBody(_ text: String) {
        guard let body else { return }
        if let field = body as? NSTextField {
            field.stringValue = text
            return
        }
        for view in body.subviews {
            if let field = view as? NSTextField {
                field.stringValue = text
                return
            }
        }
    }
}

/// A prompt row that knows its own message, so it can offer "Undo from here" the way every other
/// destructive action on a Mac does: from the row's own context menu rather than a button that
/// would sit in the transcript forever asking to be pressed.
///
/// The item is left off the menu entirely when it does not apply, rather than shown and disabled,
/// because a menu that always has the same items and sometimes greys one out invites a second
/// look at a row that never earned one. Where it does apply, the menu is the message's own, with
/// Copy beside it, because the words are a selectable label whose text menu would otherwise
/// answer every right-click on them.
@MainActor
final class PromptRow: NSView {
    private let messageID: String
    private let text: String?
    private let context: TranscriptContext

    init(messageID: String, text: String?, context: TranscriptContext) {
        self.messageID = messageID
        self.text = text
        self.context = context
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return asksForMenu(NSApp.currentEvent) ? self : hit
    }

    /// Whether the event in flight is a request for a context menu this row answers: a right
    /// click, or a click with Control held, on a message that can be wound back to. Any other
    /// event reaches the label as before, so selecting the words still works.
    private func asksForMenu(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        let wantsMenu =
            event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        return wantsMenu && context.offersUndo?(messageID) == true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard context.offersUndo?(messageID) == true else { return nil }
        let menu = NSMenu()
        if let target = link(under: event) {
            for item in RowKit.ProseLabel.linkItems(target) { menu.addItem(item) }
            menu.addItem(.separator())
        }
        let item = NSMenuItem(
            title: RevertReading.actionTitle, action: #selector(undo), keyEquivalent: "")
        item.target = self
        item.image = NSImage(
            systemSymbolName: RevertReading.actionSymbol, accessibilityDescription: nil)
        menu.addItem(item)
        if text != nil {
            menu.addItem(.separator())
            let copy = NSMenuItem(
                title: Localized.text("Copy"), action: #selector(copyWords), keyEquivalent: "")
            copy.target = self
            menu.addItem(copy)
        }
        return menu
    }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.control), let menu = menu(for: event) else {
            return super.mouseDown(with: event)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func undo() {
        context.confirmUndo?(messageID)
    }

    /// The link under a right-click, when it landed on one. The message's own menu answers every
    /// right-click on the row, and a link in the words would otherwise have lost Open and Copy.
    private func link(under event: NSEvent) -> URL? {
        let point = convert(event.locationInWindow, from: nil)
        guard let label = hitLabel(at: point, in: self) else { return nil }
        return label.link(at: label.convert(point, from: self))
    }

    private func hitLabel(at point: NSPoint, in view: NSView) -> RowKit.ProseLabel? {
        for child in view.subviews.reversed() where !child.isHidden {
            let local = child.convert(point, from: view)
            guard child.bounds.contains(local) else { continue }
            if let label = child as? RowKit.ProseLabel { return label }
            if let found = hitLabel(at: local, in: child) { return found }
        }
        return nil
    }

    @objc private func copyWords() {
        guard let words = context.promptWords?(messageID) ?? text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(words, forType: .string)
    }
}

/// The row a sent message stands in until the server's account carries it. The rule and the words
/// are the prompt's own, because that is what this is; the state is the ink — faint on the wire,
/// full once the server has it, the danger tone when it never got there — and the line under the
/// words is drawn only when `PendingSendReading.caption` has something to say. The row survives a
/// phase change: the bubble animates from faint to full instead of being torn down and remade.
@MainActor
final class PendingSendRowView: NSView {
    private let rule = RowKit.Ground(frame: .zero)
    private let column = NSStackView()
    private let words: NSTextField
    private lazy var fold: NSButton = RowKit.linkButton("") { [weak self] in self?.toggleFold() }
    private let strip = NSStackView()
    private let mark = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    private let acts = NSStackView()
    private lazy var pulse = ActivityPulse(view: mark)
    private var ink: PendingSendReading.Ink
    private var send: PendingSend
    private var plan: ResumePlan?
    private var icon: ActivityIcon?
    private var breathing: ActivityIcon?
    private var offered: [String] = []
    private var foldOpen: Bool
    private var showsStrip = false
    private var showsActs = false
    private var fadeToken = 0
    private let context: TranscriptContext

    init(send: PendingSend, plan: ResumePlan?, now: Date, context: TranscriptContext) {
        self.send = send
        self.plan = plan
        self.context = context
        ink = PendingSendReading.ink(send)
        foldOpen = context.isExpanded(Self.foldKey(send))
        words = RowKit.attributedLabel(NSAttributedString(string: ""))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        rule.wantsLayer = true
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(words)

        fold.font = MacTheme.Ramp.font(.codeAction)
        fold.contentTintColor = MacTheme.Color.secondaryLabel
        column.addArrangedSubview(fold)

        strip.orientation = .horizontal
        strip.alignment = .firstBaseline
        strip.spacing = 5
        strip.wantsLayer = true
        mark.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        mark.wantsLayer = true
        caption.font = MacTheme.Ramp.font(.hint)
        strip.addArrangedSubview(mark)
        strip.addArrangedSubview(caption)
        strip.isHidden = true
        column.addArrangedSubview(strip)

        acts.orientation = .horizontal
        acts.spacing = MacTheme.Spacing.m
        acts.wantsLayer = true
        acts.isHidden = true
        column.addArrangedSubview(acts)

        addSubview(rule)
        addSubview(column)
        NSLayoutConstraint.activate([
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor),
            rule.widthAnchor.constraint(equalToConstant: 2),
            column.leadingAnchor.constraint(
                equalTo: rule.trailingAnchor, constant: MacTheme.Spacing.s + 2),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        writeWords()
        paint(now: now, animated: false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Where a reader's open or closed fold is kept: the echo's own key, the way a sent prompt's
    /// fold is kept under its message.
    private static func foldKey(_ send: PendingSend) -> String {
        PromptFold.key(messageID: "echo:\(send.id.uuidString)")
    }

    /// The room the words lose to the rule and the gap beside it, the same as a sent prompt's.
    private static var indent: CGFloat { 2 + MacTheme.Spacing.s + 2 }

    private var columns: Int {
        PromptFold.columns(
            width: Double(max(0, (context.columnWidth?() ?? 0) - Self.indent)),
            fontSize: Double(MacTheme.Ramp.font(.prompt).pointSize), monospaced: false)
    }

    /// The words exactly as the server's own row will draw them: the prompt face, links live, and
    /// a long prompt folded with the same line under it, so the swap changes nothing.
    private func writeWords() {
        let text = send.text
        words.isHidden = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let reading = PromptFold.read(text, columns: columns, expanded: foldOpen)
        words.attributedStringValue = MacMarkdown.plainWithLinks(
            reading.folded ? PromptFold.cut(text, columns: columns) : text,
            font: MacTheme.Ramp.font(.prompt), color: MacTheme.Color.label)
        if let title = reading.toggleLabel {
            fold.title = (reading.folded ? "⌄ " : "⌃ ") + title
            fold.isHidden = false
        } else {
            fold.isHidden = true
        }
    }

    private func toggleFold() {
        foldOpen.toggle()
        context.onToggle?(Self.foldKey(send), foldOpen)
        writeWords()
    }

    /// The same row, a moment later. Only what changed moves: a new ink crossfades the rule, a line
    /// or a row of choices that comes or goes fades, and then all of it holds still.
    func restate(send: PendingSend, plan: ResumePlan?, now: Date) {
        let textChanged = send.text != self.send.text
        self.send = send
        self.plan = plan
        if textChanged { writeWords() }
        let next = PendingSendReading.ink(send)
        let inkChanged = next != ink
        ink = next
        paint(now: now, animated: true, inkChanged: inkChanged)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        breathing = nil
        pulse.apply(nil)
        breathe()
    }

    /// The mark moves only while the line it leads is on screen. A hidden strip is taken out of
    /// its stack, and a motion laid on a mark outside a window never starts, so the motion is laid
    /// on after the strip is back — and only when what it should be doing changed, because laying
    /// the same swell on again every paint is how a breath turns into a stutter.
    private func breathe() {
        let wanted = window != nil && showsStrip ? icon : nil
        guard wanted != breathing else { return }
        breathing = wanted
        pulse.apply(nil)
        pulse.apply(wanted)
    }

    private func paint(now: Date, animated: Bool, inkChanged: Bool = false) {
        let motion = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if inkChanged, motion, let layer = rule.layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = SendMotion.ink
            fade.timingFunction = SendMotion.curve
            layer.add(fade, forKey: "ink")
        }
        rule.blade = true
        rule.fill =
            plan != nil
            ? MacTheme.Color.warning
            : (ink == .failed ? MacTheme.Color.danger : MacTheme.Color.accent)
        rule.needsDisplay = true
        let line = plan.map { ResumeReading.caption($0, now: now) }
            ?? PendingSendReading.caption(send, now: now)
        let nextIcon = plan == nil ? PendingSendReading.icon(send) : ResumeReading.icon
        if let line {
            caption.stringValue = line
            caption.textColor = nextIcon.tone.color
            mark.image = NSImage(systemSymbolName: nextIcon.symbol, accessibilityDescription: nil)
            mark.contentTintColor = nextIcon.tone.color
            mark.isHidden = mark.image == nil
        }
        icon = line == nil ? nil : nextIcon
        offer()
        reveal(strip: line != nil, acts: !acts.arrangedSubviews.isEmpty, motion: motion)
        breathe()
        setAccessibilityLabel(
            plan.map { ResumeReading.spoken($0, words: send.text, now: now) }
                ?? PendingSendReading.spoken(send, now: now))
    }

    /// The choices the row makes, rebuilt only when they change: a row restated on every state
    /// keeps the buttons a pointer may be resting on.
    private func offer() {
        let choices: [(title: String, press: () -> Void)]
        if let plan, let act = context.resumeAct {
            let id = plan.id
            choices = ResumeReading.acts.map { choice in
                (ResumeReading.title(choice), { act(id, choice) })
            }
        } else if !send.acts.isEmpty, let act = context.pendingAct {
            let id = send.id
            let shown = send
            choices = send.acts.map { choice in
                (PendingSendReading.title(choice, for: shown), { act(id, choice) })
            }
        } else {
            choices = []
        }
        let titles = choices.map(\.title) + [plan?.id.uuidString ?? send.id.uuidString]
        guard titles != offered else { return }
        offered = titles
        for view in acts.arrangedSubviews { view.removeFromSuperview() }
        for choice in choices {
            acts.addArrangedSubview(RowKit.linkButton(choice.title, action: choice.press))
        }
    }

    /// The line and the choices come in by fading after the row has made room for them, and go by
    /// fading before the room closes, so the words above never move while something is half-drawn.
    private func reveal(strip showStrip: Bool, acts showActs: Bool, motion: Bool) {
        let appearing = (showStrip && !showsStrip ? [strip as NSView] : [])
            + (showActs && !showsActs ? [acts as NSView] : [])
        let leaving = (!showStrip && showsStrip ? [strip as NSView] : [])
            + (!showActs && showsActs ? [acts as NSView] : [])
        showsStrip = showStrip
        showsActs = showActs
        fadeToken += 1
        let token = fadeToken
        for view in appearing {
            view.isHidden = false
            view.alphaValue = motion ? 0 : 1
        }
        guard motion, !(appearing.isEmpty && leaving.isEmpty) else {
            for view in leaving { view.isHidden = true }
            for view in [strip, acts] as [NSView] { view.alphaValue = 1 }
            return
        }
        NSAnimationContext.runAnimationGroup { animation in
            animation.duration = SendMotion.ink
            animation.timingFunction = SendMotion.curve
            for view in appearing { view.animator().alphaValue = 1 }
            for view in leaving { view.animator().alphaValue = 0 }
        } completionHandler: { [weak self] in
            MainThread.call {
                guard let self, self.fadeToken == token else { return }
                for view in leaving { view.isHidden = true }
                for view in [self.strip, self.acts] as [NSView] { view.alphaValue = 1 }
            }
        }
    }

    /// What a harness reads to prove the row is drawn at full strength from the press.
    var inkAlpha: CGFloat { min(words.alphaValue, rule.alphaValue, alphaValue) }

    /// The choices the row offers, by title, for a harness.
    var actTitles: [String] {
        acts.isHidden ? [] : acts.arrangedSubviews.compactMap { ($0 as? NSButton)?.title }
    }

    /// The line under the words, for a harness; nil when the row has nothing to say.
    var captionLine: String? { strip.isHidden ? nil : caption.stringValue }

    /// The motion laid on the row's mark, for a harness that proves a held send breathes. Whether
    /// the window then animates it is the motion budget's call, made the same way for every mark.
    var markMotion: ActivityMotion { breathing?.motion ?? .still }
}
