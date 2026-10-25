import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

extension QuickAskPanel {
    /// A press on the model pill opens the party; with ⌥ held it opens the dial, the way to the
    /// effort ladder and the whole shortlist, exactly as the chat's pill does.
    func pressModelPill() {
        if NSEvent.modifierFlags.contains(.option) {
            openModelDial()
        } else {
            openModelParty()
        }
    }

    /// The six cards as they read from this aim: the aimed machine first, then every other the
    /// panel can reach, and the one in use is the slot the aim's model and level already match.
    func partyCards() -> [PartyCard] {
        let server = targetServer
        return PartyReading.cards(
            slots: ModelParty.slots(), sources: chooserSources(for: server),
            model: QuickAskDefaults.model(forProfileID: server.id),
            effort: QuickAskDefaults.effort(forProfileID: server.id),
            agentOptions: agentOptions(forProfileID: server.id))
    }

    private func agentOptions(forProfileID profileID: String) -> [String] {
        servers.first { $0.id == profileID }
            .flatMap { ServerDirectory.shared.backend(for: $0)?.reasoningEffortOptions } ?? []
    }

    private func partyRecents() -> [PartyRecent] {
        PartyReading.recents(
            slots: ModelParty.slots(), sources: chooserSources(for: targetServer))
    }

    private func partyLevels(of card: PartyCard) -> [String] {
        guard let preset = card.resolved ?? card.preset else { return [] }
        let catalog =
            chooserSources(for: targetServer).first { $0.profileID == card.profileID }?.models
            ?? ModelCatalogStore.cached(targetServer.id)
        return ModelEffort.options(
            models: catalog, selection: preset.selection,
            agentOptions: agentOptions(forProfileID: card.profileID ?? targetServer.id))
    }

    private func partyModel() -> PartyPanelModel {
        PartyPanelModel(
            cards: { [weak self] in self?.partyCards() ?? [] },
            recents: { [weak self] in self?.partyRecents() ?? [] },
            levels: { [weak self] card in self?.partyLevels(of: card) ?? [] },
            isRunning: { false })
    }

    /// The party opened on the model pill, below it where there is room and above where there is
    /// not, since this panel can stand anywhere on the display. Pressing the pill while it is open
    /// closes it, the way the dial does, and a press that arrives in the breath after a transient
    /// popover closed itself is the same press.
    func openModelParty() {
        guard !asking else { return }
        if let partyPopover, partyPopover.isShown {
            partyPopover.close()
            return
        }
        if let partyClosedAt, Date().timeIntervalSince(partyClosedAt) < 0.3 { return }
        dialPopover?.close()
        let actions = PartyPanelActions(
            take: { [weak self] card in self?.takePartyCard(card) },
            fill: { [weak self] slot in self?.openPartyChooser(slot: slot) },
            replace: { [weak self] slot in self?.openPartyChooser(slot: slot) },
            recent: { [weak self] recent in self?.takeRecent(recent) },
            addRecent: { [weak self] recent in self?.addRecentToParty(recent) },
            browse: { [weak self] in
                self?.partyPopover?.close()
                self?.openModelDirectoryNow()
            })
        partyPopover = PartyPopover.present(
            from: dialPill, prefers: .below, model: partyModel(), actions: actions,
            onClosed: { [weak self] in
                self?.partyPopover = nil
                self?.partyClosedAt = Date()
                self?.editor.focus()
            })
    }

    private func awayNotice(_ card: PartyCard) -> String {
        card.machine.map { Localized.text("%@ is not answering", $0) } ?? card.subtitle
    }

    /// What a pair asks of the level, as the pick that takes it: a pair that keeps the level keeps
    /// the one this aim holds, which the model it lands on then carries onto its own levels.
    func effortAsk(for preset: ModelPreset) -> EffortAsk {
        .set(preset.asks(current: QuickAskDefaults.effort(forProfileID: targetServer.id)))
    }

    /// A card pressed: the model, the level and the machine at once. A slot on another machine
    /// re-aims the question there through the same path a pick of it in the chooser takes; there
    /// is no chat to carry, so nothing asks first.
    func takePartyCard(_ card: PartyCard) {
        partyPopover?.close()
        guard !asking else { return }
        guard !card.isAway, let resolved = card.resolved, let profileID = card.profileID else {
            setStatus(awayNotice(card))
            editor.focus()
            return
        }
        let pick = ModelPick(
            profileID: profileID, selection: resolved.selection,
            isElsewhere: profileID != targetServer.id,
            serverName: card.machine ?? targetServer.name, modelName: card.modelWord,
            preset: resolved)
        takePick(pick, effort: effortAsk(for: resolved))
    }

    /// ⌃⌥n: slot n, and nothing else. A hollow slot says so rather than quietly taking some other
    /// model; with an empty party the chord is the nth pinned pair, as before there was one.
    func applyPreset(number: Int) {
        guard !ModelParty.presets().isEmpty else {
            takePinned(at: number - 1)
            return
        }
        guard let card = partyCards().first(where: { $0.slot == number - 1 }), !card.isHollow
        else {
            setStatus(Localized.text("Slot %d is empty", number))
            return
        }
        takePartyCard(card)
    }

    /// ⌃⌥→ and ⌃⌥←: the next slot round the party from the one in use, every filled slot that some
    /// machine answers for.
    func stepPreset(by delta: Int) {
        guard !ModelParty.presets().isEmpty else {
            stepPinned(by: delta)
            return
        }
        let ring = partyCards().filter { !$0.isHollow && !$0.isAway && $0.resolved != nil }
        guard !ring.isEmpty else {
            setStatus(ComposerView.noPresetsHint)
            return
        }
        let here = ring.firstIndex { $0.isInUse }
        let next =
            here.map { (($0 + delta) % ring.count + ring.count) % ring.count }
            ?? (delta >= 0 ? 0 : ring.count - 1)
        takePartyCard(ring[next])
    }

    private func pinnedHere() -> [ModelPreset] {
        let server = targetServer
        return ModelPresetCycle.reachable(
            ModelParty.ring(), models: ModelCatalogStore.cached(server.id),
            acceptsAnyModelID: ModelFleet.acceptsAnyModelID(server.backend))
    }

    private func takePinned(at index: Int) {
        let pinned = pinnedHere()
        guard !pinned.isEmpty else {
            setStatus(ComposerView.noPresetsHint)
            return
        }
        guard pinned.indices.contains(index) else {
            setStatus(Localized.text("Only %d pinned pairs run on this machine", pinned.count))
            return
        }
        takePinnedPair(pinned[index])
    }

    private func stepPinned(by delta: Int) {
        let server = targetServer
        guard
            let pair = ModelPresetCycle.step(
                pinnedHere(), model: QuickAskDefaults.model(forProfileID: server.id),
                effort: QuickAskDefaults.effort(forProfileID: server.id), by: delta)
        else {
            setStatus(ComposerView.noPresetsHint)
            return
        }
        takePinnedPair(pair)
    }

    private func takePinnedPair(_ pair: ModelPreset) {
        let server = targetServer
        let pick = ModelPick(
            profileID: server.id, selection: pair.selection, isElsewhere: false,
            serverName: server.name, modelName: "", preset: pair)
        takePick(pick, effort: effortAsk(for: pair))
    }

    private func takeRecent(_ recent: PartyRecent) {
        partyPopover?.close()
        let pick = ModelPick(
            profileID: recent.profileID, selection: recent.selection,
            isElsewhere: recent.profileID != targetServer.id, serverName: recent.machine ?? "",
            modelName: recent.word)
        takePick(pick)
    }

    /// The chord the shortcut set binds to a slot or to the ring, when the key is one of them. The
    /// panel is not the window the registry serves, so it asks the registry rather than reading
    /// keys of its own, and a chord a person rebound is the chord that works here.
    func handlePartyKey(_ event: NSEvent) -> Bool {
        guard let chord = MacKeys.chord(for: event),
            case .run(let action) = shortcuts.resolve(
                chord, context: .insert, pending: [], awaitingApproval: false)
        else { return false }
        switch action {
        case .preset(let number): applyPreset(number: number)
        case .presetNext: stepPreset(by: 1)
        case .presetPrevious: stepPreset(by: -1)
        default: return false
        }
        return true
    }

    /// The chooser over the fleet as this aim sees it, opened as a sheet on the panel. Closing it
    /// any way at all leaves the panel up and hands the keyboard back to the question.
    func presentChooser(
        context: ChooserContext, onPick: @escaping @MainActor (ModelPick) -> Void
    ) {
        let server = targetServer
        var adding: (@MainActor (ModelPick) -> String?)?
        if context == .composer {
            adding = { [weak self] pick in self?.addToParty(pick) }
        }
        let sheet = ModelChooserSheet.present(
            on: self, sources: chooserSources(for: server),
            selected: QuickAskDefaults.model(forProfileID: server.id), context: context,
            onAddToParty: adding
        ) { [weak self] pick in
            self?.modelSheet = nil
            onPick(pick)
        }
        sheet.onEnded = { [weak self] in
            self?.modelSheet = nil
            self?.editor.focus()
        }
        modelSheet = sheet
    }

    /// The chooser in fill mode: every pick, on any machine, goes into slot `slot` and the party
    /// opens again to show it there.
    func openPartyChooser(slot: Int) {
        partyPopover?.close()
        presentChooser(context: .party) { [weak self] pick in
            self?.fillParty(slot: slot, with: pick)
        }
    }

    /// The model at the level this aim holds, carried onto the model's own levels: what a pick of
    /// it would run at, taken as one decision. A model that takes no levels is the server's.
    private func presetCarrying(_ selection: ModelSelection, profileID: String) -> ModelPreset {
        let catalog =
            chooserSources(for: targetServer).first { $0.profileID == profileID }?.models
            ?? ModelCatalogStore.cached(profileID)
        let options = ModelEffort.options(
            models: catalog, selection: selection,
            agentOptions: agentOptions(forProfileID: profileID))
        let carried = ModelEffort.carry(
            QuickAskDefaults.effort(forProfileID: targetServer.id), options: options)
        return ModelPreset(
            selection: selection, effort: carried.level.map { .level($0) } ?? .server)
    }

    private func fillParty(slot: Int, with pick: ModelPick) {
        guard let selection = pick.selection else {
            setStatus(Localized.text("A slot holds a model, not the server's choice"))
            return
        }
        let preset = pick.preset ?? presetCarrying(selection, profileID: pick.profileID)
        ModelParty.replace(slot: slot, with: preset)
        setStatus(Localized.text("Added to slot %d", slot + 1))
        partyClosedAt = nil
        DispatchQueue.main.async { [weak self] in self?.openModelParty() }
    }

    /// "Add to party" on a model of the chooser: the first hollow slot, and the sentence that says
    /// which. With six full nothing moves, the chooser gives way and the party asks which one makes
    /// room; the nil answer tells the chooser there is nothing to say in its own line.
    private func addToParty(_ pick: ModelPick) -> String? {
        guard let selection = pick.selection else { return nil }
        let preset = pick.preset ?? presetCarrying(selection, profileID: pick.profileID)
        switch ModelParty.place(preset) {
        case .placed(let slot):
            return Localized.text("Added to slot %d", slot + 1)
        case .full:
            modelSheet?.onEnded = { [weak self] in
                self?.modelSheet = nil
                self?.presentMakeRoom(for: preset)
            }
            modelSheet?.dismiss()
            return nil
        }
    }

    private func addRecentToParty(_ recent: PartyRecent) {
        let preset = presetCarrying(recent.selection, profileID: recent.profileID)
        switch ModelParty.place(preset) {
        case .placed(let slot):
            setStatus(Localized.text("Added to slot %d", slot + 1))
        case .full:
            partyPopover?.close()
            DispatchQueue.main.async { [weak self] in self?.presentMakeRoom(for: preset) }
        }
    }

    /// With six full, the six cards asked "which one makes room?": a press replaces that slot.
    func presentMakeRoom(for preset: ModelPreset) {
        makeRoomPopover?.close()
        let actions = PartyPanelActions(
            take: { [weak self] card in
                ModelParty.replace(slot: card.slot, with: preset)
                self?.makeRoomPopover?.close()
                self?.setStatus(Localized.text("Added to slot %d", card.slot + 1))
            },
            fill: { _ in }, replace: { _ in }, recent: { _ in }, addRecent: { _ in }, browse: {})
        makeRoomPopover = PartyPopover.present(
            from: dialPill, mode: .makeRoom, prefers: .below, model: partyModel(),
            actions: actions,
            onClosed: { [weak self] in
                self?.makeRoomPopover = nil
                self?.editor.focus()
            })
    }
}
