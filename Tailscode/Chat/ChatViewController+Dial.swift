import MidgarCore
import TailscodeCore
import CodingAgentKit
import UIKit

extension ChatViewController {
    /// The pill in the composer carries both the model and the effort, and names them. It reads the
    /// displayed derivation — pick, then transcript, then session record — while the menu's
    /// checkmarks stay on the explicit pick, so "Auto" remains checked for a chat the server is
    /// still deciding for.
    func refreshDial() {
        guard viewModel.supportsModelSelection || viewModel.supportsReasoningEffort else {
            composer.accessory = nil
            composer.heatColor = nil
            return
        }
        if composer.accessory !== dialPill {
            dialPill.railHost = view
            dialPill.railBelow = composer
            dialPill.onEffort = { [weak self] level in self?.setEffortFromDial(level) }
            dialPill.onCycle = { [weak self] delta in self?.cyclePreset(by: delta) }
            dialPill.footer = { [weak self] rung in self?.railFooter(for: rung) }
            composer.accessory = dialPill
        }
        let model = viewModel.displayedModel
        let effort = viewModel.displayedEffort
        dialPill.content = ModelDialPill.Content(
            modelWord: model.map { ModelBadge.word(for: $0, in: availableModels) }
                ?? String(localized: "Auto"),
            chip: ModelBadge.chip(selection: model, effort: nil, catalog: availableModels),
            effort: effort, options: viewModel.reasoningEffortOptions,
            choosesModel: viewModel.supportsModelSelection)
        dialPill.modelMenu = UIMenu(title: String(localized: "Model"), children: dialMenuElements())
        composer.heatColor = Self.heatColor(for: effort)
    }

    /// A hot level, from xhigh up, marks the top of the box; ultracode has its own aura.
    private static func heatColor(for effort: String?) -> UIColor? {
        guard let effort, !ModelDial.isPower(effort), (ModelDial.rank(effort) ?? 0) >= 4 else {
            return nil
        }
        return Theme.Color.modelEffort(effort)
    }

    private func dialMenuElements() -> [UIMenuElement] {
        let allowsAuto = ChatModelResolver.honoursServerDefault(viewModel.backend)
        return ModelMenu.elements(
            sources: ModelFleet.sources(
                profiles: ConnectionController.shared.profiles, current: viewModel.contextID,
                currentModels: viewModel.supportsModelSelection ? availableModels : [],
                allowsServerDefault: allowsAuto, reachability: pickerReachability),
            choice: ModelChoice(model: viewModel.selectedModel, effort: viewModel.currentEffort),
            efforts: viewModel.backend.reasoningEffortOptions,
            allowsServerDefault: allowsAuto,
            quotas: QuotaSurface.relevantQuotas(
                for: viewModel.backend.agentType, among: UsageWidgetStore.cachedQuotas()),
            includesEffort: false,
            actions: ModelMenu.Actions(
                selectModel: { [weak self] selection in self?.chooseModel(selection) },
                selectEffort: { [weak self] level in self?.setEffortFromDial(level) },
                selectPreset: { [weak self] preset in self?.choose(preset) },
                browseAll: { [weak self] in self?.presentModelPicker() },
                selectElsewhere: { [weak self] pick in self?.apply(pick) }))
    }

    func chooseModel(_ selection: ModelSelection?) {
        Theme.Haptics.selection()
        let carry = viewModel.selectModel(selection)
        updateNavControls()
        saySwitch(carry, selection: selection)
    }

    func choose(_ preset: ModelPreset) {
        Theme.Haptics.selection()
        let carry = viewModel.apply(preset)
        updateNavControls()
        saySwitch(carry, selection: preset.selection)
    }

    /// What a model change did to the level, said where it happened: a word that moved on its own
    /// is a surprise, and one that is told is a fact.
    private func saySwitch(_ carry: EffortCarry, selection: ModelSelection?) {
        let name = selection.map { ModelBadge.word(for: $0, in: availableModels) }
            ?? String(localized: "Auto")
        guard let notice = carry.notice(modelName: name) else { return }
        presentToast(notice, duration: 3)
    }

    private func setEffortFromDial(_ level: String?) {
        viewModel.setEffort(level)
        updateNavControls()
    }

    private func railFooter(for rung: EffortRung) -> String? {
        EffortRail.footer(
            for: rung,
            yours: EffortHistory.line(level: rung.level, messages: viewModel.state.messages))
    }

    /// Steps along the pinned pairs without opening anything: a swipe on the pill, a chord.
    func cyclePreset(by delta: Int) {
        guard let preset = viewModel.presetStep(by: delta) else {
            let away = viewModel.presetPlacement(
                elsewhere: ModelFleet.sources(
                    profiles: ConnectionController.shared.profiles, current: viewModel.contextID)
            ).awayNotice
            presentToast(away ?? String(localized: "Pin a model and level in the model menu"))
            return
        }
        applyPreset(preset)
    }

    func applyPreset(_ preset: ModelPreset) {
        let carry = viewModel.apply(preset)
        updateNavControls()
        let name = ModelBadge.word(for: preset.selection, in: availableModels)
        presentToast(carry.notice(modelName: name) ?? ModelPresetCycle.said(preset, modelName: name))
    }

    /// One notch hotter or colder from a hardware key, said the way the desktops say it: the pill
    /// moves, and a screen reader is told where it landed.
    func stepEffort(by delta: Int) {
        let options = viewModel.reasoningEffortOptions
        guard ModelEffort.isOffered(options: options) else {
            let name = viewModel.displayedModel.map { ModelBadge.word(for: $0, in: availableModels) }
                ?? String(localized: "Auto")
            presentToast(ModelDial.headline(modelName: name, options: []))
            return
        }
        let notch = ModelDial.notch(from: viewModel.displayedEffort, by: delta, options: options)
        setEffortFromDial(notch.level)
        Theme.Haptics.notch()
        EffortSpeech.note(notch)
    }

    @objc func presentModelPicker() {
        Theme.Haptics.tap()
        presentChooser(context: .chat) { [weak self] pick in self?.apply(pick) }
    }

    /// The one chooser, opened for what the pick will do: change this chat, or branch it from an
    /// answer's question. A branch carries no dial, because the level in force belongs to this chat
    /// and a pick made here never changes it.
    func presentChooser(
        context: ModelPickerViewController.Context, onSelect: @escaping (ModelPick) -> Void
    ) {
        if context == .chat, let demo = Self.demoPicker(onSelect: onSelect) {
            modelPicker = demo
            demo.onClose = { [weak self] in self?.modelPicker = nil }
            present(UINavigationController(rootViewController: demo), animated: true)
            return
        }
        let picker = ModelPickerViewController(
                sources: ModelFleet.sources(
                    profiles: ConnectionController.shared.profiles,
                    current: viewModel.contextID, currentModels: availableModels,
                    allowsServerDefault: ChatModelResolver.honoursServerDefault(viewModel.backend),
                    reachability: pickerReachability),
                selected: viewModel.selectedModel,
                quotas: QuotaSurface.relevantQuotas(
                    for: viewModel.backend.agentType, among: UsageWidgetStore.cachedQuotas()),
                dial: context == .chat ? pickerDial() : nil,
                context: context, onSelect: onSelect)
        modelPicker = picker
        picker.onClose = { [weak self] in
            self?.pickerWatch?.cancel()
            self?.pickerWatch = nil
            self?.modelPicker = nil
        }
        let contextID = viewModel.contextID
        let backend = viewModel.backend
        Task { @MainActor in
            let fresh = await ModelCatalog.fresh(for: contextID, backend: backend)
            picker.update(
                sources: ModelFleet.sources(
                    profiles: ConnectionController.shared.profiles,
                    current: contextID, currentModels: fresh,
                    allowsServerDefault: ChatModelResolver.honoursServerDefault(backend),
                    reachability: pickerReachability))
        }
        pickerWatch?.cancel()
        pickerWatch = Task { [weak self, weak picker] in
            for await reading in ModelCatalogWatch.readings(profileID: contextID, backend: backend)
            {
                guard let self, let picker else { return }
                self.modelsReachable = reading.reachable
                self.availableModels = reading.models
                picker.update(
                    sources: ModelFleet.sources(
                        profiles: ConnectionController.shared.profiles,
                        current: contextID, currentModels: reading.models,
                        allowsServerDefault: ChatModelResolver.honoursServerDefault(backend),
                        reachability: self.pickerReachability))
            }
        }
        let nav = UINavigationController(rootViewController: picker)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.selectedDetentIdentifier = .large
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    /// What the picker needs from this chat to set the level and pin pairs from its own sheet.
    private func pickerDial() -> ModelPickerViewController.Dial {
        let model = viewModel.displayedModel
        return ModelPickerViewController.Dial(
            modelName: model.map { ModelBadge.word(for: $0, in: availableModels) }
                ?? String(localized: "Auto"),
            chip: ModelBadge.chip(selection: model, effort: nil, catalog: availableModels),
            options: viewModel.reasoningEffortOptions,
            agentOptions: viewModel.backend.reasoningEffortOptions,
            effort: viewModel.displayedEffort, contextTokens: transcriptFill?.used,
            onEffort: { [weak self] level in self?.setEffortFromDial(level) })
    }

    /// What the picker names the current server's ask as: `nil` while it is still out.
    private var pickerReachability: [String: Bool] {
        guard let reachable = modelsReachable else { return [:] }
        return [viewModel.contextID: reachable]
    }

    /// The shared fixture, when a run asks for it: a fleet's worth of catalog with no fleet
    /// attached, so the surface that has to survive two hundred models can be looked at on all
    /// three desks without owning two hundred models.
    private static func demoPicker(
        onSelect: @escaping (ModelPick) -> Void
    ) -> ModelPickerViewController? {
        #if DEBUG
            guard ProcessInfo.processInfo.environment["TAILSCODE_OPEN_MODELS"] == "demo" else {
                return nil
            }
            DialTour.pinFixturePairs()
            return ModelPickerViewController(
                sources: ModelChooserDemo.sources(), selected: ModelChooserDemo.selected,
                quotas: ModelChooserDemo.quotas(), recents: ModelChooserDemo.recents,
                dial: ModelPickerViewController.Dial(
                    modelName: "Opus",
                    chip: ModelBadge.chip(
                        selection: ModelChooserDemo.selected, effort: nil,
                        catalog: ModelChooserDemo.sources().flatMap(\.models)),
                    options: ["low", "medium", "high"], agentOptions: ["low", "medium", "high"],
                    effort: "high", contextTokens: 148_900, onEffort: { _ in }),
                onSelect: onSelect)
        #else
            return nil
        #endif
    }

    /// A model on this server changes what this chat runs. A model on another one cannot — the
    /// conversation is a session on the machine that answers it — so the app says so and offers the
    /// only thing it can honour: the same model, on that machine, in a new chat.
    func apply(_ pick: ModelPick) {
        guard pick.isElsewhere else {
            if let preset = pick.preset {
                choose(preset)
            } else {
                chooseModel(pick.selection)
            }
            return
        }
        let plan = CarryPlan.continuing(
            pick: pick, title: navDisplayTitle, messages: viewModel.state.messages)
        let words = plan.moveWords(for: pick)
        let alert = UIAlertController(
            title: words.title, message: words.body, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: words.action, style: .default) { [weak self] _ in
                self?.moveToHome(pick, carrying: plan)
            })
        present(alert, animated: true)
    }

    /// Leaves this chat for the Home composer aimed at the pick, with what the pick carries: the
    /// level and folder this chat was in, and the brief and the draft of the conversation left
    /// behind.
    private func moveToHome(_ pick: ModelPick, carrying plan: CarryPlan) {
        let effort: String?
        switch pick.preset?.effort {
        case .level(let level)?: effort = level
        case .server?: effort = nil
        default: effort = viewModel.displayedEffort
        }
        let directory = viewModel.session.directory
        let stacked = navigationController?.viewControllers.first as? HomeViewController
        let workspace = sequence(first: self as UIViewController, next: \.parent)
            .lazy.compactMap { $0 as? WorkspaceSplitViewController }.first
        Theme.Haptics.success()
        if stacked == nil, let workspace {
            workspace.showHome()
        } else {
            navigationController?.popToRootViewController(animated: true)
        }
        guard let home = stacked ?? workspace?.home else { return ModelFleet.adopt(pick) }
        home.aimCompose(
            at: pick.profileID, carrying: pick, effort: effort, directory: directory, carry: plan)
    }

    /// An answer asked again on another model: the chooser says what a pick does, so a pick needs
    /// no alert. The new chat starts from what came before the question, with the question waiting
    /// unsent in the Home composer.
    func tryWithAnotherModel(answerID: String) {
        presentChooser(context: .branch) { [weak self] pick in
            guard let self else { return }
            let plan = CarryPlan.branching(
                pick: pick, title: self.navDisplayTitle, messages: self.viewModel.state.messages,
                answerID: answerID)
            self.moveToHome(pick, carrying: plan)
        }
    }

    /// Diagnostic: fires when a still-pending bubble (queued item or local echo)
    /// carries the same text as a message already in the server transcript — the
    /// exact condition that renders a duplicate. Logs the shape so the trigger
    /// (reuse path, resync, stale echo) can be pinned from a device log.
    static func logPendingPhantom(state: ConversationState, viewModel: ChatViewModel) {
        let pendingTexts = viewModel.queued.map(\.text) + viewModel.pendingSends.map(\.text)
        guard !pendingTexts.isEmpty else { return }
        let serverUserTexts = Set(
            state.messages.filter { $0.role == .user }.map { $0.text })
        let phantoms = pendingTexts.filter { serverUserTexts.contains($0) }
        guard !phantoms.isEmpty else { return }
        MidgarLog.error(
            "pending phantom: \(phantoms.count) pending bubble(s) duplicate a server message — "
                + "queued=\(viewModel.queued.count) echoes=\(viewModel.pendingSends.count) "
                + "serverUsers=\(serverUserTexts.count) first=\"\(phantoms[0].prefix(30))\"", category: .chat)
    }
}
