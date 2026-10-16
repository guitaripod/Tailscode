import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// What a pane tells the call about itself: which conversation it holds, the state it last drew,
/// how to send words the way its composer does, how to stop its turn, and where to say something.
protocol CallPaneHost: AnyObject {
    var callEntry: SessionEntry? { get }
    var callState: ConversationState? { get }
    var callWindow: UnsafeMutablePointer<GtkWidget>? { get }
    func callSend(_ words: String) -> Bool
    func callStopTurn()
    func callNotice(_ words: String)
    func callAnnounce(_ words: String)
    func callChipChanged()
}

/// A pane's part in a call, which is a state of the conversation it holds rather than a window of
/// its own: one control in the controls row beside attach, and one strip docked above the composer
/// while the call is live.
///
/// The call itself is `VoiceCallDesk`'s and the process's (`VoiceCallRunner`); this pane only reads
/// what the gateway says about calling its server, starts a call for its chat through its own send
/// path, draws the snapshots of the call when it is for its chat, feeds the call the agent's account
/// whenever the conversation changes, and hangs up when the chat it called about is no longer the
/// one it holds.
final class PaneCall: @unchecked Sendable {
    let chip: UnsafeMutablePointer<GtkWidget>
    let chipParts: ChatChips.Parts
    let strip: CallStripView
    private weak var host: (any CallPaneHost)?
    private let runner: VoiceCallRunner
    private var endpoint: VoiceEndpoint?
    private var watched: VoiceEndpoint?
    private var boundCall: ActiveCall?
    private var subscription: Task<Void, Never>?
    private var ownedChat: String?
    private var lastAgent: VoiceAgentSnapshot?
    private var waitingSeen: Set<String> = []
    private var chimesSeen: Int?
    private var lastFace: VoiceCallFace?
    private var suspended = false
    private var gone = false

    private final class Link: @unchecked Sendable {
        weak var call: PaneCall?
    }

    init(host: any CallPaneHost, runner: VoiceCallRunner = .shared) {
        self.host = host
        self.runner = runner
        let link = Link()
        let control = ChatChips.control(
            glyph: VoiceCallEntryPoint.glyph, word: VoiceCallEntryPoint.title, label: VoiceCallEntryPoint.title
        ) {
            Gtk.onMain { link.call?.pressEntry() }
        }
        chip = control.button
        chipParts = control.parts
        gtk_widget_set_visible(chip, 0)
        strip = CallStripView(
            reportLines: { link.call?.reportLines ?? [] },
            mute: { muted in runner.setMuted(muted) },
            hangUp: { runner.hangUp() })
        link.call = self
        runner.watch(self) { [weak self] in self?.refresh() }
    }

    var reportLines: [String] { endpoint.map(runner.report(for:)) ?? [] }

    static func key(of entry: SessionEntry) -> String { "\(entry.profileID)/\(entry.session.id)" }

    var chatKey: String? { host?.callEntry.map(Self.key(of:)) }

    var isOwner: Bool { ownedChat != nil && ownedChat == chatKey && runner.isActive(chat: ownedChat ?? "") }

    /// The pane opened another chat, left its chat, or is showing the same one again. A call this
    /// pane started is for the chat it was started in: once the pane holds any other, it is over.
    func chatChanged() {
        guard !gone else { return }
        let key = chatKey
        if let owned = ownedChat, owned != key {
            ownedChat = nil
            if runner.isActive(chat: owned) { runner.hangUp() }
        }
        lastAgent = nil
        waitingSeen = []
        resetWatch()
        refresh()
    }

    /// A zoom hid the pane, or showed it again. A hidden pane asks nothing of any gateway, and the
    /// call, which belongs to the chat, goes on.
    func setSuspended(_ value: Bool) {
        guard suspended != value else { return }
        suspended = value
        resetWatch()
    }

    /// The pane is closing: whatever call it started ends, its gateway is no longer asked about and
    /// its strip is taken down.
    func shutdown() {
        guard !gone else { return }
        if let owned = ownedChat, runner.isActive(chat: owned) { runner.hangUp() }
        ownedChat = nil
        gone = true
        subscription?.cancel()
        subscription = nil
        if let watched { runner.unwatchReach(of: watched) }
        watched = nil
        runner.unwatch(self)
        strip.tearDown()
    }

    private func resetWatch() {
        let wanted: VoiceEndpoint? = (suspended || gone) ? nil : host?.callEntry.flatMap { runner.endpoint(for: $0) }
        endpoint = host?.callEntry.flatMap { runner.endpoint(for: $0) }
        guard wanted != watched else { return }
        if let watched { runner.unwatchReach(of: watched) }
        watched = wanted
        if let wanted { runner.watchReach(of: wanted) }
    }

    /// Everything the pane shows of the call, read again: the control from what the gateway says,
    /// and the strip bound to the call when it is for this pane's chat.
    func refresh() {
        guard !gone else { return }
        endpoint = host?.callEntry.flatMap { runner.endpoint(for: $0) }
        updateChip()
        guard let key = chatKey, let call = runner.active, call.chat == key, boundCall !== call else { return }
        bind(call)
    }

    var chipVisible: Bool { gtk_widget_get_visible(chip) != 0 }

    var chipEnabled: Bool { gtk_widget_get_sensitive(chip) != 0 }

    var chipTooltip: String {
        gtk_widget_get_tooltip_text(chip).map { String(cString: $0) } ?? ""
    }

    var chipWordText: String {
        chipParts.word.flatMap { gtk_label_get_text(op($0)).map { String(cString: $0) } } ?? ""
    }

    static func shows(reach: VoiceReach, active: Bool) -> Bool {
        VoiceCallEntryPoint.isShown(reach: reach, active: active)
    }

    private func updateChip() {
        guard let key = chatKey, let endpoint else {
            let was = chipVisible
            gtk_widget_set_visible(chip, 0)
            if was { host?.callChipChanged() }
            return
        }
        let active = runner.isActive(chat: key)
        let reach = runner.reach(of: endpoint)
        let visible = Self.shows(reach: reach, active: active)
        let was = chipVisible
        gtk_widget_set_visible(chip, visible ? 1 : 0)
        if was != visible { host?.callChipChanged() }
        guard visible else { return }
        gtk_widget_set_sensitive(chip, VoiceCallEntryPoint.isEnabled(reach: reach, active: active) ? 1 : 0)
        gtk_widget_set_tooltip_text(chip, VoiceCallEntryPoint.tooltip(reach: reach, active: active))
        tailscode_set_accessible_label(chip, VoiceCallEntryPoint.accessibilityLabel(reach: reach, active: active))
        if let word = chipParts.word { gtk_label_set_text(op(word), VoiceCallEntryPoint.label(active: active)) }
        ChatChips.setTone(chipParts.glyph, active ? .danger : (reach.canStart ? nil : reach.tone))
    }

    func pressEntry() {
        guard let host, let entry = host.callEntry, let endpoint else { return }
        let key = Self.key(of: entry)
        if runner.isActive(chat: key) {
            runner.hangUp()
            return
        }
        let reach = runner.reach(of: endpoint)
        switch reach {
        case .wantsPassword:
            askForPassword(endpoint)
        case _ where reach.opensSetup:
            openSetup(endpoint: endpoint, key: key)
        default:
            begin(entry: entry, endpoint: endpoint, key: key)
        }
    }

    /// The checklist for voice on this server, which every press that cannot start a call opens.
    /// Finishing it starts the call the person pressed for, if they are still in the chat they pressed in.
    func openSetup(endpoint: VoiceEndpoint, key: String) {
        SetupWindow.present(
            target: .voice(endpoint), parent: host?.callWindow,
            reportLines: { VoiceCallRunner.shared.report(for: endpoint) },
            onFinish: { [weak self] in Gtk.onMain { [weak self] in self?.startAfterSetup(endpoint: endpoint, key: key) } })
    }

    private func startAfterSetup(endpoint: VoiceEndpoint, key: String) {
        guard !gone, let entry = host?.callEntry, Self.key(of: entry) == key else { return }
        runner.refresh(endpoint)
        begin(entry: entry, endpoint: endpoint, key: key)
    }

    private func begin(entry: SessionEntry, endpoint: VoiceEndpoint, key: String) {
        ownedChat = key
        runner.start(
            chat: key, title: entry.session.title, endpoint: endpoint,
            send: { [weak self] words in
                await withCheckedContinuation { continuation in
                    Gtk.onMain { [weak self] in continuation.resume(returning: self?.host?.callSend(words) ?? false) }
                }
            },
            stopTurn: { [weak self] in
                Gtk.onMain { [weak self] in self?.host?.callStopTurn() }
            },
            done: { [weak self] result in
                guard let self else { return }
                if case .failure(let failure) = result {
                    if self.ownedChat == key { self.ownedChat = nil }
                    self.failed(failure, endpoint: endpoint)
                }
            })
    }

    private func failed(_ failure: VoiceCallStartError, endpoint: VoiceEndpoint) {
        switch failure {
        case .wantsPassword: askForPassword(endpoint)
        case .superseded: break
        case .notReady(let reach) where reach.opensSetup:
            if let entry = host?.callEntry { openSetup(endpoint: endpoint, key: Self.key(of: entry)) }
        default: host?.callNotice(failure.line)
        }
    }

    private func askForPassword(_ endpoint: VoiceEndpoint) {
        Dialogs.prompt(
            title: Localized.text("Voice gateway password"), body: VoiceReach.wantsPassword.line,
            placeholder: "", confirmLabel: Localized.text("Save"), secret: true, parent: host?.callWindow
        ) { password in
            guard !password.isEmpty else { return }
            VoiceCallRunner.shared.remember(password: password, for: endpoint)
        }
    }

    private func bind(_ call: ActiveCall) {
        subscription?.cancel()
        boundCall = call
        chimesSeen = nil
        lastFace = nil
        subscription = Task { [weak self] in
            for await snapshot in call.snapshots {
                Gtk.onMain { [weak self] in self?.apply(snapshot, of: call) }
            }
        }
    }

    private func apply(_ snapshot: VoiceCallSnapshot, of call: ActiveCall) {
        guard boundCall === call, !gone else { return }
        let session = call.session
        strip.apply(snapshot, level: { [face = snapshot.face] in
            switch face {
            case .speaking: return session.outputLevel
            default: return 0
            }
        })
        if let seen = chimesSeen, snapshot.finishedChimes > seen, snapshot.isOpen {
            runner.chime(VoiceChime.finished(), in: call.chat)
        }
        chimesSeen = snapshot.finishedChimes
        if lastFace != snapshot.face, snapshot.face.isSettledNews { host?.callAnnounce(snapshot.spoken) }
        lastFace = snapshot.face
        if let state = host?.callState { feedAgent(state, push: snapshot.isOpen) }
        updateChip()
    }

    /// The conversation moved: the call is told what the agent is doing, in the words the gateway's
    /// model can say, and a question or an approval that has just begun to wait gets its own sound.
    func stateChanged(_ state: ConversationState) {
        guard !gone, let key = chatKey, runner.isActive(chat: key), boundCall?.chat == key else { return }
        feedAgent(state, push: true)
        let waiting = Set(state.pendingPermissions.map(\.id) + state.pendingQuestions.map(\.id))
        let arrived = !waiting.subtracting(waitingSeen).isEmpty
        waitingSeen = waiting
        if arrived, boundCall?.latest?.isOpen == true { runner.chime(VoiceChime.attention(), in: key) }
    }

    private func feedAgent(_ state: ConversationState, push: Bool) {
        guard let key = chatKey else { return }
        let snapshot = SpokenDigest.snapshot(from: state, after: lastAgent)
        lastAgent = snapshot
        strip.setAgent(kind: ActivityKind.inFlight(in: state), text: snapshot.digest)
        if push { runner.feed(agent: snapshot, chat: key) }
    }

    /// What the control and the strip are doing, for the harness.
    var reading: String {
        "chip=\(chipVisible ? "shown" : "hidden") enabled=\(chipEnabled) word=\"\(chipWordText)\" "
            + "owner=\(isOwner) watching=\(watched != nil) chat=\(chatKey ?? "none") host=\(host?.callEntry?.host ?? "none") endpoint=\(endpoint?.address ?? "none") "
            + "reach=\(endpoint.map { String(describing: runner.reach(of: $0)) } ?? "none") strip: \(strip.report)"
    }
}

extension VoiceCallFace {
    /// A face that is news to a person who is not looking at the strip.
    var isSettledNews: Bool {
        switch self {
        case .degraded, .ended: return true
        default: return false
        }
    }
}

extension ChatPane: CallPaneHost {
    var callEntry: SessionEntry? { entry }
    var callState: ConversationState? { lastState }
    var callWindow: UnsafeMutablePointer<GtkWidget>? { host?.windowWidget }
}
