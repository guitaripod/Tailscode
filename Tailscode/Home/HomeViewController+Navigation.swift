import TailscodeCore
import CodingAgentKit
import CodingAgentKitApple
import UIKit

extension HomeViewController {
    func openSession(withID id: String) {
        if let top = navigationController?.topViewController as? ChatViewController,
            top.sessionID == id
        {
            return
        }
        guard let entry = viewModel.entries.first(where: { $0.session.id == id }) else {
            pendingDeepLink = (id, Date())
            Task { await load() }
            return
        }
        pendingDeepLink = nil
        land(on: entry)
    }

    /// Clearing the way to a chat and pushing it are two navigation transitions, and starting the
    /// second before the first has finished is how a deep link corrupts the stack: the push waits
    /// for the dismissal it depends on. A notification tap can also arrive mid-transition or before
    /// Home has a window, so the push itself is deferred until the stack is quiet.
    func land(on entry: SessionEntry) {
        loadViewIfNeeded()
        view.endEditing(true)
        let open = { [weak self] in
            guard let self else { return }
            if let nav = self.navigationController, nav.topViewController !== self {
                nav.popToRootViewController(animated: false)
            }
            DispatchQueue.main.async { [weak self] in
                self?.openChat(for: entry)
            }
        }
        if let presented = presentedViewController {
            presented.dismiss(animated: false, completion: open)
            return
        }
        open()
    }

    /// Stays parked until the session actually appears: the cold-launch
    /// snapshot applies before the list loads, and consuming (and dropping)
    /// the link on that early pass loses notification taps.
    func consumePendingDeepLink() {
        guard let pending = pendingDeepLink else { return }
        guard Date().timeIntervalSince(pending.parkedAt) < 30 else {
            pendingDeepLink = nil
            return
        }
        guard let entry = viewModel.entries.first(where: { $0.session.id == pending.sessionID })
        else { return }
        pendingDeepLink = nil
        land(on: entry)
    }

    /// Starts the conversation a finger has come down on, before the finger lifts.
    ///
    /// The press is the intent and the lift only confirms it, so the tenth of a second between
    /// them, and the push after, is spent reading the chat: its transcript from this device's
    /// cache, the stream dialled, the server asked what changed. The chat that opens renders what
    /// is already in memory instead of a placeholder. A press that turns into a scroll costs one
    /// read: the conversation is unbound, so it stops itself the moment it settles, and nothing
    /// holds on to it past a few seconds.
    func warm(_ entry: SessionEntry) {
        guard
            SessionActivity.shared.retainedViewModel(
                for: entry.session.id, contextID: entry.profileID) == nil,
            warmed?.session.id != entry.session.id || warmed?.contextID != entry.profileID,
            let backend = viewModel.backend(for: entry)
        else { return }
        let chat = ChatViewModel(
            backend: backend, session: entry.session, contextID: entry.profileID,
            serverName: entry.profileName)
        chat.isBound = false
        warmed = chat
        chat.start()
        AppLogger.session.info("warm session=\(entry.session.id)")
        Task { @MainActor [weak self, weak chat] in
            try? await Task.sleep(for: Self.warmLifetime)
            guard let self, let chat, self.warmed === chat else { return }
            self.warmed = nil
            let kept = SessionActivity.shared.retainedViewModel(
                for: chat.session.id, contextID: chat.contextID)
            if !chat.isBound, kept !== chat { chat.stop() }
        }
    }

    private static let warmLifetime: Duration = .seconds(8)

    /// The warmed conversation, if it is the one being opened.
    private func takeWarmed(_ entry: SessionEntry) -> ChatViewModel? {
        guard let chat = warmed, chat.session.id == entry.session.id,
            chat.contextID == entry.profileID
        else { return nil }
        warmed = nil
        return chat
    }

    /// Opens a conversation, and — when the caller has one — puts a question into it.
    ///
    /// The question travels *with* the open rather than being chained onto what this returns.
    /// Every early exit here returns nil (the chat is already on screen, a push is mid-flight,
    /// the server is gone), and a caller that wrote `openChat(…)?.send(text)` therefore dropped
    /// the words silently on each of them: the chat opened, the question did not. A quick ask's
    /// dismissal is exactly when a transition is most likely to be running, which is what made it
    /// a coin toss. So `sending` is carried through the retry, delivered to a chat already open,
    /// and sent by the one path that has the view model.
    ///
    /// The question travels as a decision rather than as words (`QuickAskSend`), because a slash
    /// typed into a surface that has no conversation yet still has to run as a command in the one
    /// it mints. Both roads out of here hand it to the same `deliver`: the chat already on screen
    /// used to be the road that quietly bypassed the grammar.
    @discardableResult
    func openChat(
        for entry: SessionEntry, seeding choice: ModelChoice? = nil,
        sending question: (send: QuickAskSend, attachments: [PromptAttachment])? = nil
    ) -> ChatViewModel? {
        guard let nav = navigationController else { return nil }
        let target = ChatTarget(contextID: entry.profileID, sessionID: entry.session.id)
        switch ChatNavigator.shared.admit(
            target, on: nav,
            retry: { [weak self] in self?.openChat(for: entry, seeding: choice, sending: question) })
        {
        case .alreadyOnTop:
            AppLogger.session.info(
                "openChat dedupe session=\(entry.session.id) title=\(entry.session.title)")
            if let top = nav.topViewController as? ChatViewController {
                if let question {
                    top.deliver(question.send, attachments: question.attachments)
                } else {
                    Theme.Haptics.tap()
                    top.announceIdentity()
                }
            }
            return nil
        case .hold:
            return nil
        case .push:
            break
        }
        guard let backend = viewModel.backend(for: entry) else { return nil }
        SessionSeenStore.markSeen(entry.session.id)
        let reused =
            SessionActivity.shared.retainedViewModel(
                for: entry.session.id, contextID: entry.profileID)
            ?? takeWarmed(entry)
        let chatViewModel =
            reused
            ?? ChatViewModel(
                backend: backend, session: entry.session, contextID: entry.profileID,
                serverName: entry.profileName)
        if let choice { chatViewModel.seed(choice) }
        /// A sheet still over the stack is the one animation this movement gets: the chat is
        /// pushed behind it and revealed as it slides away, rather than the two of them taking
        /// turns for the better part of a second.
        let previousTop = (nav.topViewController as? ChatViewController)?.sessionID ?? "-"
        let chat = ChatViewController(viewModel: chatViewModel)
        showConversation(chat, animated: presentedViewController == nil)
        AppLogger.session.info(
            "openChat push session=\(entry.session.id) title=\(entry.session.title) top=\(previousTop) reused=\(reused != nil)")
        if let question { chat.deliver(question.send, attachments: question.attachments) }
        return chatViewModel
    }

    func startChat(on profile: ConnectionProfile) {
        Theme.Haptics.tap()
        let stored = AppPreferences.lastComposeTarget
        let directory =
            (stored?.profileID == profile.id ? stored?.directory : nil)
            ?? recentDirectories(for: profile).first
        setComposeTarget(profile: profile, directory: directory)
        composerBar.focus()
    }

    func pushSaved() {
        Theme.Haptics.tap()
        if let workspace { return workspace.showSaved() }
        navigationController?.pushViewController(SavedChatsViewController(), animated: true)
    }

    /// The iPad's workspace moved Home between its conversation column and the phone's single
    /// stack. Beside a sidebar, the bar keeps only what the sidebar does not already offer and the
    /// board is called Home, the name of the row that brings it back.
    func workspaceDidRearrange() {
        guard isViewLoaded else { return }
        updateLeftBarItems()
        updateComposeButton()
        applySnapshot()
    }

    /// New Chat from anywhere the workspace offers it: one server aims the box at it, more than one
    /// focuses the box with the server it was last aimed at, whose chip is the one question left.
    func beginNewChat() {
        guard let profile = viewModel.servers.first else {
            presentServerSetup()
            return
        }
        if viewModel.servers.count == 1 {
            startChat(on: profile)
        } else {
            focusComposer()
        }
    }

    #if DEBUG
        /// Puts the Saved list into a named state so each one can be reviewed
        /// without tapping: `empty` clears it, `seed` bookmarks real chats, and
        /// `states` adds a chat its server no longer has plus one whose server
        /// is gone entirely.
        func seedSavedForVerification(_ mode: String) {
            for chat in SavedChatStore.all() {
                SavedChatStore.remove(profileID: chat.profileID, sessionID: chat.sessionID)
            }
            guard mode != "empty" else { return }
            for entry in viewModel.entries.prefix(3) { SavedChatStore.save(entry) }
            guard mode == "states", let sample = viewModel.entries.first else { return }
            var ghost = sample.session
            ghost.title = "Deleted on the server"
            SavedChatStore.save(
                SessionEntry(
                    profileID: sample.profileID, profileName: sample.profileName,
                    host: sample.host, backendType: sample.backendType,
                    session: AgentSession(
                        id: "ghost-session", agentType: sample.backendType, title: ghost.title,
                        createdAt: ghost.createdAt, updatedAt: ghost.updatedAt)))
            SavedChatStore.save(
                SessionEntry(
                    profileID: "removed-server", profileName: "old-laptop",
                    host: "old-laptop", backendType: sample.backendType,
                    session: AgentSession(
                        id: "orphan-session", agentType: sample.backendType,
                        title: "Chat on a server I disconnected",
                        createdAt: ghost.createdAt, updatedAt: ghost.updatedAt)))
        }
    #endif

    /// Opening from Home prefers the live session so the chat starts with the
    /// server's own view of it, and falls back to the saved snapshot when the
    /// listing hasn't landed — the bookmark is meant to work while offline.
    func openSaved(_ chat: SavedChat) {
        if let entry = viewModel.entries.first(where: {
            $0.profileID == chat.profileID && $0.session.id == chat.sessionID
        }) {
            openChat(for: entry)
            return
        }
        guard let profile = viewModel.servers.first(where: { $0.id == chat.profileID }) else {
            pushSaved()
            return
        }
        let entry = SessionEntry(
            profileID: chat.profileID, profileName: chat.profileName,
            host: profile.baseURL.host ?? chat.profileName, backendType: chat.backend,
            session: AgentSession(
                id: chat.sessionID, agentType: chat.backend, title: chat.title,
                directory: chat.directory, createdAt: chat.updatedAt, updatedAt: chat.updatedAt))
        openChat(for: entry)
    }

    #if DEBUG
        /// Opens the new-chat sheet on the first server and starts in a folder, so the states a
        /// mint can end in — waiting, and each failure with its own remedy — can be seen on a
        /// simulator without a hand on the screen.
        func startChatForVerification(in directory: String) {
            guard let profile = viewModel.servers.first else { return }
            NewChatFlow.begin(
                from: self, profile: profile, viewModel: viewModel, directory: directory
            ) { [weak self] entry in
                self?.openSession(withID: entry.session.id)
            }
        }
    #endif

    func openServer(withID id: String) {
        pushChats(filterProfileID: id)
    }

    func pushChats(filterProfileID: String? = nil) {
        if let workspace {
            return workspace.showChats(filterProfileID.map { .profile($0) } ?? .all)
        }
        navigationController?.pushViewController(
            SessionListViewController(filterProfileID: filterProfileID), animated: true)
    }

    /// A folder opens a container, never a composer: a chat's own menu names its project, and
    /// choosing it lands on that project's board — its chats and nothing else — with the launch
    /// pad's mint waiting in the board's chrome.
    func openProjectBoard(for scope: ProjectScope) {
        Theme.Haptics.tap()
        let board = SessionListViewController(scope: scope)
        if let workspace {
            board.showsAsColumn = true
            return workspace.push(list: board)
        }
        navigationController?.pushViewController(board, animated: true)
    }

    /// One gesture puts the box in the ask lane — the icon's jump list, the Control Center tile,
    /// the keyboard's own verb — and it lands on the box that is already there rather than on a
    /// sheet over it. Anything covering Home is dismissed first, because a question summoned from
    /// outside the app is a question aimed at the field, not at whatever was left open. With no
    /// servers the gesture goes to setup instead of focusing a dead text box.
    func presentQuickAsk() {
        if presentedViewController != nil {
            dismiss(animated: true) { [weak self] in self?.presentQuickAsk() }
            return
        }
        navigationController?.popToViewController(self, animated: true)
        Theme.Haptics.tap()
        guard !viewModel.servers.isEmpty else {
            presentServerSetup()
            return
        }
        setLane(.ask, animated: composerBar.lane != .ask)
        composerBar.focus()
    }

    /// Throwing the switch is a change of destination, so it moves the draft the way re-aiming the
    /// chip does: what is written belongs to the lane it was written in, and each lane hands back
    /// whatever it was left holding.
    func setLane(_ lane: QuickAskLane, animated: Bool) {
        guard askLane != lane else { return }
        let previous = askLane
        askLane = lane
        enhancement.mode = lane == .image ? .image : .coding
        enhanceOverlay?.requestDismiss()
        composerBar.setEnhanceHint(false)
        composerBar.setLane(lane, animated: animated)
        if previous == .video || previous == .image { composerBar.clearText() }
        if lane == .video || lane == .image {
            if let scope = composerDraftScope {
                DraftStore.record(composerBar.rawText, for: scope)
            }
            composerDraftScope = nil
            composerBar.setText(
                lane == .video
                    ? ForgeRunner.shared.board.recipe.prompt
                    : ImageStudio.shared.slot.promptDraft)
        }
        dismissFailure()
        appliedComposerState = nil
        updateComposer()
        updateSuggestions()
        updateCommandPalette(for: lane.needsRenderer ? "" : composerBar.currentText)
    }

    /// A render is minutes long and happens on another machine, so the ring on the way in says
    /// where it is, and keeps saying how it ended until the video surface has shown it. The video
    /// lane reads the same snapshots: its chips restate the recipe, and the box follows a draft
    /// another surface edited.
    @objc func updateVideoMark() {
        videoButton.apply(
            light: ForgeRunner.shared.light, configured: ForgeRunner.shared.endpoint != nil)
        updateComposeButton()
        guard askLane == .video else { return }
        appliedComposerState = nil
        updateComposer()
        let prompt = ForgeRunner.shared.board.recipe.prompt
        if !composerBar.isEditing, composerBar.rawText != prompt {
            composerBar.setText(prompt)
        }
    }

    @objc func openVideo() {
        Theme.Haptics.tap()
        presentVideo()
    }

    /// A render is a task you start, watch and collect — not a place you work — so the forge opens
    /// over whatever is on screen and closes back to it, with the conversation behind it untouched.
    /// Closing it never stops the render: the job lives in `ForgeRunner`, above every surface that
    /// draws it.
    func presentVideo() {
        let host: UIViewController = navigationController ?? self
        guard host.presentedViewController == nil else {
            host.dismiss(animated: true) { [weak self] in self?.presentVideo() }
            return
        }
        let forge = UINavigationController(rootViewController: VideoForgeViewController())
        forge.modalPresentationStyle = .fullScreen
        host.present(forge, animated: true)
    }

    /// The mark beside the video one, wearing whether a picture is being made. The lane and this
    /// control appear and leave together, because both are the same fact about this device: a
    /// machine that can paint is known, or it is not.
    @objc func updateImageMark() {
        let door = ImageGenDoor.current()
        imageButton.apply(painting: ImageStudio.shared.isPainting, door: door)
        updateComposeButton()
        guard askLane == .image else { return }
        guard door.isOpen else {
            setLane(.chat, animated: true)
            return
        }
        appliedComposerState = nil
        updateComposer()
    }

    @objc func openImage() {
        Theme.Haptics.tap()
        presentImage()
    }

    /// A picture is a task you start, watch and collect — the forge's own argument, about the
    /// other thing that machine does — so the studio opens over whatever is on screen and closes
    /// back to it. Closing never stops the render: the job lives in `ImageStudio`, above every
    /// surface that draws it.
    func presentImage() {
        let host: UIViewController = navigationController ?? self
        guard host.presentedViewController == nil else {
            host.dismiss(animated: true) { [weak self] in self?.presentImage() }
            return
        }
        let studio = UINavigationController(rootViewController: ImageStudioViewController())
        studio.modalPresentationStyle = .fullScreen
        host.present(studio, animated: true)
    }

    func pushUsage() {
        if let workspace { return workspace.show(place: UsageViewController()) }
        navigationController?.pushViewController(UsageViewController(), animated: true)
    }
}
