import TailscodeCore
import CodingAgentKit
import UIKit

extension HomeViewController {
    /// Where the next message goes. A target the user chose is stored and authoritative; everything
    /// else is a guess drawn from the chat list, which re-sorts by itself every time another device
    /// finishes a turn or a poll lands. Re-deriving the guess on each of those would move the
    /// destination — and with it the scope the composer's draft is filed under — with nobody
    /// touching the phone, so the guess is made once and kept until a real retarget or a change to
    /// the servers themselves.
    var composeTarget: (profileID: String, directory: String?)? {
        if let stored = AppPreferences.lastComposeTarget,
            viewModel.servers.contains(where: { $0.id == stored.profileID })
        {
            return stored
        }
        if let memo = resolvedComposeTarget,
            viewModel.servers.contains(where: { $0.id == memo.profileID })
        {
            return memo
        }
        let resolved = resolveComposeTarget()
        resolvedComposeTarget = resolved
        return resolved
    }

    private func resolveComposeTarget() -> (profileID: String, directory: String?)? {
        if let recent = viewModel.entries.first(where: { $0.session.directory != nil }) {
            return (recent.profileID, recent.session.directory)
        }
        guard let first = viewModel.servers.first else { return nil }
        return (first.id, FileBrowserRecents.all(for: first.id).first)
    }

    /// Everything the lane decides, resolved in one place. The chat lane goes to a project the
    /// person keeps aimed; the ask lane goes to the machine the last question went to, falling back
    /// to whatever the composer was already pointed at rather than to an arbitrary server.
    var composerAim: ComposerAim? {
        switch askLane {
        case .video, .image:
            return nil
        case .chat:
            guard let target = composeTarget,
                let profile = viewModel.servers.first(where: { $0.id == target.profileID })
            else { return nil }
            return ComposerAim(
                lane: .chat, profile: profile, directory: target.directory,
                memoryKey: profile.id, resolutionContext: nil,
                draftScope: .home(profileID: profile.id, directory: target.directory))
        case .ask:
            guard
                let id = QuickAskDefaults.target(
                    among: viewModel.servers.map(\.id), fallback: composeTarget?.profileID),
                let profile = viewModel.servers.first(where: { $0.id == id })
            else { return nil }
            return ComposerAim(
                lane: .ask, profile: profile, directory: nil,
                memoryKey: QuickAskDefaults.contextID(forProfileID: profile.id),
                resolutionContext: QuickAskDefaults.aimContext(forProfileID: profile.id),
                draftScope: .quickAsk(profileID: profile.id))
        }
    }

    /// Reapplies only when something the user can see actually changed: the live
    /// refresh runs this every few seconds, and reassigning a button's menu
    /// underneath an open one is exactly the kind of churn that makes a picker
    /// flicker shut mid-choice. Both menus resolve their contents when opened,
    /// so skipping the rebuild can't serve a stale list.
    func updateComposer() {
        composerBar.isHidden = viewModel.servers.isEmpty && !askLane.needsRenderer
        if askLane == .video {
            updateVideoComposer()
            return
        }
        if askLane == .image {
            updateImageComposer()
            return
        }
        guard let aim = composerAim else {
            updateSuggestions()
            return
        }
        syncComposerDraft(to: aim.draftScope)
        loadCommandsIfNeeded(for: aim.profile)
        let title = composerChipTitle(for: aim)
        let modelLabel = modelChipLabel(for: aim)
        composerBar.ultracodeEffort =
            modelChoices[aim.memoryKey]?.effort
            ?? EffortPreferenceStore.globalEffort(
                forContextID: aim.resolutionContext ?? aim.profile.id)
        let state = [
            aim.lane.rawValue, aim.profile.id, aim.directory ?? "", title, modelLabel ?? "",
            dialOptions(for: aim).joined(separator: ","),
        ].joined(separator: "|")
        guard state != appliedComposerState else { return }
        appliedComposerState = state
        let icon = UIImage(
            systemName: aim.profile.backend.symbolName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))?
            .withTintColor(aim.profile.backend.brandColor, renderingMode: .alwaysOriginal)
        composerBar.setContext(
            icon: icon, title: title, menu: composerTargetMenu(for: aim),
            opensChooserOnTap: aim.lane == .chat)
        updateModelChip(for: aim, label: modelLabel)
        refreshAbilities(for: aim)
        updateSuggestions()
        view.setNeedsLayout()
    }

    /// The video lane's chrome: the destination chip names the renderer the way the chat lane
    /// names its project — or says none is set up and opens the setup — the model chip has nothing
    /// to say, the paperclip is not offered, and the walkable settings ride as chips under the box.
    private func updateVideoComposer() {
        let board = ForgeRunner.shared.board
        let configured = ForgeRunner.shared.endpoint != nil
        composerBar.setDial(nil, menu: nil)
        composerBar.showsAttach = false
        composerBar.ultracodeEffort = nil
        let title = board.value(of: .endpoint)
        let state = ["video", title, "\(configured)"].joined(separator: "|")
        if state != appliedComposerState {
            appliedComposerState = state
            let icon = UIImage(
                systemName: configured ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))?
                .withTintColor(
                    configured ? Theme.Color.accent : Theme.Color.warning,
                    renderingMode: .alwaysOriginal)
            composerBar.setContext(icon: icon, title: title, menu: videoTargetMenu())
        }
        videoChips.update(board: board)
        updateSuggestions()
        view.setNeedsLayout()
    }

    /// The image lane's chrome: the destination chip names the machine that will paint — and what
    /// it last said about itself, since a renderer that was asleep or missing model files is worth
    /// knowing before the send rather than after — the model chip has nothing to say, the paperclip
    /// is not offered, and the two decisions ride as chips under the box.
    private func updateImageComposer() {
        let studio = ImageStudio.shared
        let door = studio.door
        composerBar.setDial(nil, menu: nil)
        composerBar.showsAttach = false
        composerBar.ultracodeEffort = nil
        let title = door.machine ?? ImageGenSurface.title
        let tone = door.tone
        let state = ["image", title, "\(tone?.rawValue ?? "-")"].joined(separator: "|")
        if state != appliedComposerState {
            appliedComposerState = state
            let icon = UIImage(
                systemName: tone == nil
                    ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))?
                .withTintColor(
                    tone == .attention ? Theme.Color.warning : Theme.Color.accent,
                    renderingMode: .alwaysOriginal)
            composerBar.setContext(icon: icon, title: title, menu: imageTargetMenu())
        }
        imageChips.update(
            slot: studio.slot, sighting: studio.sighting,
            referenceMenu: imageIntake.menu(references: studio.slot.references))
        updateSuggestions()
        view.setNeedsLayout()
    }

    private func imageTargetMenu() -> UIMenu {
        UIMenu(
            subtitle: ImageGenDoor.current().line,
            children: [
                UIAction(
                    title: ImageGenSurface.title,
                    image: UIImage(systemName: ImageGenEntryPoint.symbol)
                ) { [weak self] _ in self?.presentImage() },
                UIAction(
                    title: Localized.text("See what is missing"),
                    image: UIImage(systemName: "info.circle")
                ) { [weak self] _ in self?.presentImageMachine() },
                UIAction(
                    title: ForgeSetup.title, image: UIImage(systemName: "desktopcomputer")
                ) { [weak self] _ in self?.presentRendererSetup() },
            ])
    }

    private func presentImageMachine() {
        Theme.Haptics.tap()
        let held = ImageStudio.shared
        MediaSetupGate.present(
            endpoint: held.endpoint.forgeEndpoint, focus: .pictures, from: self, onChanged: { held.adoptDoor() })
    }

    /// Sending from the image lane starts the render and opens the studio over it, so the first
    /// seconds of waiting are watched rather than guessed at — and everything that happens to the
    /// picture afterwards is one screen rather than a hunt. A render already out is never
    /// cancelled by a send: the surface simply opens on it.
    func paintSend(_ text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        let studio = ImageStudio.shared
        studio.rememberDraft(words)
        if !studio.isPainting {
            Theme.Haptics.send()
            studio.submit(prompt: words)
        }
        view.endEditing(true)
        presentImage()
    }

    func videoTargetMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(
                title: ForgeSurface.title, image: UIImage(systemName: ForgeEntryPoint.symbol)
            ) { [weak self] _ in self?.presentVideo() },
            UIAction(
                title: ForgeSetup.title, image: UIImage(systemName: "desktopcomputer")
            ) { [weak self] _ in self?.presentRendererSetup() },
        ])
    }

    private func presentRendererSetup() {
        Theme.Haptics.tap()
        let nav = UINavigationController(rootViewController: ForgeSetupViewController())
        nav.navigationBar.prefersLargeTitles = true
        present(nav, animated: true)
    }

    /// Sending from the video lane is the forge's own begin: a configured renderer starts the
    /// render and the surface opens over the work so the first seconds of waiting are watched; a
    /// missing one opens the same surface leading with its setup instead of failing the send. A
    /// render already out is never cancelled by a send — the surface simply opens on it.
    func renderSend(_ text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        let runner = ForgeRunner.shared
        runner.describe(words)
        if let action = runner.begin(), case .render(let recipe) = action {
            Theme.Haptics.send()
            runner.render(recipe)
        }
        view.endEditing(true)
        presentVideo()
    }

    /// A chat names the project it will live in; a question has none to name, so the chip says
    /// only which machine is being asked rather than inventing a place for the answer to live.
    private func composerChipTitle(for aim: ComposerAim) -> String {
        guard aim.lane == .chat, let directory = aim.directory else { return aim.profile.name }
        return "\((directory as NSString).lastPathComponent) · \(aim.profile.name)"
    }

    /// The chip names the model the next message will actually run on — resolved
    /// exactly the way the chat screen resolves it — so starting a chat is never
    /// a blind commitment to whatever the server happens to default to. Nil for
    /// a backend that has neither model nor effort control, which then shows no
    /// chip at all.
    private func modelChipLabel(for aim: ComposerAim) -> String? {
        guard let backend = viewModel.backend(forProfileID: aim.profile.id),
            backend.capabilities.supportsModelSelection
                || backend.capabilities.supportsReasoningEffort
        else { return nil }
        let choice = modelChoices[aim.memoryKey] ?? ModelChoice()
        return ModelBadge.label(
            model: choice.model, effort: choice.effort,
            catalog: ModelCatalog.cached(for: aim.profile.id))
    }

    private func updateModelChip(for aim: ComposerAim, label: String?) {
        guard label != nil, let backend = viewModel.backend(forProfileID: aim.profile.id) else {
            composerBar.setDial(nil, menu: nil)
            return
        }
        configureDialPill()
        let choice = modelChoices[aim.memoryKey] ?? ModelChoice()
        let options = dialOptions(for: aim)
        composerBar.setDial(
            ModelDialPill.Content(
                modelWord: choice.model.map {
                    ModelBadge.word(for: $0, in: ModelCatalog.cached(for: aim.profile.id))
                } ?? String(localized: "Auto"),
                chip: ModelBadge.chip(
                    selection: choice.model, effort: nil,
                    catalog: ModelCatalog.cached(for: aim.profile.id)),
                effort: ModelEffort.surviving(choice.effort, options: options), options: options,
                choosesModel: backend.capabilities.supportsModelSelection),
            menu: modelMenu(for: aim, backend: backend))
        resolveModelChoiceIfNeeded(for: aim, backend: backend)
    }

    /// The levels the model aimed at takes, which is what the pill offers: none draws no effort half.
    func dialOptions(for aim: ComposerAim) -> [String] {
        guard let backend = viewModel.backend(forProfileID: aim.profile.id),
            backend.capabilities.supportsReasoningEffort
        else { return [] }
        let choice = modelChoices[aim.memoryKey] ?? ModelChoice()
        return ModelEffort.options(
            models: ModelCatalog.cached(for: aim.profile.id), selection: choice.model,
            agentOptions: backend.reasoningEffortOptions)
    }

    private func configureDialPill() {
        let pill = composerBar.dialPill
        pill.railHost = view
        pill.railBelow = composerBar
        pill.onEffort = { [weak self] level in
            guard let self, let aim = self.composerAim else { return }
            self.setComposeEffort(level, for: aim)
        }
        pill.onScrub = { [weak self] level in
            guard let self, let aim = self.composerAim else { return }
            self.setComposeEffort(level, for: aim, quiet: true)
        }
        pill.onCycle = { [weak self] delta in self?.cycleComposePreset(by: delta) }
        pill.footer = { rung in EffortRail.footer(for: rung, yours: nil) }
    }

    /// Where every pin stands from the aimed server: the ones it runs, through the doors it lists,
    /// and the ones that live on another machine.
    func composePins(for aim: ComposerAim) -> PinPlacement {
        ModelPresetCycle.placement(
            ModelPresetStore.all(), models: ModelCatalog.cached(for: aim.profile.id),
            acceptsAnyModelID: ModelFleet.acceptsAnyModelID(aim.profile.backend),
            elsewhere: ModelFleet.sources(
                profiles: ConnectionController.shared.profiles, current: aim.profile.id))
    }

    func cycleComposePreset(by delta: Int) {
        guard let aim = composerAim else { return }
        let choice = modelChoices[aim.memoryKey] ?? ModelChoice()
        let pins = composePins(for: aim)
        guard
            let preset = ModelPresetCycle.step(
                pins.reachable, model: choice.model, effort: choice.effort, by: delta)
        else {
            toast(pins.awayNotice ?? String(localized: "Pin a model and level in the model menu"))
            return
        }
        setComposePreset(preset, for: aim)
    }

    /// What the chat screen's picker does with the fleet, on Home: a machine that did not answer
    /// the last listing says so in every menu that offers its models.
    var composeReachability: [String: Bool] {
        Dictionary(viewModel.unreachable.map { ($0, false) }, uniquingKeysWith: { first, _ in first })
    }

    func setComposePreset(_ preset: ModelPreset, for aim: ComposerAim) {
        let backend = viewModel.backend(forProfileID: aim.profile.id)
        let current = (modelChoices[aim.memoryKey] ?? ModelChoice()).effort
        let carry = preset.applied(
            currentEffort: current, models: ModelCatalog.cached(for: aim.profile.id),
            agentOptions: backend?.reasoningEffortOptions ?? [])
        setComposeModel(preset.selection, for: aim, announces: false)
        setComposeEffort(carry.level, for: aim)
        let name = ModelBadge.word(for: preset.selection, in: ModelCatalog.cached(for: aim.profile.id))
        toast(carry.notice(modelName: name) ?? ModelPresetCycle.said(preset, modelName: name))
    }

    private func resolveModelChoiceIfNeeded(for aim: ComposerAim, backend: any CodingAgentBackend) {
        guard modelChoices[aim.memoryKey] == nil,
            resolvingModels.insert(aim.memoryKey).inserted
        else { return }
        Task { @MainActor in
            let choice = await ChatModelResolver.choice(
                profileID: aim.profile.id, backend: backend, contextID: aim.resolutionContext)
            resolvingModels.remove(aim.memoryKey)
            modelChoices[aim.memoryKey] = choice
            updateComposer()
        }
    }
}
