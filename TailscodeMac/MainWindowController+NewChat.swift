import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

extension MainWindowController {
    /// ⌘N: a server and a directory, then Enter. No configured server means the checklist that sets
    /// one up — the thing that fixes the actual problem — rather than an empty picker.
    /// - Parameter profile: the server the sheet opens on, when the question has already been
    ///   answered somewhere else — a pane's chooser — so it is never asked twice.
    /// - Parameter carrying: the conversation this chat continues, if it does: its brief waits in
    ///   the new chat's composer and its draft, when it has one, in the box.
    func presentNewChat(
        on profile: ConnectionProfile? = nil, browsing: Bool = false, carrying: CarryPlan? = nil
    ) {
        let profiles = ServerDirectory.shared.profiles
        guard !profiles.isEmpty else {
            FirstRunWindow.present(way: nil)
            return
        }
        let entries = sidebar.allEntries
        let down = sidebar.unreachableServers
        Task { [weak self] in
            let locals = await Task.detached { NewChatSheet.localAddresses }.value
            guard let self, let window = self.window else { return }
            NewChatSheet.present(
                on: window, profiles: profiles, entries: entries, unreachable: down,
                localAddresses: locals, preferredServer: profile?.id, browsing: browsing,
                onFix: { [weak self] fix, done in self?.applyNewChatFix(fix, done: done) }
            ) { [weak self] profile, directory, done in
                self?.createChat(on: profile, directory: directory, carrying: carrying, done: done)
            }
        }
    }

    /// The one round trip that mints the session id is all the new chat waits for. The sidebar
    /// row is seeded from the answer and the conversation opens on the spot with the composer
    /// focused; the full list refresh reconciles behind it, because a person who just started a
    /// chat is looking at the prompt box, not at the list.
    func createChat(
        on profile: ConnectionProfile, directory: String?, carrying: CarryPlan? = nil,
        done: @escaping @MainActor (NewChatFailure?) -> Void = { _ in }
    ) {
        guard let backend = ServerDirectory.shared.backend(for: profile) else {
            done(NewChatDiagnosis.noCredentials(server: Self.newChatServer(profile)))
            return
        }
        let server = Self.newChatServer(profile)
        let password = ServerDirectory.shared.password(for: profile)
        Task { [weak self] in
            let minted = await NewChatAttempt.mint(
                using: backend, server: server, baseURL: profile.baseURL, password: password,
                directory: directory)
            guard case .success(let session) = minted else {
                done(minted.failureValue)
                return
            }
            done(nil)
            guard let self else { return }
            let entry = SessionEntry(
                profileID: profile.id, profileName: profile.name,
                host: profile.baseURL.host ?? profile.name,
                backendType: profile.backend, session: session)
            if let carrying { Self.hand(carrying, to: entry) }
            self.sidebar.noteCreated(entry)
            self.transcript.focusComposer()
            await self.sidebar.refresh()
        }
    }

    /// What a carried chat starts with, put where its composer will look when the chat opens: the
    /// brief on the shelf and the question, for a retry, as the draft the box restores.
    private static func hand(_ plan: CarryPlan, to entry: SessionEntry) {
        CarryShelf.hold(plan.brief, profileID: entry.profileID, sessionID: entry.session.id)
        guard let draft = plan.draft else { return }
        DraftStore.record(
            draft, for: .chat(profileID: entry.profileID, sessionID: entry.session.id))
    }

    static func newChatServer(_ profile: ConnectionProfile) -> NewChatServer {
        NewChatServer(
            profileID: profile.id, name: profile.name, backend: profile.backend,
            address: ServerLabel.address(profile))
    }

    /// The failure card's own remedy, carried out: a repoint rewrites the server's address so the
    /// chat can be tried again on the spot; anything else opens the screen it is fixed on.
    private func applyNewChatFix(
        _ fix: NewChatFailure.Fix, done: @escaping @MainActor (NewChatFailure?) -> Void
    ) {
        switch fix {
        case .repoint(let profileID, let url, _):
            guard var profile = ServerDirectory.shared.profiles.first(where: { $0.id == profileID })
            else {
                done(NewChatDiagnosis.noSuchServer())
                return
            }
            let password = ServerDirectory.shared.password(for: profile)
            profile.baseURL = url
            do {
                try ServerDirectory.shared.save(profile, password: password)
                done(nil)
                Task { [weak self] in await self?.sidebar.refresh() }
            } catch {
                done(
                    NewChatDiagnosis.failure(
                        server: Self.newChatServer(profile), directory: nil,
                        error: AgentErrorText.readable(error), witness: .unknown))
            }
        case .editServer, .none, .retry:
            presentServers()
            done(nil)
        }
    }

    /// A notification tap: raise the window, then bring the session it names to the eye — the
    /// pane already showing it if one is, else through the ordinary open into the focused pane.
    func openSession(withID id: String) {
        window?.makeKeyAndOrderFront(nil)
        MacNotifier.clearNotices(sessionID: id)
        if let pane = splitPanes.pane(showing: id) {
            splitPanes.focus(pane, grabKeyboard: false)
            return
        }
        sidebar.open(withID: id)
    }
}
