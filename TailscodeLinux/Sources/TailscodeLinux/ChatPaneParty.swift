import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension ChatPane {
    /// What the party reads about this chat: its machines, the model and level it runs, and the
    /// levels its agent offers where a model names none.
    func partyInputs() -> PartyInputs {
        PartyInputs(
            sources: modelSources(), model: chosenModel ?? activeSelection,
            effort: resolvedEffort(), agentOptions: backend?.reasoningEffortOptions ?? [])
    }

    func makePartyPopover() -> PartyPopover {
        let hooks = PartyHooks()
        hooks.inputs = { [weak self] in
            self?.partyInputs()
                ?? PartyInputs(sources: [], model: nil, effort: nil, agentOptions: [])
        }
        hooks.take = { [weak self] card in self?.takeParty(card) }
        hooks.pick = { [weak self] pick in self?.apply(pick) }
        hooks.fill = { [weak self] slot in self?.openPartyFill(slot: slot) }
        hooks.catalog = { [weak self] in self?.openModelChooser() }
        hooks.addRecent = { [weak self] recent, anchor in
            guard let self else { return }
            self.addToParty(
                PartyEdits.preset(
                    for: recent.selection, profileID: recent.profileID, inputs: self.partyInputs()),
                on: anchor)
        }
        return PartyPopover(hooks: hooks)
    }

    /// A card pressed outside edit mode. A slot this machine runs is taken as a pinned pair is, a
    /// slot on another machine asks first and carries the conversation as any pick there does, and
    /// one that does not answer says so.
    func takeParty(_ card: PartyCard) {
        guard let resolved = card.resolved else {
            host?.toast(card.subtitle)
            return
        }
        guard !card.isAway else {
            host?.toast(Localized.text("%@ is not answering", card.machine ?? card.title))
            return
        }
        guard let machine = card.machine, let profileID = card.profileID else {
            take(resolved)
            return
        }
        apply(
            ModelPick(
                profileID: profileID, selection: resolved.selection, isElsewhere: true,
                serverName: machine, modelName: card.modelWord, preset: resolved))
    }

    /// ⌃⌥n for a slot: this machine's model at its level, or the reason it is not taken.
    func takeSlot(_ number: Int) {
        let card = partyInputs().cards[number - 1]
        guard !card.isHollow else {
            host?.flash(Localized.text("Slot %d is empty", number))
            return
        }
        if let machine = card.machine {
            host?.flash(Localized.text("Slot %d lives on %@", number, machine))
            return
        }
        takeParty(card)
    }

    /// The chooser, aimed at one slot: whatever is picked, on any machine, goes into it, at the
    /// level this chat holds carried onto that model unless the pick came with a level of its own.
    func openPartyFill(slot: Int) {
        let sources = modelSources().map { source in
            ModelSource(
                profileID: source.profileID, name: source.name, backend: source.backend,
                models: source.models, isCurrent: source.isCurrent, allowsServerDefault: false,
                acceptsAnyModelID: source.acceptsAnyModelID, isReachable: source.isReachable)
        }
        ModelChooserWindow.present(
            sources: sources, selected: chosenModel,
            parent: host?.windowWidget ?? root, quotas: modelQuotas(), context: .party,
            onRefresh: { [weak self] in self?.refreshModelCatalog() }
        ) { [weak self] pick in
            Gtk.onMain { [weak self] in
                guard let self, let preset = PartyEdits.preset(for: pick, inputs: self.partyInputs())
                else { return }
                PartyEdits.replace(slot, with: preset)
                self.host?.toast(Localized.text("Added to slot %d", slot + 1))
            }
        }
    }

    /// A model offered to the party from the chooser or the recent chips.
    func addToParty(_ preset: ModelPreset, on anchor: UnsafeMutablePointer<GtkWidget>) {
        PartyRoom.offer(preset, on: anchor, inputs: partyInputs()) { [weak self] words in
            Gtk.onMain { [weak self] in self?.host?.toast(words) }
        }
    }

    /// The pick of a chooser row, offered to the party at the level a pick of it would run at.
    func addToParty(_ pick: ModelPick, on anchor: UnsafeMutablePointer<GtkWidget>) {
        guard let preset = PartyEdits.preset(for: pick, inputs: partyInputs()) else { return }
        addToParty(preset, on: anchor)
    }
}
