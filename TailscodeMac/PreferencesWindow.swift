import AppKit
import CodingAgentKit
import CodingAgentKitApple
import MidgarKit
import TailscodeCore
import UserNotifications

/// The settings window: every knob the Mac app has, live — nothing here needs an OK, because the
/// only honest way to pick a behavior is to watch it change. The keys are the same
/// `tailscode.*` defaults the Linux desktop and the phone read, so a preference is a fact about
/// the person, not about the toolkit. The theme is the one preference whose result is the window
/// you are picking it in; type size is the other, so it is shown with a preview of the lines it
/// moves, and ⌘± zooms the whole window on top of it.
@MainActor
final class PreferencesWindow: NSWindowController, NSWindowDelegate {
    private let onComposerChanged: @MainActor () -> Void
    private let onTranscriptChanged: @MainActor () -> Void
    private let onReloadShortcuts: @MainActor () -> Void
    private let linesLabel = NSTextField(labelWithString: "")
    private let windowLabel = NSTextField(labelWithString: "")
    private let hapticLabel = NSTextField(labelWithString: "")
    private let summonButton = NSButton(title: "", target: nil, action: nil)
    private let summonState = NSTextField(wrappingLabelWithString: "")
    private var summonRecorder: Any?
    private var hapticStop = -1
    /// What Settings asks the window it belongs to, because the servers, the updates, the pro
    /// unlock, the cheatsheet and the panes are the window's own and Settings only points at them.
    struct Actions {
        var manageServers: @MainActor () -> Void = {}
        var openUpdates: @MainActor () -> Void = {}
        var openPro: @MainActor () -> Void = {}
        var showCheatsheet: @MainActor () -> Void = {}
        var isSidebarShown: @MainActor () -> Bool = { true }
        var setSidebarShown: @MainActor (Bool) -> Void = { _ in }
        var isTerminalShown: @MainActor () -> Bool = { false }
        var setTerminalShown: @MainActor (Bool) -> Void = { _ in }
    }

    var actions = Actions()
    private let permissionState = NSTextField(wrappingLabelWithString: "")
    private let permissionButton = NSButton(title: "", target: nil, action: nil)
    private let cacheState = NSTextField(wrappingLabelWithString: "")
    private let cacheButton = NSButton(title: "", target: nil, action: nil)
    private weak var typeSection: TypeSettingsView?
    private var tabs: NSTabViewController?
    private let watchAccounts = NSStackView()
    private let deepseekRow = NSStackView()
    private let ollamaRow = NSStackView()
    /// The block the accounts notification calls. A block observer is held by the notification
    /// centre rather than by this window, so it outlives the window unless it is handed back —
    /// `nonisolated(unsafe)` because `deinit` is the one place that must reach it and `deinit` is
    /// not on the main actor.
    private nonisolated(unsafe) var accountsWatch: (any NSObjectProtocol)?
    private nonisolated(unsafe) var summonWatch: (any NSObjectProtocol)?

    init(
        onComposerChanged: @escaping @MainActor () -> Void,
        onTranscriptChanged: @escaping @MainActor () -> Void,
        onReloadShortcuts: @escaping @MainActor () -> Void
    ) {
        self.onComposerChanged = onComposerChanged
        self.onTranscriptChanged = onTranscriptChanged
        self.onReloadShortcuts = onReloadShortcuts
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.openSize.width, height: Self.openSize.height),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = Localized.text("Settings")
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        window.contentMinSize = NSSize(width: 620, height: 440)
        super.init(window: window)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("TailscodeSettingsPanes2")
        NotificationCenter.default.addObserver(
            self, selector: #selector(repaint), name: MacTheme.Chrome.didRepaint, object: nil)
        #if !TAILSCODE_MAS
            accountsWatch = NotificationCenter.default.addObserver(
                forName: MediaAccounts.didChange, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.renderWatchAccounts() }
            }
        #endif
        summonWatch = NotificationCenter.default.addObserver(
            forName: MacSummon.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderSummon() }
        }
    }

    deinit {
        if let accountsWatch { NotificationCenter.default.removeObserver(accountsWatch) }
        if let summonWatch { NotificationCenter.default.removeObserver(summonWatch) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The size the window opens at the first time: wide enough for seven toolbar pages and tall
    /// enough that most pages are read without scrolling.
    private static let openSize = NSSize(width: 660, height: 680)

    /// Every row reads its value from a store as it is built, and this window is kept for the life
    /// of the app — so the pages are made at each presentation rather than once. A demo world
    /// left, a type scale stepped, a default written from somewhere else: all of it is true again
    /// the next time the window is opened. The page that was open stays open.
    func present(selecting pane: Int? = nil) {
        install(selecting: pane)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The page a name stands for — `appearance`, `conversation`, `notifications`, `accounts`,
    /// `keyboard` or `advanced` — for a launch argument that wants to look at one.
    static func page(named name: String) -> Int? {
        Pane.allCases.firstIndex { String(describing: $0) == name }
    }

    /// Switches the open window to a page the way a click on its toolbar does, for a check that
    /// wants to see what a person sees after the first click rather than at presentation.
    func select(pageNamed name: String) {
        guard let index = Self.page(named: name) else { return }
        tabs?.selectedTabViewItemIndex = index
    }

    /// Opens on the type controls, for a menu item that is about nothing else: they are a section
    /// of the Appearance page, below the theme, and the one thing wanted would otherwise be a
    /// page and a scroll away.
    func presentTypeSize() {
        present(selecting: Pane.allCases.firstIndex(of: .appearance))
        window?.contentView?.layoutSubtreeIfNeeded()
        guard let typeSection else { return }
        typeSection.scrollToVisible(typeSection.bounds)
    }

    /// Puts freshly made pages in the window without moving the window: replacing a window's
    /// content controller resizes it to the controller's own size, which would undo whatever
    /// shape the person gave Settings.
    private func install(selecting pane: Int?) {
        guard let window else { return }
        let frame = window.frame
        let wasShown = window.isVisible
        let controller = makeTabs(selecting: pane ?? tabs?.selectedTabViewItemIndex ?? 0)
        tabs = controller
        window.contentViewController = controller
        if wasShown {
            window.setFrame(frame, display: true)
        } else if !window.setFrameUsingName("TailscodeSettingsPanes2") {
            window.setContentSize(Self.openSize)
            window.center()
        }
    }

    /// The theme is the second axis, and it is the one AppKit has no trait for: a colour already
    /// handed out keeps answering for the theme it was made under, so the window the theme is
    /// picked in has to redraw itself along with the rest of the app. The rebuild waits a turn
    /// because the control that asked for it is inside what is being replaced.
    @objc private func repaint() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, window.isVisible else { return }
                self.install(selecting: nil)
            }
        }
    }

    /// A recorder left running would keep swallowing every keystroke in the app after the window
    /// that started it is gone.
    func windowWillClose(_ notification: Notification) {
        stopRecordingSummon()
    }

    /// The monitor is application-wide and answers every press with nothing, so a recorder still
    /// armed when the keyboard moves on would eat what is typed into the composer next door.
    /// Recording is a state of this window, and it ends with the window's turn at the keyboard.
    func windowDidResignKey(_ notification: Notification) {
        stopRecordingSummon()
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

    /// One page of Settings: a name and a symbol for the toolbar, and what it holds.
    private enum Pane: CaseIterable {
        case general
        case appearance
        case conversation
        case notifications
        case accounts
        case keyboard
        case advanced

        var title: String {
            switch self {
            case .general: return Localized.text("General")
            case .appearance: return Localized.text("Appearance")
            case .conversation: return Localized.text("Conversation")
            case .notifications: return Localized.text("Notifications")
            case .accounts: return Localized.text("Accounts")
            case .keyboard: return Localized.text("Keyboard")
            case .advanced: return Localized.text("Advanced")
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .appearance: return "paintbrush"
            case .conversation: return "text.bubble"
            case .notifications: return "bell"
            case .accounts: return "person.crop.circle"
            case .keyboard: return "keyboard"
            case .advanced: return "gearshape.2"
            }
        }
    }

    /// Settings as the Mac does it: a toolbar of pages rather than one long scroll, each page a
    /// few related sections, so a preference is found by what it is about and the page for it
    /// is short enough to read through. The panes are made at each presentation, because every
    /// row reads its value from a store as it is built.
    private func makeTabs(selecting index: Int = 0) -> NSTabViewController {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for pane in Pane.allCases {
            let controller = NSViewController()
            controller.view = held(content(of: pane))
            controller.title = pane.title
            let item = NSTabViewItem(viewController: controller)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        tabs.selectedTabViewItemIndex = min(max(0, index), Pane.allCases.count - 1)
        return tabs
    }

    /// A page is a scroll view that lays itself out by constraints, and a tab controller sizes a
    /// page by its frame — which a view that opts out of autoresizing never gets, so every page
    /// but the one open at presentation came up with no size and showed nothing. The page stands
    /// in a plain view the controller can size, pinned to all four edges of it.
    private func held(_ page: NSView) -> NSView {
        let container = NSView(frame: NSRect(origin: .zero, size: Self.openSize))
        container.autoresizingMask = [.width, .height]
        page.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            page.topAnchor.constraint(equalTo: container.topAnchor),
            page.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func content(of pane: Pane) -> NSView {
        switch pane {
        case .general: return generalPane()
        case .appearance: return appearancePane()
        case .conversation: return conversationPane()
        case .notifications: return notificationsPane()
        case .accounts: return accountsPane()
        case .keyboard: return keyboardPane()
        case .advanced: return advancedPane()
        }
    }

    private func newColumn() -> NSStackView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = MacTheme.Spacing.s
        column.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        return column
    }

    /// The breath between two sections, and none above the first.
    private func gap(_ column: NSStackView) {
        if !column.arrangedSubviews.isEmpty { column.addArrangedSubview(spacer(MacTheme.Spacing.m)) }
    }

    private func scrolled(_ column: NSStackView) -> NSView {
        for view in column.arrangedSubviews where view is NSStackView {
            view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -48).isActive = true
        }
        return MacDialogs.scrollColumn(holding: column)
    }

    private func generalPane() -> NSView {
        let column = newColumn()
        addMidgarEntry(to: column)
        gap(column)
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
            gap(column)
        }

        column.addArrangedSubview(MacDialogs.sectionHeader(Localized.text("Servers")))
        for row in serverRows() { column.addArrangedSubview(row) }
        let manage = NSButton(
            title: Localized.text("Manage…"), target: self, action: #selector(manageServers))
        column.addArrangedSubview(
            buttonRow(
                title: Localized.text("Your machines"),
                subtitle: Localized.text(
                    "Add a machine, change an address or a password, or remove one"),
                button: manage))

        gap(column)
        column.addArrangedSubview(MacDialogs.sectionHeader(Localized.text("About")))
        column.addArrangedSubview(
            infoRow(title: Localized.text("Version"), detail: Self.versionLine))
        let updates = NSButton(
            title: Localized.text("Open"), target: self, action: #selector(openUpdates))
        column.addArrangedSubview(
            buttonRow(
                title: Localized.text("Update Center"),
                subtitle: Localized.text(
                    "This app and every server it talks to: what each runs and what it could run"),
                button: updates))
        #if TAILSCODE_MAS
            let pro = NSButton(
                title: Localized.text("Tailscode Pro…"), target: self, action: #selector(openPro))
            column.addArrangedSubview(
                buttonRow(
                    title: Localized.text("Tailscode Pro"),
                    subtitle: MacProStore.shared.isPro
                        ? Localized.text("Unlocked — thank you")
                        : Localized.text("Unlimited servers, and delegation to cheaper models"),
                    button: pro))
        #endif
        return scrolled(column)
    }

    /// The doorway into the Midgar portal: the first thing in the first page, as wide as the
    /// page's other rows and a fixed 116 points tall.
    private func addMidgarEntry(to column: NSStackView) {
        let entry = MidgarEntryView()
        column.addArrangedSubview(entry)
        NSLayoutConstraint.activate([
            entry.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -48),
            entry.heightAnchor.constraint(equalToConstant: MidgarEntryView.preferredHeight),
        ])
    }

    private static var versionLine: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(MacCLI.version) (\($0))" } ?? MacCLI.version
    }

    /// One row per machine the app talks to, saying when it last answered — a name and an address
    /// alone cannot tell a machine that is up from one that has been silent since yesterday.
    private func serverRows() -> [NSView] {
        let profiles = ServerDirectory.shared.profiles
        guard !profiles.isEmpty else {
            return [
                indented(
                    MacDialogs.detailLabel(
                        Localized.text("No servers yet. Add the machine your agents run on."),
                        wraps: true), by: 0)
            ]
        }
        return profiles.map { profile in
            infoRow(
                title: ServerLabel.display(profile),
                detail: "\(ServerLabel.address(profile)) · \(serverState(profile))")
        }
    }

    private func serverState(_ profile: ConnectionProfile) -> String {
        guard !profile.id.hasPrefix(DemoWorld.profilePrefix) else { return Localized.text("Demo") }
        guard let heard = ServerDirectory.shared.lastHeard[ServerLabel.display(profile)] else {
            return Localized.text("Not heard from yet")
        }
        return Localized.text("Answered %@ ago", SessionRowModel.age(of: heard))
    }

    private func appearancePane() -> NSView {
        let column = newColumn()
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
        column.addArrangedSubview(
            popUpRow(
                title: ChatDensitySetting.title,
                subtitle: ChatDensitySetting.explanation,
                options: ChatDensity.allCases.map(\.title),
                selected: ChatDensity.allCases.firstIndex(of: ChatDensitySetting.current) ?? 0,
                action: #selector(chatDensityChanged)))
        column.addArrangedSubview(
            popUpRow(
                title: ActivityStyleSetting.title,
                subtitle: MacBrain.isAvailable
                    ? ActivityStyleSetting.explanation
                    : Localized.text(
                        "This Mac cannot draw the head, so every turn stays as flat lines."),
                options: ActivityStyle.allCases.map(\.title),
                selected: ActivityStyle.allCases.firstIndex(of: ActivityStyleSetting.current) ?? 0,
                action: #selector(activityStyleChanged)))

        gap(column)
        let type = TypeSettingsView()
        typeSection = type
        column.addArrangedSubview(type)

        gap(column)
        column.addArrangedSubview(MacDialogs.sectionHeader(Localized.text("Layout")))
        column.addArrangedSubview(
            switchRow(
                title: Localized.text("Chat list"),
                subtitle: Localized.text(
                    "The conversations beside the one you are in; drag its edge to size it, and the size is remembered"),
                value: actions.isSidebarShown(), action: #selector(sidebarShownChanged)))
        #if !TAILSCODE_MAS
            column.addArrangedSubview(
                switchRow(
                    title: Localized.text("Terminal"),
                    subtitle: Localized.text(
                        "A shell under the conversation, in the project the chat is working in"),
                    value: actions.isTerminalShown(), action: #selector(terminalShownChanged)))
        #endif
        return scrolled(column)
    }

    private func conversationPane() -> NSView {
        let column = newColumn()
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

        gap(column)
        column.addArrangedSubview(MacDialogs.sectionHeader(Localized.text("Transcript")))
        column.addArrangedSubview(
            switchRow(
                title: Localized.text("Compact agent steps"),
                subtitle: Localized.text(
                    "Thinking and tool calls between prompts fold to one line you can open"),
                value: compactTools, action: #selector(compactChanged)))
        column.addArrangedSubview(
            switchRow(
                title: ResponseStatsSetting.title,
                subtitle: ResponseStatsSetting.explanation,
                value: ResponseStatsSetting.isEnabled, action: #selector(responseStatsChanged)))
        column.addArrangedSubview(
            switchRow(
                title: LinkEmbedsSetting.title,
                subtitle: LinkEmbedsSetting.explanation,
                value: LinkEmbedsSetting.isEnabled, action: #selector(linkEmbedsChanged)))
        column.addArrangedSubview(
            switchRow(
                title: AutoResumeSetting.title,
                subtitle: AutoResumeSetting.explanation,
                value: AutoResumeSetting.isEnabled, action: #selector(autoResumeChanged)))
        column.addArrangedSubview(
            stepperRow(
                title: Localized.text("Rows kept on screen"),
                subtitle: Localized.text(
                    "Older rows wait behind one button — this keeps a huge chat fast"),
                value: transcriptWindow, lower: 50, upper: 5000, step: 50,
                valueLabel: windowLabel, action: #selector(windowChanged)))
        return scrolled(column)
    }

    private func notificationsPane() -> NSView {
        let column = newColumn()
        column.addArrangedSubview(MacDialogs.sectionHeader(Localized.text("Notifications")))
        permissionButton.title = Localized.text("Open System Settings…")
        permissionButton.target = self
        permissionButton.action = #selector(openNotificationSettings)
        column.addArrangedSubview(
            chordRow(
                title: Localized.text("Allowed by macOS"), button: permissionButton,
                detail: permissionState, monospaced: false))
        renderNotificationPermission()
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

        gap(column)
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
        return scrolled(column)
    }

    private func accountsPane() -> NSView {
        let column = newColumn()
        #if !TAILSCODE_MAS
            gap(column)
            column.addArrangedSubview(MacDialogs.sectionHeader(WatchAccounts.heading))
            column.addArrangedSubview(
                indented(MacDialogs.detailLabel(WatchAccounts.description, wraps: true), by: 0))
            watchAccounts.orientation = .vertical
            watchAccounts.alignment = .leading
            watchAccounts.spacing = MacTheme.Spacing.s
            column.addArrangedSubview(watchAccounts)
            renderWatchAccounts()
        #endif

        gap(column)
        column.addArrangedSubview(MacDialogs.sectionHeader(Localized.text("Usage")))
        column.addArrangedSubview(
            indented(
                MacDialogs.detailLabel(
                    Localized.text(
                        "The full quota picture lives at the foot of the chat list; the Ollama Cloud and DeepSeek keys are the account facts this machine keeps."),
                    wraps: true), by: 0))
        deepseekRow.orientation = .vertical
        deepseekRow.alignment = .leading
        deepseekRow.spacing = MacTheme.Spacing.s
        column.addArrangedSubview(deepseekRow)
        renderDeepSeek()
        ollamaRow.orientation = .vertical
        ollamaRow.alignment = .leading
        ollamaRow.spacing = MacTheme.Spacing.s
        column.addArrangedSubview(ollamaRow)
        renderOllama()
        return scrolled(column)
    }

    private func keyboardPane() -> NSView {
        let column = newColumn()
        column.addArrangedSubview(MacDialogs.sectionHeader(Localized.text("Keyboard")))
        let cheatsheet = NSButton(
            title: Localized.text("Show"), target: self, action: #selector(showCheatsheet))
        column.addArrangedSubview(
            buttonRow(
                title: Localized.text("Shortcut cheatsheet"),
                subtitle: Localized.text("Every shortcut, as it is bound right now"),
                button: cheatsheet))
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

        gap(column)
        column.addArrangedSubview(
            MacDialogs.sectionHeader(Localized.text("Ask from anywhere")))
        column.addArrangedSubview(
            switchRow(
                title: Localized.text("Summon with a chord"),
                subtitle: Localized.text(
                    "One chord, pressed in any app on this Mac, opens the question box"),
                value: SummonSettings.isEnabled, action: #selector(summonEnabledChanged)))
        summonButton.target = self
        summonButton.action = #selector(recordSummonChord)
        column.addArrangedSubview(
            chordRow(title: Localized.text("Chord"), button: summonButton, detail: summonState))
        renderSummon()
        return scrolled(column)
    }

    private func advancedPane() -> NSView {
        let column = newColumn()
        column.addArrangedSubview(MacDialogs.sectionHeader(Localized.text("Diagnostics")))
        let copyFlight = NSButton(
            title: Localized.text("Copy"), target: self, action: #selector(copyDiagnostics))
        column.addArrangedSubview(
            buttonRow(
                title: Localized.text("Copy diagnostics"), subtitle: FlightRing.defaultURL().path,
                button: copyFlight))
        let reveal = NSButton(
            title: Localized.text("Show in Finder"), target: self, action: #selector(revealLogs))
        column.addArrangedSubview(
            buttonRow(
                title: Localized.text("Logs"),
                subtitle: Localized.text("The flight recorder and the app's own log, for a bug report"),
                button: reveal))

        gap(column)
        column.addArrangedSubview(MacDialogs.sectionHeader(Localized.text("Storage")))
        cacheButton.title = Localized.text("Clear")
        cacheButton.target = self
        cacheButton.action = #selector(clearPictureCache)
        column.addArrangedSubview(
            chordRow(
                title: Localized.text("Cached pictures"), button: cacheButton, detail: cacheState,
                monospaced: false))
        renderCacheState()

        gap(column)
        column.addArrangedSubview(MacDialogs.sectionHeader(Localized.text("Alpha")))
        column.addArrangedSubview(
            switchRow(
                title: Localized.text("Presence orb"),
                subtitle: Localized.text(
                    "A GPU-rendered creature at the foot of the chat list, breathing what every conversation is doing; may cost battery"),
                value: PresenceOrbSetting.isEnabled, action: #selector(presenceOrbChanged)))
        return scrolled(column)
    }


    /// The flight recorder's last quarter hour, decoded, on the pasteboard for a bug report. The
    /// ring holds counts and durations only, so there is nothing in it to redact.
    @objc private func copyDiagnostics() {
        Seatbelts.shared.writer?.drain()
        let text = FlightFormatter.format(FlightRing.read(url: FlightRing.defaultURL()), minutes: 15)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func presenceOrbChanged(_ sender: NSButton) {
        PresenceOrbSetting.setEnabled(sender.state == .on)
    }

    @objc private func manageServers() { actions.manageServers() }
    @objc private func openUpdates() { actions.openUpdates() }
    @objc private func openPro() { actions.openPro() }
    @objc private func showCheatsheet() { actions.showCheatsheet() }

    @objc private func sidebarShownChanged(_ sender: NSButton) {
        actions.setSidebarShown(sender.state == .on)
    }

    @objc private func terminalShownChanged(_ sender: NSButton) {
        actions.setTerminalShown(sender.state == .on)
    }

    /// Whether the system will let a notice be raised at all, said where the switches that ask for
    /// notices are: three switches that all read "on" over a permission that is off look like a
    /// fault in the app rather than a decision in System Settings.
    private func renderNotificationPermission() {
        Task { [weak self] in
            let status = await UNUserNotificationCenter.current().notificationSettings()
                .authorizationStatus
            let words: String
            switch status {
            case .authorized, .provisional, .ephemeral:
                words = Localized.text("Allowed — banners and sounds are on")
            case .denied:
                words = Localized.text(
                    "Turned off in System Settings — nothing can be raised until it is on")
            default:
                words = Localized.text("Not asked yet — the Test button below asks")
            }
            self?.permissionState.stringValue = words
        }
    }

    @objc private func openNotificationSettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func revealLogs() {
        NSWorkspace.shared.activateFileViewerSelecting([FlightRing.defaultURL()])
    }

    private func renderCacheState() {
        let size = ByteCountFormatter.string(
            fromByteCount: Int64(ImageDisk.bytesUsed()), countStyle: .file)
        cacheState.stringValue = Localized.text("%@ kept so chats open faster", size)
        cacheButton.isEnabled = ImageDisk.bytesUsed() > 0
    }

    @objc private func clearPictureCache() {
        ImageDisk.clear()
        renderCacheState()
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

    @objc private func responseStatsChanged(_ sender: NSButton) {
        ResponseStatsSetting.setEnabled(sender.state == .on)
        onTranscriptChanged()
    }

    @objc private func linkEmbedsChanged(_ sender: NSButton) {
        LinkEmbedsSetting.setEnabled(sender.state == .on)
        onTranscriptChanged()
    }

    @objc private func autoResumeChanged(_ sender: NSButton) {
        AutoResumeSetting.setEnabled(sender.state == .on)
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

    /// The file is revealed rather than opened where the app is sandboxed: handing a path inside
    /// this app's own container to another program is a door the container does not have, and a
    /// button that quietly opens nothing is worse than one that shows where the file is.
    @objc private func editShortcuts() {
        ShortcutSet.ensureConfigFile()
        #if TAILSCODE_MAS
            NSWorkspace.shared.activateFileViewerSelecting([ShortcutSet.configURL])
        #else
            NSWorkspace.shared.open(ShortcutSet.configURL)
        #endif
    }

    @objc private func reloadShortcuts() {
        onReloadShortcuts()
    }

    #if !TAILSCODE_MAS
        /// The two video accounts, drawn and redrawn in place. Signing in or out rewrites everything a
        /// row says while the window stands open, and the content is only made again at the next
        /// presentation — so the section empties and refills itself in place instead. The width
        /// constraint `scrolled(_:)` applies runs exactly once, over the column's own children, and
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
    #endif

    /// The optional DeepSeek key, stated as the fact it is: set, or not. The row is drawn again in
    /// place after the editor closes, because whether a key exists is exactly what the editor
    /// changes and the content is otherwise only made at the next presentation.
    private func renderDeepSeek() {
        for view in deepseekRow.arrangedSubviews { view.removeFromSuperview() }
        let button = NSButton(
            title: Localized.text("Edit"), target: self, action: #selector(editDeepSeekKey))
        let view = buttonRow(
            title: Localized.text("DeepSeek API key"),
            subtitle: DeepSeekCredentials.hasToken
                ? Localized.text("Saved in this Mac's Keychain")
                : Localized.text("Not set"),
            button: button)
        deepseekRow.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: deepseekRow.widthAnchor).isActive = true
    }

    @objc private func editDeepSeekKey() {
        DeepSeekKeySheet.present(on: window) { [weak self] in
            self?.renderDeepSeek()
        }
    }

    /// The optional Ollama Cloud key, stated as the fact it is: set, or not. The row is drawn
    /// again in place after the editor closes, because whether a key exists is exactly what the
    /// editor changes and the content is otherwise only made at the next presentation.
    private func renderOllama() {
        for view in ollamaRow.arrangedSubviews { view.removeFromSuperview() }
        let button = NSButton(
            title: Localized.text("Edit"), target: self, action: #selector(editOllamaKey))
        let view = buttonRow(
            title: Localized.text("Ollama Cloud API key"),
            subtitle: OllamaCredentials.hasToken
                ? Localized.text("Saved in this Mac's Keychain")
                : Localized.text("Not set"),
            button: button)
        ollamaRow.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: ollamaRow.widthAnchor).isActive = true
    }

    @objc private func editOllamaKey() {
        OllamaKeySheet.present(on: window) { [weak self] in
            self?.renderOllama()
        }
    }

    #if !TAILSCODE_MAS
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
            identity.font = MacTheme.Ramp.font(.toolOutput)
            let secret = NSSecureTextField(string: current?.secret ?? "")
            secret.placeholderString = YouTubeSetup.secretPrompt
            secret.font = MacTheme.Ramp.font(.toolOutput)
            let fields = NSStackView(views: [identity, secret])
            fields.orientation = .vertical
            fields.alignment = .leading
            fields.spacing = MacTheme.Spacing.xs
            fields.frame = NSRect(x: 0, y: 0, width: 320, height: 56)
            identity.widthAnchor.constraint(equalToConstant: 320).isActive = true
            secret.widthAnchor.constraint(equalToConstant: 320).isActive = true
            alert.accessoryView = fields
            alert.window.initialFirstResponder = identity

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
    #endif

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

    @objc private func chatDensityChanged(_ sender: NSPopUpButton) {
        ChatDensitySetting.set(ChatDensity.allCases[sender.indexOfSelectedItem])
    }

    @objc private func activityStyleChanged(_ sender: NSPopUpButton) {
        ActivityStyleSetting.set(ActivityStyle.allCases[sender.indexOfSelectedItem])
    }

    private func popUpRow(
        title: String, subtitle: String, options: [String], selected: Int, action: Selector
    ) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = MacTheme.Ramp.font(.panelLabel)
        let popUp = NSPopUpButton()
        popUp.addItems(withTitles: options)
        popUp.selectItem(at: min(selected, max(0, options.count - 1)))
        popUp.target = self
        popUp.action = action
        popUp.setAccessibilityLabel(title)
        popUp.setContentHuggingPriority(.required, for: .horizontal)
        popUp.setContentCompressionResistancePriority(MacTheme.Layout.belowWindowSize, for: .horizontal)
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
        toggle.font = MacTheme.Ramp.font(.panelLabel)
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
        label.font = MacTheme.Ramp.font(.panelLabel)
        valueLabel.stringValue = "\(value)"
        valueLabel.font = MacTheme.Ramp.font(.metricValue)
        valueLabel.alignment = .right
        floorWidth(valueLabel, 44)
        let stepper = NSStepper()
        stepper.minValue = Double(lower)
        stepper.maxValue = Double(upper)
        stepper.increment = Double(step)
        stepper.integerValue = value
        stepper.autorepeat = true
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = action
        stepper.setAccessibilityLabel(title)
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
        label.font = MacTheme.Ramp.font(.panelLabel)
        valueLabel.stringValue = HapticStrength.label(value)
        valueLabel.font = MacTheme.Ramp.font(.metricValue)
        valueLabel.alignment = .right
        floorWidth(valueLabel, 60)
        let slider = NSSlider(
            value: value, minValue: HapticStrength.range.lowerBound,
            maxValue: HapticStrength.range.upperBound, target: self, action: action)
        slider.isContinuous = true
        slider.setAccessibilityLabel(title)
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

    /// The chord row, whose detail line is the only place this app can say what the machine did
    /// with the key — a global shortcut that was refused looks exactly like one that works from
    /// everywhere inside the app.
    private func chordRow(
        title: String, button: NSButton, detail: NSTextField, monospaced: Bool = true
    ) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = MacTheme.Ramp.font(.panelLabel)
        button.bezelStyle = .rounded
        button.setContentHuggingPriority(.required, for: .horizontal)
        let filler = NSView()
        filler.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [label, filler, button])
        row.orientation = .horizontal
        row.spacing = MacTheme.Spacing.s
        detail.font = MacTheme.Ramp.font(monospaced ? .rowDetail : .panelFootnote)
        detail.textColor = MacTheme.Color.secondaryLabel
        detail.lineBreakMode = .byWordWrapping
        detail.maximumNumberOfLines = 0
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let column = NSStackView(views: [row, detail])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        detail.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    private func renderSummon() {
        let state = MacSummon.shared.state
        summonButton.title =
            summonRecorder == nil
            ? SummonSettings.chord.display(on: .apple) : Localized.text("Press a chord…")
        summonState.stringValue =
            [state.line(on: .apple), state.detail(on: .apple), MacSummon.shared.caution]
            .compactMap { $0 }.joined(separator: " · ")
    }

    @objc private func summonEnabledChanged(_ sender: NSButton) {
        SummonSettings.setEnabled(sender.state == .on)
        MacSummon.shared.refresh()
    }

    /// A chord is picked by pressing it. The monitor swallows the press rather than letting it
    /// reach the window, which is what makes recording ⌘-anything possible at all, and the press
    /// is judged before it is kept: a chord that would break another app on this Mac is named and
    /// refused rather than quietly claimed.
    @objc private func recordSummonChord() {
        guard summonRecorder == nil else {
            stopRecordingSummon()
            return
        }
        summonRecorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.heardSummonChord(event) }
            return nil
        }
        renderSummon()
    }

    private func heardSummonChord(_ event: NSEvent) {
        if event.keyCode == 53 {
            stopRecordingSummon()
            return
        }
        guard let key = SummonKeys.name(appleKeyCode: UInt32(event.keyCode)) else {
            summonState.stringValue =
                SummonJudge.judge(SummonChord(key: ""), on: .apple).note ?? ""
            NSSound.beep()
            return
        }
        let flags = event.modifierFlags
        let chord = SummonChord(
            control: flags.contains(.control), alt: flags.contains(.option),
            shift: flags.contains(.shift), meta: flags.contains(.command), key: key)
        if case .refused(let reason) = SummonJudge.judge(chord, on: .apple) {
            summonState.stringValue = reason
            NSSound.beep()
            return
        }
        SummonSettings.setChord(chord)
        stopRecordingSummon()
        MacSummon.shared.refresh()
    }

    private func stopRecordingSummon() {
        if let summonRecorder { NSEvent.removeMonitor(summonRecorder) }
        summonRecorder = nil
        renderSummon()
    }

    /// A fact with nothing to press: its name, and what it says beneath.
    private func infoRow(title: String, detail: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = MacTheme.Ramp.font(.panelLabel)
        let text = MacDialogs.detailLabel(detail, wraps: true)
        let column = NSStackView(views: [label, text])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        text.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    private func buttonRow(title: String, subtitle: String, button: NSButton) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = MacTheme.Ramp.font(.panelLabel)
        button.bezelStyle = .rounded
        button.setContentHuggingPriority(.required, for: .horizontal)
        let filler = NSView()
        filler.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [label, filler, button])
        row.orientation = .horizontal
        row.spacing = MacTheme.Spacing.s
        let detail = MacDialogs.detailLabel(subtitle, wraps: true)
        let column = NSStackView(views: [row, detail])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        detail.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    /// The gutter that keeps a changing number from shifting the row it sits in. The value labels
    /// outlive the column they are put in — they are the ones the change handlers write to — so a
    /// floor added on one build has to be taken back before the next one, or every presentation
    /// leaves another copy of it behind on the same label.
    private func floorWidth(_ label: NSTextField, _ width: CGFloat) {
        NSLayoutConstraint.deactivate(label.constraints.filter { $0.firstAttribute == .width })
        label.widthAnchor.constraint(greaterThanOrEqualToConstant: width).isActive = true
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
