import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore
import UIKit

/// The speaker a call's two chimes come out of: the call's own playback, so they follow its audio
/// route and its echo cancellation. It is handed the playback when the audio stack is built and let
/// go of when the call ends, and a chime asked for outside that window is not played.
final class CallChimeSpeaker: @unchecked Sendable {
    private let lock = NSLock()
    private var playback: (any VoiceAudioPlayback)?

    func adopt(_ playback: any VoiceAudioPlayback) {
        lock.withLock { self.playback = playback }
    }

    func release() {
        lock.withLock { playback = nil }
    }

    func play(_ pcm: Data) {
        guard let target = lock.withLock({ playback }) else { return }
        Task { await target.play(pcm) }
    }
}

/// Everything one chat does about a call, kept out of the screen that shows it. It owns the entry
/// control and the dock, starts a call through the process's one desk, follows that call's snapshots
/// onto the dock, hands the agent's account to the call every time the conversation moves, and plays
/// the two chimes with their haptic cues. The screen supplies what only it can: the conversation,
/// the send path, the stop, a place to present.
@MainActor
final class ChatCallController {
    struct Host {
        var presenter: () -> UIViewController?
        var state: () -> ConversationState
        var sending: () -> Bool
        var title: () -> String
        var deliver: (String) -> Bool
        var stopTurn: () -> Void
        var toast: (String) -> Void
        var dismissKeyboard: () -> Void
        var barItemsChanged: () -> Void
    }

    static let noticeSeconds: Duration = .seconds(6)
    static let settingsNoticeSeconds: Duration = .seconds(12)

    let dock = CallDockView()
    let barItem: UIBarButtonItem

    private let chatID: String
    private let endpoint: VoiceEndpoint?
    private let host: Host
    private let gate = VoiceCallGate.shared
    private var attached: ActiveCall?
    private var snapshot: VoiceCallSnapshot?
    private var speaker = CallChimeSpeaker()
    private var starting = false
    private var watching = false
    private var visible = false
    private var lastAgent: VoiceAgentSnapshot?
    private var agentFeed: AsyncStream<VoiceAgentSnapshot>.Continuation?
    private var lastChimes = 0
    private var awaiting: Set<String> = []
    private var connected = false
    private var degraded = false
    private var watcher: Task<Void, Never>?
    private var follower: Task<Void, Never>?
    private var pump: Task<Void, Never>?
    private var noticeClock: Task<Void, Never>?
    private nonisolated(unsafe) var gateObserver: NSObjectProtocol?

    init(chatID: String, profileID: String, host: Host) {
        self.chatID = chatID
        self.host = host
        endpoint = VoiceCallGate.shared.endpoint(forProfile: profileID)
        barItem = UIBarButtonItem(
            image: UIImage(systemName: VoiceCallEntryPoint.symbol), style: .plain, target: nil, action: nil)
        barItem.primaryAction = UIAction(
            image: UIImage(systemName: VoiceCallEntryPoint.symbol)
        ) { [weak self] _ in self?.entryPressed() }
        dock.reportLines = { [weak self] in self?.reportLines ?? [] }
        dock.onHangUp = { [weak self] in self?.hangUpPressed() }
        dock.onToggleMute = { [weak self] in self?.mutePressed() }
        dock.onOpenSettings = { [weak self] in self?.openSettings() }
        gateObserver = NotificationCenter.default.addObserver(
            forName: VoiceCallGate.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshEntry() }
        }
        refreshEntry()
    }

    deinit {
        watcher?.cancel()
        follower?.cancel()
        pump?.cancel()
        noticeClock?.cancel()
        agentFeed?.finish()
        if let gateObserver { NotificationCenter.default.removeObserver(gateObserver) }
        let chat = chatID
        Task { @MainActor in VoiceCallGate.shared.hangUp(chat: chat, because: "the chat screen went away") }
    }

    var barItems: [UIBarButtonItem] { visible ? [barItem] : [] }

    var reportLines: [String] {
        endpoint.map { gate.reportLines(for: $0) } ?? []
    }

    /// The screen has loaded: begin following whichever call is this chat's.
    func attach() {
        guard watcher == nil else { return }
        watcher = Task { [weak self] in
            guard let desk = self?.gate.desk else { return }
            for await call in desk.activeChanges() { self?.activeChanged(call) }
        }
    }

    func screenAppeared() {
        guard let endpoint, !watching else { return }
        watching = true
        gate.watch(endpoint)
        refreshEntry()
    }

    func screenGone() {
        guard let endpoint, watching else { return }
        watching = false
        gate.unwatch(endpoint)
    }

    /// The reader has left this conversation for good, so the call for it goes with them.
    func chatLeft() {
        screenGone()
        gate.hangUp(chat: chatID, because: "the chat was left")
        noticeClock?.cancel()
        if attached == nil { dock.hide() }
    }

    /// The face of the call standing now, for what draws it beside the conversation; nil when no
    /// call is attached or the one that was has ended.
    var currentFace: VoiceCallFace? {
        guard attached != nil, snapshot?.end == nil else { return nil }
        return snapshot?.face
    }

    /// The conversation moved: hand the call the agent's new account, and chime when something
    /// started waiting for the person.
    func conversationChanged() {
        guard attached != nil, snapshot?.end == nil else { return }
        let state = host.state()
        noteAttention(in: state)
        feedAgent(state)
    }

    private func activeChanged(_ call: ActiveCall?) {
        guard let call, call.chat == chatID else { return }
        attach(call)
    }

    private func attach(_ call: ActiveCall) {
        guard attached !== call else { return }
        detach()
        noticeClock?.cancel()
        attached = call
        snapshot = nil
        connected = false
        degraded = false
        lastAgent = nil
        lastChimes = call.latest?.finishedChimes ?? 0
        awaiting = pendingIDs(in: host.state())
        let (feed, continuation) = AsyncStream.makeStream(
            of: VoiceAgentSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        agentFeed = continuation
        let chat = chatID
        pump = Task { [desk = gate.desk] in
            for await agent in feed { await desk.feed(agent: agent, chat: chat) }
        }
        dock.level = { call.session.outputLevel }
        host.dismissKeyboard()
        refreshEntry()
        let first = call.latest ?? VoiceCallSnapshot()
        apply(first, from: call)
        feedAgent(host.state())
        follower = Task { [weak self] in
            for await next in call.snapshots { self?.apply(next, from: call) }
        }
    }

    private func detach() {
        follower?.cancel()
        pump?.cancel()
        agentFeed?.finish()
        follower = nil
        pump = nil
        agentFeed = nil
    }

    private func apply(_ next: VoiceCallSnapshot, from call: ActiveCall) {
        guard attached === call else { return }
        snapshot = next
        if let end = next.end {
            finish(call, next, end)
            return
        }
        dock.show(next)
        noteTransitions(next)
    }

    private func noteTransitions(_ next: VoiceCallSnapshot) {
        if !connected, next.face != .connecting {
            connected = true
            Theme.Haptics.success()
            AppLogger.connection.info("call live chat=\(chatID)")
        }
        if case .degraded = next.face {
            if !degraded {
                degraded = true
                Theme.Haptics.warning()
                if let line = next.degraded?.line { UIAccessibility.post(notification: .announcement, argument: line) }
            }
        } else {
            degraded = false
        }
        if next.finishedChimes > lastChimes {
            lastChimes = next.finishedChimes
            speaker.play(VoiceChime.finished())
            Theme.Haptics.received()
            UIAccessibility.post(notification: .announcement, argument: VoiceCallReading.agentFinished)
        }
    }

    private func finish(_ call: ActiveCall, _ last: VoiceCallSnapshot, _ end: VoiceCallEnd) {
        detach()
        attached = nil
        speaker.release()
        let line = last.endLine ?? VoiceCallReading.end(end, client: .ios)
        let settings = end == .microphoneDenied
        let notice = CallNotice(
            face: .ended, title: VoiceCallFace.ended.word, line: end == .hungUp ? nil : line,
            offersSettings: settings)
        AppLogger.connection.info("call ended chat=\(chatID) end=\(Self.name(of: end))")
        if end != .hungUp { Theme.Haptics.warning() }
        UIAccessibility.post(notification: .announcement, argument: line)
        show(notice, for: settings ? Self.settingsNoticeSeconds : Self.noticeSeconds)
        refreshEntry()
    }

    private func show(_ notice: CallNotice, for duration: Duration) {
        dock.show(notice)
        noticeClock?.cancel()
        noticeClock = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, self.attached == nil else { return }
            self.dock.hide()
        }
    }

    private static func name(of end: VoiceCallEnd) -> String {
        switch end {
        case .hungUp: return "hungUp"
        case .replaced: return "replaced"
        case .lost: return "lost"
        case .couldNotConnect: return "couldNotConnect"
        case .microphoneDenied: return "microphoneDenied"
        case .audioUnavailable: return "audioUnavailable"
        case .gateway(let code, _): return "gateway.\(code)"
        }
    }

    private func pendingIDs(in state: ConversationState) -> Set<String> {
        Set(state.pendingQuestions.map(\.id) + state.pendingPermissions.map(\.id))
    }

    private func noteAttention(in state: ConversationState) {
        let ids = pendingIDs(in: state)
        let fresh = ids.subtracting(awaiting)
        awaiting = ids
        guard !fresh.isEmpty, let face = snapshot?.face else { return }
        switch face {
        case .hearing, .speaking: return
        default: break
        }
        speaker.play(VoiceChime.attention())
        Theme.Haptics.needsYou()
    }

    private func feedAgent(_ state: ConversationState) {
        let sending = host.sending()
        let next = SpokenDigest.snapshot(from: state, sending: sending, after: lastAgent, now: Date())
        dock.show(agent: next.digest, activity: Self.activity(for: state, sending: sending))
        guard next != lastAgent else { return }
        lastAgent = next
        agentFeed?.yield(next)
    }

    private static func activity(for state: ConversationState, sending: Bool) -> ActivityKind? {
        if let live = ActivityKind.inFlight(in: state) { return live }
        if let work = state.backgroundWork {
            return work.stalled ? .stalled(tasks: work.tasks) : .inBackground(tasks: work.tasks)
        }
        return sending ? .working : nil
    }

    private var reach: VoiceReach {
        guard let endpoint else { return .noGateway }
        let reading = gate.reach(for: endpoint)
        if case .busy = reading, gate.hasCall(on: endpoint) { return .ready(gateway: "") }
        return reading
    }

    private func refreshEntry() {
        let reading = reach
        let shown = endpoint != nil && VoiceCallEntryPoint.isShown(reach: reading, active: false) && attached == nil
        let usable = VoiceCallEntryPoint.isEnabled(reach: reading) && !starting
        barItem.tintColor = usable ? nil : Theme.Color.tertiaryLabel
        barItem.accessibilityLabel = starting ? VoiceCallReading.name : VoiceCallEntryPoint.accessibilityLabel(reach: reading, active: false)
        barItem.accessibilityTraits = usable ? .button : [.button, .notEnabled]
        guard shown != visible else { return }
        visible = shown
        host.barItemsChanged()
    }

    private func entryPressed() {
        guard let endpoint, !starting else { return }
        let reading = reach
        guard VoiceCallEntryPoint.isEnabled(reach: reading) else {
            Theme.Haptics.tap()
            host.toast(VoiceCallEntryPoint.tooltip(reach: reading))
            return
        }
        if reading.opensSetup {
            openSetup(for: endpoint)
            return
        }
        if reading.asksForPassword {
            askPassword(for: endpoint)
            return
        }
        begin(on: endpoint)
    }

    /// The voice checklist for this server, which every press that cannot start a call opens.
    /// Finishing it starts the call the person pressed for, if they are still in that chat.
    private func openSetup(for endpoint: VoiceEndpoint) {
        guard let presenter = host.presenter() else { return }
        Theme.Haptics.tap()
        let chat = chatID
        SetupGate.present(
            .voice(endpoint), from: presenter, reportLines: { [weak self] in self?.reportLines ?? [] },
            onFinish: { [weak self] in
                guard let self, self.chatID == chat, self.attached == nil else { return }
                Task { [weak self] in
                    await self?.gate.desk.refresh(endpoint)
                    self?.begin(on: endpoint)
                }
            })
    }

    private func askPassword(for endpoint: VoiceEndpoint) {
        guard let presenter = host.presenter() else { return }
        let alert = UIAlertController(
            title: VoiceCallReading.name, message: VoiceReach.wantsPassword.line, preferredStyle: .alert)
        alert.addTextField { field in
            field.isSecureTextEntry = true
            field.placeholder = String(localized: "Password")
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: String(localized: "Save"), style: .default) { [weak self, weak alert] _ in
                guard let self, let text = alert?.textFields?.first?.text, !text.isEmpty else { return }
                Task { [weak self] in
                    guard let self else { return }
                    let answer = await self.gate.desk.remember(password: text, for: endpoint)
                    if answer.canStart { self.begin(on: endpoint) } else { self.host.toast(answer.line) }
                }
            })
        presenter.present(alert, animated: true)
    }

    private func begin(on endpoint: VoiceEndpoint) {
        guard !starting else { return }
        starting = true
        refreshEntry()
        host.dismissKeyboard()
        Theme.Haptics.tap()
        let speaker = CallChimeSpeaker()
        self.speaker = speaker
        let chat = chatID
        let title = host.title()
        let app = BetaEnvironment.appVersion.raw
        AppLogger.connection.info("call start chat=\(chat) host=\(endpoint.host) demo=\(endpoint.isDemo)")
        let send: @Sendable (String) async -> Bool = { [weak self] text in
            await MainActor.run { self?.dispatch(text) ?? false }
        }
        let stopTurn: @Sendable () async -> Void = { [weak self] in
            await MainActor.run { self?.stopAgent() }
        }
        let desk = gate.desk
        Task { [weak self] in
            let result = await desk.start(
                chat: chat, title: title, endpoint: endpoint, client: .ios, app: app,
                audio: { try Self.makeAudio(speaker: speaker) }, send: send, stopTurn: stopTurn)
            self?.started(result)
        }
    }

    private func started(_ result: Result<Void, VoiceCallStartError>) {
        starting = false
        refreshEntry()
        guard case .failure(let error) = result else { return }
        switch error {
        case .superseded:
            return
        case .wantsPassword:
            if let endpoint { askPassword(for: endpoint) }
        case .notReady(let reach) where reach.opensSetup:
            if let endpoint { openSetup(for: endpoint) }
        case .notReady, .audio:
            AppLogger.connection.info("call refused chat=\(chatID) reason=\(error.line)")
            Theme.Haptics.warning()
            show(CallNotice(face: .ended, title: VoiceCallReading.name, line: error.line, offersSettings: false),
                for: Self.noticeSeconds)
        }
    }

    private nonisolated static func makeAudio(speaker: CallChimeSpeaker) throws -> (VoiceAudioCapture, VoiceAudioPlayback) {
        let io = AppleVoiceIO()
        io.onInterruption = {
            Task { @MainActor in VoiceCallGate.shared.hangUp(because: "the audio was interrupted") }
        }
        io.onFailure = { _ in
            Task { @MainActor in VoiceCallGate.shared.hangUp(because: "the audio engine could not be restored") }
        }
        let playback = io.playback
        speaker.adopt(playback)
        return (io.capture, playback)
    }

    /// What the voice heard, through the same road a typed message takes: the queue, the pending
    /// ink, the marks and the live card all behave as if it had been typed. Only a blank
    /// transcript is refused.
    private func dispatch(_ text: String) -> Bool {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return false }
        AppLogger.chat.info("call dispatch session=\(chatID) chars=\(words.count)")
        let accepted = host.deliver(words)
        feedAgent(host.state())
        return accepted
    }

    private func stopAgent() {
        AppLogger.chat.info("call stop session=\(chatID)")
        host.stopTurn()
    }

    private func hangUpPressed() {
        Theme.Haptics.tap()
        Task { [desk = gate.desk] in await desk.hangUp() }
    }

    private func mutePressed() {
        guard let call = attached, let current = snapshot else { return }
        Theme.Haptics.selection()
        let next = !current.muted
        Task { await call.session.setMuted(next) }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
