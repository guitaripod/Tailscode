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
        guard let text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
    private let strip = NSStackView()
    private let mark = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    private let acts = NSStackView()
    private var ink: PendingSendReading.Ink
    private var send: PendingSend
    private var plan: ResumePlan?
    private let context: TranscriptContext

    init(send: PendingSend, plan: ResumePlan?, now: Date, context: TranscriptContext) {
        self.send = send
        self.plan = plan
        self.context = context
        ink = PendingSendReading.ink(send)
        words = RowKit.attributedLabel(
            MacMarkdown.plainWithLinks(
                send.text, font: MacTheme.Ramp.font(.prompt), color: MacTheme.Color.label))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(words)

        strip.orientation = .horizontal
        strip.alignment = .firstBaseline
        strip.spacing = 5
        mark.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        caption.font = MacTheme.Ramp.font(.hint)
        strip.addArrangedSubview(mark)
        strip.addArrangedSubview(caption)
        column.addArrangedSubview(strip)

        acts.orientation = .horizontal
        acts.spacing = MacTheme.Spacing.m
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
        words.alphaValue = ink.opacity
        rule.alphaValue = ink.opacity
        paint(now: now)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The same row, a moment later: the ink moves on the platform's clock when the phase changed,
    /// and the strip appears or goes as the caption has something to say.
    func restate(send: PendingSend, plan: ResumePlan?, now: Date) {
        self.send = send
        self.plan = plan
        let next = PendingSendReading.ink(send)
        if next != ink {
            ink = next
            let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            NSAnimationContext.runAnimationGroup { animation in
                animation.duration = reduced ? 0 : 0.25
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animation.allowsImplicitAnimation = true
                words.animator().alphaValue = next.opacity
                rule.animator().alphaValue = next.opacity
            }
        }
        paint(now: now)
    }

    private func paint(now: Date) {
        rule.fill =
            plan != nil
            ? MacTheme.Color.warning
            : (ink == .failed ? MacTheme.Color.danger : MacTheme.Color.accent)
        rule.needsDisplay = true
        let line = plan.map { ResumeReading.caption($0, now: now) }
            ?? PendingSendReading.caption(send, now: now)
        let icon = plan == nil ? PendingSendReading.icon(send) : ResumeReading.icon
        strip.isHidden = line == nil
        if let line {
            caption.stringValue = line
            caption.textColor = icon.tone.color
            mark.image = NSImage(systemSymbolName: icon.symbol, accessibilityDescription: nil)
            mark.contentTintColor = icon.tone.color
            mark.isHidden = mark.image == nil
        }
        for view in acts.arrangedSubviews { view.removeFromSuperview() }
        if let plan, let act = context.resumeAct {
            let id = plan.id
            for choice in ResumeReading.acts {
                acts.addArrangedSubview(
                    RowKit.linkButton(ResumeReading.title(choice)) { act(id, choice) })
            }
        } else if !send.acts.isEmpty, let act = context.pendingAct {
            let id = send.id
            for choice in send.acts {
                acts.addArrangedSubview(
                    RowKit.linkButton(PendingSendReading.title(choice)) { act(id, choice) })
            }
        }
        acts.isHidden = acts.arrangedSubviews.isEmpty
        setAccessibilityLabel(
            plan.map { ResumeReading.spoken($0, words: send.text, now: now) }
                ?? PendingSendReading.spoken(send, now: now))
    }
}
