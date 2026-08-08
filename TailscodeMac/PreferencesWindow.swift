import AppKit
import TailscodeCore

/// The settings window: every knob the Mac app has, live — nothing here needs an OK, because the
/// only honest way to pick a behavior is to watch it change. The keys are the same
/// `tailscode.*` defaults the Linux desktop and the phone read, so a preference is a fact about
/// the person, not about the toolkit. Type size has no row here — ⌘± owns it — but the theme does:
/// it is the one preference whose result is the window you are picking it in.
@MainActor
final class PreferencesWindow: NSWindowController {
    private let onComposerChanged: @MainActor () -> Void
    private let onTranscriptChanged: @MainActor () -> Void
    private let onReloadShortcuts: @MainActor () -> Void
    private let linesLabel = NSTextField(labelWithString: "")
    private let windowLabel = NSTextField(labelWithString: "")
    private let hapticLabel = NSTextField(labelWithString: "")
    private var hapticStop = -1
    private let watchAccounts = NSStackView()
    /// The block the accounts notification calls. A block observer is held by the notification
    /// centre rather than by this window, so it outlives the window unless it is handed back —
    /// `nonisolated(unsafe)` because `deinit` is the one place that must reach it and `deinit` is
    /// not on the main actor.
    private nonisolated(unsafe) var accountsWatch: (any NSObjectProtocol)?

    init(
        onComposerChanged: @escaping @MainActor () -> Void,
        onTranscriptChanged: @escaping @MainActor () -> Void,
        onReloadShortcuts: @escaping @MainActor () -> Void
    ) {
        self.onComposerChanged = onComposerChanged
        self.onTranscriptChanged = onTranscriptChanged
        self.onReloadShortcuts = onReloadShortcuts
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = Localized.text("Settings")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = makeContent()
        window.center()
        accountsWatch = NotificationCenter.default.addObserver(
            forName: MediaAccounts.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderWatchAccounts() }
        }
    }

    deinit {
        guard let accountsWatch else { return }
        NotificationCenter.default.removeObserver(accountsWatch)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        window?.makeKeyAndOrderFront(nil)
    }

    private var defaults: UserDefaults { .standard }

    private var sendOnReturn: Bool {
        defaults.object(forKey: "tailscode.sendOnReturn") as? Bool ?? true
    }

    private var vimComposer: Bool {
        defaults.bool(forKey: "tailscode.vimComposer")
    }

    private var composerLines: Int {
        let stored = defaults.integer(forKey: "tailscode.composerLines")
        return stored == 0 ? 12 : min(20, max(1, stored))
    }

    private var compactTools: Bool {
        if defaults.object(forKey: "tailscode.compactTools") == nil { return true }
        return defaults.bool(forKey: "tailscode.compactTools")
    }

    private var transcriptWindow: Int {
        let stored = defaults.integer(forKey: "tailscode.transcriptWindow")
        return stored == 0 ? 400 : min(5000, max(50, stored))
    }

    private func makeContent() -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = MacTheme.Spacing.s
        column.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)

        if ServerDirectory.shared.isDemoMode {
            column.addArrangedSubview(MacDialogs.sectionHeader(Localized.text("Demo")))
            let leave = NSButton(
                title: Localized.text("Leave"), target: self, action: #selector(leaveDemo))
            column.addArrangedSubview(
                buttonRow(
                    title: Localized.text("Demo world"),
                    subtitle: Localized.text(
                        "Scripted servers with no tailnet — leave to set up a real one"),
                    button: leave))
            column.addArrangedSubview(spacer(MacTheme.Spacing.m))
        }

        column.addArrangedSubview(MacDialogs.sectionHeader(Localized.text("Appearance")))
        column.addArrangedSubview(
            popUpRow(
                title: Localized.text("Theme"),
                subtitle: Localized.text("The canvas the glass floats over, and every signal on it"),
                options: Self.themeTitles,
                selected: Self.themeIndex, action: #selector(themeChanged)))
        column.addArrangedSubview(
            popUpRow(
                title: Localized.text("Light or dark"),
                subtitle: Localized.text("Which of the theme's two faces it wears"),
                options: ThemeAppearance.allCases.map(\.title),
                selected: ThemeAppearance.allCases.firstIndex(of: ThemeSelection.appearance) ?? 0,
                action: #selector(appearanceChanged)))

        column.addArrangedSubview(spacer(MacTheme.Spacing.m))
        column.addArrangedSubview(MacDialogs.sectionHeader(Localized.text("Prompt box")))
        column.addArrangedSubview(
            switchRow(
                title: Localized.text("Return sends the message"),
                subtitle: Localized.text("Shift+Return writes a new line either way"),
                value: sendOnReturn, action: #selector(sendOnReturnChanged)))
        column.addArrangedSubview(
            switchRow(
                title: Localized.text("Vim mode"),
                subtitle: Localized.text(
                    "Normal, visual and visual-line: motions, operators, text objects, registers, undo"),
                value: vimComposer, action: #selector(vimChanged)))
        column.addArrangedSubview(
            stepperRow(
                title: Localized.text("Grows to (lines)"),
                subtitle: Localized.text("Starts one line tall; scrolls past this height"),
                value: composerLines, lower: 1, upper: 20, step: 1, valueLabel: linesLabel,
                action: #selector(linesChanged)))

        column.addArrangedSubview(spacer(MacTheme.Spacing.m))
        column.addArrangedSubview(MacDialogs.sectionHeader(Localized.text("Transcript")))
        column.addArrangedSubview(
            switchRow(
                title: Localized.text("Compact agent steps"),
                subtitle: Localized.text(
                    "Thinking and tool calls between prompts fold to one line you can open"),
                value: compactTools, action: #selector(compactChanged)))
        column.addArrangedSubview(
            stepperRow(
                title: Localized.text("Rows kept on screen"),
                subtitle: Localized.text(
                    "Older rows wait behind one button — this keeps a huge chat fast"),
                value: transcriptWindow, lower: 50, upper: 5000, step: 50,
                valueLabel: windowLabel, action: #selector(windowChanged)))

        column.addArrangedSubview(spacer(MacTheme.Spacing.m))
        column.addArrangedSubview(MacDialogs.sectionHeader(Localized.text("Notifications")))
        column.addArrangedSubview(
            switchRow(
                title: Localized.text("A turn finishes"),
                subtitle: Localized.text(
                    "Any chat, not only the open one — raised only while the app is in the background"),
                value: MacNotifier.notifyTurnComplete, action: #selector(notifyTurnsChanged)))
        column.addArrangedSubview(
            switchRow(
                title: Localized.text("An agent needs you"),
                subtitle: Localized.text(
                    "An approval to give or a question to answer; withdrawn once it is answered"),
                value: MacNotifier.notifyNeedsYou, action: #selector(notifyNeedsChanged)))
        let test = NSButton(
            title: Localized.text("Test"), target: self, action: #selector(sendTestNotification))
        column.addArrangedSubview(
            buttonRow(
                title: Localized.text("Prove the path"),
                subtitle: Localized.text("Sends one notification two seconds from now"),
                button: test))

        column.addArrangedSubview(spacer(MacTheme.Spacing.m))
        column.addArrangedSubview(MacDialogs.sectionHeader(Localized.text("Haptics")))
        column.addArrangedSubview(
            switchRow(
                title: Localized.text("Cues you feel"),
                subtitle: Localized.text(
                    "The trackpad reports the wait — sent, a step landing, needs you, finished — while a hand is on it"),
                value: MacHaptics.isEnabled, action: #selector(hapticsEnabledChanged)))
        column.addArrangedSubview(
            sliderRow(
                title: Localized.text("Strength"),
                subtitle: Localized.text(
                    "Softer settings drop a cue's reinforcement before they drop the cue; drag to feel each stop"),
                value: MacHaptics.strength, valueLabel: hapticLabel,
                action: #selector(hapticStrengthChanged)))

        column.addArrangedSubview(spacer(MacTheme.Spacing.m))
        column.addArrangedSubview(MacDialogs.sectionHeader(WatchAccounts.heading))
        column.addArrangedSubview(
            indented(MacDialogs.detailLabel(WatchAccounts.description, wraps: true), by: 0))
        watchAccounts.orientation = .vertical
        watchAccounts.alignment = .leading
        watchAccounts.spacing = MacTheme.Spacing.s
        column.addArrangedSubview(watchAccounts)
        renderWatchAccounts()

        column.addArrangedSubview(spacer(MacTheme.Spacing.m))
        column.addArrangedSubview(MacDialogs.sectionHeader(Localized.text("Keyboard")))
        let edit = NSButton(
            title: Localized.text("Edit"), target: self, action: #selector(editShortcuts))
        column.addArrangedSubview(
            buttonRow(
                title: Localized.text("Shortcuts file"), subtitle: ShortcutSet.configURL.path,
                button: edit))
        let reload = NSButton(
            title: Localized.text("Reload"), target: self, action: #selector(reloadShortcuts))
        column.addArrangedSubview(
            buttonRow(
                title: Localized.text("Apply changes from the file"),
                subtitle: Localized.text(
                    "Unknown keys and conflicts are reported rather than guessed at"),
                button: reload))

        column.addArrangedSubview(spacer(MacTheme.Spacing.m))
        column.addArrangedSubview(MacDialogs.sectionHeader(Localized.text("Alpha")))
        column.addArrangedSubview(
            switchRow(
                title: Localized.text("Presence orb"),
                subtitle: Localized.text(
                    "A GPU-rendered creature at the foot of the chat list, breathing what every conversation is doing; may cost battery"),
                value: PresenceOrbSetting.isEnabled, action: #selector(presenceOrbChanged)))

        for view in column.arrangedSubviews where view is NSStackView {
            view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -48).isActive = true
        }
        return MacDialogs.scrollColumn(holding: column)
    }

    @objc private func presenceOrbChanged(_ sender: NSButton) {
        PresenceOrbSetting.setEnabled(sender.state == .on)
    }

    @objc private func leaveDemo() {
        ServerDirectory.shared.leaveDemoMode()
        onTranscriptChanged()
        window?.close()
    }

    @objc private func sendOnReturnChanged(_ sender: NSButton) {
        defaults.set(sender.state == .on, forKey: "tailscode.sendOnReturn")
    }

    @objc private func vimChanged(_ sender: NSButton) {
        defaults.set(sender.state == .on, forKey: "tailscode.vimComposer")
        onComposerChanged()
    }

    @objc private func linesChanged(_ sender: NSStepper) {
        defaults.set(sender.integerValue, forKey: "tailscode.composerLines")
        linesLabel.stringValue = "\(sender.integerValue)"
        onComposerChanged()
    }

    @objc private func compactChanged(_ sender: NSButton) {
        defaults.set(sender.state == .on, forKey: "tailscode.compactTools")
        onTranscriptChanged()
    }

    @objc private func windowChanged(_ sender: NSStepper) {
        defaults.set(sender.integerValue, forKey: "tailscode.transcriptWindow")
        windowLabel.stringValue = "\(sender.integerValue)"
        onTranscriptChanged()
    }

    @objc private func hapticsEnabledChanged(_ sender: NSButton) {
        MacHaptics.setEnabled(sender.state == .on)
        if sender.state == .on { MacHaptics.shared.play(.tap, strength: MacHaptics.strength) }
    }

    /// The setting is chosen by feel: every step-width stop the slider passes plays the send cue
    /// at the strength under the pointer, so silence, a single tick and the full recipe are felt
    /// as they are crossed rather than read about afterwards.
    @objc private func hapticStrengthChanged(_ sender: NSSlider) {
        MacHaptics.setStrength(sender.doubleValue)
        hapticLabel.stringValue = HapticStrength.label(sender.doubleValue)
        let stop = Int((sender.doubleValue / HapticStrength.step).rounded())
        guard stop != hapticStop else { return }
        hapticStop = stop
        MacHaptics.shared.play(.send, strength: sender.doubleValue)
    }

    @objc private func notifyTurnsChanged(_ sender: NSButton) {
        MacNotifier.setNotifyTurnComplete(sender.state == .on)
    }

    @objc private func notifyNeedsChanged(_ sender: NSButton) {
        MacNotifier.setNotifyNeedsYou(sender.state == .on)
    }

    @objc private func sendTestNotification() {
        MacNotifier.shared.sendTest()
    }

    @objc private func editShortcuts() {
        ShortcutSet.ensureConfigFile()
        NSWorkspace.shared.open(ShortcutSet.configURL)
    }

    @objc private func reloadShortcuts() {
        onReloadShortcuts()
    }

    /// The two video accounts, drawn and redrawn in place. Signing in or out rewrites everything a
    /// row says, and this window is built once and kept for the life of the app — so the section
    /// empties and refills itself rather than the window being rebuilt around it. The width
    /// constraint `makeContent` applies runs exactly once, over the column's own children, and
    /// never sees a row made later: each one is given the same constraint as it is made.
    private func renderWatchAccounts() {
        for view in watchAccounts.arrangedSubviews { view.removeFromSuperview() }
        for row in WatchAccounts.rows() {
            let button = NSButton(
                title: row.actionTitle, target: self, action: #selector(watchAccountPressed))
            button.identifier = NSUserInterfaceItemIdentifier(row.id)
            let view = buttonRow(title: row.title, subtitle: row.detail, button: button)
            watchAccounts.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: watchAccounts.widthAnchor).isActive = true
            guard let note = row.note else { continue }
            let caption = MacDialogs.detailLabel(note, wraps: true)
            watchAccounts.addArrangedSubview(caption)
            caption.widthAnchor.constraint(equalTo: watchAccounts.widthAnchor).isActive = true
        }
    }

    /// The row is read again at the moment it is pressed rather than captured when it was drawn:
    /// an account can land or expire while the window sits open, and the button must mean what the
    /// row says now.
    @objc private func watchAccountPressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
            let row = WatchAccounts.rows().first(where: { $0.id == id })
        else { return }
        switch row.action {
        case .signIn(let source):
            guard let window else { return }
            WatchSignInSheet.present(on: window, source: source) { [weak self] in
                self?.renderWatchAccounts()
            }
        case .signOut(let source):
            MediaAccounts.signOut(source)
            renderWatchAccounts()
        case .configure:
            explainWatchAccount(row)
        }
    }

    /// The one step of this feature that happens somewhere else. Google will only run its device
    /// flow for an application registered to somebody, so the alert states why, links the console,
    /// and takes the client id and secret right there — a requirement explained but not actionable
    /// is a dead end wearing a button.
    private func explainWatchAccount(_ row: WatchAccountRow) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = YouTubeSetup.heading
        alert.informativeText =
            ([YouTubeSetup.why] + YouTubeSetup.steps.enumerated().map { "\($0.offset + 1). \($0.element)" })
            .joined(separator: "\n\n")

        let current = MediaClientConfig.youtube
        let identity = NSTextField(string: current?.id ?? "")
        identity.placeholderString = YouTubeSetup.idPrompt
        identity.font = MacTheme.Font.mono(11)
        let secret = NSSecureTextField(string: current?.secret ?? "")
        secret.placeholderString = YouTubeSetup.secretPrompt
        secret.font = MacTheme.Font.mono(11)
        let fields = NSStackView(views: [identity, secret])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = MacTheme.Spacing.xs
        fields.frame = NSRect(x: 0, y: 0, width: 320, height: 56)
        identity.widthAnchor.constraint(equalToConstant: 320).isActive = true
        secret.widthAnchor.constraint(equalToConstant: 320).isActive = true
        alert.accessoryView = fields

        alert.addButton(withTitle: Localized.text("Save"))
        alert.addButton(withTitle: Localized.text("Open the console"))
        alert.addButton(withTitle: Localized.text("Close"))
        let finish: @MainActor (NSApplication.ModalResponse) -> Void = { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                let typedID = identity.stringValue
                let typedSecret = secret.stringValue
                guard YouTubeSetup.looksValid(id: typedID, secret: typedSecret) else {
                    self?.rejectWatchClient()
                    return
                }
                MediaClientConfig.setYouTube(id: typedID, secret: typedSecret)
                self?.renderWatchAccounts()
            case .alertSecondButtonReturn:
                if let url = URL(string: YouTubeSetup.consoleURL) {
                    NSWorkspace.shared.open(url)
                }
            default:
                return
            }
        }
        guard let window else {
            finish(alert.runModal())
            return
        }
        alert.beginSheetModal(for: window, completionHandler: finish)
    }

    /// A pasted mistake is caught here rather than at the end of a sign-in that would fail for a
    /// reason nobody could connect back to this box.
    private func rejectWatchClient() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = YouTubeSetup.rejection
        alert.addButton(withTitle: Localized.text("Close"))
        guard let window else {
            alert.runModal()
            return
        }
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    /// The catalog with the platform's own answer at its head — "System" is not a theme, it is the
    /// choice to have none, and on a Mac whose materials Apple drew that is a real answer.
    private static var themeIDs: [String] { [ThemeSelection.systemID] + AppTheme.all.map(\.id) }

    private static var themeTitles: [String] {
        [Localized.text("System — macOS's own colours, under Liquid Glass")]
            + AppTheme.all.map { "\($0.name) — \($0.blurb)" }
    }

    private static var themeIndex: Int {
        themeIDs.firstIndex(of: ThemeSelection.themeID) ?? 0
    }

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        ThemeSelection.setThemeID(Self.themeIDs[sender.indexOfSelectedItem])
        MacTheme.Chrome.apply()
    }

    @objc private func appearanceChanged(_ sender: NSPopUpButton) {
        ThemeSelection.setAppearance(ThemeAppearance.allCases[sender.indexOfSelectedItem])
        MacTheme.Chrome.apply()
    }

    private func popUpRow(
        title: String, subtitle: String, options: [String], selected: Int, action: Selector
    ) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = MacTheme.Font.body()
        let popUp = NSPopUpButton()
        popUp.addItems(withTitles: options)
        popUp.selectItem(at: min(selected, max(0, options.count - 1)))
        popUp.target = self
        popUp.action = action
        popUp.setContentHuggingPriority(.required, for: .horizontal)
        let filler = NSView()
        filler.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [label, filler, popUp])
        row.orientation = .horizontal
        row.spacing = MacTheme.Spacing.s
        let detail = MacDialogs.detailLabel(subtitle, wraps: true)
        let column = NSStackView(views: [row, indented(detail, by: 0)])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    private func switchRow(
        title: String, subtitle: String, value: Bool, action: Selector
    ) -> NSView {
        let toggle = NSButton(checkboxWithTitle: title, target: self, action: action)
        toggle.state = value ? .on : .off
        let detail = MacDialogs.detailLabel(subtitle, wraps: true)
        let column = NSStackView(views: [toggle, indented(detail)])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        return column
    }

    private func stepperRow(
        title: String, subtitle: String, value: Int, lower: Int, upper: Int, step: Int,
        valueLabel: NSTextField, action: Selector
    ) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = MacTheme.Font.body()
        valueLabel.stringValue = "\(value)"
        valueLabel.font = MacTheme.Font.mono(11)
        valueLabel.alignment = .right
        valueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        let stepper = NSStepper()
        stepper.minValue = Double(lower)
        stepper.maxValue = Double(upper)
        stepper.increment = Double(step)
        stepper.integerValue = value
        stepper.autorepeat = true
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = action
        let filler = NSView()
        filler.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [label, filler, valueLabel, stepper])
        row.orientation = .horizontal
        row.spacing = MacTheme.Spacing.s
        let detail = MacDialogs.detailLabel(subtitle, wraps: true)
        let column = NSStackView(views: [row, indented(detail, by: 0)])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    private func sliderRow(
        title: String, subtitle: String, value: Double, valueLabel: NSTextField, action: Selector
    ) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = MacTheme.Font.body()
        valueLabel.stringValue = HapticStrength.label(value)
        valueLabel.font = MacTheme.Font.mono(11)
        valueLabel.alignment = .right
        valueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        let slider = NSSlider(
            value: value, minValue: HapticStrength.range.lowerBound,
            maxValue: HapticStrength.range.upperBound, target: self, action: action)
        slider.isContinuous = true
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        let filler = NSView()
        filler.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [label, filler, valueLabel, slider])
        row.orientation = .horizontal
        row.spacing = MacTheme.Spacing.s
        let detail = MacDialogs.detailLabel(subtitle, wraps: true)
        let column = NSStackView(views: [row, indented(detail, by: 0)])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    private func buttonRow(title: String, subtitle: String, button: NSButton) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = MacTheme.Font.body()
        button.bezelStyle = .rounded
        button.setContentHuggingPriority(.required, for: .horizontal)
        let filler = NSView()
        filler.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [label, filler, button])
        row.orientation = .horizontal
        row.spacing = MacTheme.Spacing.s
        let detail = MacDialogs.detailLabel(subtitle)
        let column = NSStackView(views: [row, detail])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    private func indented(_ view: NSView, by inset: CGFloat = 20) -> NSView {
        let wrapper = NSStackView(views: [view])
        wrapper.edgeInsets = NSEdgeInsets(top: 0, left: inset, bottom: 0, right: 0)
        return wrapper
    }

    private func spacer(_ height: CGFloat) -> NSView {
        let view = NSView()
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }
}
