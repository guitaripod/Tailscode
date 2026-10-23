import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

extension MainWindowController {
    func toggleCheatsheet() {
        if let cheatsheet, cheatsheet.isVisible {
            cheatsheet.close()
            return
        }
        presentCheatsheet()
    }

    func closeCheatsheet() {
        guard let cheatsheet, cheatsheet.isVisible else { return }
        cheatsheet.close()
    }

    /// A question that arrived from another app. The window comes forward first because the field
    /// is inside it: a panel that opened behind whatever was frontmost would take the keystrokes
    /// meant for the question with it.
    func summonQuickAsk() {
        window?.makeKeyAndOrderFront(nil)
        presentQuickAsk()
    }

    /// The chord summons one field and nothing else; the words land in the focused pane as a new
    /// conversation with no project directory. With no servers the chord goes to setup instead
    /// of presenting a dead field.
    /// `demoServer` adds one machine with a name long enough to test the aim strip, so the panel
    /// can be measured against the worst name a person might give a server — `--open quickask:long`.
    func presentQuickAsk(demoServer: Bool = false) {
        var profiles = ServerDirectory.shared.profiles
        if demoServer, let address = URL(string: "http://100.64.0.99:4098") {
            profiles.append(
                ConnectionProfile(
                    id: "demo-long-name", name: "build-server-in-the-basement-rack-two",
                    backend: .claudeCode, baseURL: address))
        }
        guard !profiles.isEmpty else {
            presentServers()
            return
        }
        QuickAskPanel.present(
            over: window, servers: profiles, preferredServer: currentEntry?.profileID,
            recents: sidebar.entries,
            onAsk: { [weak self] profileID, send, attachments, done in
                guard let self,
                    let profile = ServerDirectory.shared.profiles.first(where: {
                        $0.id == profileID
                    })
                else {
                    done(NewChatDiagnosis.noSuchServer())
                    return
                }
                self.mintQuickAsk(
                    on: profile, send: send, attachments: attachments, done: done)
            },
            onResume: { [weak self] entry in self?.sidebar.open(entry) })
    }

    /// The quick-ask mint queues the words — keyed to the minted session — and opens the chat in
    /// one main-actor turn, so nothing a hand does mid-flight can slip between the queue and the
    /// open, and no other conversation can ever inherit the question. A failed mint queues
    /// nothing and answers the panel with its reason.
    ///
    /// What travels is the decision rather than the string: the catalog that could answer a slash
    /// belongs to the machine being aimed at, and it was read where the question was typed, so a
    /// command typed into a quick ask runs as a command here rather than reaching the model as the
    /// word it was typed as.
    private func mintQuickAsk(
        on profile: ConnectionProfile, send: QuickAskSend, attachments: [PendingAttachment],
        done: @escaping @MainActor (NewChatFailure?) -> Void
    ) {
        guard let backend = ServerDirectory.shared.backend(for: profile) else {
            done(NewChatDiagnosis.noCredentials(server: Self.newChatServer(profile)))
            return
        }
        let server = Self.newChatServer(profile)
        let password = ServerDirectory.shared.password(for: profile)
        Task { [weak self] in
            let minted = await NewChatAttempt.mint(
                using: backend, server: server, baseURL: profile.baseURL, password: password,
                directory: nil)
            guard case .success(let session) = minted else {
                done(minted.failureValue)
                return
            }
            guard let self else {
                done(nil)
                return
            }
            QuickAskDefaults.stamp(profileID: profile.id, sessionID: session.id)
            let entry = SessionEntry(
                profileID: profile.id, profileName: profile.name,
                host: profile.baseURL.host ?? profile.name,
                backendType: profile.backend, session: session)
            self.transcript.queueFirstMessage(
                send, attachments: attachments, forSession: entry.session.id)
            self.sidebar.noteCreated(entry)
            /// The panel is answered — which is what closes it — only once the conversation is
            /// on screen behind it, and the keyboard is moved after the close rather than
            /// before: a field focused under a panel that is still key loses the focus again
            /// the moment that panel goes.
            done(nil)
            self.transcript.focusComposer()
            await self.sidebar.refresh()
        }
    }

    /// The panel is as tall as its rows want and never taller than the screen it opens on: the ramp
    /// grows with the type scale and the sections do not, so the sheet that fits a laptop at 1.0
    /// runs off the bottom at 2.0 — and a shortcut sheet whose last section cannot be reached is
    /// worse than no sheet at all. Past that height it scrolls, and it resizes.
    func presentCheatsheet() {
        let panel = CheatsheetPanel(
            contentRect: .zero, styleMask: [.titled, .closable, .resizable], backing: .buffered,
            defer: false)
        panel.title = Localized.text("Keyboard shortcuts")
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        let content = makeCheatsheetContent()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = content
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        panel.contentView = scroll
        let fitting = content.fittingSize
        panel.setContentSize(fitting)
        let chrome = panel.frame.height - fitting.height
        let room = ((window?.screen ?? NSScreen.main)?.visibleFrame.height ?? panel.frame.height)
            - chrome
        panel.setContentSize(NSSize(width: fitting.width, height: min(fitting.height, room)))
        if let frame = window?.frame {
            let size = panel.frame.size
            panel.setFrameOrigin(
                NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        }
        panel.makeKeyAndOrderFront(nil)
        cheatsheet = panel
    }

    /// Generated from the registry, so it always tells the truth — overrides included — in two
    /// columns, because forty rows in one column is a scroll rather than a glance.
    ///
    /// Every gap is a token taken through the same scale the type is, because the sheet is nothing
    /// but type: at ⌘+ a fixed rhythm puts a section header on top of its first row, and a fixed
    /// key column cuts the one column the panel exists to show.
    private func makeCheatsheetContent() -> NSView {
        let scale = MacTheme.UIScale.factor
        let sections = shortcuts.helpSections()
        let left = cheatsheetColumn()
        let right = cheatsheetColumn()
        let total = sections.reduce(0) { $0 + $1.rows.count + 2 }
        var used = 0
        for section in sections {
            let target = used < (total + 1) / 2 ? left : right
            used += section.rows.count + 2
            let header = NSTextField(labelWithString: section.title)
            header.font = MacTheme.Ramp.font(.sectionLabel)
            header.textColor = MacTheme.Color.secondaryLabel
            target.addArrangedSubview(header)
            target.setCustomSpacing(MacTheme.Spacing.s * scale, after: header)
            for row in section.rows {
                let keys = NSTextField(labelWithString: row.keys)
                keys.font = MacTheme.Ramp.font(.toolOutput)
                keys.lineBreakMode = .byTruncatingTail
                keys.widthAnchor.constraint(equalToConstant: 160 * scale).isActive = true
                let what = NSTextField(labelWithString: row.what)
                what.font = MacTheme.Ramp.font(.panelFootnote)
                what.textColor = MacTheme.Color.secondaryLabel
                let line = NSStackView(views: [keys, what])
                line.orientation = .horizontal
                line.spacing = MacTheme.Spacing.m * scale
                line.alignment = .firstBaseline
                target.addArrangedSubview(line)
            }
            if let last = target.arrangedSubviews.last {
                target.setCustomSpacing(MacTheme.Spacing.l * scale, after: last)
            }
        }
        let columns = NSStackView(views: [left, right])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = MacTheme.Spacing.xl * scale
        let footer = NSTextField(
            labelWithString: Localized.text(
                "Rebind any of these: %@", ShortcutSet.configURL.path))
        footer.font = MacTheme.Ramp.font(.panelFootnote)
        footer.textColor = MacTheme.Color.tertiaryLabel
        let content = NSStackView(views: [columns, footer])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = MacTheme.Spacing.l * scale
        content.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.l * scale, left: MacTheme.Spacing.xl * scale,
            bottom: MacTheme.Spacing.l * scale, right: MacTheme.Spacing.xl * scale)
        content.translatesAutoresizingMaskIntoConstraints = false
        return content
    }

    private func cheatsheetColumn() -> NSStackView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = MacTheme.Spacing.xs * MacTheme.UIScale.factor
        return column
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        toast(Localized.text("Copied"))
    }
}
