import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension QuickAskWindow {
    /// What the party reads about this ask: every machine the question could go to with the aimed
    /// one first, the model and level it will run, and the levels its agent offers where a model
    /// names none. The same cards the chat's pill draws, over the quick ask's own memory.
    func partyInputs() -> PartyInputs {
        let server = targetServer
        return PartyInputs(
            sources: ModelFleet.sources(
                profiles: servers, current: server.id, reachability: reachability),
            model: QuickAskDefaults.model(forProfileID: server.id),
            effort: ModelEffort.surviving(
                QuickAskDefaults.effort(forProfileID: server.id), options: effortOptions()),
            agentOptions: agentEfforts[server.id] ?? [])
    }

    static func makePartyPopover() -> PartyPopover {
        let hooks = PartyHooks()
        hooks.inputs = {
            QuickAskWindow.open?.partyInputs()
                ?? PartyInputs(sources: [], model: nil, effort: nil, agentOptions: [])
        }
        hooks.take = { card in Gtk.onMain { QuickAskWindow.open?.takeParty(card) } }
        hooks.pick = { pick in Gtk.onMain { QuickAskWindow.open?.takeRecent(pick) } }
        hooks.fill = { slot in Gtk.onMain { QuickAskWindow.open?.openPartyFill(slot: slot) } }
        hooks.catalog = { Gtk.onMain { QuickAskWindow.open?.chooseModel() } }
        hooks.addRecent = { recent, anchor in
            let bits = UInt(bitPattern: anchor)
            Gtk.onMain {
                guard let open = QuickAskWindow.open,
                    let held = UnsafeMutablePointer<GtkWidget>(bitPattern: bits)
                else { return }
                open.addToParty(
                    PartyEdits.preset(
                        for: recent.selection, profileID: recent.profileID,
                        inputs: open.partyInputs()), on: held)
            }
        }
        let party = PartyPopover(hooks: hooks)
        party.fit = { QuickAskWindow.open?.partyFit() ?? PartyFit(ceiling: nil, shift: 0) }
        return party
    }

    /// Where the party may stand: it hangs under a pill at the window's right edge, so it is shifted
    /// until its own right edge is the window's, and it is never taller than the screen the window is
    /// on less a margin, which the desktop can always honour by flipping it above the pill or
    /// sliding it over the pill; anything taller scrolls.
    func partyFit() -> PartyFit {
        var width: Int32 = 0
        var height: Int32 = 0
        tailscode_monitor_size(window, &width, &height)
        let ceiling: Int32? = height > 0 ? max(240, height - 96) : nil
        guard let box = Gtk.bounds(of: dial.button, in: window) else {
            return PartyFit(ceiling: ceiling, shift: 0)
        }
        let edge = Double(gtk_widget_get_width(window)) - Double(Self.partyGutter)
        let center = box.x + box.width / 2
        let wanted = edge - Double(PartyPopover.width) / 2
        return PartyFit(ceiling: ceiling, shift: Int32(min(0, wanted - center)))
    }

    static let partyGutter: Int32 = 10

    /// A card pressed outside edit mode. The slot is the aim: its model, its level and the machine
    /// that runs it, which is where this question will go; one that does not answer says so.
    func takeParty(_ card: PartyCard) {
        guard !asking else { return }
        guard let resolved = card.resolved else {
            setHint(card.subtitle)
            return
        }
        guard !card.isAway else {
            setHint(Localized.text("%@ is not answering", card.machine ?? card.title))
            return
        }
        aim(at: resolved, profileID: card.profileID ?? targetServer.id, word: card.modelWord)
    }

    /// A model used lately, taken as a pick of it is anywhere: on the machine that runs it, at the
    /// level the aim carries onto it.
    func takeRecent(_ chosen: ModelPick) {
        guard let selection = chosen.selection else {
            pick(chosen, effort: .unchanged, notice: nil)
            return
        }
        aim(
            at: ModelPreset(selection: selection, effort: .keep),
            profileID: chosen.profileID, word: chosen.modelName)
    }

    /// One decision: model and level together, and the machine that runs them when it is not the
    /// one aimed at. The level is carried onto the model's own the way a pick anywhere carries it.
    func aim(at preset: ModelPreset, profileID: String, word: String) {
        guard let server = servers.first(where: { $0.id == profileID }) else { return }
        let carry = preset.applied(
            currentEffort: QuickAskDefaults.effort(forProfileID: targetServer.id),
            models: ModelCatalogStore.cached(server.id),
            agentOptions: agentEfforts[server.id] ?? [])
        let elsewhere = server.id != targetServer.id
        var said = ModelPresetCycle.said(preset, modelName: word)
        if elsewhere { said += " · " + Localized.text("on %@", server.name) }
        let notice = carry.notice(modelName: word).map { said + " — " + $0 } ?? said
        pick(
            ModelPick(
                profileID: server.id, selection: preset.selection, isElsewhere: elsewhere,
                serverName: server.name, modelName: word, preset: preset),
            effort: .set(carry.level), notice: notice)
    }

    /// ⌃⌥n for a slot: whichever machine runs it, or the reason it is not taken. While the party is
    /// empty the nth pinned pair the aimed machine can run, as in the chat.
    func takePreset(number: Int) {
        guard !asking else { return }
        if (1...ModelParty.size).contains(number), !ModelParty.presets().isEmpty {
            let card = partyInputs().cards[number - 1]
            guard !card.isHollow else {
                setHint(Localized.text("Slot %d is empty", number))
                return
            }
            takeParty(card)
            return
        }
        let presets = reachablePins()
        guard presets.indices.contains(number - 1) else {
            if presets.isEmpty { setHint(Self.pinHint) }
            return
        }
        take(pin: presets[number - 1])
    }

    /// ⌃⌥←/→: the next slot round the ring from the one this ask runs, over every machine that
    /// answers; while the party is empty, the pinned pairs of the aimed machine.
    func stepPreset(by delta: Int) {
        guard !asking else { return }
        guard !ModelParty.presets().isEmpty else {
            let pins = reachablePins()
            guard
                let preset = ModelPresetCycle.step(
                    pins, model: QuickAskDefaults.model(forProfileID: targetServer.id),
                    effort: partyInputs().effort, by: delta)
            else {
                setHint(Self.pinHint)
                return
            }
            take(pin: preset)
            return
        }
        let ring = partyInputs().cards.filter { !$0.isHollow && !$0.isAway && $0.resolved != nil }
        guard !ring.isEmpty else {
            setHint(Localized.text("No slot of the party can be taken here"))
            return
        }
        let here = ring.firstIndex { $0.isInUse }
        let next = here.map { ($0 + delta + ring.count) % ring.count } ?? (delta > 0 ? 0 : ring.count - 1)
        takeParty(ring[next])
    }

    static var pinHint: String { Localized.text("Pin a model and level with ⌃S in the model dial") }

    private func reachablePins() -> [ModelPreset] {
        ModelPresetCycle.reachable(
            ModelParty.ring(), models: ModelCatalogStore.cached(targetServer.id),
            acceptsAnyModelID: ModelFleet.acceptsAnyModelID(targetServer.backend))
    }

    private func take(pin preset: ModelPreset) {
        let models = ModelCatalogStore.cached(targetServer.id)
        let word = models.first { $0.providerID == preset.selection.providerID && $0.id == preset.selection.modelID }?.name
            ?? ModelBadge.label(model: preset.selection, effort: nil, catalog: models)
        aim(at: preset, profileID: targetServer.id, word: word)
    }

    /// The chooser, aimed at one slot: whatever is picked, on any machine, goes into it, at the
    /// level this ask holds carried onto that model unless the pick came with a level of its own.
    func openPartyFill(slot: Int) {
        guard !asking else { return }
        let server = targetServer
        let sources = partyInputs().sources.map { source in
            ModelSource(
                profileID: source.profileID, name: source.name, backend: source.backend,
                models: source.models, isCurrent: source.isCurrent, allowsServerDefault: false,
                acceptsAnyModelID: source.acceptsAnyModelID, isReachable: source.isReachable)
        }
        ModelChooserWindow.present(
            sources: sources, selected: QuickAskDefaults.model(forProfileID: server.id),
            parent: window, context: .party,
            onRefresh: { [weak self] in self?.refreshModelCatalog(for: server) }
        ) { [weak self] pick in
            Gtk.onMain { [weak self] in
                guard let self,
                    let preset = PartyEdits.preset(for: pick, inputs: self.partyInputs())
                else { return }
                PartyEdits.replace(slot, with: preset)
                let words = Localized.text("Added to slot %d", slot + 1)
                Gtk.after(320) { [weak self] in
                    Gtk.onMain { [weak self] in self?.openParty(announcing: words) }
                }
            }
        }
    }

    func openParty(announcing words: String? = nil) {
        if let words { dial.party?.announce(words) }
        dial.open()
    }

    /// A model offered to the party from the chooser or the recent chips.
    func addToParty(_ preset: ModelPreset, on anchor: UnsafeMutablePointer<GtkWidget>) {
        PartyRoom.offer(
            preset, on: anchor, inputs: partyInputs(), floor: Double(partyFit().ceiling ?? 0)
        ) { words in
            Gtk.onMain { QuickAskWindow.open?.setHint(words) }
        }
    }

    func addToParty(_ pick: ModelPick, on anchor: UnsafeMutablePointer<GtkWidget>) {
        guard let preset = PartyEdits.preset(for: pick, inputs: partyInputs()) else { return }
        addToParty(preset, on: anchor)
    }

    /// ⌃⌥1–6 and the ring, honouring whatever the keybinding file made of them. The action is the
    /// shortcut set's own, so a rebound chord reaches the party here as it does in the chat.
    func partyAction(keyval: UInt32, state: UInt32) -> KeyAction? {
        guard state & KeyChord.controlMask != 0 || state & KeyChord.altMask != 0,
            let chord = KeyChord.canonical(keyval: keyval, state: state)
        else { return nil }
        guard
            case .run(let action) = shortcuts.resolve(
                chord, context: .insert, pending: [], awaitingApproval: false)
        else { return nil }
        switch action {
        case .preset, .presetNext, .presetPrevious: return action
        default: return nil
        }
    }

    func perform(party action: KeyAction) {
        switch action {
        case .preset(let number): takePreset(number: number)
        case .presetNext: stepPreset(by: 1)
        case .presetPrevious: stepPreset(by: -1)
        default: break
        }
    }
}
