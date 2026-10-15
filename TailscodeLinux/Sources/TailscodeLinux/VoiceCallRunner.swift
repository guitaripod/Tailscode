import CodingAgentKit
import Foundation
import TailscodeCore

/// The one call this process may be in, held above every pane.
///
/// `VoiceCallDesk` in Core is the whole of the call's logic and is an actor that never touches the
/// main queue, so it is made here once, with the secrets the rest of this client keeps its
/// passwords in. What is added is only what a GTK surface needs and Core cannot hold: a mirror of
/// the desk's answers that the main loop may read without awaiting (`g_application_run` never
/// drains libdispatch's main queue, so an await into the desk from a signal handler is a hang), the
/// watchers a pane registers to be told when it changes, and the audio the call plays its two
/// sounds through.
final class VoiceCallRunner: @unchecked Sendable {
    static let shared = VoiceCallRunner(
        desk: VoiceCallDesk(secrets: FileSecretStore()),
        audio: {
            guard PulseVoiceIO.isAvailable else {
                throw VoiceAudioError.unavailable("this build has no PulseAudio support")
            }
            let made = PulseVoiceIO()
            return (made.capture, made.playback)
        })

    let desk: VoiceCallDesk
    private(set) var active: ActiveCall?
    private(set) var lastEnds: [VoiceEndpoint: VoiceCallEnd] = [:]
    private var mirror: [VoiceEndpoint: VoiceReach] = [:]
    private var watchers: [ObjectIdentifier: @Sendable () -> Void] = [:]
    private let audio: @Sendable () throws -> (VoiceAudioCapture, VoiceAudioPlayback)
    private var capture: VoiceAudioCapture?
    private var playback: VoiceAudioPlayback?
    private var started = false
    private var watching: [VoiceEndpoint: Int] = [:]
    private let operations: AsyncStream<Operation>.Continuation
    private let queue: AsyncStream<Operation>

    nonisolated(unsafe) static var forcedReach: VoiceReach?
    nonisolated(unsafe) static var forcedEndpoint: VoiceEndpoint?

    private enum Operation: Sendable {
        case watch(VoiceEndpoint)
        case unwatch(VoiceEndpoint)
        case refresh(VoiceEndpoint)
    }

    init(desk: VoiceCallDesk, audio: @escaping @Sendable () throws -> (VoiceAudioCapture, VoiceAudioPlayback)) {
        self.desk = desk
        self.audio = audio
        (queue, operations) = AsyncStream<Operation>.makeStream()
    }

    func watch(_ owner: AnyObject, _ block: @escaping @Sendable () -> Void) {
        begin()
        watchers[ObjectIdentifier(owner)] = block
    }

    func unwatch(_ owner: AnyObject) {
        watchers.removeValue(forKey: ObjectIdentifier(owner))
    }

    private func changed() {
        for watcher in watchers.values { watcher() }
    }

    /// Starts the three readers of the desk: what its gateways say, which call is running, and the
    /// one queue its watch and unwatch go through, in the order they were asked for.
    private func begin() {
        guard !started else { return }
        started = true
        let desk = desk
        let queue = queue
        Task { [weak self] in
            for await change in desk.reachChanges() {
                Gtk.onMain { [weak self] in
                    self?.mirror[change.endpoint] = change.reach
                    self?.changed()
                }
            }
        }
        Task { [weak self] in
            for await call in desk.activeChanges() {
                Gtk.onMain { [weak self] in self?.adopt(call) }
            }
        }
        Task {
            for await operation in queue {
                switch operation {
                case .watch(let endpoint): await desk.watchReach(of: endpoint)
                case .unwatch(let endpoint): await desk.unwatchReach(of: endpoint)
                case .refresh(let endpoint): await desk.refresh(endpoint)
                }
            }
        }
    }

    private func adopt(_ call: ActiveCall?) {
        active = call
        changed()
        guard let call else { return }
        Task { [weak self] in
            var last: VoiceCallSnapshot?
            for await snapshot in call.snapshots { last = snapshot }
            guard let end = last?.end else { return }
            Gtk.onMain { [weak self] in
                self?.lastEnds[call.endpoint] = end
                self?.changed()
            }
        }
    }

    /// Where a conversation's gateway is, from the profile it was opened on.
    func endpoint(for entry: SessionEntry) -> VoiceEndpoint? {
        if let forced = Self.forcedEndpoint { return forced }
        guard let url = URL(string: "http://\(entry.host)") else { return nil }
        return VoiceEndpoint(profileURL: url)
    }

    func reach(of endpoint: VoiceEndpoint) -> VoiceReach {
        if let forced = Self.forcedReach { return forced }
        if endpoint.isDemo { return .ready(gateway: VoiceDemo.gatewayVersion) }
        return mirror[endpoint] ?? .unknown
    }

    func watchReach(of endpoint: VoiceEndpoint) {
        begin()
        watching[endpoint, default: 0] += 1
        operations.yield(.watch(endpoint))
    }

    func unwatchReach(of endpoint: VoiceEndpoint) {
        guard let count = watching[endpoint], count > 0 else { return }
        watching[endpoint] = count == 1 ? nil : count - 1
        operations.yield(.unwatch(endpoint))
    }

    func refresh(_ endpoint: VoiceEndpoint) {
        begin()
        operations.yield(.refresh(endpoint))
    }

    func remember(password: String, for endpoint: VoiceEndpoint) {
        Task { [desk] in _ = await desk.remember(password: password, for: endpoint) }
    }

    func report(for endpoint: VoiceEndpoint) -> [String] {
        VoiceCallReport.lines(endpoint: endpoint, reach: reach(of: endpoint), end: lastEnds[endpoint])
    }

    func isActive(chat: String) -> Bool { active?.chat == chat }

    /// Starts a call for a chat. The audio is built on demand and only for a real gateway: a demo
    /// host's scripted call has no microphone and no speaker, and a build with no PulseAudio says
    /// so before anything is dialled.
    func start(
        chat: String, title: String?, endpoint: VoiceEndpoint,
        send: @escaping @Sendable (String) async -> Bool, stopTurn: @escaping @Sendable () async -> Void,
        done: @escaping @Sendable (Result<Void, VoiceCallStartError>) -> Void
    ) {
        begin()
        let runner = self
        Task { [desk] in
            let result = await desk.start(
                chat: chat, title: title, endpoint: endpoint, client: .linux,
                app: "Tailscode \(TailscodeVersion.current)",
                audio: {
                    let made = try runner.audio()
                    runner.hold(made)
                    return made
                }, send: send, stopTurn: stopTurn)
            Gtk.onMain { done(result) }
        }
    }

    private func hold(_ made: (VoiceAudioCapture, VoiceAudioPlayback)) {
        Gtk.onMain { [weak self] in
            self?.capture = made.0
            self?.playback = made.1
        }
    }

    func hangUp() {
        Task { [desk] in await desk.hangUp() }
    }

    func setMuted(_ value: Bool) {
        guard let session = active?.session else { return }
        Task { await session.setMuted(value) }
    }

    func feed(agent: VoiceAgentSnapshot, chat: String) {
        guard active?.chat == chat else { return }
        Task { [desk] in await desk.feed(agent: agent, chat: chat) }
    }

    /// The call's own sounds go through the call's speaker, so they follow its route and its echo
    /// cancelling; a demo call has no speaker and stays quiet.
    func chime(_ pcm: Data, in chat: String) {
        guard let call = active, call.chat == chat, !call.endpoint.isDemo, let playback else {
            return
        }
        Task { await playback.play(pcm) }
    }

    /// What the call is holding open right now, for the harness that has to prove a hang up leaves
    /// nothing running.
    var audioReading: String {
        guard let capture, let playback else { return "audio=none" }
        return "audio=held capture=\(String(format: "%.2f", capture.level)) playback=\(String(format: "%.2f", playback.level))"
    }
}
