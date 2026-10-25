import AppKit
import TailscodeCore

/// The sheet Escape and the sheet's own buttons are answered by, so a sheet that is hearing keys
/// can still be closed by the one key it never records.
private final class ShortcutCaptureWindow: NSWindow {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Changing one shortcut by pressing it. The sheet records with an application-local monitor, the
/// same technique the summon chord's recorder uses, so Tab, Return and every arrow can be
/// recorded instead of moving focus around a sheet that would otherwise act on them. The judging
/// is Core's: what the keys fit, who else has them, and the edit that gives them over.
@MainActor
final class ShortcutCaptureSheet: NSObject, NSTextFieldDelegate {
    let id: String
    let window: NSWindow
    private(set) var captured: [KeyChord] = []
    private(set) var verdict = ShortcutCaptureVerdict.idle
    private(set) var fileProblem: String?
    private let definition: ShortcutDefinition
    private let onChange: @MainActor () -> Void
    private weak var parent: NSWindow?
    private var monitor: Any?
    private var observers: [any NSObjectProtocol] = []

    private let titleLabel = NSTextField(labelWithString: "")
    private let keysNow = NSStackView()
    private let captureHolder = NSStackView()
    private let verdictLabel = NSTextField(wrappingLabelWithString: "")
    private let problemLabel = NSTextField(wrappingLabelWithString: "")
    private let typedField = NSTextField(string: "")
    private let typedToggle = NSButton(title: "", target: nil, action: nil)
    private let restore: RowKit.ActionButton
    private let add: RowKit.ActionButton
    private let content = NSView()
    private let column = NSStackView()

    static let width: CGFloat = 460

    init?(id: String, onChange: @escaping @MainActor () -> Void) {
        guard let definition = ShortcutRegistry.definition(id) else { return nil }
        self.id = id
        self.definition = definition
        self.onChange = onChange
        let window = ShortcutCaptureWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        self.window = window
        restore = RowKit.ActionButton(title: Localized.text("Restore default")) {}
        add = RowKit.ActionButton(title: Localized.text("Add key")) {}
        super.init()
        window.isReleasedWhenClosed = false
        window.title = Localized.text("Change shortcut")
        window.onCancel = { [weak self] in self?.finish() }
        build()
        restore.setAction { [weak self] in self?.restoreDefault() }
        add.setAction { [weak self] in self?.commit() }
        render()
    }

    /// Opens the sheet on `parent` and starts hearing keys whenever the sheet is the key window.
    func begin(on parent: NSWindow) {
        self.parent = parent
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in MainThread.call { self?.startHearing() } },
            center.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in MainThread.call { self?.stopHearing() } },
        ]
        parent.beginSheet(window) { [weak self] _ in
            MainThread.call { self?.ended() }
        }
    }

    func finish() {
        stopHearing()
        guard let parent, window.sheetParent === parent else { return }
        parent.endSheet(window)
    }

    private func ended() {
        stopHearing()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    private func startHearing() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainThread.call { self.hear(event) }
        }
    }

    /// A monitor left installed would keep swallowing the keys of whatever window is in front.
    /// Hearing is a state of the sheet's turn at the keyboard, and it ends with it.
    func stopHearing() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    var isHearing: Bool { monitor != nil }

    /// Every key is swallowed except a bare Escape, which closes the sheet, and a bare Delete,
    /// which clears what was pressed; while the typed field has focus the keys are its own.
    func hear(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, typedField.currentEditor() == nil else { return event }
        let held = event.modifierFlags.intersection([.control, .option, .shift, .command])
        if held.isEmpty, event.keyCode == 53 {
            finish()
            return nil
        }
        if held.isEmpty, event.keyCode == 51 || event.keyCode == 117 {
            clear()
            return nil
        }
        press(event)
        return nil
    }

    func press(_ event: NSEvent) {
        guard let chord = MacKeys.chord(for: event) else {
            if event.modifierFlags.contains(.command) {
                verdict = .menuBar
                render()
            } else {
                NSSound.beep()
            }
            return
        }
        take(ShortcutCaptureVerdict.pressed(chord, after: captured))
    }

    func take(_ chords: [KeyChord], contexts: Set<KeyContext>? = nil) {
        captured = chords
        verdict = ShortcutCaptureVerdict(
            chords: chords, contexts: contexts, for: id, in: ShortcutBindings.load())
        render()
    }

    func clear() {
        captured = []
        typedField.stringValue = ""
        verdict = .idle
        render()
    }

    func controlTextDidChange(_ notification: Notification) {
        typedChanged()
    }

    func typedChanged() {
        let text = typedField.stringValue
        verdict = ShortcutCaptureVerdict(typed: text, for: id, in: ShortcutBindings.load())
        captured = KeySpec.parse(text)?.chords ?? []
        render()
    }

    func commit() {
        guard let spec = verdict.spec else { return }
        apply(ShortcutEditor.adding(spec, to: id, in: ShortcutBindings.load()))
    }

    func restoreDefault() {
        apply(ShortcutEditor.restoring(id, in: ShortcutBindings.load()))
    }

    func remove(_ spec: String) {
        apply(ShortcutEditor.removing(spec, from: id, in: ShortcutBindings.load()))
    }

    /// A write that cannot be made says why where the person is looking: the file is theirs, and
    /// overwriting something they typed by hand is the one thing this sheet never does.
    func apply(_ plan: ShortcutEditor.Plan) {
        do {
            try ShortcutEditor.apply(plan)
            fileProblem = nil
            captured = []
            typedField.stringValue = ""
            verdict = .idle
            onChange()
        } catch ShortcutFile.Failure.unreadable {
            fileProblem = Localized.text(
                "keybindings.json is not valid JSON — fix it in the text editor, or reset it")
        } catch {
            fileProblem = error.localizedDescription
        }
        render()
    }

    @objc private func toggleTyped() {
        let shown = typedField.isHidden
        typedField.isHidden = !shown
        typedToggle.image = Self.chevron(open: shown)
        window.makeFirstResponder(shown ? typedField : nil)
        fit()
    }

    @objc private func typedCommitted() {
        typedChanged()
        commit()
    }

    private static func chevron(open: Bool) -> NSImage? {
        NSImage(
            systemSymbolName: open ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil)
    }

    private func build() {
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = MacTheme.Spacing.s
        column.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        column.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = MacTheme.Ramp.font(.headline)
        titleLabel.stringValue = definition.title
        let category = MacDialogs.detailLabel(definition.category.title)
        for view in [titleLabel, category] { column.addArrangedSubview(view) }
        column.setCustomSpacing(MacTheme.Spacing.m, after: category)

        column.addArrangedSubview(MacDialogs.sectionHeader(Localized.text("Keys now")))
        keysNow.orientation = .vertical
        keysNow.alignment = .leading
        keysNow.spacing = MacTheme.Spacing.xs
        column.addArrangedSubview(keysNow)
        column.setCustomSpacing(MacTheme.Spacing.m, after: keysNow)

        column.addArrangedSubview(MacDialogs.sectionHeader(Localized.text("New key")))
        captureHolder.orientation = .vertical
        captureHolder.alignment = .centerX
        captureHolder.edgeInsets = NSEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        captureHolder.translatesAutoresizingMaskIntoConstraints = false
        RowKit.ground(
            behind: captureHolder, fill: MacTheme.Color.canvasRaised,
            stroke: MacTheme.Color.separator, radius: MacTheme.Radius.control)
        column.addArrangedSubview(captureHolder)
        captureHolder.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true

        verdictLabel.font = MacTheme.Ramp.font(.panelFootnote)
        problemLabel.font = MacTheme.Ramp.font(.panelFootnote)
        problemLabel.textColor = MacTheme.Color.warning
        for label in [verdictLabel, problemLabel] {
            label.isSelectable = false
            column.addArrangedSubview(label)
        }

        typedToggle.title = Localized.text("Type it instead")
        typedToggle.image = Self.chevron(open: false)
        typedToggle.imagePosition = .imageLeading
        typedToggle.isBordered = false
        typedToggle.font = MacTheme.Ramp.font(.panelFootnote)
        typedToggle.target = self
        typedToggle.action = #selector(toggleTyped)
        column.addArrangedSubview(typedToggle)
        typedField.placeholderString = "normal:ctrl+b · g g · esc · f5"
        typedField.font = .monospacedSystemFont(
            ofSize: MacTheme.Ramp.font(.panelFootnote).pointSize, weight: .regular)
        typedField.delegate = self
        typedField.target = self
        typedField.action = #selector(typedCommitted)
        typedField.isHidden = true
        column.addArrangedSubview(typedField)

        let done = RowKit.ActionButton(title: Localized.text("Done")) { [weak self] in
            self?.finish()
        }
        add.keyEquivalent = "\r"
        let buttons = NSStackView(views: [restore, RowKit.spacer(), done, add])
        buttons.orientation = .horizontal
        buttons.spacing = MacTheme.Spacing.s
        column.addArrangedSubview(buttons)
        column.setCustomSpacing(MacTheme.Spacing.m, after: typedField)

        for view in [keysNow, captureHolder, verdictLabel, problemLabel, typedField, buttons] {
            view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40).isActive = true
        }

        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: content.topAnchor),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            content.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        window.contentView = content
    }

    /// Everything the sheet shows is drawn from the file as it stands and from what has been
    /// pressed, so a change made anywhere else is seen the next time anything here is touched.
    func render() {
        let bindings = ShortcutBindings.load()
        renderKeysNow(bindings)
        renderCapture()
        verdictLabel.stringValue = verdict.message
        verdictLabel.textColor =
            switch verdict.tone {
            case .idle: MacTheme.Color.secondaryLabel
            case .free: MacTheme.Color.success
            case .warning: MacTheme.Color.warning
            }
        problemLabel.stringValue = fileProblem ?? ""
        problemLabel.isHidden = fileProblem == nil
        restore.isHidden = !bindings.isCustomized(id)
        add.title = verdict.addTitle
        add.isEnabled = verdict.canAdd
        fit()
    }

    private func renderKeysNow(_ bindings: ShortcutBindings) {
        for view in keysNow.arrangedSubviews {
            keysNow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let entry = ShortcutEditor.sections(bindings: bindings, query: id)
            .flatMap(\.entries).first { $0.id == id }
        guard let keys = entry?.keys, !keys.isEmpty else {
            keysNow.addArrangedSubview(Keycaps.keys([]))
            return
        }
        for key in keys {
            let remove = NSButton(
                image: NSImage(
                    systemSymbolName: "xmark.circle.fill",
                    accessibilityDescription: Localized.text("Remove this key")) ?? NSImage(),
                target: self, action: #selector(removePressed(_:)))
            remove.isBordered = false
            remove.contentTintColor = MacTheme.Color.tertiaryLabel
            remove.identifier = NSUserInterfaceItemIdentifier(key.spec)
            remove.toolTip = Localized.text("Remove this key")
            var views: [NSView] = [Keycaps.key(key)]
            if let scope = key.scope { views.append(MacDialogs.detailLabel(scope)) }
            views.append(RowKit.spacer())
            views.append(remove)
            let row = NSStackView(views: views)
            row.orientation = .horizontal
            row.spacing = MacTheme.Spacing.s
            keysNow.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: keysNow.widthAnchor).isActive = true
        }
    }

    @objc private func removePressed(_ sender: NSButton) {
        guard let spec = sender.identifier?.rawValue else { return }
        remove(spec)
    }

    private func renderCapture() {
        for view in captureHolder.arrangedSubviews {
            captureHolder.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if captured.isEmpty {
            let prompt = NSTextField(labelWithString: Localized.text("Press the keys now"))
            prompt.font = MacTheme.Ramp.font(.panelLabel)
            prompt.textColor = MacTheme.Color.tertiaryLabel
            captureHolder.addArrangedSubview(prompt)
        } else {
            captureHolder.addArrangedSubview(Keycaps.pressed(captured))
        }
    }

    /// The sheet grows and shrinks with what it says, and a sheet hangs from the top of its
    /// parent, so the top edge is the one that stays where it is.
    private func fit() {
        content.layoutSubtreeIfNeeded()
        let height = content.fittingSize.height
        guard height > 0, abs(window.contentRect(forFrameRect: window.frame).height - height) > 0.5
        else { return }
        var frame = window.frame
        let target = window.frameRect(
            forContentRect: NSRect(x: 0, y: 0, width: Self.width, height: height))
        frame.origin.y += frame.height - target.height
        frame.size = target.size
        window.setFrame(frame, display: true)
    }
}
