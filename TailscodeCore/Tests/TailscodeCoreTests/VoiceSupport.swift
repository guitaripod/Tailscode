import CodingAgentKit
import Foundation

@testable import TailscodeCore

final class ManualVoiceClock: VoiceClock, @unchecked Sendable {
    private struct Waiter {
        let id: Int
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var time: TimeInterval = 0
    private var counter = 0
    private var waiters: [Waiter] = []

    func now() -> TimeInterval { lock.withLock { time } }

    var sleepers: Int { lock.withLock { waiters.count } }

    func sleep(for seconds: TimeInterval) async throws {
        let id = lock.withLock { () -> Int in
            counter += 1
            return counter
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let cancelled = lock.withLock { () -> Bool in
                    if Task.isCancelled { return true }
                    waiters.append(Waiter(id: id, deadline: time + max(0, seconds), continuation: continuation))
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiter = lock.withLock { () -> Waiter? in
                guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return waiters.remove(at: index)
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by seconds: TimeInterval) async {
        let target = now() + seconds
        await settle()
        while true {
            let due = lock.withLock { () -> Waiter? in
                guard let index = waiters.indices.filter({ waiters[$0].deadline <= target })
                    .min(by: { waiters[$0].deadline < waiters[$1].deadline })
                else { return nil }
                let waiter = waiters.remove(at: index)
                time = max(time, waiter.deadline)
                return waiter
            }
            guard let due else { break }
            due.continuation.resume()
            await settle()
        }
        lock.withLock { time = target }
        await settle()
    }

    func settle() async {
        for _ in 0..<6 {
            try? await Task.sleep(nanoseconds: 300_000)
            for _ in 0..<5 { await Task.yield() }
        }
    }
}

func eventually(timeout: TimeInterval = 3, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return await condition()
}

final class FakeTransport: VoiceTransport, @unchecked Sendable {
    struct Refused: Error {}

    private let lock = NSLock()
    private var failures = 0
    private var stream: AsyncThrowingStream<VoiceFrame, Error>.Continuation?
    private var textLog: [String] = []
    private var binaryLog: [Data] = []
    private var connectLog: [(URL, String?)] = []
    private var closeCount = 0

    func failNextConnects(_ count: Int) { lock.withLock { failures = count } }

    var connects: Int { lock.withLock { connectLog.count } }
    var connectedURL: URL? { lock.withLock { connectLog.last?.0 } }
    var connectedBearer: String? { lock.withLock { connectLog.last?.1 } }
    var closes: Int { lock.withLock { closeCount } }
    var texts: [String] { lock.withLock { textLog } }
    var binaries: [Data] { lock.withLock { binaryLog } }

    var clientMessages: [VoiceClientMessage] {
        texts.compactMap { try? VoiceCodec.decodeClient($0) }
    }

    var agentFrames: [VoiceClientMessage.AgentState] {
        clientMessages.compactMap { if case .agent(let state) = $0 { return state } else { return nil } }
    }

    func connect(url: URL, bearer: String?) async throws {
        let shouldFail = lock.withLock { () -> Bool in
            connectLog.append((url, bearer))
            guard failures > 0 else { return false }
            failures -= 1
            return true
        }
        if shouldFail { throw Refused() }
    }

    func sendBinary(_ data: Data) async throws { lock.withLock { binaryLog.append(data) } }

    func sendText(_ text: String) async throws { lock.withLock { textLog.append(text) } }

    func receive() -> AsyncThrowingStream<VoiceFrame, Error> {
        let (stream, continuation) = AsyncThrowingStream<VoiceFrame, Error>.makeStream()
        lock.withLock { self.stream = continuation }
        return stream
    }

    func close() async {
        let continuation = lock.withLock { () -> AsyncThrowingStream<VoiceFrame, Error>.Continuation? in
            closeCount += 1
            defer { stream = nil }
            return stream
        }
        continuation?.finish()
    }

    func emit(_ message: VoiceServerMessage) {
        guard let text = try? VoiceCodec.encode(message) else { return }
        _ = lock.withLock { stream }?.yield(.text(text))
    }

    func emit(audio: Data) {
        _ = lock.withLock { stream }?.yield(.binary(audio))
    }

    func drop() {
        let continuation = lock.withLock { () -> AsyncThrowingStream<VoiceFrame, Error>.Continuation? in
            defer { stream = nil }
            return stream
        }
        continuation?.finish(throwing: Refused())
    }

    func clearLog() {
        lock.withLock {
            textLog = []
            binaryLog = []
        }
    }
}

final class FakeCapture: VoiceAudioCapture, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Data>.Continuation?
    private var active = false
    private var failure: VoiceAudioError?
    private var stops = 0

    func failStart(with error: VoiceAudioError) { lock.withLock { failure = error } }

    var running: Bool { lock.withLock { active } }
    var stopCount: Int { lock.withLock { stops } }
    var level: Double { 0.5 }

    func start() async throws -> AsyncStream<Data> {
        if let error = lock.withLock({ failure }) { throw error }
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        lock.withLock {
            self.continuation = continuation
            active = true
        }
        return stream
    }

    func stop() async {
        let continuation = lock.withLock { () -> AsyncStream<Data>.Continuation? in
            active = false
            stops += 1
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.finish()
    }

    func push(_ chunk: Data) { _ = lock.withLock { continuation }?.yield(chunk) }
}

final class FakePlayback: VoiceAudioPlayback, @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var flushed = 0
    private var started = false
    private var stopped = 0

    var played: [Data] { lock.withLock { chunks } }
    var flushes: Int { lock.withLock { flushed } }
    var isStarted: Bool { lock.withLock { started } }
    var stops: Int { lock.withLock { stopped } }
    var level: Double { 0.25 }

    func start() async throws { lock.withLock { started = true } }
    func play(_ pcm: Data) async { lock.withLock { chunks.append(pcm) } }
    func flush() async { lock.withLock { flushed += 1 } }
    func stop() async {
        lock.withLock {
            started = false
            stopped += 1
        }
    }
}

final class Prompts: @unchecked Sendable {
    private let lock = NSLock()
    private var sentLog: [String] = []
    private var accepting = true
    private var stopLog = 0

    var sent: [String] { lock.withLock { sentLog } }
    var stops: Int { lock.withLock { stopLog } }
    func accept(_ value: Bool) { lock.withLock { accepting = value } }

    func send(_ text: String) -> Bool {
        lock.withLock {
            sentLog.append(text)
            return accepting
        }
    }

    func stop() { lock.withLock { stopLog += 1 } }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [VoiceCallSnapshot] = []
    private var finished = false

    var snapshots: [VoiceCallSnapshot] { lock.withLock { log } }
    var isFinished: Bool { lock.withLock { finished } }
    var faces: [VoiceCallFace] { snapshots.map(\.face) }

    func watch(_ stream: AsyncStream<VoiceCallSnapshot>) -> Task<Void, Never> {
        Task {
            for await snapshot in stream { lock.withLock { log.append(snapshot) } }
            lock.withLock { finished = true }
        }
    }
}

struct VoiceRig {
    let session: VoiceCallSession
    let transport: FakeTransport
    let capture: FakeCapture
    let playback: FakePlayback
    let clock: ManualVoiceClock
    let prompts: Prompts
    let recorder: Recorder
    let watcher: Task<Void, Never>

    init(
        transport: FakeTransport = FakeTransport(), capture: FakeCapture = FakeCapture(),
        playback: FakePlayback = FakePlayback(), clock: ManualVoiceClock = ManualVoiceClock(),
        title: String? = "Fix the parser"
    ) {
        let prompts = Prompts()
        self.transport = transport
        self.capture = capture
        self.playback = playback
        self.clock = clock
        self.prompts = prompts
        session = VoiceCallSession(
            endpoint: VoiceEndpoint(host: "box.tailnet.ts.net"), bearer: "secret", client: .linux,
            appVersion: "1.70", title: title, transport: transport, capture: capture,
            playback: playback, send: { prompts.send($0) }, stopTurn: { prompts.stop() }, clock: clock,
            wallClock: { Date(timeIntervalSince1970: 1_000) })
        let recorder = Recorder()
        self.recorder = recorder
        watcher = recorder.watch(session.snapshots)
    }

    func opened() async {
        await session.start()
        transport.emit(.ready(.init(gateway: "0.1", model: "voice")))
        transport.emit(.phase(.listening, at: 1))
        _ = await eventually { await session.current().face == .listening }
    }

    func snapshot() async -> VoiceCallSnapshot { await session.current() }
}
