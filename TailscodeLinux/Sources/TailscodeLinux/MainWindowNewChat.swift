import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension MainWindow {
    /// The forge, opened over the work rather than beside it. A render is a task somebody starts,
    /// watches and collects — not a place they work — so it is a modal on top of this window and
    /// the conversation behind it is left exactly as it was. One already open is raised rather than
    /// made a second time, and closing it never touches a render, which lives in `ForgeRunner`.
    @discardableResult
    func presentForge() -> StudioSheet {
        studioSheet!.show(.video)
    }

    /// The image studio, opened over the work the same way the forge is. Making a picture is a
    /// task you start, watch and collect rather than a place you work, so it costs the
    /// conversation behind it nothing and never leaves a pane behind. One already open is raised
    /// rather than made a second time, and closing it never touches a render, which lives in
    /// `ImageStudio`.
    @discardableResult
    func presentImageStudio() -> StudioSheet? {
        guard ImageGenDoor.current().isOpen else { return nil }
        return studioSheet?.show(.image)
    }

    /// The dispatcher board, opened over the work the same way the forge is: a thing you check on
    /// rather than a place you type, so it costs the conversation behind it nothing.
    @discardableResult
    func presentDelegate(host: String? = nil, handoff: DelegateHandoff? = nil) -> DelegateWindow {
        DelegateWindow.chatSource = { [weak self] in self?.entries ?? SessionListCache.load() }
        return DelegateWindow.present(parent: window, host: host, handoff: handoff)
    }

    /// A slot that started, stopped, or learned the stream's own title. The layout is written back
    /// so a restart reopens what was playing, exactly as it reopens a conversation.
    func videoSlotChanged() {
        splitHost.persist()
    }

    /// `HOST:PORT:/folder`, the driver's way of pointing a preview pane without typing into it; an
    /// empty argument opens the pane asking.
    static func previewTarget(from argument: String) -> PreviewTarget? {
        let parts = argument.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count == 3, let port = Int(parts[1]), !parts[0].isEmpty, !parts[2].isEmpty else {
            return nil
        }
        return PreviewTarget(host: parts[0], port: port, project: parts[2])
    }

    /// A sentence a preview pane composed — the build that would not build, and what to do about
    /// it — handed to a conversation the way a design follow-up is: the focused chat if there is
    /// one, otherwise the first chat on screen. With no chat open the words go to the clipboard so
    /// nothing the pane worked out is lost.
    func previewAsksAgent(_ words: String, from source: ChatPane) {
        let chats = splitHost.orderedPanes.filter { $0 !== source && $0.entry != nil }
        let target = chats.first { $0 === activePane } ?? chats.first
        guard let target else {
            Gtk.copyToClipboard(words)
            return
        }
        target.sendComposed(words)
    }

    /// What a chat dragged from the list is called, for the caption inside the drop highlight —
    /// the listing first, then the bookmarks, so a chat whose server is unreachable still names
    /// itself while it is being carried.
    func chatTitle(for payload: PaneDragPayload) -> String? {
        if let entry = self.entry(for: payload) {
            return SessionRowModel(entry: entry, unreachable: false, unread: false, saved: false)
                .title
        }
        return SavedChatStore.all().first { $0.sessionID == payload.sessionID }?.title
    }

    func entry(for payload: PaneDragPayload) -> SessionEntry? {
        entries.first {
            $0.profileID == payload.profileID && $0.session.id == payload.sessionID
        }
    }

    /// A chat let go over a pane. The middle of a pane means open it there; an edge means the
    /// arrangement the highlight drew — the pane halves and the arriving chat takes that side. A
    /// chat no listing knows changes nothing rather than emptying a pane.
    @discardableResult
    func pane(_ pane: ChatPane, received payload: PaneDragPayload, zone: PaneDropZone) -> Bool {
        guard let entry = entry(for: payload) else { return false }
        freshlyCreated = nil
        switch zone {
        case .fill:
            pane.open(entry)
            splitHost.focus(pane, grabKeyboard: false)
        case .split(let edge):
            guard let fresh = splitHost.split(pane, edge: edge) else { return false }
            fresh.open(entry)
            splitHost.focus(fresh, grabKeyboard: false)
        }
        focused = .transcript
        return true
    }

    /// - Parameters:
    ///   - profile: the server the dialog opens on, when the question has already been answered
    ///     somewhere else — a pane's chooser — so it is never asked twice.
    ///   - pane: where the minted chat opens; the focused pane when nothing says otherwise.
    func presentNewChat(on profile: ConnectionProfile? = nil, into pane: ChatPane? = nil) {
        Task { [weak self, weak pane] in
            let profiles = await ServerDirectory.shared.profiles()
            let localAddresses = Self.localAddresses
            Gtk.onMain { [weak self, weak pane] in
                guard let self else { return }
                guard !profiles.isEmpty else {
                    self.presentServers()
                    return
                }
                Dialogs.newChat(
                    parent: self.window, profiles: profiles, entries: self.entries,
                    preferredServer: profile?.id ?? (pane ?? self.activePane).entry?.profileID,
                    localAddresses: localAddresses, unreachable: Set(self.unreachable),
                    onFix: { [weak self] fix, done in
                        Gtk.onMain { [weak self] in self?.applyNewChatFix(fix, done: done) }
                    }
                ) { [weak self, weak pane] profileID, directory, done in
                    self?.createChat(
                        onProfileID: profileID, directory: directory, into: pane, done: done)
                }
            }
        }
    }

    /// Read once, off the main context: `tailscale status` is a subprocess, and the answer does
    /// not change within a run.
    static let localAddresses: Set<String> = {
        var hosts: Set<String> = ["127.0.0.1", "localhost", "::1"]
        var name = [CChar](repeating: 0, count: 256)
        if gethostname(&name, 255) == 0 { hosts.insert(String(cString: name).lowercased()) }
        if let address = TailnetStatusLinux.read().address { hosts.insert(address) }
        return hosts
    }()

    /// The one round trip that mints the session id is all the new chat waits for; the full list
    /// refresh reconciles behind it.
    /// The server is looked up when the chat is minted, never when the modal opened: a repoint
    /// applied from the failure card rewrites the address a second earlier, and retrying against
    /// the copy the dialog captured would hit the same wrong port again.
    func createChat(
        onProfileID profileID: String, directory: String?, into pane: ChatPane? = nil,
        firstMessage: QuickAskSend? = nil, attachments: [PendingAttachment] = [],
        quickAsk: Bool = false,
        done: @escaping @Sendable (NewChatFailure?) -> Void = { _ in }
    ) {
        Task { [weak self] in
            let profiles = await ServerDirectory.shared.profiles()
            guard let profile = profiles.first(where: { $0.id == profileID }) else {
                done(NewChatDiagnosis.noSuchServer())
                return
            }
            Gtk.onMain { [weak self] in
                self?.createChat(
                    on: profile, directory: directory, into: pane, firstMessage: firstMessage,
                    attachments: attachments, quickAsk: quickAsk, done: done)
            }
        }
    }

    /// - Parameter firstMessage: what should go out the moment the minted chat's own conversation
    ///   exists — queued on the pane keyed to the minted session in the same main loop turn that
    ///   opens it, so nothing can slip between the queue and the open and no other conversation can
    ///   ever inherit it. A failed mint queues nothing. It carries the decision the surface already
    ///   made rather than bare words, because the catalog that answers `/` belongs to the machine
    ///   the question was aimed at and is fetched long before the chat it will run in exists.
    /// - Parameter quickAsk: stamps the minted conversation with the quick ask's own aim, so the
    ///   question runs on the model it was aimed at rather than on the server's own memory, which
    ///   the aim deliberately left alone.
    func createChat(
        on profile: ConnectionProfile, directory: String?, into pane: ChatPane? = nil,
        firstMessage: QuickAskSend? = nil, attachments: [PendingAttachment] = [],
        quickAsk: Bool = false,
        done: @escaping @Sendable (NewChatFailure?) -> Void = { _ in }
    ) {
        Trace.mark("createChat begin")
        let askedForPane = pane != nil
        Task { [weak self, weak pane] in
            guard let backend = await ServerDirectory.shared.backend(for: profile) else {
                done(NewChatDiagnosis.noCredentials(server: Self.newChatServer(profile)))
                return
            }
            let minted = await NewChatAttempt.mint(
                using: backend, server: Self.newChatServer(profile), baseURL: profile.baseURL,
                password: await ServerDirectory.shared.password(for: profile), directory: directory)
            guard case .success(let session) = minted else {
                done(minted.failureValue)
                return
            }
            Trace.mark("createChat session created")
            if quickAsk {
                QuickAskDefaults.stamp(profileID: profile.id, sessionID: session.id)
            }
            let entry = SessionEntry(
                profileID: profile.id, profileName: profile.name,
                host: profile.baseURL.host ?? profile.name,
                backendType: profile.backend, session: session)
            Gtk.onMain { [weak self, weak pane] in
                guard let self else {
                    done(nil)
                    return
                }
                if !self.entries.contains(where: { $0.session.id == entry.session.id }) {
                    self.entries.insert(entry, at: 0)
                }
                self.freshlyCreated = entry
                self.lastSidebar = nil
                self.renderSidebar()
                guard let target = pane ?? (askedForPane ? nil : self.activePane) else {
                    done(nil)
                    return
                }
                if let firstMessage {
                    target.queueFirstMessage(
                        firstMessage, attachments: attachments, forSession: entry.session.id)
                }
                target.open(entry, freshlyCreated: true)
                /// The surface that asked is told inside the same main-loop turn that put the
                /// conversation on screen, so what it does next — closing itself — can only
                /// happen over a window that is already showing the answer's chat. Answering
                /// from the task thread let the two race, and a modal closing first left the
                /// keyboard on whatever the sidebar had focused.
                done(nil)
                Gtk.onMain { [weak target] in
                    guard let target, target.sessionID == entry.session.id else { return }
                    target.focusComposer()
                }
            }
            await self?.refresh()
            Trace.mark("createChat refresh done")
        }
    }

    static func newChatServer(_ profile: ConnectionProfile) -> NewChatServer {
        NewChatServer(
            profileID: profile.id, name: profile.name, backend: profile.backend,
            address: ServerLabel.address(profile))
    }

    /// The remedy the failure card offers, carried out: a repoint rewrites the profile's address
    /// and answers so the chat can be tried again on the spot; anything else opens the screen
    /// where the rest of it is fixed by hand.
    func applyNewChatFix(
        _ fix: NewChatFailure.Fix, done: @escaping @Sendable (NewChatFailure?) -> Void
    ) {
        switch fix {
        case .repoint(let profileID, let url, _):
            Task { [weak self] in
                let profiles = await ServerDirectory.shared.profiles()
                guard var profile = profiles.first(where: { $0.id == profileID }) else {
                    done(NewChatDiagnosis.noSuchServer())
                    return
                }
                let password = await ServerDirectory.shared.password(for: profile)
                profile.baseURL = url
                do {
                    try await ServerDirectory.shared.save(profile, password: password)
                    SettingsFile.capture()
                    done(nil)
                    await self?.refresh()
                } catch {
                    done(
                        NewChatDiagnosis.failure(
                            server: Self.newChatServer(profile), directory: nil,
                            error: AgentErrorText.readable(error), witness: .unknown))
                }
            }
        case .editServer, .none, .retry:
            presentServers()
            done(nil)
        }
    }
}
