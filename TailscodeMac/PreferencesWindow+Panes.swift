import AppKit
import CodingAgentKit
import CodingAgentKitApple
import MidgarPortal
import MidgarUI
import TailscodeCore
import UserNotifications

extension PreferencesWindow {
    /// One page of Settings: a name and a symbol for the toolbar, and what it holds.
    enum Pane: CaseIterable {
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
    func makeTabs(selecting index: Int = 0) -> NSTabViewController {
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
        #if TAILSCODE_MAS
            let token = NSButton(
                title: Localized.text("Change"), target: self, action: #selector(editTailnetToken))
            column.addArrangedSubview(
                buttonRow(
                    title: Localized.text("API access token"),
                    subtitle: MacTailnetCredentials.key.settingsValue,
                    button: token))
        #endif

        gap(column)
        column.addArrangedSubview(MacDialogs.sectionHeader(Localized.text("About")))
        column.addArrangedSubview(
            infoRow(title: MidgarSettingsRow.version().title, detail: Self.versionLine))
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
                    subtitle: ProAccess.shared.isPro
                        ? Localized.text("Unlocked — thank you")
                        : Localized.text("Unlimited servers, and delegation to cheaper models"),
                    button: pro))
        #endif
        return scrolled(column)
    }

    /// The doorway into the Midgar portal: the first thing in the first page, as wide as the
    /// page's other rows and a fixed 116 points tall.
    private func addMidgarEntry(to column: NSStackView) {
        let entry = MidgarEntryView(config: TailscodeMidgar.shared.portalConfig)
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
        column.addArrangedSubview(
            switchRow(
                title: Localized.text("Running low"),
                subtitle: Localized.text(
                    "A usage window is on course to run out before it resets. Account-wide windows only, once per window"),
                value: MacNotifier.notifyRunningLow, action: #selector(notifyRunningLowChanged)))
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
        addShortcutsSection(to: column)

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
}
