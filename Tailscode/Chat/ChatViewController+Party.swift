import CodingAgentKit
import TailscodeCore
import UIKit

extension ChatViewController {
    /// What the party reads this chat as: the model and level its next send runs at, and whether
    /// a turn is running, which is the only time the slot in use breathes.
    private var partyAim: PartyAim {
        PartyAim(
            model: viewModel.displayedModel, effort: viewModel.displayedEffort,
            agentOptions: viewModel.backend.reasoningEffortOptions, isBusy: viewModel.isBusy)
    }

    /// Every machine's catalog with this chat's server first, as the quick menu always read it.
    private func partySources() -> [ModelSource] {
        ModelFleet.sources(
            profiles: ConnectionController.shared.profiles, current: viewModel.contextID,
            currentModels: viewModel.supportsModelSelection ? availableModels : [],
            allowsServerDefault: ChatModelResolver.honoursServerDefault(viewModel.backend),
            reachability: pickerReachability)
    }

    /// The sheet the model pill opens. A slot on this machine is taken as a pinned pair is; a slot
    /// or a recent on another goes through `apply(_:)`, which asks before it carries the chat.
    func presentParty(editing: Bool = false) {
        guard viewModel.supportsModelSelection, presentedViewController == nil else { return }
        Theme.Haptics.tap()
        PartyViewController.present(
            from: self, sources: { [weak self] in self?.partySources() ?? [] },
            aim: { [weak self] in
                self?.partyAim
                    ?? PartyAim(model: nil, effort: nil, agentOptions: [], isBusy: false)
            },
            actions: PartyViewController.Actions(
                take: { [weak self] preset in self?.choose(preset) },
                takeModel: { [weak self] selection in self?.chooseModel(selection) },
                takeElsewhere: { [weak self] pick in self?.apply(pick) },
                browseAll: { [weak self] in self?.presentModelPicker() },
                fill: { [weak self] party, onPick in
                    self?.presentChooser(context: .party, from: party, onSelect: onPick)
                }),
            editing: editing)
    }

    /// A hardware chord for slot `number`: that slot's own model and level, and a word when the
    /// slot cannot be taken from here.
    func takePartySlot(_ number: Int) {
        let aim = partyAim
        let card = PartyReading.cards(
            slots: ModelParty.slots(), sources: partySources(), model: aim.model,
            effort: aim.effort, agentOptions: aim.agentOptions)[number - 1]
        if card.isHollow {
            presentToast(String(localized: "Slot \(number) is empty"))
        } else if let machine = card.machine {
            presentToast(String(localized: "Slot \(number) lives on \(machine)"))
        } else if let resolved = card.resolved, !card.isAway {
            applyPreset(resolved)
        } else {
            presentToast(card.subtitle)
        }
    }
}
