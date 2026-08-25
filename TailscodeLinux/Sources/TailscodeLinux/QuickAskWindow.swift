import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// The quick-ask surface, drawn: one entry, the aim it remembered, and what the aim can be
/// handed. Enter is the whole ceremony — the words and anything attached to them go out as a new
/// conversation with no project directory on the server named in the chip, and the window stays
/// up only long enough for that server to answer, so a failed mint keeps the question in hand
/// rather than swallowing it. The aim is both halves and both are the quick ask's own: tab or a
/// click moves the machine, `alt+m` or the model chip opens the catalog, `alt+e` or the effort
/// chip says how hard it is asked to think, and `QuickAskDefaults` remembers all three per server
/// beside the composer's memory rather than inside it.
///
/// Owing no form is not the same as being able to do nothing. `alt+a` attaches a file and
/// `alt+v` takes the clipboard's picture, offered only where the aim can read them; the empty
/// window argues for itself with `QuickAskStarters` — `alt+1…9`, or a click — and hands back the
/// last few questions asked on this machine, so the blank entry is a way into everything the
/// agent can do instead of a text field with a placeholder.
final class QuickAskWindow: @unchecked Sendable {
    nonisolated(unsafe) private(set) static var open: QuickAskWindow?

    private let servers: [ConnectionProfile]
    /// What each machine's agent takes as an effort level, read where a backend could be asked:
    /// this window holds profiles rather than connections, and a level it cannot offer honestly
    /// is one it must not offer at all.
    private let agentEfforts: [String: [String]]
    /// Which machines resolve their own slash words out of the prompt text. Read where a backend
    /// could be asked, for the same reason the effort levels are: this window holds profiles rather
    /// than connections, and the grammar belongs to the server the question is aimed at.
    private let promptTextGrammar: [String: Bool]
    /// What the aimed server can be told to do. Answered from what it last published so the first
    /// keystroke is never blank, and corrected by a fetch behind it.
    private var commands: [AgentCommand] = []
    private let recents: [SessionEntry]
    private var catalogWatch: Task<Void, Never>?
    private var targetIndex: Int
    private let onAsk:
        @Sendable (String, QuickAskSend, [PendingAttachment], @escaping @Sendable (NewChatFailure?)
            -> Void) -> Void
    private let onResume: @Sendable (SessionEntry) -> Void

    private let window: UnsafeMutablePointer<GtkWidget>
    private let editor: PromptEditor
    private let title: UnsafeMutablePointer<GtkWidget>
    private let target: UnsafeMutablePointer<GtkWidget>
    private let model: UnsafeMutablePointer<GtkWidget>
    private let effort: UnsafeMutablePointer<GtkWidget>
    private let attach: UnsafeMutablePointer<GtkWidget>
    private let send: UnsafeMutablePointer<GtkWidget>
    private let chips: UnsafeMutablePointer<GtkWidget>
    private let starters: UnsafeMutablePointer<GtkWidget>
    private let hint: UnsafeMutablePointer<GtkWidget>
    private let vimBadge = Gtk.label("", css: "vim-badge", selectable: false)
    private var attachments: [PendingAttachment] = []
    private var offered: [QuickAskStarter] = []
    private var pastedImageCount = 0
    private var asking = false
    private var summonWatch: NSObjectProtocol?
    private var completion: SlashPopover?

    /// - Parameter onAsk: mints the conversation on the chosen server and answers with nothing
    ///   when it worked, or with the reason it did not; the words and their attachments travel
    ///   with the mint, so the caller owns getting them sent once the chat exists.
    /// - Parameter onResume: opens a question already asked on this machine rather than asking a
    ///   new one.
    static func present(
        servers: [ConnectionProfile], agentEfforts: [String: [String]] = [:],
        promptTextGrammar: [String: Bool] = [:],
        preferredServer: String?, recents: [SessionEntry],
        parent: UnsafeMutablePointer<GtkWidget>?,
        onAsk: @escaping @Sendable (
            String, QuickAskSend, [PendingAttachment], @escaping @Sendable (NewChatFailure?) -> Void
        ) -> Void,
        onResume: @escaping @Sendable (SessionEntry) -> Void
    ) {
        guard !servers.isEmpty else { return }
        open?.close()
        open = QuickAskWindow(
            servers: servers, agentEfforts: agentEfforts, promptTextGrammar: promptTextGrammar,
            preferredServer: preferredServer, recents: recents, parent: parent, onAsk: onAsk,
            onResume: onResume)
    }

    private init(
        servers: [ConnectionProfile], agentEfforts: [String: [String]],
        promptTextGrammar: [String: Bool],
        preferredServer: String?, recents: [SessionEntry],
        parent: UnsafeMutablePointer<GtkWidget>?,
        onAsk: @escaping @Sendable (
            String, QuickAskSend, [PendingAttachment], @escaping @Sendable (NewChatFailure?) -> Void
        ) -> Void,
        onResume: @escaping @Sendable (SessionEntry) -> Void
    ) {
        self.servers = servers
        self.agentEfforts = agentEfforts
        self.promptTextGrammar = promptTextGrammar
        self.recents = recents
        self.onAsk = onAsk
        self.onResume = onResume
        let aimed = QuickAskDefaults.target(
            among: servers.map(\.id), fallback: preferredServer)
        targetIndex = servers.firstIndex { $0.id == aimed } ?? 0

        window = gtk_window_new()!
        gtk_window_set_title(ptr(window), Localized.text("Quick ask"))
        gtk_window_set_modal(ptr(window), 1)
        gtk_window_set_default_size(ptr(window), 620, -1)
        if let parent, let root = gtk_widget_get_root(parent) {
            gtk_window_set_transient_for(ptr(window), ptr(UnsafeMutableRawPointer(root)))
        }

        editor = PromptEditor(
            css: "ask-entry", placeholder: Localized.text("Ask anything — no project, no setup"))
        hint = Gtk.label("", css: "ask-hint", selectable: false)
        target = Gtk.menuButton("", css: ["flat", "ask-chip"]) {
            QuickAskWindow.open?.serverRows() ?? []
        }
        model = Gtk.menuButton("", css: ["flat", "ask-chip"]) {
            QuickAskWindow.open?.modelRows() ?? []
        }
        effort = Gtk.menuButton("", css: ["flat", "ask-chip"]) {
            QuickAskWindow.open?.effortRows() ?? []
        }
        attach = Gtk.button("📎", css: ["flat", "ask-chip"]) {
            Gtk.onMain { QuickAskWindow.open?.pickAttachments() }
        }
        send = Gtk.button("↵", css: ["flat", "ask-send"]) {
            Gtk.onMain { QuickAskWindow.open?.submit() }
        }
        gtk_widget_set_valign(send, GTK_ALIGN_END)
        chips = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        starters = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)

        /// The window wears the desktop's own bar rather than a row of its own that has to be
        /// read as one: the name of the thing is in the title, the machine it will ask is the
        /// subtitle under it, and the two controls that change either sit where a header keeps
        /// controls. Nothing in the body then competes with the question.
        title = adw_window_title_new(Localized.text("Quick ask"), "")!
        let header = adw_header_bar_new()!
        adw_header_bar_set_title_widget(op(UnsafeMutableRawPointer(header)), title)
        adw_header_bar_pack_start(op(UnsafeMutableRawPointer(header)), target)
        adw_header_bar_pack_end(op(UnsafeMutableRawPointer(header)), attach)
        adw_header_bar_pack_end(op(UnsafeMutableRawPointer(header)), effort)
        adw_header_bar_pack_end(op(UnsafeMutableRawPointer(header)), model)
        gtk_window_set_titlebar(ptr(window), header)

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
        Gtk.margins(column, top: 16, bottom: 14, leading: 16, trailing: 16)
        gtk_window_set_child(ptr(window), column)

        let caret = Gtk.label("›", css: "ask-caret", selectable: false)
        gtk_widget_set_valign(caret, GTK_ALIGN_START)
        Gtk.margins(caret, top: 8)
        gtk_widget_set_valign(vimBadge, GTK_ALIGN_END)
        gtk_widget_set_visible(vimBadge, 0)
        gtk_label_set_ellipsize(op(vimBadge), PANGO_ELLIPSIZE_NONE)
        let field = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.addClass(field, "ask-field")
        gtk_box_append(ptr(field), caret)
        gtk_box_append(ptr(field), editor.widget)
        gtk_box_append(ptr(field), vimBadge)
        gtk_box_append(ptr(field), send)
        gtk_box_append(ptr(column), field)
        gtk_box_append(ptr(column), chips)
        gtk_box_append(ptr(column), hint)
        gtk_box_append(ptr(column), starters)
        editor.carryModeOn(field)

        let completion = SlashPopover(anchor: field)
        completion.hasProject = false
        completion.onPick = { [weak self] command in
            Gtk.onMain { [weak self] in self?.acceptSlashCommand(command) }
        }
        self.completion = completion

        /// The whole surface takes a drop, not a button on it: something dragged out of a file
        /// manager is a question about that thing, and aiming it at a paperclip is not a gesture
        /// anybody should have to make.
        Gtk.acceptFileDrops(on: column) { [weak self] paths in
            Gtk.onMain { [weak self] in self?.take(paths: paths) }
        }

        editor.onHeightChanged = { [weak self] in self?.fitToContents() }
        editor.onChanged = { [weak self] in
            self?.stashDraft()
            self?.refreshStarterVisibility()
            self?.refreshSend()
            self?.refreshAura()
            self?.updateSlashCompletion()
        }
        Gtk.onKey(window) { [weak self] keyval, state in
            guard let self else { return false }
            let control = state & KeyChord.controlMask != 0
            let shift = state & Keymap.shift != 0
            if self.completion?.isShown == true {
                if keyval == Keymap.down || (control && keyval == UInt32(UnicodeScalar("n").value)) {
                    Gtk.onMain { [weak self] in self?.completion?.move(by: 1) }
                    return true
                }
                if keyval == Keymap.up || (control && keyval == UInt32(UnicodeScalar("p").value)) {
                    Gtk.onMain { [weak self] in self?.completion?.move(by: -1) }
                    return true
                }
                if keyval == Keymap.tab {
                    Gtk.onMain { [weak self] in
                        guard let self, let command = self.completion?.selected else { return }
                        self.acceptSlashCommand(command)
                    }
                    return true
                }
                if keyval == Keymap.escape {
                    Gtk.onMain { [weak self] in self?.completion?.dismiss() }
                    return true
                }
            }
            if let claimed = self.vimKey(keyval: keyval, state: state) { return claimed }
            if keyval == Keymap.escape {
                Gtk.onMain { [weak self] in self?.close() }
                return true
            }
            if keyval == Keymap.tab {
                Gtk.onMain { [weak self] in self?.cycleTarget() }
                return true
            }
            if control, keyval == UInt32(UnicodeScalar("v").value) {
                Gtk.onMain { [weak self] in self?.pasteFromClipboard() }
                return true
            }
            /// Return is the send unless the settings say otherwise, and shift always writes the
            /// line break — the same bargain the chat's own box makes, so a question with a
            /// paragraph in it is typed the way a prompt is.
            let isReturn = keyval == Keymap.enter || keyval == Keymap.keypadEnter
            if isReturn, !shift, Preferences.sendOnReturn || control {
                Gtk.onMain { [weak self] in self?.submit() }
                return true
            }
            if isReturn { return false }
            guard state & KeyChord.altMask != 0 else { return false }
            if keyval == UInt32(UnicodeScalar("m").value) {
                Gtk.onMain { [weak self] in self?.chooseModel() }
                return true
            }
            if keyval == UInt32(UnicodeScalar("e").value) {
                Gtk.onMain { [weak self] in
                    guard let self, gtk_widget_get_visible(self.effort) != 0 else { return }
                    gtk_menu_button_popup(op(self.effort))
                }
                return true
            }
            if keyval == UInt32(UnicodeScalar("a").value) {
                Gtk.onMain { [weak self] in self?.pickAttachments() }
                return true
            }
            if keyval == UInt32(UnicodeScalar("v").value) {
                Gtk.onMain { [weak self] in self?.pasteFromClipboard() }
                return true
            }
            guard let digit = Keymap.digit(keyval), digit > 0 else { return false }
            Gtk.onMain { [weak self] in self?.pickStarter(at: digit - 1) }
            return true
        }
        Gtk.connect(UnsafeMutableRawPointer(window), "destroy") {
            Gtk.onMain { QuickAskWindow.open = nil }
        }

        /// The desktop answers about the chord seconds after the app starts, which is often after
        /// this window has already been opened by that very chord.
        summonWatch = NotificationCenter.default.addObserver(
            forName: Summon.didChange, object: nil, queue: nil
        ) { _ in
            Gtk.onMain {
                guard let open = QuickAskWindow.open else { return }
                adw_window_title_set_subtitle(
                    op(UnsafeMutableRawPointer(open.title)), Self.subtitle())
            }
        }

        refreshTarget()
        watchCatalog()
        restoreDraft()
        updateVimBadge()
        loadCommands()
        gtk_window_present(ptr(window))
        editor.focus()
        AppLog.write(.ui, "ASK shown target=\(servers[targetIndex].name)")
    }

    private var targetServer: ConnectionProfile { servers[targetIndex] }

    private var draftScope: DraftScope { .quickAsk(profileID: targetServer.id) }

    /// A question survives the surface it was being written in: the window is opened by a chord
    /// pressed in the middle of something else and closed by the same reflex, so what is in the
    /// entry is filed as it is typed and handed back the next time this machine is aimed at.
    private func stashDraft() {
        guard !asking else { return }
        DraftStore.record(editor.text, for: draftScope)
    }

    private func restoreDraft() {
        let draft = DraftStore.text(for: draftScope)
        guard !draft.isEmpty else { return }
        write(draft)
    }

    /// Every path that puts words in the box lands here, so the vim document that shadows it is
    /// never left describing a draft that has been replaced underneath it.
    private func write(_ text: String) {
        editor.setText(text)
        editor.vim.reset(to: text, cursor: text.count, mode: .insert)
        updateVimBadge()
    }

    /// Moving the question to another machine leaves the words filed under the one being left and
    /// hands back whatever was last written for the one arrived at, the way re-aiming Home's
    /// composer does — a draft belongs to the machine it was written for.
    private func retarget(to index: Int) {
        watchCatalog()
        guard index != targetIndex else { return }
        stashDraft()
        targetIndex = index
        refreshTarget()
        write(DraftStore.text(for: draftScope))
        refreshAura()
        loadCommands()
    }

    /// A question typed here can be a command, so the surface has to know what the machine it is
    /// aimed at answers to. What that server last published is read straight away — a list that is
    /// blank for the first second is a list nobody trusts — and the fetch behind it only corrects
    /// it. There is no project, so the catalog is the machine's own and the commands that read a
    /// transcript are dropped: the conversation this send mints has nothing for them to read.
    private func loadCommands() {
        let server = targetServer
        commands = CommandCatalogStore.forQuickAsk(CommandCatalogStore.cached(server.id))
        completion?.catalogSize = commands.count
        Task { [weak self] in
            let profiles = await ServerDirectory.shared.profiles()
            guard let profile = profiles.first(where: { $0.id == server.id }),
                let backend = await ServerDirectory.shared.backend(for: profile),
                backend.capabilities.supportsCommands
            else { return }
            let fetched = await CommandCatalogStore.refresh(profileID: server.id, backend: backend)
            Gtk.onMain { [weak self] in
                guard let self, self.targetServer.id == server.id else { return }
                self.commands = CommandCatalogStore.forQuickAsk(fetched)
                self.completion?.catalogSize = self.commands.count
                self.updateSlashCompletion()
            }
        }
    }

    private func updateSlashCompletion() {
        guard let completion else { return }
        let typing = !Preferences.vimComposer || editor.vim.mode == .insert
        guard typing else {
            completion.dismiss()
            return
        }
        completion.renderCompletion(
            SlashPresentation.of(
                text: editor.text, commands: commands,
                recents: SlashRecents.surviving(in: commands)),
            cursor: completion.cursor)
    }

    private func acceptSlashCommand(_ command: AgentCommand) {
        SlashRecents.record(command.name)
        write(command.takesArguments ? "/\(command.name) " : "/\(command.name)")
        editor.focus()
        updateSlashCompletion()
    }

    private func cycleTarget() {
        guard servers.count > 1, !asking else { return }
        retarget(to: (targetIndex + 1) % servers.count)
        AppLog.write(.ui, "ASK target=\(targetServer.name)")
    }

    /// The whole catalog, from the fleet's own cache — a machine's models are a fact about that
    /// machine, so the chooser can name what another server runs without this ask ever having
    /// talked to it, and a pick landing there re-aims the question rather than moving a chat.
    private func chooseModel() {
        guard !asking else { return }
        let server = targetServer
        ModelChooserWindow.present(
            sources: ModelFleet.sources(profiles: servers, current: server.id),
            selected: QuickAskDefaults.model(forProfileID: server.id), parent: window
        ) { [weak self] pick in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                QuickAskDefaults.adopt(pick)
                if let index = self.servers.firstIndex(where: { $0.id == pick.profileID }) {
                    self.retarget(to: index)
                }
                self.refreshTarget()
                FileHandle.standardOutput.write(
                    Data("ASK model=\(self.targetServer.name)\n".utf8))
            }
        }
    }

    /// What the aim can be handed, re-read whenever either half of it moves. A picture already in
    /// the strip that the new model cannot read is dropped out loud rather than carried to a send
    /// the other machine would refuse.
    private var abilities: ModelAbilities {
        let server = targetServer
        let selection = QuickAskDefaults.model(forProfileID: server.id)
        let capabilities = selection.flatMap { pick in
            ModelCatalogStore.cached(server.id).first {
                $0.providerID == pick.providerID && $0.id == pick.modelID
            }?.capabilities
        }
        return ModelAbilities.resolve(supportsAttachments: true, model: capabilities)
    }

    /// Where the question goes, as a menu rather than a cycle: every server named with the
    /// agent that would answer and the address it lives at, the aimed one ticked. Cycling hid
    /// the list and made reaching the third machine two blind presses.
    private func serverRows() -> [(title: String, detail: String?, action: @Sendable () -> Void)] {
        servers.enumerated().map { index, server in
            let aimed = index == targetIndex
            return (
                (aimed ? "✓ " : "") + server.name + " · " + ServerLabel.agent(server.backend),
                server.baseURL.absoluteString,
                { Gtk.onMain { QuickAskWindow.open?.retarget(to: index) } }
            )
        }
    }

    /// What will answer, at menu length: the server's own default, your stars, what you reached
    /// for, the local floor — the same list the composer's pill shows — and the road to the full
    /// directory when none of the shortlist is the answer.
    private func modelRows() -> [(title: String, detail: String?, action: @Sendable () -> Void)] {
        guard !asking else { return [] }
        let server = targetServer
        let selected = QuickAskDefaults.model(forProfileID: server.id)
        var rows: [(title: String, detail: String?, action: @Sendable () -> Void)] = [
            (
                (selected == nil ? "✓ " : "") + Localized.text("Server default"),
                Localized.text("Let the machine decide"),
                { Gtk.onMain { QuickAskWindow.open?.pick(ModelPick(
                    profileID: server.id, selection: nil, isElsewhere: false,
                    serverName: server.name, modelName: "")) } }
            )
        ]
        let sources = ModelFleet.sources(profiles: servers, current: server.id)
        for candidate in ModelChooser.shortlist(sources: sources, selected: selected, limit: 8) {
            let star = candidate.offers.contains {
                ModelFavoritesStore.isFavorite($0.selection)
            } ? "★ " : ""
            let aimed = !candidate.isElsewhere && candidate.carries(selected)
            rows.append(
                (
                    (aimed ? "✓ " : "") + star + candidate.name,
                    candidate.isElsewhere
                        ? Localized.text("on %@ — the ask moves there", candidate.serverName)
                        : candidate.primary.providerName,
                    {
                        let chosen = ModelPick(
                            profileID: candidate.profileID, selection: candidate.selection,
                            isElsewhere: candidate.isElsewhere,
                            serverName: candidate.serverName, modelName: candidate.name)
                        Gtk.onMain { QuickAskWindow.open?.pick(chosen) }
                    }
                ))
        }
        rows.append(
            (
                Localized.text("All models…"), Localized.text("Search every server's catalog"),
                { Gtk.onMain { QuickAskWindow.open?.chooseModel() } }
            ))
        return rows
    }

    private func pick(_ pick: ModelPick) {
        QuickAskDefaults.adopt(pick)
        if let index = servers.firstIndex(where: { $0.id == pick.profileID }) {
            retarget(to: index)
        }
        refreshTarget()
        editor.focus()
    }

    /// The catalog is asked once per aim, in the background: a server that has never been
    /// opened has an empty cache, and a model chip hidden for that read as "this server has
    /// no models" when the truth was only that nobody had asked yet.
    private func watchCatalog() {
        catalogWatch?.cancel()
        let server = targetServer
        Task { [weak self] in
            let profiles = await ServerDirectory.shared.profiles()
            guard let profile = profiles.first(where: { $0.id == server.id }),
                let backend = await ServerDirectory.shared.backend(for: profile)
            else { return }
            for await reading in ModelCatalogWatch.readings(
                profileID: server.id, backend: backend)
            {
                guard let self, self.targetServer.id == server.id else { return }
                ModelCatalogStore.store(reading.models, for: server.id)
                Gtk.onMain { [weak self] in self?.refreshTarget() }
            }
        }
    }

    private func refreshTarget() {
        let server = targetServer
        gtk_menu_button_set_label(op(target), server.name + " · " + ServerLabel.agent(server.backend))
        adw_window_title_set_subtitle(
            op(UnsafeMutableRawPointer(title)), Self.subtitle())
        let picked = QuickAskDefaults.model(forProfileID: server.id)
        gtk_menu_button_set_label(
            op(model),
            picked == nil && ModelCatalogStore.cached(server.id).isEmpty
                ? Localized.text("Model…")
                : ModelBadge.label(model: picked, effort: nil))
        let levels = effortOptions()
        dropUnofferedEffort(on: server.id, options: levels)
        gtk_menu_button_set_label(
            op(effort),
            ModelEffort.label(
                QuickAskDefaults.effort(forProfileID: server.id), options: levels))
        gtk_widget_set_visible(effort, ModelEffort.isOffered(options: levels) ? 1 : 0)
        refreshAura()
        let able = abilities
        gtk_widget_set_visible(attach, able.attachments ? 1 : 0)
        let kept = attachments.filter { able.accepts(mime: $0.mime) }
        let dropped = attachments.count - kept.count
        attachments = kept
        renderAttachments()
        renderStarters()
        refreshSend()
        guard !asking else { return }
        setHint(dropped > 0 ? QuickAskComposition.droppedNotice(count: dropped) : Self.keysHint(
            machines: servers.count))
    }

    /// What the keys do, said once under the box. Which key sends is the person's own setting, so
    /// the line reads it rather than asserting Enter — and it always names the one that writes a
    /// line break, because a box that grows is worth nothing to somebody who does not know how to
    /// put a paragraph in it.
    private static func keysHint(machines: Int) -> String {
        let sending =
            Preferences.sendOnReturn
            ? Localized.text("Enter sends · shift+enter for a new line")
            : Localized.text("Ctrl+enter sends · enter for a new line")
        guard machines > 1 else {
            return sending + Localized.text(" · esc closes")
        }
        return sending + Localized.text(" · tab moves the machine · esc closes")
    }

    /// The bar's second line teaches the thing a person cannot discover from inside this window:
    /// that it can be opened without the app in front of them. The machine it will ask is already
    /// the chip beside it, so saying that here too would spend the line on something visible.
    private static func subtitle() -> String {
        let state = Summon.shared.state
        guard state.isLive, let chord = state.chord else { return "" }
        return Localized.text("%@ from anywhere", chord.display(on: .linux))
    }

    /// The send arrow is lit by the same rule that lets Enter through, so the one control and the
    /// one key can never disagree about whether there is a question yet.
    private func refreshSend() {
        let ready = QuickAskComposition.canSend(
            text: editor.text.trimmingCharacters(in: .whitespacesAndNewlines),
            attachments: attachments.count)
        gtk_widget_set_sensitive(send, ready && !asking ? 1 : 0)
        if ready { Gtk.addClass(send, "ask-send-ready") } else {
            gtk_widget_remove_css_class(send, "ask-send-ready")
        }
    }

    /// How hard the machine is asked to think, which is half of what a question costs and the
    /// other half of the aim: the levels are the picked model's own where the catalog names them
    /// and the agent's otherwise, and a pick is the quick ask's own memory on that server rather
    /// than the machine's — the same bargain the model chip strikes.
    private func effortOptions() -> [String] {
        let server = targetServer
        return ModelEffort.options(
            models: ModelCatalogStore.cached(server.id),
            selection: QuickAskDefaults.model(forProfileID: server.id),
            agentOptions: agentEfforts[server.id] ?? [])
    }

    /// A model whose levels are its own can make the level already picked unrunnable. The aim
    /// then hands the choice back to the machine rather than keeping a word the question could
    /// not be asked with — a chip may never name a level the send would not carry.
    private func dropUnofferedEffort(on profileID: String, options: [String]) {
        guard let chosen = QuickAskDefaults.effort(forProfileID: profileID), !chosen.isEmpty,
            !options.contains(chosen)
        else { return }
        QuickAskDefaults.recordEffort(nil, forProfileID: profileID)
    }

    private func effortRows() -> [(String, String?, @Sendable () -> Void)] {
        let server = targetServer
        var rows: [(String, String?, @Sendable () -> Void)] = [
            (Localized.text("Server default"), Localized.text("Let the machine decide"),
             { Gtk.onMain { QuickAskWindow.open?.setEffort(nil, on: server.id) } })
        ]
        for option in effortOptions() {
            let power = option == Ultracode.effortLevel
            rows.append(
                (power ? "\(option) ✦" : option, power ? Ultracode.menuSubtitle : nil,
                 { Gtk.onMain { QuickAskWindow.open?.setEffort(option, on: server.id) } }))
        }
        return rows
    }

    private func setEffort(_ level: String?, on profileID: String) {
        QuickAskDefaults.recordEffort(level, forProfileID: profileID)
        refreshTarget()
        editor.focus()
        AppLog.write(.ui, "ASK effort=\(level ?? "server")")
    }

    /// Vim is the composer's, so it is the quick ask's: the same engine, the same badge, the same
    /// rule that a mode is worn rather than remembered. Escape leaves insert before it closes the
    /// window, because a hand that pressed it meant the mode it was in.
    private func vimKey(keyval: UInt32, state: UInt32) -> Bool? {
        guard Preferences.vimComposer, !asking, editor.hasFocus(in: window) else { return nil }
        let control = state & KeyChord.controlMask != 0
        let key = VimKey(
            character: Keymap.scalar(keyval),
            isEscape: keyval == Keymap.escape,
            isEnter: keyval == Keymap.enter || keyval == Keymap.keypadEnter,
            isBackspace: keyval == Keymap.backspace,
            control: control)
        if editor.vim.mode == .insert {
            guard key.isEscape || (control && Keymap.scalar(keyval) == "[") else { return nil }
            applyVim(VimKey(isEscape: true))
            return true
        }
        if key.isEscape { return nil }
        guard !control, state & KeyChord.altMask == 0 else { return nil }
        applyVim(key)
        return true
    }

    private func applyVim(_ key: VimKey) {
        let outcome = editor.vim.handle(key, text: editor.text, cursor: editor.cursor)
        switch outcome {
        case .handled: editor.write(editor.vim.document, selection: editor.vim.selection)
        case .passThrough: break
        case .send: submit()
        }
        updateVimBadge()
    }

    private func updateVimBadge() {
        editor.refreshMode()
        guard Preferences.vimComposer else {
            gtk_widget_set_visible(vimBadge, 0)
            return
        }
        gtk_widget_set_visible(vimBadge, 1)
        gtk_label_set_text(op(vimBadge), editor.vim.mode.label)
        gtk_widget_remove_css_class(vimBadge, "vim-badge-visual")
        gtk_widget_remove_css_class(vimBadge, "vim-badge-insert")
        switch editor.vim.mode {
        case .insert: Gtk.addClass(vimBadge, "vim-badge-insert")
        case .visual, .visualLine: Gtk.addClass(vimBadge, "vim-badge-visual")
        case .normal: break
        }
    }

    /// The powers are visibly on before the question is sent: the aim's own effort, or the word
    /// typed into the draft, lights the same rainbow the chat's box wears.
    private func refreshAura() {
        editor.setAura(
            effort: QuickAskDefaults.effort(forProfileID: targetServer.id), inFlight: false)
    }

    private func setHint(_ text: String) {
        gtk_label_set_text(op(hint), text)
    }

    /// The empty window's argument for itself: what this thing can be asked to do, offered
    /// against what the aim can take, and the last few questions asked here. It gets out of the
    /// way the moment there is a question and comes back if the entry is emptied again.
    private func renderStarters() {
        Gtk.removeChildren(of: starters)
        offered = QuickAskStarters.offered(for: abilities)
        gtk_box_append(ptr(starters), section(Localized.text("Try")))
        for (index, starter) in offered.enumerated() {
            gtk_box_append(
                ptr(starters),
                row(
                    glyph: starter.glyph, title: starter.title, detail: starter.detail,
                    keycap: index < 9 ? "alt+\(index + 1)" : nil
                ) { [weak self] in
                    Gtk.onMain { [weak self] in self?.pickStarter(at: index) }
                })
        }
        let asked = QuickAskRecents.asks(among: recents, profileID: targetServer.id)
        guard !asked.isEmpty else {
            refreshStarterVisibility()
            return
        }
        gtk_box_append(ptr(starters), section(Localized.text("Asked here")))
        for entry in asked {
            let title = AgentSession.isPlaceholderTitle(entry.session.title)
                ? Localized.text("Untitled question") : entry.session.title
            gtk_box_append(
                ptr(starters),
                row(
                    glyph: "↻", title: title, detail: Localized.text("asked %@ ago", SessionRowModel.age(of: entry.session.updatedAt)),
                    keycap: nil
                ) { [weak self] in
                    Gtk.onMain { [weak self] in self?.resume(entry) }
                })
        }
        refreshStarterVisibility()
    }

    private func section(_ text: String) -> UnsafeMutablePointer<GtkWidget> {
        Gtk.label(text, css: "ask-section", selectable: false)
    }

    /// One row, built rather than written: the glyph keeps its own column so every title starts at
    /// the same place, the detail is the quieter half of the same line, and the key that would do
    /// this without the mouse sits at the end wearing the shape of a key.
    private func row(
        glyph: String, title: String, detail: String, keycap: String?,
        onClick: @escaping @Sendable () -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "ask-row")
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        let mark = whole(Gtk.label(glyph, css: "ask-glyph", selectable: false))
        gtk_label_set_xalign(op(mark), 0.5)
        gtk_label_set_width_chars(op(mark), 2)
        gtk_widget_set_valign(mark, GTK_ALIGN_BASELINE)
        gtk_box_append(ptr(line), mark)
        let words = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_widget_set_hexpand(words, 1)
        gtk_widget_set_halign(words, GTK_ALIGN_START)
        gtk_box_append(
            ptr(words), whole(Gtk.label(title, css: "ask-row-title", selectable: false)))
        let note = Gtk.label(detail, css: "ask-row-detail", selectable: false)
        gtk_label_set_ellipsize(op(note), PANGO_ELLIPSIZE_END)
        gtk_box_append(ptr(words), note)
        gtk_box_append(ptr(line), words)
        if let keycap {
            let cap = whole(Gtk.label(keycap, css: "ask-keycap", selectable: false))
            gtk_widget_set_valign(cap, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(line), cap)
        }
        gtk_button_set_child(ptr(button), line)
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked", onClick)
        return button
    }

    /// A label that is never shortened. Every label in this app ellipsizes by default, which is
    /// right for a title that has to share a row with something bigger and wrong for the three
    /// words that say which key does this — "alt+…" is not a shortcut anybody can press.
    private func whole(_ label: UnsafeMutablePointer<GtkWidget>) -> UnsafeMutablePointer<GtkWidget>
    {
        gtk_label_set_ellipsize(op(label), PANGO_ELLIPSIZE_NONE)
        gtk_widget_set_hexpand(label, 0)
        return label
    }

    /// The rows are the empty state and nothing more, and a window that kept their height after
    /// they left would be a pane of dead space under the question: the toplevel is asked for its
    /// natural height again every time they come or go.
    private func refreshStarterVisibility() {
        let empty = editor.text.isEmpty && attachments.isEmpty
        let visible: Int32 = empty && !asking ? 1 : 0
        guard gtk_widget_get_visible(starters) != visible else { return }
        gtk_widget_set_visible(starters, visible)
        fitToContents()
    }

    /// The window is exactly as tall as what is in it, which means it has to be asked again every
    /// time that changes: a box that grew inside a window that did not would write the question
    /// off the bottom edge of its own surface.
    private func fitToContents() {
        gtk_window_set_default_size(ptr(window), 560, -1)
    }

    /// A starter is the first half of a sentence, never a question the app asked on somebody's
    /// behalf: the words land in the entry with the caret at their end, and a row that needs a
    /// file opens the chooser for it in the same gesture.
    private func pickStarter(at index: Int) {
        guard !asking, offered.indices.contains(index) else { return }
        let starter = offered[index]
        QuickAskStarterRecents.record(starter.id)
        if editor.text.isEmpty { write(starter.prompt) }
        editor.focus()
        refreshStarterVisibility()
        switch starter.opens {
        case .files, .photos: pickAttachments()
        case .camera, .none: break
        }
        AppLog.write(.ui, "ASK starter=\(starter.id)")
    }

    private func resume(_ entry: SessionEntry) {
        guard !asking else { return }
        let onResume = onResume
        let session = entry
        close()
        onResume(session)
    }

    private func pickAttachments() {
        guard !asking, abilities.attachments else { return }
        Gtk.openFiles(parent: window) { [weak self] paths in
            self?.take(paths: paths)
        }
    }

    /// Read fully at pick time, so a file edited or deleted between picking and sending still
    /// sends the bytes that were chosen; a refusal names its reason instead of shrinking a file.
    private func take(paths: [String]) {
        guard !asking, abilities.attachments else { return }
        for path in paths {
            switch AttachmentIntake.read(path: path) {
            case .success(let attachment):
                guard abilities.accepts(mime: attachment.mime) else {
                    setHint(Localized.text("This model can't read %@", attachment.name))
                    continue
                }
                attachments.append(attachment)
            case .failure(let refusal):
                setHint(refusal.message)
            }
        }
        renderAttachments()
    }

    /// The clipboard, whatever it is holding. A screenshot and a file copied in a file manager
    /// both become chips here rather than making a person save one and pick the other back up, and
    /// words go in at the caret. What the aim cannot be handed says so in the hint line.
    private func pasteFromClipboard() {
        guard !asking else { return }
        let able = abilities
        let named = pastedImageCount
        Gtk.readClipboard { offer in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                let plan = PasteIntake.plan(for: offer, abilities: able, alreadyNamed: named)
                self.pastedImageCount = plan.named
                if let text = plan.text, !text.isEmpty { self.editor.insertAtCaret(text) }
                if !plan.attachments.isEmpty {
                    self.attachments.append(contentsOf: plan.attachments)
                    self.renderAttachments()
                }
                if let notice = plan.notices.first { self.setHint(notice) }
            }
        }
    }

    private func renderAttachments() {
        Gtk.removeChildren(of: chips)
        gtk_widget_set_visible(chips, attachments.isEmpty ? 0 : 1)
        gtk_button_set_label(
            ptr(attach), attachments.isEmpty ? "📎" : "📎 \(attachments.count)")
        for attachment in attachments {
            let title = "\(attachment.name) · \(AttachmentIntake.sizeText(attachment.data.count))  ✕"
            let id = attachment.id
            gtk_box_append(
                ptr(chips),
                Gtk.button(title, css: ["chip"]) { [weak self] in
                    Gtk.onMain { [weak self] in
                        guard let self else { return }
                        self.attachments.removeAll { $0.id == id }
                        self.renderAttachments()
                    }
                })
        }
        refreshStarterVisibility()
    }

    /// The window outlives Enter the way the new-chat modal outlives Start: the mint happens on
    /// another machine, and a surface that vanished the instant a request went out could never
    /// say it failed. Success closes it; failure names itself and gives the words — and the
    /// pictures — back.
    private func submit() {
        guard !asking else { return }
        let text = editor.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard QuickAskComposition.canSend(text: text, attachments: attachments.count) else { return }
        asking = true
        completion?.dismiss()
        editor.setSensitive(false)
        gtk_widget_set_sensitive(attach, 0)
        gtk_widget_set_sensitive(send, 0)
        refreshStarterVisibility()
        setHint(QuickAskComposition.waitingTitle(server: targetServer.name))
        let server = targetServer
        let send = QuickAskSend.decide(
            text: text, commands: commands,
            resolvesFromPromptText: promptTextGrammar[server.id] == true)
        if case .command(let command, _) = send.kind { SlashRecents.record(command.name) }
        onAsk(server.id, send, attachments) { [weak self] failure in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                guard let failure else {
                    QuickAskDefaults.record(profileID: server.id)
                    DraftStore.clear(.quickAsk(profileID: server.id))
                    AppLog.write(.ui, "ASK sent server=\(server.name)")
                    self.close()
                    return
                }
                self.asking = false
                self.editor.setSensitive(true)
                gtk_widget_set_sensitive(self.attach, 1)
                self.refreshSend()
                self.editor.focus()
                self.setHint("\(failure.title) — \(failure.detail)")
                self.refreshStarterVisibility()
                AppLog.write(.ui, "ASK failed \(failure.title)")
            }
        }
    }

    func driveType(_ text: String) {
        write(text)
    }

    func driveGo() {
        submit()
    }

    func driveStarter(_ index: Int) {
        pickStarter(at: index)
    }

    private func close() {
        stashDraft()
        DraftStore.flush()
        completion?.tearDown()
        completion = nil
        if let summonWatch { NotificationCenter.default.removeObserver(summonWatch) }
        summonWatch = nil
        gtk_window_destroy(ptr(window))
        Self.open = nil
    }
}
