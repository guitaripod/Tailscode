import TailscodeCore
import CodingAgentKit
import CodingAgentKitApple
import UIKit

extension ServerDetailViewController {
    /// Rebuilt on every present so a catalog that was still loading when the row
    /// was drawn is complete by the time the menu opens.
    func modelMenu() -> UIMenu {
        UIMenu(
            title: String(localized: "Default model"),
            children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    Task { @MainActor in
                        guard let self, let backend = self.backend else { return completion([]) }
                        let models =
                            backend.capabilities.supportsModelSelection
                            ? await ModelCatalog.models(for: self.profile.id, backend: backend) : []
                        completion(
                            ModelMenu.elements(
                                sources: ModelFleet.sources(
                                    profiles: ConnectionController.shared.profiles,
                                    current: self.profile.id, currentModels: models,
                                    allowsServerDefault:
                                        ChatModelResolver.honoursServerDefault(backend)),
                                choice: self.modelChoice,
                                efforts: backend.reasoningEffortOptions,
                                allowsServerDefault: ChatModelResolver.honoursServerDefault(backend),
                                quotas: QuotaSurface.relevantQuotas(
                                    for: backend.agentType, among: UsageWidgetStore.cachedQuotas()),
                                actions: ModelMenu.Actions(
                                    selectModel: { [weak self] selection in
                                        self?.setDefaultModel(selection)
                                    },
                                    selectEffort: { [weak self] level in
                                        self?.setDefaultEffort(level)
                                    },
                                    browseAll: { [weak self] in
                                        self?.presentModelPicker(backend: backend, models: models)
                                    })))
                    }
                }
            ])
    }

    private func setDefaultModel(_ selection: ModelSelection?) {
        ModelPreferenceStore.recordPick(selection, sessionKey: nil, contextID: profile.id)
        modelChoice.model = selection
        Theme.Haptics.selection()
        reconfigure([.defaultModel])
    }

    private func setDefaultEffort(_ level: String?) {
        EffortPreferenceStore.recordPick(level, sessionKey: nil, contextID: profile.id)
        modelChoice.effort = level
        Theme.Haptics.selection()
        reconfigure([.defaultModel])
    }

    private func presentModelPicker(backend: any CodingAgentBackend, models: [ModelInfo]) {
        guard !models.isEmpty else { return }
        Theme.Haptics.tap()
        let source = ModelSource(
            profileID: profile.id, name: profile.name, backend: profile.backend, models: models,
            isCurrent: true, allowsServerDefault: true,
            acceptsAnyModelID: profile.backend == .claudeCode)
        let picker = ModelPickerViewController(
            sources: [source], selected: modelChoice.model,
            quotas: QuotaSurface.relevantQuotas(
                for: profile.backend, among: UsageWidgetStore.cachedQuotas()),
            context: .serverDefault
        ) { [weak self] pick in
            self?.setDefaultModel(pick.selection)
        }
        let nav = UINavigationController(rootViewController: picker)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.selectedDetentIdentifier = .large
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
        let contextID = profile.id
        let profileSnapshot = profile
        let sources = { (models: [ModelInfo]) in
            [
                ModelSource(
                    profileID: profileSnapshot.id, name: profileSnapshot.name,
                    backend: profileSnapshot.backend, models: models, isCurrent: true,
                    allowsServerDefault: true,
                    acceptsAnyModelID: profileSnapshot.backend == .claudeCode)
            ]
        }
        let watch = PickerCatalogWatch.keep(
            picker: picker, profileID: contextID, backend: backend, sources: sources)
        picker.onClose = { watch.cancel() }
        Task { @MainActor in
            let fresh = await ModelCatalog.fresh(for: contextID, backend: backend)
            picker.update(sources: sources(fresh))
        }
    }

    var supportsModelDefaults: Bool {
        guard let backend else { return false }
        return backend.capabilities.supportsModelSelection
            || backend.capabilities.supportsReasoningEffort
    }
}
