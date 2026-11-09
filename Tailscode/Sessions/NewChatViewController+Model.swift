import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore
import UIKit

extension NewChatViewController {
    /// The pill the composer wears, wired to what a new chat on the chosen server starts with:
    /// the model half opens the full chooser, the level half lifts the ladder over the sheet.
    func configureDialPill(below row: UIView) {
        dialPill.railHost = view
        dialPill.railBelow = row
        dialPill.onOpenModels = { [weak self] in self?.presentModelChooser() }
        dialPill.onEffort = { [weak self] level in self?.setStartingEffort(level) }
        dialPill.onScrub = { [weak self] level in self?.setStartingEffort(level, quiet: true) }
        dialPill.footer = { rung in EffortRail.footer(for: rung, yours: nil) }
    }

    /// The pill's face from the same defaults the stamp reads.
    func renderDial(_ defaults: NewChatDefaults) {
        let catalog = ModelCatalog.cached(for: chooser.server?.profileID ?? "")
        let backend = chooser.server.flatMap { viewModel.backend(forProfileID: $0.profileID) }
        dialPill.content = ModelDialPill.Content(
            modelWord: defaults.model.map { ModelBadge.word(for: $0, in: catalog) }
                ?? String(localized: "Auto"),
            chip: defaults.chip, effort: defaults.effort, options: effortOptions(),
            choosesModel: backend?.capabilities.supportsModelSelection ?? true)
        dialPill.accessibilityLabel = defaults.sentence
    }

    /// The levels the starting model takes: its own where the catalog names them, the agent's
    /// otherwise.
    func effortOptions() -> [String] {
        chooser.defaults?.levels ?? []
    }

    /// `m`, ⌃m while typing, or a tap on the pill's model half: the full chooser over the fleet,
    /// with the chosen machine first, its levels on the strip, as the composer opens it.
    func presentModelChooser() {
        guard let server = chooser.server,
            let backend = viewModel.backend(forProfileID: server.profileID),
            backend.capabilities.supportsModelSelection
        else { return }
        Theme.Haptics.tap()
        let profileID = server.profileID
        let allowsServerDefault = ChatModelResolver.honoursServerDefault(backend)
        let sources = { (models: [ModelInfo]) in
            ModelFleet.sources(
                profiles: ConnectionController.shared.profiles, current: profileID,
                currentModels: models, allowsServerDefault: allowsServerDefault)
        }
        let defaults = chooser.defaults
        let picker = ModelPickerViewController(
            sources: sources(ModelCatalog.cached(for: profileID)), selected: defaults?.model,
            quotas: QuotaSurface.relevantQuotas(
                for: server.backend, among: UsageWidgetStore.cachedQuotas()),
            dial: ModelPickerViewController.Dial(
                modelName: dialPill.content.modelWord, chip: defaults?.chip,
                options: effortOptions(), agentOptions: server.agentEfforts ?? [],
                effort: defaults?.effort, contextTokens: nil,
                onEffort: { [weak self] level in self?.setStartingEffort(level) }),
            context: .composer
        ) { [weak self] pick in self?.take(pick) }
        let nav = UINavigationController(rootViewController: picker)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.selectedDetentIdentifier = .large
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
        let watch = PickerCatalogWatch.keep(
            picker: picker, profileID: profileID, backend: backend, sources: sources)
        picker.onClose = { watch.cancel() }
        Task { @MainActor in
            let fresh = await ModelCatalog.fresh(for: profileID, backend: backend)
            picker.update(sources: sources(fresh))
        }
    }

    /// A model picked in the chooser becomes the chosen server's last-used default, the way a
    /// composer pick does; one on another machine moves the sheet there, because the chat is
    /// made where its model runs. A pinned pair sets its level too; any other pick carries the
    /// level to the nearest one the model takes, and says so.
    func take(_ pick: ModelPick) {
        guard let current = chooser.server?.profileID else { return }
        let profileID = pick.profileID.isEmpty ? current : pick.profileID
        if profileID != current, chooser.servers.contains(where: { $0.profileID == profileID }) {
            chooser.chooseServer(profileID)
        }
        NewChatDefaults.record(model: pick.selection, profileID: profileID)
        if let preset = pick.preset {
            let agent = chooser.servers.first { $0.profileID == profileID }?.agentEfforts ?? []
            let carry = preset.applied(
                currentEffort: EffortPreferenceStore.globalEffort(forContextID: profileID),
                models: ModelCatalog.cached(for: profileID), agentOptions: agent)
            NewChatDefaults.record(effort: carry.level, profileID: profileID)
        } else {
            carryEffort(to: pick.selection, on: profileID)
        }
        Theme.Haptics.selection()
        serviceListing()
        reload()
    }

    private func carryEffort(to selection: ModelSelection?, on profileID: String) {
        let agent = chooser.servers.first { $0.profileID == profileID }?.agentEfforts ?? []
        let models = ModelCatalog.cached(for: profileID)
        let remembered = EffortPreferenceStore.globalEffort(forContextID: profileID)
        let carry = ModelEffort.adoption(
            remembered, for: selection, models: models, agentOptions: agent)
        guard carry.level != remembered else { return }
        NewChatDefaults.record(effort: carry.level, profileID: profileID)
        let name =
            selection.map { ModelBadge.word(for: $0, in: models) } ?? String(localized: "Auto")
        if let notice = carry.notice(modelName: name) {
            UIAccessibility.post(notification: .announcement, argument: notice)
        }
    }

    /// A level set on the ladder or the chooser's strip is the server's last-used level, the way
    /// the composer's is.
    func setStartingEffort(_ level: String?, quiet: Bool = false) {
        guard let profileID = chooser.server?.profileID else { return }
        NewChatDefaults.record(effort: level, profileID: profileID)
        if !quiet { Theme.Haptics.selection() }
        reload()
    }
}
