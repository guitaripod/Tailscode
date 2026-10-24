import CodingAgentKit
import TailscodeCore
import UIKit

extension HomeViewController {
    private func partySources(for aim: ComposerAim, backend: any CodingAgentBackend) -> [ModelSource] {
        ModelFleet.sources(
            profiles: ConnectionController.shared.profiles, current: aim.profile.id,
            currentModels: backend.capabilities.supportsModelSelection
                ? ModelCatalog.cached(for: aim.profile.id) : [],
            allowsServerDefault: ChatModelResolver.honoursServerDefault(backend),
            reachability: composeReachability)
    }

    private func partyAim(for aim: ComposerAim, backend: any CodingAgentBackend) -> PartyAim {
        let choice = modelChoices[aim.memoryKey] ?? ModelChoice()
        return PartyAim(
            model: choice.model, effort: choice.effort, agentOptions: backend.reasoningEffortOptions,
            isBusy: false)
    }

    /// The sheet the composer's model pill opens: the party aimed at the machine the message is
    /// headed for. A slot or a recent on another machine re-aims the message there, as a pick in
    /// the chooser does; the catalog is awaited first only when nothing is remembered yet.
    func presentParty(editing: Bool = false) {
        guard let aim = composerAim, presentedViewController == nil,
            let backend = viewModel.backend(forProfileID: aim.profile.id)
        else { return }
        Theme.Haptics.tap()
        Task { @MainActor [weak self] in
            if backend.capabilities.supportsModelSelection {
                _ = await ModelCatalog.models(for: aim.profile.id, backend: backend)
            }
            guard let self, self.presentedViewController == nil else { return }
            PartyViewController.present(
                from: self,
                sources: { [weak self] in self?.partySources(for: aim, backend: backend) ?? [] },
                aim: { [weak self] in
                    self?.partyAim(for: aim, backend: backend)
                        ?? PartyAim(model: nil, effort: nil, agentOptions: [], isBusy: false)
                },
                actions: PartyViewController.Actions(
                    take: { [weak self] preset in self?.setComposePreset(preset, for: aim) },
                    takeModel: { [weak self] selection in self?.setComposeModel(selection, for: aim) },
                    takeElsewhere: { [weak self] pick in self?.retargetCompose(to: pick, from: aim) },
                    browseAll: { [weak self] in
                        self?.presentComposeModelPicker(
                            aim: aim, backend: backend,
                            models: ModelCatalog.cached(for: aim.profile.id))
                    },
                    fill: { [weak self] party, onPick in
                        self?.presentComposeModelPicker(
                            aim: aim, backend: backend,
                            models: ModelCatalog.cached(for: aim.profile.id), context: .party,
                            from: party, onPick: onPick)
                    },
                    followServer: followServerAction(for: aim)),
                editing: editing)
        }
    }

    /// A hardware chord for slot `number`: that slot's own model and level aimed at this message,
    /// and a word when the slot cannot be taken here.
    func takeComposePartySlot(_ number: Int) {
        guard let aim = composerAim, let backend = viewModel.backend(forProfileID: aim.profile.id)
        else { return }
        let reading = partyAim(for: aim, backend: backend)
        let card = PartyReading.cards(
            slots: ModelParty.slots(), sources: partySources(for: aim, backend: backend),
            model: reading.model, effort: reading.effort, agentOptions: reading.agentOptions)[number - 1]
        if card.isHollow {
            toast(String(localized: "Slot \(number) is empty"))
        } else if let machine = card.machine {
            toast(String(localized: "Slot \(number) lives on \(machine)"))
        } else if let resolved = card.resolved, !card.isAway {
            setComposePreset(resolved, for: aim)
        } else {
            toast(card.subtitle)
        }
    }
}
