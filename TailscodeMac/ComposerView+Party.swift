import AppKit
import CodingAgentKit
import MidgarCore
import TailscodeCore

/// One slot as the Model menu lists it.
struct PartyMenuRow {
    let slot: Int
    let title: String
    let isCurrent: Bool
}

extension ComposerView {
    /// A press on the model pill opens the party; with ⌥ held it opens the dial, the way to the
    /// effort ladder and the whole shortlist that the party replaced as the pill's first answer.
    func pressModelPill() {
        if NSEvent.modifierFlags.contains(.option) {
            openModelDial()
        } else {
            openModelParty()
        }
    }

    var isTurnRunning: Bool { lastState?.status == .running }

    /// The six cards as they read from this chat: every machine the app knows is a place a slot
    /// can be run, this one first.
    func partyCards() -> [PartyCard] {
        PartyReading.cards(
            slots: ModelParty.slots(), sources: modelSources(), model: activeSelection,
            effort: displayedEffort(), agentOptions: backend?.reasoningEffortOptions ?? [])
    }

    #if DEBUG
        /// The party opened over the demo fleet once each machine has said what it runs, so every card
        /// names its model by codename — `--open party` from the command line, after `DialTour` has
        /// filled the six slots, with two recent models for the footer.
        func openDemoParty() {
            RecentModelsStore.record(ModelSelection(providerID: "google", modelID: "gemini-3-pro"))
            RecentModelsStore.record(ModelSelection(providerID: "anthropic", modelID: "claude-haiku-4-5"))
            Task { @MainActor [weak self] in
                await DemoCatalogs.warm()
                self?.openModelParty()
            }
        }
    #endif

    private func partyRecents() -> [PartyRecent] {
        PartyReading.recents(slots: ModelParty.slots(), sources: modelSources())
    }

    private func partyLevels(of card: PartyCard) -> [String] {
        guard let preset = card.resolved ?? card.preset else { return [] }
        let catalog = modelSources().first { $0.profileID == card.profileID }?.models ?? models
        return ModelEffort.options(
            models: catalog, selection: preset.selection,
            agentOptions: backend?.reasoningEffortOptions ?? [])
    }

    private func partyModel() -> PartyPanelModel {
        PartyPanelModel(
            cards: { [weak self] in self?.partyCards() ?? [] },
            recents: { [weak self] in self?.partyRecents() ?? [] },
            levels: { [weak self] card in self?.partyLevels(of: card) ?? [] },
            isRunning: { [weak self] in self?.isTurnRunning ?? false })
    }

    /// The party opened on its own pill. Pressing the pill while it is open closes it, the way
    /// the dial does, and a press that arrives in the breath after a transient popover closed
    /// itself is the same press.
    func openModelParty() {
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
                self?.openModelChooser()
            })
        partyPopover = PartyPopover.present(
            from: pills.dialAnchor, model: partyModel(), actions: actions,
            onClosed: { [weak self] in
                self?.partyPopover = nil
                self?.partyClosedAt = Date()
            })
    }

    private func awayNotice(_ card: PartyCard) -> String {
        card.machine.map { Localized.text("%@ is not answering", $0) } ?? card.subtitle
    }

    private static func effortAsk(for preset: ModelPreset) -> EffortAsk {
        switch preset.effort {
        case .keep: return .unchanged
        case .server: return .set(nil)
        case .level(let level): return .set(level)
        }
    }

    /// A card pressed: on this machine it is the pinned pair taken, the same pick the chords make;
    /// on another it asks first and carries the conversation there, as Continue on… does.
    func takePartyCard(_ card: PartyCard) {
        partyPopover?.close()
        guard !card.isAway, let resolved = card.resolved else {
            onDialToast?(awayNotice(card))
            return
        }
        guard let machine = card.machine, let profileID = card.profileID else {
            applyPreset(resolved)
            return
        }
        let pick = ModelPick(
            profileID: profileID, selection: resolved.selection, isElsewhere: true,
            serverName: machine, modelName: card.modelWord, preset: resolved)
        handleModelPick(pick, effort: Self.effortAsk(for: resolved))
    }

    /// ⌃⌥n: slot n, and nothing else. A hollow slot and a slot that lives on another machine say
    /// so rather than quietly taking some other model.
    func takePartySlot(_ slot: Int) {
        let number = slot + 1
        guard let card = partyCards().first(where: { $0.slot == slot }), !card.isHollow else {
            onDialToast?(Localized.text("Slot %d is empty", number))
            return
        }
        if let machine = card.machine {
            onDialToast?(Localized.text("Slot %d lives on %@", number, machine))
        } else if card.isAway || card.resolved == nil {
            onDialToast?(awayNotice(card))
        } else if let resolved = card.resolved {
            applyPreset(resolved)
        }
    }

    private func takeRecent(_ recent: PartyRecent) {
        partyPopover?.close()
        let pick = ModelPick(
            profileID: recent.profileID, selection: recent.selection,
            isElsewhere: recent.machine != nil, serverName: recent.machine ?? "",
            modelName: recent.word)
        handleModelPick(pick)
    }

    /// The model at the level this chat runs, carried onto the model's own levels: what a pick of
    /// it would run at, taken as one decision. A model that takes no levels is the server's.
    func presetCarrying(_ selection: ModelSelection, profileID: String) -> ModelPreset {
        let catalog = modelSources().first { $0.profileID == profileID }?.models ?? models
        let options = ModelEffort.options(
            models: catalog, selection: selection,
            agentOptions: backend?.reasoningEffortOptions ?? [])
        let carried = ModelEffort.carry(displayedEffort(), options: options)
        return ModelPreset(
            selection: selection, effort: carried.level.map { .level($0) } ?? .server)
    }

    /// The chooser in fill mode: every pick, on any machine, goes into slot `slot` and the party
    /// opens again to show it there.
    func openPartyChooser(slot: Int) {
        partyPopover?.close()
        guard let host = window else { return }
        modelSheet = ModelChooserSheet.present(
            on: host, sources: modelSources(), selected: chosenModel,
            quotas: quotasForModels?() ?? [], context: .party
        ) { [weak self] pick in
            self?.modelSheet = nil
            self?.fillParty(slot: slot, with: pick)
        }
    }

    private func fillParty(slot: Int, with pick: ModelPick) {
        guard let selection = pick.selection else {
            onDialToast?(Localized.text("A slot holds a model, not the server's choice"))
            return
        }
        let preset = pick.preset ?? presetCarrying(selection, profileID: pick.profileID)
        ModelParty.replace(slot: slot, with: preset)
        onDialToast?(Localized.text("Added to slot %d", slot + 1))
        DispatchQueue.main.async { [weak self] in self?.openModelParty() }
    }

    /// "Add to party" on a model of the chooser: the first hollow slot, and the sentence that says
    /// which. With six full nothing moves, the chooser gives way and the party asks which one makes
    /// room; the nil answer tells the chooser there is nothing to say in its own line.
    func addToParty(_ pick: ModelPick) -> String? {
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
            onDialToast?(Localized.text("Added to slot %d", slot + 1))
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
                self?.onDialToast?(Localized.text("Added to slot %d", card.slot + 1))
            },
            fill: { _ in }, replace: { _ in }, recent: { _ in }, addRecent: { _ in }, browse: {})
        makeRoomPopover = PartyPopover.present(
            from: pills.dialAnchor, mode: .makeRoom, model: partyModel(), actions: actions,
            onClosed: { [weak self] in self?.makeRoomPopover = nil })
    }

    /// The six slots for the Model menu, each with the word it is said by. Empty while the party
    /// is, which leaves the menu listing the pins as it did before there was one.
    func partyMenuRows() -> [PartyMenuRow] {
        guard !ModelParty.presets().isEmpty else { return [] }
        return partyCards().map { card in
            guard !card.isHollow else {
                return PartyMenuRow(
                    slot: card.slot, title: Localized.text("Slot %d is empty", card.slot + 1),
                    isCurrent: false)
            }
            let said =
                card.title == card.modelWord ? card.subtitle : card.title + " · " + card.subtitle
            let title = card.machine.map { said + " · " + $0 } ?? said
            return PartyMenuRow(slot: card.slot, title: title, isCurrent: card.isInUse)
        }
    }
}
