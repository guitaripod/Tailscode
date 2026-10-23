import TailscodeCore
import CodingAgentKitApple
import UIKit

extension HomeViewController {
    func composerTargetMenu(for aim: ComposerAim) -> UIMenu {
        switch aim.lane {
        case .chat:
            return UIMenu(
                title: String(localized: "Start the chat in…"),
                children: [
                    UIDeferredMenuElement.uncached { [weak self] completion in
                        completion(self?.composeTargets() ?? [])
                    }
                ])
        case .ask:
            return UIMenu(
                title: String(localized: "Ask on"),
                children: [
                    UIDeferredMenuElement.uncached { [weak self] completion in
                        completion(self?.askTargets() ?? [])
                    }
                ])
        case .video:
            return videoTargetMenu()
        case .image:
            assertionFailure("a render lane has no ComposerAim")
            return UIMenu()
        }
    }

    private func composeTargets() -> [UIMenuElement] {
        let current = composeTarget
        let serverMenus: [UIMenuElement] = viewModel.servers.map { profile in
            var children: [UIMenuElement] = []
            children.append(contentsOf: recentDirectories(for: profile).map { directory in
                UIAction(
                    title: (directory as NSString).lastPathComponent,
                    subtitle: directory,
                    image: UIImage(systemName: "folder"),
                    state: current?.profileID == profile.id && current?.directory == directory
                        ? .on : .off
                ) { [weak self] _ in
                    self?.setComposeTarget(profile: profile, directory: directory)
                }
            })
            children.append(
                UIAction(
                    title: String(localized: "Somewhere else…"),
                    subtitle: String(localized: "Search folders, browse, or type a path"),
                    image: UIImage(systemName: "folder.badge.plus")
                ) {
                    [weak self] _ in self?.chooseComposeTarget(profile: profile)
                })
            if viewModel.servers.count == 1 {
                return UIMenu(options: .displayInline, children: children)
            }
            return UIMenu(
                title: profile.name, subtitle: machineLine(for: profile, lane: .chat),
                image: UIImage(systemName: profile.backend.symbolName),
                children: children)
        }
        return serverMenus
    }

    /// A question carries no project, so the ask lane's chip offers machines and nothing else.
    private func askTargets() -> [UIMenuElement] {
        let current = composerAim?.profile.id
        return viewModel.servers.map { profile in
            UIAction(
                title: profile.name, subtitle: machineLine(for: profile, lane: .ask),
                image: UIImage(systemName: profile.backend.symbolName),
                state: profile.id == current ? .on : .off
            ) { [weak self] _ in self?.aimAsk(at: profile.id) }
        }
    }

    /// What a lane on a machine will run before anybody aims at it: the pill's own reading when it
    /// has been drawn, else what this device remembers for that machine — the person's pick, then
    /// the server default it already named — the level narrowed to the ones that model takes.
    private func aimedChoice(for profile: ConnectionProfile, lane: QuickAskLane) -> ModelChoice {
        let ask = lane == .ask
        var choice: ModelChoice
        if let held = modelChoices[ask ? QuickAskDefaults.contextID(forProfileID: profile.id) : profile.id] {
            choice = held
        } else {
            let context = ask ? QuickAskDefaults.aimContext(forProfileID: profile.id) : profile.id
            choice = ModelChoice(model: ModelPreferenceStore.globalModel(forContextID: context))
            if let backend = viewModel.backend(forProfileID: profile.id) {
                if choice.model == nil, !ChatModelResolver.honoursServerDefault(backend) {
                    choice.model = ChatModelResolver.knownServerDefault(profileID: profile.id)
                }
                choice.effort = ChatModelResolver.effort(
                    profileID: profile.id, backend: backend, contextID: context)
            }
        }
        guard let backend = viewModel.backend(forProfileID: profile.id),
            backend.capabilities.supportsReasoningEffort
        else { return ModelChoice(model: choice.model) }
        choice.effort = ModelEffort.surviving(
            choice.effort,
            options: ModelEffort.options(
                models: ModelCatalog.cached(for: profile.id), selection: choice.model,
                agentOptions: backend.reasoningEffortOptions))
        return choice
    }

    /// A machine row's subtitle: what it will run, and that it is not answering when it is not.
    private func machineLine(for profile: ConnectionProfile, lane: QuickAskLane) -> String {
        let choice = aimedChoice(for: profile, lane: lane)
        return AimReading.machineLine(
            modelWord: choice.model.map {
                ModelBadge.word(for: $0, in: ModelCatalog.cached(for: profile.id))
            }, effort: choice.effort,
            isReachable: viewModel.unreachable.contains(profile.id) ? false : nil)
    }

    /// Explicitly chosen recents first, then directories of past sessions.
    func recentDirectories(for profile: ConnectionProfile) -> [String] {
        let sessionDirs = viewModel.entries
            .filter { $0.profileID == profile.id }
            .compactMap(\.session.directory)
        var seen = Set<String>()
        var result: [String] = []
        for directory in FileBrowserRecents.all(for: profile.id) + sessionDirs
        where seen.insert(directory).inserted {
            result.append(directory)
            if result.count == 6 { break }
        }
        return result
    }

    /// - Parameter announces: whether a change of machine says what the new one will run. A move
    ///   that already says so in its own sentence passes false.
    func setComposeTarget(
        profile: ConnectionProfile, directory: String?, announces: Bool = true
    ) {
        let moved = askLane == .chat && composerAim?.profile.id != profile.id
        AppPreferences.lastComposeTarget = (profile.id, directory)
        resolvedComposeTarget = nil
        if let directory { FileBrowserRecents.record(directory, for: profile.id) }
        Theme.Haptics.selection()
        setLane(.chat, animated: true)
        appliedComposerState = nil
        updateComposer()
        guard announces, moved, viewModel.servers.count > 1 else { return }
        let choice = aimedChoice(for: profile, lane: .chat)
        toast(
            ComposerRetarget.sentence(
                machine: profile.name,
                modelWord: choice.model.map {
                    ModelBadge.word(for: $0, in: ModelCatalog.cached(for: profile.id))
                },
                effort: choice.effort))
    }

    /// A model that lives on another machine moves the composer there, the way a pick in the full
    /// picker does: machine, model and level are one aimed decision. The pill is seeded with the
    /// pick and the level carried onto that machine's own catalog — so it never shows the last
    /// aim's model — the folder survives only where that machine knows it, and one sentence says
    /// where the composer now points.
    func retargetCompose(to pick: ModelPick, from aim: ComposerAim) {
        retargetCompose(
            to: pick, lane: aim.lane, effort: modelChoices[aim.memoryKey]?.effort,
            directory: aim.directory)
    }

    func retargetCompose(
        to pick: ModelPick, lane: QuickAskLane, effort: String?, directory: String?
    ) {
        guard
            let profile = viewModel.servers.first(where: { $0.id == pick.profileID })
                ?? ConnectionController.shared.profiles.first(where: { $0.id == pick.profileID })
        else { return }
        let backend = viewModel.backend(forProfileID: profile.id)
        let takesLevels = backend?.capabilities.supportsReasoningEffort ?? false
        let move = ComposerRetarget.decide(
            pick: pick, directory: lane == .chat ? directory : nil,
            knownDirectories: recentDirectories(for: profile), effort: takesLevels ? effort : nil,
            models: ModelCatalog.cached(for: profile.id),
            agentOptions: backend?.reasoningEffortOptions ?? [])
        switch lane {
        case .chat:
            ModelFleet.adopt(pick)
            if takesLevels {
                EffortPreferenceStore.recordPick(move.effort, sessionKey: nil, contextID: profile.id)
            }
            modelChoices[profile.id] = move.model.map { ModelChoice(model: $0, effort: move.effort) }
            setComposeTarget(profile: profile, directory: move.directory, announces: false)
        case .ask:
            QuickAskDefaults.adopt(pick)
            if takesLevels { QuickAskDefaults.recordEffort(move.effort, forProfileID: profile.id) }
            modelChoices[QuickAskDefaults.contextID(forProfileID: profile.id)] = move.model.map {
                ModelChoice(model: $0, effort: move.effort)
            }
            aimAsk(at: profile.id)
            appliedComposerState = nil
            updateComposer()
        case .video, .image:
            assertionFailure("a render lane has no ComposerAim")
            return
        }
        toast(
            move.sentence(
                machine: profile.name,
                modelWord: move.model.map {
                    ModelBadge.word(for: $0, in: ModelCatalog.cached(for: profile.id))
                }))
    }

    /// Moving the question to another machine takes the draft with it: what is typed belongs to
    /// the question, not to the server it was pointed at a second ago, and the words already filed
    /// under the machine being left stay there for the next time it is aimed at.
    private func aimAsk(at profileID: String) {
        guard profileID != composerAim?.profile.id else { return }
        QuickAskDefaults.record(profileID: profileID)
        Theme.Haptics.selection()
        appliedComposerState = nil
        updateComposer()
    }

    /// Aims the docked composer at another machine, the Home half of the fleet's "start a chat
    /// there" move. The compose is a promise about where the next session will live, so it is the
    /// one thing on this screen that can point somewhere else.
    ///
    /// A pick carried from a chat aims the model and level too, through the same move as a pick
    /// made here; `directory` is the folder the chat was in, kept when that machine knows it.
    func aimCompose(
        at profileID: String, carrying pick: ModelPick? = nil, effort: String? = nil,
        directory: String? = nil
    ) {
        guard let profile = ConnectionController.shared.profiles.first(where: { $0.id == profileID })
        else { return }
        if let pick {
            retargetCompose(to: pick, lane: .chat, effort: effort, directory: directory)
        } else {
            setComposeTarget(profile: profile, directory: nil)
        }
        focusComposer()
    }

    /// "Somewhere else" is one screen, not two: the same `NewChatViewController` the chat list
    /// opens, asked only for the answer. Browsing the server's tree is one of its rows, so a
    /// server that can list its files and one that cannot are the same gesture here. Never opens
    /// a bare path prompt as the fallback.
    func chooseComposeTarget(profile: ConnectionProfile) {
        NewChatFlow.chooseDirectory(from: self, profile: profile, viewModel: viewModel) {
            [weak self] profileID, directory in
            guard let self,
                let picked = self.viewModel.servers.first(where: { $0.id == profileID })
            else { return }
            self.setComposeTarget(profile: picked, directory: directory)
            self.composerBar.focus()
        }
    }

    /// What the words turn out to be, asked of the shared grammar before anything is minted: a
    /// command the aimed machine knows runs as a command in the conversation this send creates, and
    /// everything else — including a word on a server that reads its own slashes out of the prompt
    /// — goes as the words that were written.
    private func composerDecision(_ text: String, on profile: ConnectionProfile) -> QuickAskSend {
        guard let backend = viewModel.backend(forProfileID: profile.id),
            backend.capabilities.supportsCommands
        else { return QuickAskSend(text: text, kind: .prompt) }
        return QuickAskSend.decide(
            text: text, commands: commands,
            resolvesFromPromptText: backend.resolvesCommandsFromPromptText)
    }

    /// The session is created only now, on commit; the box keeps the words and whatever is in its
    /// strip until the create succeeds, so a dead server loses nothing.
    func composerSend(_ text: String) {
        if askLane == .video { return renderSend(text) }
        if askLane == .image { return paintSend(text) }
        guard let aim = composerAim,
            QuickAskComposition.canSend(text: text, attachments: attachments.count)
        else { return }
        let send = composerDecision(text, on: aim.profile)
        if case .command(let command, _) = send.kind { SlashRecents.record(command.name) }
        hideCommandPalette()
        dismissFailure()
        mint(aim: aim, send: send)
    }

    func mint(aim: ComposerAim, send: QuickAskSend) {
        lastAttempt = (aim, send)
        composerBar.setSending(true)
        Task { [weak self] in
            guard let self else { return }
            let result = await self.viewModel.createSession(
                on: aim.profile, directory: aim.directory)
            self.composerBar.setSending(false)
            switch result {
            case .success(let entry):
                self.landed(entry, aim: aim, send: send)
            case .failure(let failure):
                Theme.Haptics.error()
                self.composerBar.setText(send.text)
                DraftStore.record(send.text, for: aim.draftScope)
                self.showFailure(failure)
            }
        }
    }

    /// The handover is one movement: the conversation is opened with the words and whatever rode
    /// with them already on their way, and the box is emptied only once the machine has agreed to
    /// hold them.
    func landed(_ entry: SessionEntry, aim: ComposerAim, send: QuickAskSend) {
        switch aim.lane {
        case .chat:
            if let directory = aim.directory {
                FileBrowserRecents.record(directory, for: aim.profile.id)
            }
            AppPreferences.lastComposeTarget = (aim.profile.id, aim.directory)
        case .ask:
            QuickAskDefaults.record(profileID: aim.profile.id)
            QuickAskDefaults.stamp(profileID: aim.profile.id, sessionID: entry.session.id)
        case .video, .image:
            assertionFailure("a render lane has no ComposerAim")
        }
        let payload = attachments.map(\.prompt)
        attachments = []
        refreshAttachments()
        composerBar.clearText()
        DraftStore.clear(aim.draftScope)
        view.endEditing(true)
        Theme.Haptics.success()
        openChat(
            for: entry, seeding: modelChoices[aim.memoryKey],
            sending: (send: send, attachments: payload))
    }
}
