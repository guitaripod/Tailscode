import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

extension QuickAskPanel {
    var targetServer: ConnectionProfile {
        servers.first { $0.id == aimedServerID } ?? servers[0]
    }

    /// One step along the strip, wrapping at either end, so the same key pressed enough times
    /// reaches every machine and comes back.
    func cycleServer(by delta: Int) {
        guard servers.count > 1, !asking,
            let current = servers.firstIndex(where: { $0.id == targetServer.id })
        else { return }
        let count = servers.count
        aim(at: servers[((current + delta) % count + count) % count].id)
        refreshAim()
        editor.focus()
    }

    /// A question survives the surface it was being written in: the panel is opened by a chord
    /// pressed in the middle of something else and closed by the same reflex, so what is in the
    /// field is filed as it is typed and handed back the next time this machine is aimed at.
    func stashDraft() {
        guard !asking else { return }
        DraftStore.record(editor.text, for: draftScope)
    }

    func restoreDraft() {
        draftProfileID = targetServer.id
        let draft = DraftStore.text(for: draftScope)
        guard !draft.isEmpty else { return }
        editor.setText(draft, caretAtEnd: true)
        refreshStarterVisibility()
    }

    /// Moving the question to another machine leaves the words filed under the one being left and
    /// hands back whatever was last written for the one arrived at — a draft belongs to the
    /// machine it was written for, the way a chat's belongs to the chat.
    private func retargetDraft() {
        guard let previous = draftProfileID, previous != targetServer.id else {
            draftProfileID = targetServer.id
            return
        }
        DraftStore.record(editor.text, for: .quickAsk(profileID: previous))
        draftProfileID = targetServer.id
        editor.setText(DraftStore.text(for: draftScope), caretAtEnd: true)
        refreshStarterVisibility()
    }

    /// The ⌥M entry: the dial opened on its own pill.
    func chooseModel() {
        openModelDial()
    }

    /// The dial over the quick ask's own memory: the shortlist is the fleet's, from every server's
    /// own cache — a machine's models are a fact about that machine, so the column can name what
    /// another server runs without this ask ever having talked to it, and a pick landing there
    /// re-aims the question rather than moving a chat. A level is live and keeps the dial open; a
    /// model is committed by the press and closes it, the way the composer's does. Pressing the
    /// pill while the dial is open closes it, the way a menu does — and a transient popover has
    /// already closed itself on the press that reaches the pill, so a press inside a breath of
    /// that close is the same press.
    func openModelDial() {
        guard !asking else { return }
        if let dialPopover, dialPopover.isShown {
            dialPopover.close()
            return
        }
        if let dialClosedAt, Date().timeIntervalSince(dialClosedAt) < 0.3 { return }
        dialPopover = ModelDialPopover.present(
            from: dialPill, state: dialState(),
            onEffort: { [weak self] level in
                guard let self else { return }
                QuickAskDefaults.recordEffort(level, forProfileID: self.targetServer.id)
                self.refreshAim()
            },
            onPick: { [weak self] pick, effort, notice in
                self?.takePick(pick, effort: effort, notice: notice)
            },
            onOpenCatalog: { [weak self] in self?.openModelDirectoryNow() },
            onPinned: { [weak self] preset in
                ModelPresetStore.pin(preset)
                self?.refreshAim()
            },
            onClosed: { [weak self] in
                self?.dialPopover = nil
                self?.dialClosedAt = Date()
                self?.editor.focus()
            })
    }

    /// The server's own default is a real answer on the machine already aimed at, and it is
    /// filed there rather than adopted: `adopt` re-aims at the pick's server, which for a default
    /// picked here is the server the question is already on. The level follows the model into the
    /// quick ask's own memory — the pair's level where the dial showed one, otherwise the level
    /// already remembered, carried to the nearest cooler one the model takes — and a level that
    /// moved is said on the status line, never in the chat's composer.
    private func takePick(_ pick: ModelPick, effort: EffortAsk = .unchanged, notice: String? = nil) {
        let profileID: String
        if pick.selection == nil, !pick.isElsewhere {
            profileID = targetServer.id
            QuickAskDefaults.recordModel(nil, forProfileID: profileID)
        } else {
            profileID = pick.profileID
            QuickAskDefaults.adopt(pick)
            aim(at: pick.profileID)
        }
        let asked: String?
        switch effort {
        case .unchanged: asked = QuickAskDefaults.effort(forProfileID: profileID)
        case .set(let level): asked = level
        }
        let agent =
            servers.first { $0.id == profileID }
            .flatMap { ServerDirectory.shared.backend(for: $0)?.reasoningEffortOptions } ?? []
        let carry = ModelEffort.adoption(
            asked, for: pick.selection, models: ModelCatalogStore.cached(profileID),
            agentOptions: agent)
        if effort != .unchanged || carry.level != asked {
            QuickAskDefaults.recordEffort(carry.level, forProfileID: profileID)
        }
        refreshAim()
        let name = pick.modelName.isEmpty
            ? ModelBadge.label(
                model: pick.selection, effort: nil, catalog: ModelCatalogStore.cached(profileID))
            : pick.modelName
        if let said = notice ?? carry.notice(modelName: name), !asking { setStatus(said) }
        editor.focus()
    }

    private func dialState() -> ModelDialState {
        let server = targetServer
        return ModelDialState(
            sources: chooserSources(for: server),
            selected: QuickAskDefaults.model(forProfileID: server.id),
            effort: QuickAskDefaults.effort(forProfileID: server.id), options: effortOptions(),
            modelWord: modelWord(for: server), quotas: [],
            agentOptions: ServerDirectory.shared.backend(for: server)?.reasoningEffortOptions ?? [])
    }

    /// One notch of the wheel or one ⌃⌥ arrow: the next stop cold-to-hot from the level the dial
    /// shows, pinned at both ends. Nothing opens; the pill and the status line are the whole
    /// answer, and a model that takes no level says so rather than letting the wheel turn mute.
    func stepEffort(by delta: Int) {
        guard !asking else { return }
        let server = targetServer
        let options = effortOptions()
        guard ModelEffort.isOffered(options: options) else {
            setStatus(ModelDial.headline(modelName: modelWord(for: server), options: []))
            return
        }
        let current = QuickAskDefaults.effort(forProfileID: server.id)
        let notch = ModelDial.notch(from: current, by: delta, options: options)
        if notch.level != current {
            QuickAskDefaults.recordEffort(notch.level, forProfileID: server.id)
            refreshAim()
        }
        EffortSpeech.note(notch)
    }

    /// The catalog is asked once per aim, in the background: a server that has never been
    /// opened has an empty cache, and a model chip hidden for that read as "this server has
    /// no models" when the truth was only that nobody had asked yet. Once per aim is the whole
    /// contract — every reading redraws the aim, and a redraw that restarted the watch was a watch
    /// whose first reading restarted it again, rebuilding the open dial under the pointer faster
    /// than a click could land on a row.
    private func watchCatalog() {
        guard watchedServerID != targetServer.id else { return }
        watchedServerID = targetServer.id
        catalogWatch?.cancel()
        catalogWatch = Task { [weak self] in
            guard let self else { return }
            let server = self.targetServer
            guard let backend = ServerDirectory.shared.backend(for: server) else { return }
            for await reading in ModelCatalogWatch.readings(
                profileID: server.id, backend: backend)
            {
                guard self.targetServer.id == server.id else { return }
                ModelCatalogStore.store(reading.models, for: server.id)
                await MainActor.run { self.refreshAim() }
            }
        }
    }

    private func openModelDirectoryNow() {
        let server = targetServer
        watchedServerID = server.id
        catalogWatch?.cancel()
        catalogWatch = Task { [weak self] in
            guard let self else { return }
            guard let backend = ServerDirectory.shared.backend(for: server) else { return }
            for await reading in ModelCatalogWatch.readings(profileID: server.id, backend: backend)
            {
                guard self.targetServer.id == server.id else { return }
                self.modelSheet?.update(
                    sources: self.chooserSources(
                        for: server, models: reading.models, reachable: reading.reachable))
                self.refreshAim()
            }
        }
        modelSheet = ModelChooserSheet.present(
            on: self, sources: chooserSources(for: server),
            selected: QuickAskDefaults.model(forProfileID: server.id)
        ) { [weak self] pick in
            QuickAskDefaults.adopt(pick)
            self?.modelSheet = nil
            self?.aim(at: pick.profileID)
            self?.refreshAim()
        }
    }

    private func chooserSources(
        for server: ConnectionProfile, models: [ModelInfo]? = nil, reachable: Bool? = nil
    ) -> [ModelSource] {
        ModelChooserSheet.fleetSources(
            profiles: servers, current: server.id,
            currentModels: models ?? ModelCatalogStore.cached(server.id), backend: server.backend,
            allowsServerDefault: server.backend == .claudeCode, reachable: reachable)
    }

    func aim(at profileID: String) {
        aimedServerID = profileID
        retargetDraft()
        refreshCommands()
    }

    /// How hard the machine is asked to think, which is half of what a question costs and the
    /// other half of the aim: the levels are the picked model's own where the catalog names them
    /// and the agent's otherwise, and a pick is the quick ask's own memory on that server rather
    /// than the machine's — the same bargain the dial's model half strikes.
    private func effortOptions() -> [String] {
        let server = targetServer
        let agent = ServerDirectory.shared.backend(for: server)?.reasoningEffortOptions ?? []
        return ModelEffort.options(
            models: ModelCatalogStore.cached(server.id),
            selection: QuickAskDefaults.model(forProfileID: server.id), agentOptions: agent)
    }

    /// The pill's second half, and the open dial with it: the level the aim remembers against
    /// what the picked model takes, drawn as heat rather than named in a menu.
    private func refreshEffort() {
        let server = targetServer
        let options = effortOptions()
        dropUnofferedEffort(on: server.id, options: options)
        let picked = QuickAskDefaults.model(forProfileID: server.id)
        dialPill.setFace(
            ModelDial.face(
                modelWord: modelWord(for: server),
                effort: QuickAskDefaults.effort(forProfileID: server.id), options: options),
            modelTint: picked.flatMap {
                ModelBadge.chip(
                    model: $0.modelID, effort: nil, providerID: nil,
                    catalog: ModelCatalogStore.cached(server.id))
            }
                .map(MacTheme.Color.modelIdentity))
        if let dialPopover, dialPopover.isShown { dialPopover.update(state: dialState()) }
    }

    /// The word the pill wears for the model: the pick's own, the server's memory where the
    /// catalog has been read, and "Model…" only while nothing is picked and nobody has asked the
    /// catalog yet — a blank word would read as a machine with no models.
    private func modelWord(for server: ConnectionProfile) -> String {
        let catalog = ModelCatalogStore.cached(server.id)
        guard let picked = QuickAskDefaults.model(forProfileID: server.id) else {
            return catalog.isEmpty
                ? Localized.text("Model…")
                : ModelBadge.label(model: nil, effort: nil, catalog: catalog)
        }
        return ModelBadge.word(for: picked, in: catalog)
    }

    /// A model whose levels are its own can make the level already picked unrunnable. The aim
    /// then carries it to the nearest cooler level the model takes, or hands it back to the
    /// machine where there is none, rather than keeping a word the question could not be asked
    /// with — a control may never name a level the send would not carry.
    private func dropUnofferedEffort(on profileID: String, options: [String]) {
        guard let chosen = QuickAskDefaults.effort(forProfileID: profileID), !chosen.isEmpty,
            !options.contains(chosen)
        else { return }
        QuickAskDefaults.recordEffort(
            ModelEffort.carry(chosen, options: options).level, forProfileID: profileID)
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

    /// The strip and the dial name what the question will actually run on, and the line under
    /// them says how to send — with one server that line also names the machine, which the hidden
    /// strip no longer can.
    func refreshAim() {
        let server = targetServer
        aimStrip.select(id: server.id)
        watchCatalog()
        refreshEffort()
        let able = abilities
        attachButton.isHidden = !able.attachments
        refreshAura()
        let kept = attachments.filter { able.accepts(mime: $0.mime) }
        let dropped = attachments.count - kept.count
        attachments = kept
        syncAttachments()
        renderStarters()
        guard !asking else { return }
        setStatus(
            dropped > 0
                ? QuickAskComposition.droppedNotice(count: dropped)
                : (servers.count < 2
                    ? Localized.text("Asks %@ — enter sends, esc closes", server.name)
                    : Localized.text("Enter sends, tab switches server, esc closes")))
    }

    /// What a number chord picks, in the order the picks are drawn: the copied thing's errands
    /// first, because a summon with something new on the pasteboard is most likely about it, and
    /// the starters after them.
    enum Pick {
        case errand(QuickAskClipboardErrand)
        case starter(Int)
    }
}
