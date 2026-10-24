import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension ChatPane {
    /// One pill for the model and the effort, because on a desk they are one decision: a tinted
    /// dot, the model's word, the level's word in its own heat, and a five-bar meter that says
    /// the tier before the word does. The wheel over it steps the level without opening anything.
    func makeDialPill() -> UnsafeMutablePointer<GtkWidget> {
        let popover = ModelDialPopover(
            makeState: { [weak self] in
                self?.dialState()
                    ?? ModelDialState(
                        sources: [], selected: nil, effort: nil, options: [], modelWord: "")
            },
            onPick: { [weak self] pick, effort, notice in
                Gtk.onMain { [weak self] in
                    self?.take(pick, effort: effort, notice: notice)
                }
            },
            onEffort: { [weak self] level in
                Gtk.onMain { [weak self] in self?.setChosenEffort(level) }
            },
            onOpenCatalog: { [weak self] in
                Gtk.onMain { [weak self] in self?.openModelChooser() }
            })
        let pill = DialPill(css: ["chip-ctl"], dial: popover, party: makePartyPopover()) {
            [weak self] delta in
            self?.stepEffort(by: delta)
        }
        dial = pill
        return pill.button
    }

    /// The dial as it would open right now: this pane's fleet, pick, level and the levels the
    /// model takes, read fresh so a wheel notch or a pick since the last open is what it shows.
    func dialState() -> ModelDialState {
        ModelDialState(
            sources: modelSources(), selected: chosenModel ?? activeSelection,
            effort: resolvedEffort(), options: effortOptions(), modelWord: modelPillText(),
            quotas: modelQuotas(), agentOptions: backend?.reasoningEffortOptions ?? [])
    }

    /// A row taken in the dial: the model first, then the level the ladder showed for it through
    /// the same road a live step takes, and the carry said once — by the dial, which saw it,
    /// rather than again by the model change underneath.
    func take(_ pick: ModelPick, effort: EffortAsk, notice: String?) {
        if pick.isElsewhere {
            continueElsewhere(pick) {
                if case .set(let level) = effort {
                    EffortPreferenceStore.recordPick(
                        level, sessionKey: nil, contextID: pick.profileID)
                    SettingsFile.capture()
                }
            }
            return
        }
        guard case .set(let level) = effort else {
            setChosenModel(pick.selection)
            return
        }
        setChosenModel(pick.selection, announcing: false)
        setChosenEffort(level)
        if let notice { host?.toast(notice) }
    }

    /// One notch of the wheel or one chord from the editor: the level moves one stop along the
    /// model's own ladder, pinned at the ends, and the pill's word and bars are the whole answer to
    /// anyone who can see them — nothing is written over a step, at either end or anywhere between.
    /// A screen reader is told where the level landed, or that it is pinned, once the hand
    /// pauses. Only a model that takes no level at all speaks on screen, because there the wheel
    /// is inert and the pill has nothing to show.
    func stepEffort(by delta: Int) {
        let options = effortOptions()
        guard ModelEffort.isOffered(options: options) else {
            host?.flash(ModelDial.headline(modelName: modelPillText(), options: []))
            return
        }
        let notch = ModelDial.notch(from: resolvedEffort(), by: delta, options: options)
        effortVoice.note(notch)
        guard notch.level != resolvedEffort() else { return }
        setChosenEffort(notch.level)
    }

    /// The ring this chat's machine can run: the party's filled slots in slot order, and while the
    /// party is empty the pinned pairs in the order they were pinned.
    func reachablePresets() -> [ModelPreset] {
        let accepts =
            modelSources().first { $0.profileID == entry?.profileID }?.acceptsAnyModelID
            ?? (backend?.agentType == .claudeCode)
        return ModelPresetCycle.reachable(
            ModelParty.ring(), models: models, acceptsAnyModelID: accepts)
    }

    /// ⌃⌥←/→: the next pinned pair round the ring, from the one this chat runs now.
    func stepPreset(by delta: Int) {
        let presets = reachablePresets()
        guard
            let preset = ModelPresetCycle.step(
                presets, model: chosenModel ?? activeSelection, effort: resolvedEffort(), by: delta)
        else {
            host?.flash(Localized.text("Pin a model and level with ⌃S in the model dial"))
            return
        }
        take(preset)
    }

    /// ⌃⌥1–9. While the party holds anything, 1 to 6 are the slots themselves: the nth slot, or
    /// the word for why it cannot be taken here. With an empty party the nth pinned pair this
    /// machine can run, as before.
    func takePreset(number: Int) {
        if (1...ModelParty.size).contains(number), !ModelParty.presets().isEmpty {
            takeSlot(number)
            return
        }
        let presets = reachablePresets()
        guard !presets.isEmpty else {
            host?.flash(Localized.text("Pin a model and level with ⌃S in the model dial"))
            return
        }
        guard presets.indices.contains(number - 1) else { return }
        take(presets[number - 1])
    }

    /// A pair is a model pick followed by its level, so the level goes through the same carry any
    /// pick does and the toast says what the chat now runs at, and what moved if anything did.
    func take(_ preset: ModelPreset) {
        let carry = preset.applied(
            currentEffort: resolvedEffort(), models: models,
            agentOptions: backend?.reasoningEffortOptions ?? [])
        setChosenModel(preset.selection, announcing: false)
        setChosenEffort(carry.level)
        let name = modelName(of: preset.selection)
        let said = ModelPresetCycle.said(preset, modelName: name)
        host?.flash(carry.notice(modelName: name).map { said + " — " + $0 } ?? said)
    }

    func modelName(of selection: ModelSelection) -> String {
        models.first { $0.providerID == selection.providerID && $0.id == selection.modelID }?.name
            ?? models.first { $0.id == selection.modelID }?.name
            ?? ModelBadge.label(model: selection, effort: nil, catalog: models)
    }

    func openModelDial() {
        dial?.openDial()
    }

    func openParty() {
        dial?.open()
    }

    func renderDial(_ face: DialFace) {
        dial?.render(face, modelTint: modelTintClass())
        queueLaneFit()
    }

    func modelTintClass() -> String? {
        guard let active = activeModelID, let chip = ModelBadge.chip(
                model: active, effort: nil, providerID: nil, catalog: models)
        else { return nil }
        return ModelTint.identityClass(family: chip.family, name: chip.name)
    }

    /// What the chat is actually being answered by: the explicit pick, else the model observed on
    /// the last assistant turn, else the session's own record.
    var activeModelID: String? {
        chosenModel?.modelID ?? observedModelID() ?? entry?.session.model
    }

    /// The model a send from here would run on, with the door it runs through — the pick, else
    /// the transcript's own record, else the session's, resolved against the catalog before the
    /// door is given up. Every quota reading bills against this.
    var activeSelection: ModelSelection? {
        ActiveModel.selection(
            picked: chosenModel, messages: lastState?.messages ?? [], session: entry?.session,
            catalog: models)
    }

    func modelPillText() -> String {
        if let chosenModel { return ModelBadge.word(for: chosenModel, in: models) }
        if let observed = observedModelID() {
            return ModelBadge.label(
                model: ModelSelection(providerID: "server", modelID: observed), effort: nil, catalog: models)
        }
        if let stored = entry?.session.model {
            return ModelBadge.label(
                model: ModelSelection(providerID: "server", modelID: stored), effort: nil, catalog: models)
        }
        return Localized.text("model")
    }

    func observedModelID() -> String? {
        guard let messages = lastState?.messages else { return nil }
        for message in messages.reversed() where message.role == .assistant {
            if let id = message.modelID, !id.isEmpty { return id }
        }
        return nil
    }

    /// The level a send from here would carry, or nil for the server deciding: the pick, else
    /// the session's own record, else what the last answer ran at — each surviving what the
    /// model actually takes, so a stranded level is the server's choice rather than a word.
    func resolvedEffort() -> String? {
        let options = effortOptions()
        guard !options.isEmpty else { return nil }
        if let kept = ModelEffort.surviving(chosenEffort, options: options) { return kept }
        if let stored = ModelEffort.surviving(entry?.session.reasoningEffort, options: options) {
            return stored
        }
        return ModelEffort.surviving(observedEffort(), options: options)
    }

    func observedEffort() -> String? {
        guard let messages = lastState?.messages else { return nil }
        for message in messages.reversed() where message.role == .assistant {
            if let effort = message.reasoningEffort, !effort.isEmpty { return effort }
        }
        return nil
    }

    /// Effort is a property of the model on servers whose catalog says so; the backend-wide list
    /// is the fallback for agents where every model takes the same levels. The rule is Core's, so
    /// what this offers and what the phone offers for the same model can never differ.
    func effortOptions() -> [String] {
        ModelEffort.options(
            models: models,
            selection: chosenModel
                ?? activeModelID.map { ModelSelection(providerID: "server", modelID: $0) },
            agentOptions: backend?.reasoningEffortOptions ?? [])
    }

    /// What the picked model can be handed. A capability is the model's far more often than the
    /// server's — one opencode machine fronts a hundred, and half of them cannot see a picture.
    var abilities: ModelAbilities {
        ModelAbilities.resolve(
            supportsAttachments: backend?.capabilities.supportsAttachments != false,
            models: models,
            selection: chosenModel
                ?? activeModelID.map { ModelSelection(providerID: "server", modelID: $0) })
    }

    func openModelChooser() {
        ModelChooserWindow.present(
            sources: modelSources(), selected: chosenModel,
            parent: host?.windowWidget ?? root, quotas: modelQuotas(),
            onRefresh: { [weak self] in self?.refreshModelCatalog() },
            onAddToParty: { [weak self] pick, anchor in
                let bits = UInt(bitPattern: anchor)
                Gtk.onMain { [weak self] in
                    guard let held = UnsafeMutablePointer<GtkWidget>(bitPattern: bits) else { return }
                    self?.addToParty(pick, on: held)
                }
            }
        ) { [weak self] pick in
            Gtk.onMain { [weak self] in self?.apply(pick) }
        }
    }

    /// A press in the open chooser, not a restart: the watch behind `models` already gave up
    /// re-asking once the server answered, so a model that server picked up since — a llama-swap
    /// entry just wired in, say — needs its own ask rather than waiting for this pane to reopen.
    func refreshModelCatalog() {
        guard let backend, let profileID = entry?.profileID, let sessionID else { return }
        track(Task { [weak self] in
            let reading = await ModelCatalogWatch.refreshOnce(profileID: profileID, backend: backend)
            Gtk.onMain { [weak self] in
                guard let self, self.sessionID == sessionID else { return }
                self.models = reading.models
                self.modelsReachable = reading.reachable
                ModelChooserWindow.updateOpen(sources: self.modelSources())
                self.refreshPills()
            }
        })
    }

    /// Every server this app is connected to, with this pane's own at the front. A catalog is a
    /// fact about a machine, so the list can name what the other machine runs without this pane
    /// ever having talked to it — and whether this one answered its last ask, so a restart reads
    /// as a state rather than a machine with no models.
    func modelSources() -> [ModelSource] {
        let profiles = host?.fleetProfiles() ?? []
        var reachability: [String: Bool] = [:]
        if let profileID = entry?.profileID, let reachable = modelsReachable {
            reachability[profileID] = reachable
        }
        let sources = ModelFleet.sources(
            profiles: profiles, current: entry?.profileID, currentModels: models,
            reachability: reachability)
        guard sources.isEmpty else { return sources }
        return [
            ModelSource(
                profileID: entry?.profileID ?? "", name: "", backend: backend?.agentType ?? .openCode,
                models: models, isCurrent: true, allowsServerDefault: true,
                acceptsAnyModelID: backend?.agentType == .claudeCode,
                isReachable: modelsReachable)
        ]
    }

    /// A model on this machine changes what this chat runs. A model on another one cannot: the
    /// conversation is a process on the machine that answers it, so the pick is remembered as that
    /// server's own choice and the pane opens a new chat there.
    func apply(_ pick: ModelPick) {
        guard pick.isElsewhere else {
            setChosenModel(pick.selection)
            return
        }
        continueElsewhere(pick)
    }

    /// A level the new model has no word for moves to the nearest cooler one it takes and is said
    /// aloud; `announcing` is false where the caller sets the level itself and says it once.
    func setChosenModel(_ selection: ModelSelection?, announcing: Bool = true) {
        chosenModel = selection
        if let entry {
            ModelPreferenceStore.recordPick(
                selection, sessionKey: Self.preferenceKey(entry), contextID: entry.profileID)
        }
        let carry = ModelEffort.adoption(
            chosenEffort, for: selection, models: models,
            agentOptions: backend?.reasoningEffortOptions ?? [])
        if announcing, let notice = carry.notice(modelName: selection.map(modelName(of:)) ?? modelPillText()) {
            host?.toast(notice)
        }
        if carry.level != chosenEffort {
            setChosenEffort(carry.level)
            return
        }
        if let entry {
            SettingsFile.capture()
        }
        refreshPills()
        updateStatus()
    }

    func setChosenEffort(_ level: String?) {
        chosenEffort = level
        if let entry {
            EffortPreferenceStore.recordPick(
                level, sessionKey: Self.preferenceKey(entry), contextID: entry.profileID)
            SettingsFile.capture()
        }
        refreshPills()
        refreshUltracodeAura()
        updateStatus()
    }

    static func preferenceKey(_ entry: SessionEntry) -> String {
        "\(entry.profileID)/\(entry.session.id)"
    }

    func refreshUltracodeAura() {
        let was = editor.auraActive
        editor.setAura(effort: chosenEffort, inFlight: ultracodeInFlight)
        if editor.auraActive != was { host?.refreshOrb() }
    }
}
