import AppKit
import CodingAgentKit
import TailscodeCore

/// What the composer's control for the call shows: whether a press can help, and the words that say
/// why or what it does. Nothing is drawn at all while there is no entry.
struct CallEntry: Equatable {
    let dimmed: Bool
    let tooltip: String
    let label: String
}

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

/// Everything one pane does about a call, kept out of the view that shows it. It owns the strip and
/// the entry's state, starts a call through the process's one desk, follows that call's snapshots
/// onto the strip, hands the agent's account to the call every time the conversation moves, and
/// plays the two chimes with their cues. The pane supplies what only it can: the conversation, the
/// send path, the stop, and where to say things.
///
/// The call is a state of the pane's conversation and ends with the pane's hold on it. The pane
/// tells this controller when it takes its live conversation (`paneBecameLive`) and when it lets go
/// by any road (`paneStopped`, which the pane's `PaneLifetime` calls: closing, parking by the
/// governor or a hidden window, switching to another chat), and when a page, a stream or a drawing
/// takes the pane over (`leave`). Each of those hangs the call up, which stops capture before the
/// last snapshot is published.
@MainActor
final class PaneCallController {
    struct Host {
        var state: () -> ConversationState
        var sending: () -> Bool
        var title: () -> String
        var deliver: (String) -> Bool
        var stopTurn: () -> Void
        var toast: (String) -> Void
        var window: () -> NSWindow?
        var announce: (String) -> Void
    }

    static let noticeSeconds: Duration = .seconds(6)
    static let settingsNoticeSeconds: Duration = .seconds(12)
    private static let microphoneSettings =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"

    let strip = CallStripView()
    let glass: NSView
    var onEntryChanged: ((CallEntry?) -> Void)? {
        didSet { onEntryChanged?(shownEntry) }
    }

    private let host: Host
    private let gate = MacVoiceCallGate.shared
    private var chatID: String?
    private var endpoint: VoiceEndpoint?
    private var live = false
    private var watching = false
    private var starting = false
    private var generation = 0
    private var attached: ActiveCall?
    private var snapshot: VoiceCallSnapshot?
    private var speaker = CallChimeSpeaker()
    private var shownEntry: CallEntry?
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
    private var gateObserver: NSObjectProtocol?

    init(host: Host) {
        self.host = host
        glass = MacTheme.glass(around: strip, cornerRadius: MacTheme.Radius.card)
        glass.isHidden = true
        strip.reportLines = { [weak self] in self?.reportLines ?? [] }
        strip.onHangUp = { [weak self] in self?.hangUpPressed() }
        strip.onToggleMute = { [weak self] in self?.mutePressed() }
        strip.onOpenSettings = { [weak self] in self?.openSettings() }
        gateObserver = NotificationCenter.default.addObserver(
            forName: MacVoiceCallGate.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshEntry() }
        }
    }

    isolated deinit {
        watcher?.cancel()
        follower?.cancel()
        pump?.cancel()
        noticeClock?.cancel()
        agentFeed?.finish()
        if let gateObserver { NotificationCenter.default.removeObserver(gateObserver) }
    }

    var reportLines: [String] {
        endpoint.map { gate.reportLines(for: $0) } ?? []
    }

    var isCalling: Bool { attached != nil || starting }

    /// The pane opened a conversation: the call that could happen here is about this chat on this
    /// server. Nothing is watched or drawn until the pane also holds the conversation live.
    func bind(_ entry: SessionEntry) {
        chatID = entry.session.id
        endpoint = gate.endpoint(forProfileID: entry.profileID)
        refreshEntry()
    }

    /// The pane took its live conversation: follow whichever call is this pane's, and keep this
    /// server's reach fresh while the pane is on screen to show a control for it.
    func paneBecameLive() {
        guard !live else { return }
        live = true
        if let endpoint, !watching {
            watching = true
            gate.watch(endpoint)
        }
        watcher = Task { [weak self] in
            guard let desk = self?.gate.desk else { return }
            for await call in desk.activeChanges() { self?.activeChanged(call) }
        }
        refreshEntry()
    }

    /// The pane let go of its conversation — closed, parked, switched to another chat, or its window
    /// went — so the call goes with it, and so does the strip.
    func paneStopped(because reason: String) {
        guard live else { return }
        live = false
        watcher?.cancel()
        watcher = nil
        if watching, let endpoint {
            watching = false
            gate.unwatch(endpoint)
        }
        endCall(because: reason)
        refreshEntry()
    }

    /// A page, a stream, a drawing or the chooser took the pane over: what the pane was is out of
    /// sight, and a microphone must never stay open behind something that is.
    func leave(because reason: String) {
        guard isCalling || !glass.isHidden else { return }
        endCall(because: reason)
        refreshEntry()
    }

    /// The conversation moved: hand the call the agent's new account, and chime when something
    /// started waiting for the person.
    func conversationChanged() {
        guard attached != nil, snapshot?.end == nil else { return }
        let state = host.state()
        noteAttention(in: state)
        feedAgent(state)
    }

    func restyle() {
        strip.restyle()
    }

    /// The control was pressed: start, ask for the password, or say why not.
    func pressEntry() {
        guard live, let endpoint, !starting, attached == nil else { return }
        let reading = reach
        guard VoiceCallEntryPoint.isEnabled(reach: reading) else {
            MacHaptics.shared.play(.tap)
            host.toast(VoiceCallEntryPoint.tooltip(reach: reading))
            return
        }
        if reading.asksForPassword {
            askPassword(for: endpoint)
            return
        }
        begin(on: endpoint)
    }

    private func activeChanged(_ call: ActiveCall?) {
        guard live, let call, call.chat == chatID, gate.isOwner(self) else { return }
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
        let chat = call.chat
        pump = Task { [desk = gate.desk] in
            for await agent in feed { await desk.feed(agent: agent, chat: chat) }
        }
        strip.level = { call.session.outputLevel }
        refreshEntry()
        glass.isHidden = false
        apply(call.latest ?? VoiceCallSnapshot(), from: call)
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
        strip.show(next)
        noteTransitions(next)
    }

    private func noteTransitions(_ next: VoiceCallSnapshot) {
        if !connected, next.face != .connecting {
            connected = true
            MacHaptics.shared.play(.success)
            AppLogger.connection.info("call live chat=\(chatID ?? "")")
        }
        if case .degraded = next.face {
            if !degraded {
                degraded = true
                MacHaptics.shared.play(.warning)
                if let line = next.degraded?.line { host.announce(line) }
            }
        } else {
            degraded = false
        }
        if next.finishedChimes > lastChimes {
            lastChimes = next.finishedChimes
            speaker.play(VoiceChime.finished())
            MacHaptics.shared.play(.received)
            host.announce(VoiceCallReading.agentFinished)
        }
    }

    private func finish(_ call: ActiveCall, _ last: VoiceCallSnapshot, _ end: VoiceCallEnd) {
        detach()
        attached = nil
        speaker.release()
        let line = last.endLine ?? VoiceCallReading.end(end, client: .mac)
        let settings = end == .microphoneDenied
        let notice = CallNotice(
            face: .ended, title: VoiceCallFace.ended.word, line: end == .hungUp ? nil : line,
            offersSettings: settings)
        AppLogger.connection.info("call ended chat=\(chatID ?? "") end=\(Self.name(of: end))")
        if end != .hungUp { MacHaptics.shared.play(.warning) }
        host.announce(line)
        show(notice, for: settings ? Self.settingsNoticeSeconds : Self.noticeSeconds)
        refreshEntry()
    }

    private func show(_ notice: CallNotice, for duration: Duration) {
        strip.show(notice)
        glass.isHidden = false
        noticeClock?.cancel()
        noticeClock = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, self.attached == nil else { return }
            self.clearStrip()
        }
    }

    private func clearStrip() {
        strip.hide()
        glass.isHidden = true
    }

    /// Ends whatever call this pane has or is opening and takes the strip away at once. A call that
    /// is still opening cannot be hung up yet, so the generation moves on and `started` ends it the
    /// moment the desk hands it back.
    private func endCall(because reason: String) {
        let calling = isCalling
        generation += 1
        starting = false
        noticeClock?.cancel()
        noticeClock = nil
        if calling, let chatID {
            gate.hangUp(chat: chatID, ownedBy: self, because: reason)
        }
        detach()
        attached = nil
        snapshot = nil
        speaker.release()
        clearStrip()
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
        MacHaptics.shared.play(.needsYou)
    }

    private func feedAgent(_ state: ConversationState) {
        let sending = host.sending()
        let next = SpokenDigest.snapshot(from: state, sending: sending, after: lastAgent, now: Date())
        strip.show(agent: next.digest, activity: Self.activity(for: state, sending: sending))
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
        let entry = currentEntry()
        guard entry != shownEntry else { return }
        shownEntry = entry
        onEntryChanged?(entry)
    }

    private func currentEntry() -> CallEntry? {
        guard live, endpoint != nil, attached == nil else { return nil }
        let reading = reach
        switch reading {
        case .unknown, .checking, .noGateway: return nil
        default: break
        }
        let usable = VoiceCallEntryPoint.isEnabled(reach: reading) && !starting
        return CallEntry(
            dimmed: !usable,
            tooltip: VoiceCallEntryPoint.tooltip(reach: reading),
            label: starting
                ? VoiceCallReading.name : VoiceCallEntryPoint.accessibilityLabel(reach: reading, active: false))
    }

    private func askPassword(for endpoint: VoiceEndpoint) {
        guard let window = host.window() else { return }
        let alert = NSAlert()
        alert.messageText = VoiceCallReading.name
        alert.informativeText = VoiceReach.wantsPassword.line
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = Localized.text("Password")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: Localized.text("Save"))
        alert.addButton(withTitle: Localized.text("Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, !field.stringValue.isEmpty, let self else { return }
            let text = field.stringValue
            Task { [weak self] in
                guard let self else { return }
                let answer = await self.gate.desk.remember(password: text, for: endpoint)
                if answer.canStart, self.live, self.attached == nil {
                    self.begin(on: endpoint)
                } else if !answer.canStart {
                    self.host.toast(answer.line)
                }
            }
        }
    }

    private func begin(on endpoint: VoiceEndpoint) {
        guard !starting, let chat = chatID else { return }
        starting = true
        generation += 1
        let ticket = generation
        refreshEntry()
        MacHaptics.shared.play(.tap)
        let speaker = CallChimeSpeaker()
        self.speaker = speaker
        let title = host.title()
        let app = BetaEnvironment.appVersion.raw
        gate.claim(for: self)
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
                chat: chat, title: title, endpoint: endpoint, client: .mac, app: app,
                audio: { try Self.makeAudio(speaker: speaker) }, send: send, stopTurn: stopTurn)
            self?.started(result, ticket: ticket, chat: chat)
        }
    }

    private func started(_ result: Result<Void, VoiceCallStartError>, ticket: Int, chat: String) {
        guard ticket == generation else {
            gate.hangUp(chat: chat, ownedBy: self, because: "the pane let go while the call was opening")
            return
        }
        starting = false
        refreshEntry()
        guard case .failure(let error) = result else { return }
        switch error {
        case .superseded:
            return
        case .wantsPassword:
            if let endpoint { askPassword(for: endpoint) }
        case .notReady, .audio:
            AppLogger.connection.info("call refused chat=\(chat) reason=\(error.line)")
            MacHaptics.shared.play(.warning)
            show(
                CallNotice(face: .ended, title: VoiceCallReading.name, line: error.line, offersSettings: false),
                for: Self.noticeSeconds)
        }
    }

    private nonisolated static func makeAudio(speaker: CallChimeSpeaker) throws -> (VoiceAudioCapture, VoiceAudioPlayback) {
        let io = AppleVoiceIO()
        io.onInterruption = {
            Task { @MainActor in MacVoiceCallGate.shared.hangUp(because: "the audio was interrupted") }
        }
        io.onFailure = { _ in
            Task { @MainActor in
                MacVoiceCallGate.shared.hangUp(because: "the audio engine could not be restored")
            }
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
        guard live, !words.isEmpty else { return false }
        AppLogger.chat.info("call dispatch session=\(chatID ?? "") chars=\(words.count)")
        let accepted = host.deliver(words)
        feedAgent(host.state())
        return accepted
    }

    private func stopAgent() {
        AppLogger.chat.info("call stop session=\(chatID ?? "")")
        host.stopTurn()
    }

    private func hangUpPressed() {
        MacHaptics.shared.play(.tap)
        guard let chatID else { return }
        gate.hangUp(chat: chatID, ownedBy: self, because: "hang up was pressed")
    }

    private func mutePressed() {
        guard let call = attached, let current = snapshot else { return }
        MacHaptics.shared.play(.selection)
        let next = !current.muted
        Task { await call.session.setMuted(next) }
    }

    private func openSettings() {
        guard let url = URL(string: Self.microphoneSettings) else { return }
        NSWorkspace.shared.open(url)
    }
}
