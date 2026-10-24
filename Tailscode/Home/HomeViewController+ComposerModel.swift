import TailscodeCore
import CodingAgentKit
import CodingAgentKitApple
import UIKit

extension HomeViewController {
    /// The ask lane's aim is its own once it has been set by hand, which is the whole point of it
    /// — and the way back is one row in the party rather than a settings screen.
    func followServerAction(for aim: ComposerAim) -> (() -> Void)? {
        guard aim.lane == .ask, QuickAskDefaults.hasOwnAim(forProfileID: aim.profile.id) else {
            return nil
        }
        return { [weak self] in
            guard let self else { return }
            QuickAskDefaults.clearOwnAim(forProfileID: aim.profile.id)
            self.modelChoices[aim.memoryKey] = nil
            self.appliedComposerState = nil
            self.updateComposer()
        }
    }

    /// A pick in the ask lane claims that lane's own memory and leaves the server's exactly as it
    /// was: pointing lookups at something cheap may never re-aim the project chats.
    func setComposeModel(
        _ selection: ModelSelection?, for aim: ComposerAim, announces: Bool = true
    ) {
        let backend = viewModel.backend(forProfileID: aim.profile.id)
        let models = ModelCatalog.cached(for: aim.profile.id)
        let agentOptions = backend?.reasoningEffortOptions ?? []
        switch aim.lane {
        case .chat:
            ModelPreferenceStore.recordPick(selection, sessionKey: nil, contextID: aim.profile.id)
            if selection == nil {
                modelChoices[aim.memoryKey] = nil
            } else {
                var choice = modelChoices[aim.memoryKey] ?? ModelChoice()
                choice.model = selection
                let carry = ModelEffort.adoption(
                    choice.effort, for: selection, models: models, agentOptions: agentOptions)
                if carry.level != choice.effort {
                    choice.effort = carry.level
                    EffortPreferenceStore.recordPick(
                        carry.level, sessionKey: nil, contextID: aim.profile.id)
                }
                modelChoices[aim.memoryKey] = choice
                announce(carry, selection: selection, models: models, if: announces)
            }
        case .video, .image:
            assertionFailure("a render lane has no ComposerAim")
        case .ask:
            QuickAskDefaults.recordModel(selection, forProfileID: aim.profile.id)
            var choice = modelChoices[aim.memoryKey] ?? ModelChoice()
            choice.model = selection
            let carry = ModelEffort.adoption(
                choice.effort, for: selection, models: models, agentOptions: agentOptions)
            if carry.level != choice.effort {
                choice.effort = carry.level
                QuickAskDefaults.recordEffort(carry.level, forProfileID: aim.profile.id)
            }
            modelChoices[aim.memoryKey] = choice
            announce(carry, selection: selection, models: models, if: announces)
        }
        Theme.Haptics.selection()
        appliedComposerState = nil
        updateComposer()
    }

    /// A level that moved because the model under it changed is said, not left to be noticed.
    private func announce(
        _ carry: EffortCarry, selection: ModelSelection?, models: [ModelInfo], if announces: Bool
    ) {
        guard announces else { return }
        let name = selection.map { ModelBadge.word(for: $0, in: models) } ?? String(localized: "Auto")
        if let notice = carry.notice(modelName: name) { toast(notice) }
    }

    func setComposeEffort(_ level: String?, for aim: ComposerAim, quiet: Bool = false) {
        switch aim.lane {
        case .chat:
            EffortPreferenceStore.recordPick(level, sessionKey: nil, contextID: aim.profile.id)
        case .ask:
            QuickAskDefaults.recordEffort(level, forProfileID: aim.profile.id)
        case .video, .image:
            assertionFailure("a render lane has no ComposerAim")
        }
        var choice = modelChoices[aim.memoryKey] ?? ModelChoice()
        choice.effort = level
        modelChoices[aim.memoryKey] = choice
        if !quiet { Theme.Haptics.selection() }
        appliedComposerState = nil
        updateComposer()
    }

    func presentComposeModelPicker(
        aim: ComposerAim, backend: any CodingAgentBackend, models: [ModelInfo],
        context: ModelPickerViewController.Context = .composer,
        from presenter: UIViewController? = nil, onPick: ((ModelPick) -> Void)? = nil
    ) {
        guard !models.isEmpty else { return }
        Theme.Haptics.tap()
        let profile = aim.profile
        let reachability = composeReachability
        let picker = ModelPickerViewController(
            sources: ModelFleet.sources(
                profiles: ConnectionController.shared.profiles, current: profile.id,
                currentModels: models, allowsServerDefault: profile.backend == .claudeCode,
                reachability: reachability),
            selected: modelChoices[aim.memoryKey]?.model,
            quotas: QuotaSurface.relevantQuotas(
                for: profile.backend, among: UsageWidgetStore.cachedQuotas()),
            dial: composePickerDial(for: aim, backend: backend), context: context
        ) { [weak self] pick in
            guard let self else { return }
            if let onPick { return onPick(pick) }
            guard pick.isElsewhere else {
                if let preset = pick.preset {
                    self.setComposePreset(preset, for: aim)
                } else {
                    self.setComposeModel(pick.selection, for: aim)
                }
                return
            }
            self.retargetCompose(to: pick, from: aim)
        }
        let nav = UINavigationController(rootViewController: picker)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.selectedDetentIdentifier = .large
            sheet.prefersGrabberVisible = true
        }
        (presenter ?? self).present(nav, animated: true)
        let contextID = profile.id
        let allowsServerDefault = profile.backend == .claudeCode
        let sources = { (models: [ModelInfo]) in
            ModelFleet.sources(
                profiles: ConnectionController.shared.profiles, current: contextID,
                currentModels: models, allowsServerDefault: allowsServerDefault,
                reachability: reachability)
        }
        let watch = PickerCatalogWatch.keep(
            picker: picker, profileID: contextID, backend: backend, sources: sources)
        picker.onClose = { watch.cancel() }
        Task { @MainActor in
            let fresh = await ModelCatalog.fresh(for: contextID, backend: backend)
            picker.update(sources: sources(fresh))
        }
    }

    private func composePickerDial(
        for aim: ComposerAim, backend: any CodingAgentBackend
    ) -> ModelPickerViewController.Dial {
        let choice = modelChoices[aim.memoryKey] ?? ModelChoice()
        return ModelPickerViewController.Dial(
            modelName: choice.model.map {
                ModelBadge.word(for: $0, in: ModelCatalog.cached(for: aim.profile.id))
            } ?? String(localized: "Auto"),
            chip: ModelBadge.chip(
                    selection: choice.model, effort: nil,
                    catalog: ModelCatalog.cached(for: aim.profile.id)),
            options: dialOptions(for: aim), agentOptions: backend.reasoningEffortOptions,
            effort: choice.effort, contextTokens: nil,
            onEffort: { [weak self] level in self?.setComposeEffort(level, for: aim) })
    }
}
