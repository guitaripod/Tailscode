import CodingAgentKit
import Foundation

/// One call. It owns the socket, the microphone and the speaker for as long as the call lasts and
/// nothing after: whichever way it ends, capture and playback are stopped before the last snapshot
/// is published. It is never main-actor, so a toolkit that cannot drain the main queue can run it.
///
/// The session is the gateway's hands and ears on this device and nothing more. A `dispatch` goes
/// through the app's own send path and is answered `sent` or `refused` by what that path says; the
/// agent is never touched from here.
public actor VoiceCallSession {
    public static let reconnectBackoff: [TimeInterval] = [1, 2, 4]
    public static let debounce: TimeInterval = 0.25
    public static let heartbeat: TimeInterval = 5
    public static let refusal = "The app could not send that to the agent."

    public nonisolated let snapshots: AsyncStream<VoiceCallSnapshot>
    private let output: AsyncStream<VoiceCallSnapshot>.Continuation

    private let endpoint: VoiceEndpoint
    private let bearer: String?
    private let client: VoiceClientKind
    private let appVersion: String
    private let title: String?
    private let transport: any VoiceTransport
    private let capture: any VoiceAudioCapture
    private let playback: any VoiceAudioPlayback
    private let sendPrompt: @Sendable (String) async -> Bool
    private let stopTurn: @Sendable () async -> Void
    private let clock: any VoiceClock
    private let wallClock: @Sendable () -> Date

    private var connection = VoiceCallConnection.connecting
    private var phase = VoicePhase.connecting
    private var degradation: VoiceCallDegradation?
    private var lines: [VoiceCallLine] = []
    private var voiceCount = 0
    private var startedAt: Date?
    private var reconnecting = false
    private var muted = false
    private var agentBusy = false
    private var finishedChimes = 0
    private var end: VoiceCallEnd?
    private var started = false
    private var generation = 0
    private var attempts = 0
    private var linkUp = false
    private var latestAgent: VoiceAgentSnapshot?
    private var sentAgent: VoiceAgentSnapshot?
    private var receiveTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var dispatchTail: Task<Void, Never>?

    public init(
        endpoint: VoiceEndpoint, bearer: String? = nil, client: VoiceClientKind, appVersion: String,
        title: String?, transport: any VoiceTransport, capture: any VoiceAudioCapture,
        playback: any VoiceAudioPlayback, send: @escaping @Sendable (String) async -> Bool,
        stopTurn: @escaping @Sendable () async -> Void, clock: any VoiceClock = SystemVoiceClock(),
        wallClock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.endpoint = endpoint
        self.bearer = bearer
        self.client = client
        self.appVersion = appVersion
        self.title = title
        self.transport = transport
        self.capture = capture
        self.playback = playback
        self.sendPrompt = send
        self.stopTurn = stopTurn
        self.clock = clock
        self.wallClock = wallClock
        let (stream, continuation) = AsyncStream<VoiceCallSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.snapshots = stream
        self.output = continuation
    }

    public nonisolated var inputLevel: Double { capture.level }

    public nonisolated var outputLevel: Double { playback.level }

    public func current() -> VoiceCallSnapshot { snapshot() }

    public func start() async {
        guard !started, end == nil else { return }
        started = true
        publish()
        do {
            let chunks = try await capture.start()
            guard end == nil else {
                await releaseAudio()
                return
            }
            captureTask = Task { [weak self] in
                for await chunk in chunks { await self?.forward(chunk) }
            }
            try await playback.start()
        } catch {
            await finish(Self.audioEnd(error))
            return
        }
        guard end == nil else {
            await releaseAudio()
            return
        }
        do {
            try await open()
        } catch {
            await finish(.couldNotConnect(Self.describe(error)))
        }
    }

    private func releaseAudio() async {
        captureTask?.cancel()
        await capture.stop()
        await playback.stop()
    }

    public func hangUp(as reason: VoiceCallEnd = .hungUp) async {
        guard end == nil else { return }
        if linkUp, let bye = try? VoiceCodec.encode(VoiceClientMessage.bye) {
            try? await transport.sendText(bye)
        }
        await finish(reason)
    }

    public func setMuted(_ value: Bool) {
        guard muted != value, end == nil else { return }
        muted = value
        publish()
    }

    public func update(agent: VoiceAgentSnapshot) {
        guard end == nil else { return }
        latestAgent = agent
        if agentBusy != agent.busy {
            let wasBusy = agentBusy
            agentBusy = agent.busy
            if wasBusy && !agent.busy && isQuiet { finishedChimes += 1 }
            publish()
        }
        debounceTask?.cancel()
        debounceTask = Task { [weak self, clock] in
            do { try await clock.sleep(for: Self.debounce) } catch { return }
            await self?.flushAgent()
        }
    }

    private var isQuiet: Bool {
        connection == .live && degradation == nil && phase != .hearing && phase != .speaking
    }

    private func open() async throws {
        generation += 1
        let current = generation
        try await transport.connect(url: endpoint.callURL, bearer: bearer)
        guard end == nil, current == generation else {
            await transport.close()
            return
        }
        let frames = transport.receive()
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            do {
                for try await frame in frames { await self?.handle(frame, generation: current) }
            } catch {
            }
            await self?.lose(generation: current)
        }
        do {
            try await transport.sendText(try VoiceCodec.encode(hello()))
        } catch {
            receiveTask?.cancel()
            await transport.close()
            throw error
        }
        linkUp = true
    }

    private func hello() -> VoiceClientMessage {
        let name = title.map { VoiceText.ascii($0, limit: 80) }.flatMap { $0.isEmpty ? nil : $0 }
        return .hello(VoiceClientMessage.Hello(client: client, app: appVersion, title: name))
    }

    private func handle(_ frame: VoiceFrame, generation current: Int) async {
        guard end == nil, current == generation else { return }
        switch frame {
        case .binary(let pcm):
            guard connection == .live, !voiceIsGated, phase != .hearing else { return }
            await playback.play(pcm)
        case .text(let text):
            guard let message = try? VoiceCodec.decodeServer(text) else { return }
            await handle(message, generation: current)
        }
    }

    private var voiceIsGated: Bool { degradation != nil || phase == .degraded }

    private func handle(_ message: VoiceServerMessage, generation current: Int) async {
        switch message {
        case .ready:
            connection = .live
            reconnecting = false
            attempts = 0
            startedAt = startedAt ?? wallClock()
            startHeartbeat()
            await sendAgent(latestAgent ?? .idle)
            publish()
        case .phase(let next, _):
            if next == .hearing { await playback.flush() }
            phase = next
            if next != .degraded { degradation = nil }
            publish()
        case .user(let id, let text, let final):
            upsertYou(id: id, text: text, final: final)
            publish()
        case .say(let text, let final):
            upsertVoice(text: text, final: final)
            publish()
        case .dispatch(let id, let text):
            enqueueDispatch(id: id, text: text)
        case .stop:
            Task { [stopTurn] in await stopTurn() }
        case .degraded(let reason, let recovering):
            degradation = VoiceCallDegradation(reason: reason, recovering: recovering)
            await playback.flush()
            publish()
        case .recycled, .unknown:
            break
        case .error(let code, let message):
            if code == "busy" && reconnecting {
                await lose(generation: current)
            } else {
                await finish(.gateway(code: code, message: VoiceText.ascii(message)))
            }
        }
    }

    private func upsertYou(id: String, text: String, final: Bool) {
        let clean = Self.tidy(text)
        guard !clean.isEmpty else { return }
        if let index = lines.lastIndex(where: { $0.kind == .you && $0.id == id }) {
            lines[index].text = clean
            lines[index].final = final
        } else {
            lines.append(VoiceCallLine(id: id, kind: .you, text: clean, final: final))
            trimLines()
        }
    }

    private func upsertVoice(text: String, final: Bool) {
        let clean = Self.tidy(text)
        guard !clean.isEmpty else { return }
        if let index = lines.lastIndex(where: { $0.kind == .voice && !$0.final }) {
            lines[index].text = clean
            lines[index].final = final
        } else {
            voiceCount += 1
            lines.append(VoiceCallLine(id: "v\(voiceCount)", kind: .voice, text: clean, final: final))
            trimLines()
        }
    }

    private func trimLines() {
        if lines.count > VoiceCallSnapshot.lineLimit {
            lines.removeFirst(lines.count - VoiceCallSnapshot.lineLimit)
        }
    }

    private static func tidy(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func enqueueDispatch(id: String, text: String) {
        let previous = dispatchTail
        let current = generation
        dispatchTail = Task { [sendPrompt, weak self] in
            await previous?.value
            let accepted = await sendPrompt(text)
            await self?.answer(id: id, accepted: accepted, generation: current)
        }
    }

    private func answer(id: String, accepted: Bool, generation current: Int) async {
        guard end == nil, current == generation, linkUp else { return }
        let reply: VoiceClientMessage = accepted ? .sent(id: id) : .refused(id: id, reason: Self.refusal)
        await transmit(reply)
    }

    private func forward(_ chunk: Data) async {
        guard end == nil, linkUp else { return }
        let current = generation
        let payload = muted ? Data(count: chunk.count) : chunk
        for piece in VoiceChunks.split(payload, limit: VoiceWire.maxChunkBytes) {
            do {
                try await transport.sendBinary(piece)
            } catch {
                await lose(generation: current)
                return
            }
        }
    }

    private func flushAgent() async {
        guard end == nil, connection == .live, let latest = latestAgent else { return }
        if let sent = sentAgent, sent.sameMeaning(as: latest) { return }
        await sendAgent(latest)
    }

    private func sendAgent(_ snapshot: VoiceAgentSnapshot) async {
        sentAgent = snapshot
        await transmit(.agent(snapshot.wire))
    }

    private func transmit(_ message: VoiceClientMessage) async {
        guard end == nil, linkUp, let text = try? VoiceCodec.encode(message) else { return }
        let current = generation
        do {
            try await transport.sendText(text)
        } catch {
            await lose(generation: current)
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self, clock] in
            while !Task.isCancelled {
                do { try await clock.sleep(for: Self.heartbeat) } catch { return }
                await self?.beat()
            }
        }
    }

    private func beat() async {
        guard end == nil, connection == .live else { return }
        await sendAgent(latestAgent ?? .idle)
    }

    private func lose(generation lost: Int) async {
        guard end == nil, lost == generation, linkUp || connection == .connecting || reconnecting else { return }
        generation += 1
        linkUp = false
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        heartbeatTask = nil
        await transport.close()
        await playback.flush()
        connection = .reconnecting
        reconnecting = true
        phase = .connecting
        degradation = nil
        publish()
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in await self?.redial() }
    }

    private func redial() async {
        while end == nil, !Task.isCancelled {
            guard attempts < Self.reconnectBackoff.count else {
                await finish(.lost)
                return
            }
            let delay = Self.reconnectBackoff[attempts]
            attempts += 1
            do { try await clock.sleep(for: delay) } catch { return }
            guard end == nil else { return }
            do {
                try await open()
                return
            } catch {
                continue
            }
        }
    }

    private func finish(_ reason: VoiceCallEnd) async {
        guard end == nil else { return }
        end = reason
        connection = .ended
        linkUp = false
        let tasks = [receiveTask, captureTask, heartbeatTask, debounceTask, reconnectTask, dispatchTail]
        tasks.forEach { $0?.cancel() }
        await capture.stop()
        await playback.stop()
        await transport.close()
        publish()
        output.finish()
    }

    private func publish() {
        output.yield(snapshot())
    }

    private func snapshot() -> VoiceCallSnapshot {
        let face = VoiceCallFace.read(
            phase: degradation != nil ? .degraded : phase, agentBusy: agentBusy, connection: connection,
            degraded: degradation?.reason)
        return VoiceCallSnapshot(
            face: face, lines: lines, startedAt: startedAt, degraded: degradation,
            reconnecting: reconnecting && end == nil, muted: muted, agentBusy: agentBusy,
            finishedChimes: finishedChimes, end: end,
            endLine: end.map { VoiceCallReading.end($0, client: client) })
    }

    static func audioEnd(_ error: Error) -> VoiceCallEnd {
        switch error as? VoiceAudioError {
        case .microphoneDenied?: return .microphoneDenied
        case .unavailable(let why)?: return .audioUnavailable(why)
        case nil: return .audioUnavailable(describe(error))
        }
    }

    private static func describe(_ error: Error) -> String {
        if case VoiceTransportError.refused(let why) = error { return why }
        return error.localizedDescription
    }
}
