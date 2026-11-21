import AppKit
import Carbon.HIToolbox
import CodingAgentKit
import TailscodeCore
import TailscodeMetal

/// A shell on the machine the conversation in focus works on.
///
/// The shell is the server's: it runs where the agent runs, in the folder the agent works in, and
/// it is still there after this window has been closed and opened. That is what lets every copy of
/// the app have one, the copy the App Store installs included: this Mac starts no process and
/// reads no folder of its own, it draws a screen and sends keys. Each server the window has looked
/// at keeps its own shell and scrollback, and the pane shows the one that belongs to the
/// conversation in focus, walking it to that conversation's folder when the shell is at its
/// prompt to be walked.
@MainActor
final class TerminalPane: NSViewController {
    private let caption = NSTextField(labelWithString: "")
    private let terminal = MacTerminalView(frame: .zero)
    private var sessions: [String: TerminalSession] = [:]
    private var shownServer: String?
    private let desk = TerminalDeskName.current(client: "mac")

    private var session: TerminalSession? { shownServer.flatMap { sessions[$0] } }

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = AppearanceView()
        container.wantsLayer = true
        container.onAppearanceChange = { [weak self] in self?.applyColours() }
        caption.lineBreakMode = .byTruncatingMiddle
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        terminal.inset = MacTheme.Spacing.m
        container.addSubview(caption)
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            caption.topAnchor.constraint(equalTo: container.topAnchor, constant: MacTheme.Spacing.s),
            caption.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: MacTheme.Spacing.m),
            caption.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -MacTheme.Spacing.m),
            terminal.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: MacTheme.Spacing.xs),
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        applyTypeScale()
        applyColours()
        restate()
    }

    private var colours: TerminalColors {
        TerminalColors(palette: MacBrainPalette.palette(for: isViewLoaded ? view.effectiveAppearance : NSApp.effectiveAppearance))
    }

    private func applyColours() {
        let colours = colours
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = NSColor(terminal: colours.background).cgColor
        }
        caption.textColor = MacTheme.Color.tertiaryLabel
        terminal.canvas = colours.background
        for session in sessions.values { session.screen?.apply(colours) }
        terminal.requestFrame()
    }

    func applyTypeScale() {
        guard isViewLoaded else { return }
        caption.font = MacTheme.Ramp.font(.panelFootnote)
        terminal.setFontSize(MacTheme.Ramp.font(.code, in: .terminal).pointSize)
    }

    func takeFocus() {
        view.window?.makeFirstResponder(terminal)
    }

    /// Whether a keystroke belongs to the shell rather than the app, which is what puts the
    /// shortcut engine in the terminal context.
    func ownsFocus(in window: NSWindow?) -> Bool {
        window?.firstResponder === terminal
    }

    /// The folder the shell on screen stands in, as its server last read it.
    func standingDirectory() -> String? {
        session?.standingDirectory
    }

    /// The server that holds the shell on screen.
    var standingServer: String? {
        session?.standingDirectory == nil ? nil : shownServer
    }

    /// Points the pane at the conversation in focus: its server's shell, walked to its folder.
    func show(
        profileID: String, server: String, backend: (any CodingAgentBackend)?, directory: String?,
        sessionID: String?
    ) {
        guard let backend else { return }
        _ = view
        if let existing = sessions[profileID] {
            let switched = shownServer != profileID
            shownServer = profileID
            existing.follow(directory: directory)
            if switched {
                terminal.session = existing
                restate()
            }
            return
        }
        let grid = terminal.grid
        let session = TerminalSession(
            backend: backend, target: .init(server: server, directory: directory, sessionID: sessionID),
            desk: desk, colors: colours, cols: grid?.cols ?? 80, rows: grid?.rows ?? 24)
        sessions[profileID] = session
        shownServer = profileID
        session.onChange { [weak self] in
            DispatchQueue.main.async { self?.restate() }
        }
        session.onDirty { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.shownServer == profileID else { return }
                self.terminal.requestFrame()
            }
        }
        terminal.session = session
        session.start()
        restate()
    }

    /// Lets go of every shell as the app goes. They stay running for this desk to find.
    func leaveAll() {
        for session in sessions.values { session.leave() }
    }

    private func restate() {
        caption.stringValue =
            session?.reading.caption
            ?? Localized.text("Open a chat and a shell opens here, on the machine that chat runs on")
    }

    /// What the screen says, for a check that has no eyes.
    var screenText: String { session?.screen?.text ?? "" }

    func driveType(_ text: String) {
        session?.type(text)
    }

    var diagnostics: String { terminal.diagnostics + " frame=\(NSStringFromRect(terminal.frame))" }

    var captionText: String { caption.stringValue }
}

private extension NSColor {
    convenience init(terminal rgb: UInt32) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }
}

/// The terminal's picture with a Mac's keyboard and pointer.
///
/// Text reaches the shell through the input system, so a dead key, a composed character and an
/// input method all type what they type everywhere else; Option is left to the keyboard layout,
/// which on most layouts outside the US is the only way to a bracket or a pipe. The keys that are
/// named and not typed, and anything held with Control, go to the terminal as keys, which turns
/// them into whatever the program on screen asked for.
@MainActor
final class MacTerminalView: TerminalMetalView, @preconcurrency NSTextInputClient {
    private var marked = ""
    private var programHasPointer = false
    private var wheel = 0.0

    private static let named: [Int: TerminalKey] = [
        kVK_Return: .enter, kVK_ANSI_KeypadEnter: .numpadEnter, kVK_Tab: .tab, kVK_Delete: .backspace,
        kVK_Escape: .escape, kVK_ForwardDelete: .delete, kVK_Home: .home, kVK_End: .end,
        kVK_PageUp: .pageUp, kVK_PageDown: .pageDown, kVK_LeftArrow: .arrowLeft,
        kVK_RightArrow: .arrowRight, kVK_DownArrow: .arrowDown, kVK_UpArrow: .arrowUp,
        kVK_F1: .function(1), kVK_F2: .function(2), kVK_F3: .function(3), kVK_F4: .function(4),
        kVK_F5: .function(5), kVK_F6: .function(6), kVK_F7: .function(7), kVK_F8: .function(8),
        kVK_F9: .function(9), kVK_F10: .function(10), kVK_F11: .function(11), kVK_F12: .function(12),
    ]

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        showsFocus = true
        session?.focus(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        showsFocus = false
        session?.focus(false)
        return true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> TerminalModifiers {
        var modifiers: TerminalModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.alt) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }

    override func keyDown(with event: NSEvent) {
        guard let session else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !marked.isEmpty {
            inputContext?.handleEvent(event)
            return
        }
        let held = Self.modifiers(flags)
        if held == .shift, event.keyCode == UInt16(kVK_PageUp) || event.keyCode == UInt16(kVK_PageDown) {
            session.screen?.scroll(pages: event.keyCode == UInt16(kVK_PageUp) ? -1 : 1)
            requestFrame()
            return
        }
        if let key = Self.named[Int(event.keyCode)] {
            var keys = held
            keys.remove(.command)
            session.press(TerminalKeyPress(key: key, modifiers: keys, isRepeat: event.isARepeat))
            return
        }
        if flags.contains(.control), let typed = event.charactersIgnoringModifiers?.lowercased().first {
            var keys: TerminalModifiers = [.control]
            if flags.contains(.shift) { keys.insert(.shift) }
            session.press(
                TerminalKeyPress(key: .typing(typed), modifiers: keys, unshifted: typed, isRepeat: event.isARepeat))
            return
        }
        inputContext?.handleEvent(event)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        marked = ""
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        session?.type(text)
    }

    override func doCommand(by selector: Selector) {}

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    }

    func unmarkText() {
        marked = ""
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func markedRange() -> NSRange {
        marked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: marked.utf16.count)
    }

    func hasMarkedText() -> Bool { !marked.isEmpty }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// Where an input method's candidate window goes: at the cursor's cell.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window, let grid, let cursor = session?.frame()?.cursor else { return .zero }
        let scale = window.backingScaleFactor
        let cell = NSRect(
            x: CGFloat(grid.padding + cursor.column * grid.cellWidth) / scale,
            y: CGFloat(grid.padding + cursor.row * grid.cellHeight) / scale,
            width: CGFloat(grid.cellWidth) / scale, height: CGFloat(grid.cellHeight) / scale)
        return window.convertToScreen(convert(cell, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    private func place(_ event: NSEvent) -> (x: Double, y: Double) {
        pixel(convert(event.locationInWindow, from: nil))
    }

    /// The pointer belongs to the program on screen when it asked for the mouse and Shift is not
    /// held; otherwise it is the person's, and the main button selects.
    private func pointer(_ action: TerminalScreen.PointerAction, _ button: TerminalScreen.PointerButton, _ event: NSEvent) {
        guard let session, let screen = session.screen else { return }
        let at = place(event)
        let modifiers = Self.modifiers(event.modifierFlags)
        switch action {
        case .press:
            let bytes = screen.bytes(pointer: .press, button: button, modifiers: modifiers, x: at.x, y: at.y, anyPressed: true)
            programHasPointer = !bytes.isEmpty
            if programHasPointer {
                session.send(bytes)
            } else if button == .left {
                screen.select(.press, x: at.x, y: at.y)
                requestFrame()
            }
        case .release:
            if programHasPointer {
                session.send(
                    screen.bytes(pointer: .release, button: button, modifiers: modifiers, x: at.x, y: at.y, anyPressed: false))
            } else if button == .left {
                screen.select(.release, x: at.x, y: at.y)
                requestFrame()
            }
            programHasPointer = false
        case .motion:
            let held = button != .none
            let bytes = screen.bytes(pointer: .motion, button: button, modifiers: modifiers, x: at.x, y: at.y, anyPressed: held)
            if !bytes.isEmpty {
                session.send(bytes)
            } else if button == .left, !programHasPointer {
                screen.select(.drag, x: at.x, y: at.y)
                requestFrame()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pointer(.press, .left, event)
    }

    override func mouseDragged(with event: NSEvent) { pointer(.motion, .left, event) }
    override func mouseUp(with event: NSEvent) { pointer(.release, .left, event) }
    override func otherMouseDown(with event: NSEvent) { pointer(.press, .middle, event) }
    override func otherMouseUp(with event: NSEvent) { pointer(.release, .middle, event) }

    override func rightMouseDown(with event: NSEvent) {
        guard let screen = session?.screen else { return }
        let at = place(event)
        let bytes = screen.bytes(
            pointer: .press, button: .right, modifiers: Self.modifiers(event.modifierFlags), x: at.x, y: at.y,
            anyPressed: true)
        if bytes.isEmpty {
            super.rightMouseDown(with: event)
        } else {
            programHasPointer = true
            session?.send(bytes)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard programHasPointer else { return }
        pointer(.release, .right, event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: Localized.text("Copy"), action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: Localized.text("Paste"), action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: Localized.text("Select All"), action: #selector(selectAll(_:)), keyEquivalent: "")
        return menu
    }

    /// A wheel turn in rows. A trackpad reports points, spent as whole rows as they add up; a
    /// wheel reports notches, three rows each.
    override func scrollWheel(with event: NSEvent) {
        guard let session, let screen = session.screen else { return }
        wheel += event.hasPreciseScrollingDeltas ? -Double(event.scrollingDeltaY / rowHeight) : -Double(event.scrollingDeltaY) * 3
        let whole = Int(wheel.rounded(.towardZero))
        guard whole != 0 else { return }
        wheel -= Double(whole)
        let at = place(event)
        let bytes = screen.wheel(rows: whole, modifiers: Self.modifiers(event.modifierFlags), x: at.x, y: at.y)
        if bytes.isEmpty {
            requestFrame()
        } else {
            session.send(bytes)
        }
    }

    @objc func copy(_ sender: Any?) {
        guard let text = session?.screen?.selectionText, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        session?.paste(text)
    }

    override func selectAll(_ sender: Any?) {
        session?.screen?.selectAll()
        requestFrame()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityLabel() -> String? { Localized.text("Terminal") }
    override func accessibilityValue() -> Any? { session?.screen?.text }
}

extension MacTerminalView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)): return session?.screen?.hasSelection == true
        case #selector(paste(_:)): return NSPasteboard.general.string(forType: .string) != nil && session != nil
        default: return true
        }
    }
}
