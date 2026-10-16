import CodingAgentKit
import Foundation

/// The scripted call a demo host gets. It speaks the same wire as the gateway, so the session, the
/// faces and the lines it hears are the real ones; only the machine is missing.
public enum VoiceDemo {
    public static let gatewayVersion = "demo"
    public static let modelName = "demo"

    public static func isDemoHost(_ host: String) -> Bool { DelegateDemo.isDemoHost(host) }

    public static func stage(clock: any VoiceClock = SystemVoiceClock()) -> VoiceDemoStage {
        VoiceDemoStage(clock: clock)
    }
}

/// One demo call's shared timeline: the transport and the microphone read the same anchor, so the
/// level the person sees rise is the level of the line being heard.
public final class VoiceDemoStage: @unchecked Sendable {
    public let clock: any VoiceClock
    public let transport: VoiceDemoTransport
    public let capture: VoiceDemoCapture
    public let playback: VoiceDemoPlayback

    init(clock: any VoiceClock) {
        self.clock = clock
        let timeline = VoiceDemoTimeline()
        self.transport = VoiceDemoTransport(clock: clock, timeline: timeline)
        self.capture = VoiceDemoCapture(clock: clock, timeline: timeline)
        self.playback = VoiceDemoPlayback()
    }
}

final class VoiceDemoTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var anchor: TimeInterval?

    func begin(at now: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        if anchor == nil { anchor = now }
    }

    func elapsed(at now: TimeInterval) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return anchor.map { now - $0 }
    }
}

public final class VoiceDemoTransport: VoiceTransport, @unchecked Sendable {
    private let clock: any VoiceClock
    private let timeline: VoiceDemoTimeline
    private let lock = NSLock()
    private var player: Task<Void, Never>?
    private var output: AsyncThrowingStream<VoiceFrame, Error>.Continuation?

    init(clock: any VoiceClock, timeline: VoiceDemoTimeline) {
        self.clock = clock
        self.timeline = timeline
    }

    public func connect(url: URL, bearer: String?) async throws {
        timeline.begin(at: clock.now())
    }

    public func sendBinary(_ data: Data) async throws {}

    public func sendText(_ text: String) async throws {}

    public func receive() -> AsyncThrowingStream<VoiceFrame, Error> {
        let (stream, continuation) = AsyncThrowingStream<VoiceFrame, Error>.makeStream()
        let clock = self.clock
        let player = Task {
            var loop = 0
            while !Task.isCancelled {
                var elapsed: TimeInterval = 0
                for cue in VoiceDemoScript.cues(loop: loop) {
                    do { try await clock.sleep(for: max(0, cue.at - elapsed)) } catch { return }
                    elapsed = cue.at
                    if let text = try? VoiceCodec.encode(cue.message) { continuation.yield(.text(text)) }
                }
                do { try await clock.sleep(for: max(0, VoiceDemoScript.loopLength - elapsed)) } catch { return }
                loop += 1
            }
        }
        continuation.onTermination = { _ in player.cancel() }
        let replaced: Task<Void, Never>? = lock.withLock {
            let old = self.player
            self.player = player
            output = continuation
            return old
        }
        replaced?.cancel()
        return stream
    }

    public func close() async {
        let (task, stream) = lock.withLock { () -> (Task<Void, Never>?, AsyncThrowingStream<VoiceFrame, Error>.Continuation?) in
            defer {
                player = nil
                output = nil
            }
            return (player, output)
        }
        task?.cancel()
        stream?.finish()
    }
}

public final class VoiceDemoCapture: VoiceAudioCapture, @unchecked Sendable {
    private let clock: any VoiceClock
    private let timeline: VoiceDemoTimeline
    private let lock = NSLock()
    private var feeder: Task<Void, Never>?
    private var output: AsyncStream<Data>.Continuation?
    private var running = false

    init(clock: any VoiceClock, timeline: VoiceDemoTimeline) {
        self.clock = clock
        self.timeline = timeline
    }

    public var isRunning: Bool {
        lock.withLock { running }
    }

    public var level: Double {
        guard let elapsed = timeline.elapsed(at: clock.now()) else { return 0 }
        return VoiceDemoScript.userLevel(at: elapsed)
    }

    public func start() async throws -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let clock = self.clock
        let feeder = Task {
            while !Task.isCancelled {
                do { try await clock.sleep(for: VoiceDemoScript.chunkInterval) } catch { return }
                continuation.yield(Data(count: VoiceWire.preferredChunkBytes))
            }
        }
        continuation.onTermination = { _ in feeder.cancel() }
        lock.withLock {
            self.feeder = feeder
            output = continuation
            running = true
        }
        return stream
    }

    public func stop() async {
        let (task, stream) = lock.withLock { () -> (Task<Void, Never>?, AsyncStream<Data>.Continuation?) in
            defer {
                feeder = nil
                output = nil
                running = false
            }
            return (feeder, output)
        }
        task?.cancel()
        stream?.finish()
    }
}

public final class VoiceDemoPlayback: VoiceAudioPlayback, @unchecked Sendable {
    private let lock = NSLock()
    private var heard = 0

    init() {}

    public var chunksPlayed: Int {
        lock.withLock { heard }
    }

    public var level: Double { 0 }

    public func start() async throws {}

    public func play(_ pcm: Data) async {
        lock.withLock { heard += 1 }
    }

    public func flush() async {}

    public func stop() async {}
}
