import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension QuickAskWindow {
    var targetServer: ConnectionProfile { servers[targetIndex] }

    static let aimStripCeiling = 5

    /// Every machine the question could go to, as one row of linked toggles above the field —
    /// each named with the agent that would answer, the aimed one pressed, the address a tooltip
    /// away — so re-aiming is one click rather than a menu opened and read. A fleet too wide for
    /// a row keeps the header's menu instead; one machine needs neither.
    func buildAimStrip() {
        guard (2...Self.aimStripCeiling).contains(servers.count) else {
            gtk_widget_set_visible(aimStrip, 0)
            gtk_widget_set_visible(target, servers.count > 1 ? 1 : 0)
            return
        }
        gtk_widget_set_visible(target, 0)
        var lead: UnsafeMutablePointer<GtkWidget>?
        for (index, server) in servers.enumerated() {
            let button = gtk_toggle_button_new()!
            let name = ServerLabel.display(server)
            let label = Gtk.label(name, wrap: true, selectable: false)
            gtk_label_set_xalign(op(label), 0.5)
            gtk_label_set_justify(op(label), GTK_JUSTIFY_CENTER)
            Gtk.fitWrap(label, to: name, ceiling: 28)
            gtk_button_set_child(ptr(button), label)
            Gtk.addClass(button, "ask-aim-segment")
            gtk_widget_set_tooltip_text(button, ServerLabel.address(server))
            gtk_widget_set_hexpand(button, 1)
            if let lead {
                gtk_toggle_button_set_group(ptr(button), ptr(lead))
            } else {
                lead = button
            }
            if index == targetIndex { gtk_toggle_button_set_active(ptr(button), 1) }
            let buttonHold = Gtk.WeakWidget(button)
            Gtk.connect(UnsafeMutableRawPointer(button), "toggled") {
                Gtk.onMain {
                    guard let held = buttonHold.widget else { return }
                    let toggle: UnsafeMutablePointer<GtkToggleButton> = ptr(held)
                    guard gtk_toggle_button_get_active(toggle) != 0,
                        let window = QuickAskWindow.open, !window.asking
                    else { return }
                    window.retarget(to: index)
                }
            }
            aimToggles.append(button)
            gtk_box_append(ptr(aimStrip), button)
        }
    }

    /// The pressed segment follows the aim wherever it was moved from — Tab, the model chooser
    /// landing on another machine — and a segment already pressed is left alone, since pressing
    /// it again is what fires the retarget it would be answering.
    func syncAimStrip() {
        guard aimToggles.indices.contains(targetIndex) else { return }
        let toggle: UnsafeMutablePointer<GtkToggleButton> = ptr(aimToggles[targetIndex])
        guard gtk_toggle_button_get_active(toggle) == 0 else { return }
        gtk_toggle_button_set_active(toggle, 1)
    }

    var draftScope: DraftScope { .quickAsk(profileID: targetServer.id) }

    /// A question survives the surface it was being written in: the window is opened by a chord
    /// pressed in the middle of something else and closed by the same reflex, so what is in the
    /// entry is filed as it is typed and handed back the next time this machine is aimed at.
    func stashDraft() {
        guard !asking else { return }
        DraftStore.record(editor.text, for: draftScope)
    }

    func restoreDraft() {
        let draft = DraftStore.text(for: draftScope)
        guard !draft.isEmpty else { return }
        write(draft)
    }

    /// Every path that puts words in the box lands here, so the vim document that shadows it is
    /// never left describing a draft that has been replaced underneath it.
    func write(_ text: String) {
        editor.setText(text)
        editor.vim.reset(to: text, cursor: text.count, mode: .insert)
        updateVimBadge()
    }

    /// Moving the question to another machine leaves the words filed under the one being left and
    /// hands back whatever was last written for the one arrived at, the way re-aiming Home's
    /// composer does — a draft belongs to the machine it was written for.
    func retarget(to index: Int) {
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
    func loadCommands() {
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

    func updateSlashCompletion() {
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

    func acceptSlashCommand(_ command: AgentCommand) {
        SlashRecents.record(command.name)
        write(command.takesArguments ? "/\(command.name) " : "/\(command.name)")
        editor.focus()
        updateSlashCompletion()
    }

    func cycleTarget() {
        guard servers.count > 1, !asking else { return }
        retarget(to: (targetIndex + 1) % servers.count)
        AppLog.write(.ui, "ASK target=\(targetServer.name)")
    }

    /// The whole catalog, from the fleet's own cache — a machine's models are a fact about that
    /// machine, so the chooser can name what another server runs without this ask ever having
    /// talked to it, and a pick landing there re-aims the question rather than moving a chat.
    func chooseModel() {
        guard !asking else { return }
        let server = targetServer
        ModelChooserWindow.present(
            sources: ModelFleet.sources(profiles: servers, current: server.id),
            selected: QuickAskDefaults.model(forProfileID: server.id), parent: window,
            onRefresh: { [weak self] in self?.refreshModelCatalog(for: server) }
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

    /// A press in the open chooser: this window draws the catalog out of the fleet's cache, which
    /// is only ever as new as the last time something asked that machine. Asking it again is the
    /// one road to a model the server picked up since.
    func refreshModelCatalog(for server: ConnectionProfile) {
        Task { [weak self] in
            guard let backend = await ServerDirectory.shared.backend(for: server) else { return }
            _ = await ModelCatalogWatch.refreshOnce(profileID: server.id, backend: backend)
            Gtk.onMain { [weak self] in
                guard let self else { return }
                ModelChooserWindow.updateOpen(
                    sources: ModelFleet.sources(profiles: self.servers, current: server.id))
            }
        }
    }

    /// What the aim can be handed, re-read whenever either half of it moves. A picture already in
    /// the strip that the new model cannot read is dropped out loud rather than carried to a send
    /// the other machine would refuse.
    var abilities: ModelAbilities {
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
    func serverRows() -> [(title: String, detail: String?, action: @Sendable () -> Void)] {
        servers.enumerated().map { index, server in
            let aimed = index == targetIndex
            return (
                (aimed ? "✓ " : "") + server.name + " · " + ServerLabel.agent(server.backend),
                server.baseURL.absoluteString,
                { Gtk.onMain { QuickAskWindow.open?.retarget(to: index) } }
            )
        }
    }

    /// The dial as it would open now: the fleet with the aimed machine first, the quick ask's own
    /// model and level on that machine, and the levels that model takes.
    func dialState() -> ModelDialState {
        let server = targetServer
        return ModelDialState(
            sources: ModelFleet.sources(profiles: servers, current: server.id),
            selected: QuickAskDefaults.model(forProfileID: server.id),
            effort: QuickAskDefaults.effort(forProfileID: server.id), options: effortOptions(),
            modelWord: modelWord(), agentOptions: agentEfforts[server.id] ?? [])
    }

    /// One notch of the wheel or one chord: the level moves one stop along the aimed model's own
    /// ladder, pinned at the ends, and the dial shows where it landed; a screen reader is told.
    func stepEffort(by delta: Int) {
        guard !asking else { return }
        let server = targetServer
        let options = effortOptions()
        guard ModelEffort.isOffered(options: options) else {
            setHint(ModelDial.headline(modelName: modelWord(), options: []))
            return
        }
        let current = ModelEffort.surviving(
            QuickAskDefaults.effort(forProfileID: server.id), options: options)
        let notch = ModelDial.notch(from: current, by: delta, options: options)
        if notch.level != current { setEffort(notch.level, on: server.id, refocus: false) }
        effortVoice.note(notch)
    }

    func announceEffort(_ words: String) {
        guard tailscode_can_announce() != 0, !words.isEmpty else { return }
        tailscode_accessible_announce(window, words, 0)
    }

    func modelWord() -> String {
        let server = targetServer
        let picked = QuickAskDefaults.model(forProfileID: server.id)
        let catalog = ModelCatalogStore.cached(server.id)
        return picked == nil && catalog.isEmpty
            ? Localized.text("Model…") : ModelBadge.label(model: picked, effort: nil, catalog: catalog)
    }

    func modelTintClass() -> String? {
        let server = targetServer
        guard let picked = QuickAskDefaults.model(forProfileID: server.id),
            let chip = ModelBadge.chip(
                model: picked.modelID, effort: nil, providerID: nil,
                catalog: ModelCatalogStore.cached(server.id))
        else { return nil }
        return ModelTint.identityClass(family: chip.family, name: chip.name)
    }

    /// A row from the dial: the server's own choice is filed against the aimed machine, a model
    /// against the machine that runs it — which re-aims the question there when that is not the
    /// machine already aimed at. The level the dial showed for the row goes with it, into the
    /// quick ask's own memory for that machine and never the chat's.
    func pick(_ pick: ModelPick, effort: EffortAsk, notice: String?) {
        let profileID = pick.profileID.isEmpty ? targetServer.id : pick.profileID
        if pick.selection == nil, !pick.isElsewhere {
            QuickAskDefaults.recordModel(nil, forProfileID: targetServer.id)
        } else {
            QuickAskDefaults.adopt(pick)
        }
        if case .set(let level) = effort {
            QuickAskDefaults.recordEffort(level, forProfileID: profileID)
        }
        if pick.selection != nil || pick.isElsewhere,
            let index = servers.firstIndex(where: { $0.id == pick.profileID })
        {
            retarget(to: index)
        }
        refreshTarget()
        if let notice { setHint(notice) }
        editor.focus()
    }

    /// The catalog is asked once per aim, in the background: a server that has never been
    /// opened has an empty cache, and a model chip hidden for that read as "this server has
    /// no models" when the truth was only that nobody had asked yet.
    func watchCatalog() {
        catalogWatch?.cancel()
        let server = targetServer
        catalogWatch = Task { [weak self] in
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

    func refreshTarget() {
        let server = targetServer
        syncAimStrip()
        gtk_menu_button_set_label(op(target), server.name + " · " + ServerLabel.agent(server.backend))
        adw_window_title_set_subtitle(
            op(UnsafeMutableRawPointer(title)), Self.subtitle())
        let levels = effortOptions()
        dropUnofferedEffort(on: server.id, options: levels)
        dial.render(
            ModelDial.face(
                modelWord: modelWord(), effort: QuickAskDefaults.effort(forProfileID: server.id),
                options: levels),
            modelTint: modelTintClass())
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
}
