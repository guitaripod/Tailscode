import Foundation
import TailscodeCore

#if HAS_PULSE
    import CPulse
#endif

/// The call's audio on Linux: PulseAudio's simple API, which PipeWire answers too, as the
/// microphone and the speaker Core's `VoiceCallSession` is handed. Both are 24 kHz mono PCM16 little
/// endian, the format the gateway speaks, so nothing here resamples.
///
/// A machine whose build has no libpulse still builds: the same types answer that audio is
/// unavailable, and Core turns that into the call's own words.
final class PulseVoiceIO: @unchecked Sendable {
    static let rate = VoicePCM.sampleRate
    static let bytesPerSecond = rate * VoicePCM.bytesPerSample
    static let chunkBytes = VoicePCM.chunkBytes
    static let playbackLatencyBytes = VoicePCM.bytes(forMilliseconds: 120)

    static var isAvailable: Bool {
        #if HAS_PULSE
            return true
        #else
            return false
        #endif
    }

    let capture = PulseCapture()
    let playback = PulsePlayback()

    /// Frees both streams and joins the capture thread, however many times it is asked.
    func stop() async {
        await capture.stop()
        await playback.stop()
    }
}

/// Which PulseAudio device a call should use, decided from `pactl`'s own listing.
enum PulseDevices {
    /// The name of an echo-cancelling device in a `pactl list short sources|sinks` listing, or nil
    /// when there is none. A monitor is never the answer: it is what a device plays, not what it
    /// hears.
    static func echoCancelled(in listing: String) -> String? {
        for line in listing.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { continue }
            let name = String(fields[1])
            let lowered = name.lowercased()
            guard !lowered.hasSuffix(".monitor") else { continue }
            if lowered.hasPrefix("echo-cancel") || lowered.contains("echo-cancel") || lowered.contains("echo_cancel") {
                return name
            }
        }
        return nil
    }

    /// The device a call opens and why, so the log can say which: a name a person or a harness set
    /// in `TAILSCODE_VOICE_SOURCE` / `TAILSCODE_VOICE_SINK`, else an echo-cancelling one the desk
    /// already runs, else nothing, which is the desk's default device.
    static func chosen(_ kind: String) -> (name: String?, why: String) {
        let variable = kind == "sources" ? "TAILSCODE_VOICE_SOURCE" : "TAILSCODE_VOICE_SINK"
        if let named = ProcessInfo.processInfo.environment[variable], !named.isEmpty {
            return (named, "named by \(variable)")
        }
        if let listing = run(["list", "short", kind]), let name = echoCancelled(in: listing) {
            return (name, "echo cancelled")
        }
        return (nil, "the default, with no echo-cancel device found")
    }

    private static func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["pactl"] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        guard done.wait(timeout: .now() + 1.5) == .success else {
            process.terminate()
            return nil
        }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}

/// One PulseAudio simple-API stream. The only place the C library is named.
final class PulseStream: @unchecked Sendable {
    enum Direction {
        case record
        case playback
    }

    private let gate = NSLock()

    #if HAS_PULSE
        private var handle: OpaquePointer?

        init(direction: Direction, device: String?, name: String) throws {
            var spec = pa_sample_spec(format: PA_SAMPLE_S16LE, rate: UInt32(PulseVoiceIO.rate), channels: 1)
            var attributes = pa_buffer_attr(
                maxlength: UInt32.max, tlength: UInt32.max, prebuf: UInt32.max, minreq: UInt32.max,
                fragsize: UInt32.max)
            switch direction {
            case .record:
                attributes.fragsize = UInt32(PulseVoiceIO.chunkBytes)
            case .playback:
                attributes.tlength = UInt32(PulseVoiceIO.playbackLatencyBytes)
                attributes.maxlength = UInt32(PulseVoiceIO.playbackLatencyBytes * 2)
                attributes.minreq = UInt32(PulseVoiceIO.chunkBytes / 2)
                attributes.prebuf = UInt32(PulseVoiceIO.chunkBytes / 2)
            }
            var failure: Int32 = 0
            let opened = pa_simple_new(
                nil, "Tailscode", direction == .record ? PA_STREAM_RECORD : PA_STREAM_PLAYBACK, device, name,
                &spec, nil, &attributes, &failure)
            guard let opened else {
                if failure == Int32(PA_ERR_ACCESS.rawValue) { throw VoiceAudioError.microphoneDenied }
                throw VoiceAudioError.unavailable(Self.describe(failure))
            }
            handle = opened
        }

        private static func describe(_ code: Int32) -> String {
            pa_strerror(code).map { String(cString: $0) } ?? "PulseAudio error \(code)"
        }

        func read(into buffer: UnsafeMutableRawBufferPointer) -> String? {
            guard let handle else { return "closed" }
            var failure: Int32 = 0
            return pa_simple_read(handle, buffer.baseAddress, buffer.count, &failure) < 0 ? Self.describe(failure) : nil
        }

        func write(_ data: Data) -> String? {
            guard let handle else { return "closed" }
            var failure: Int32 = 0
            let result = data.withUnsafeBytes { raw in
                pa_simple_write(handle, raw.baseAddress, raw.count, &failure)
            }
            return result < 0 ? Self.describe(failure) : nil
        }

        func flush() {
            gate.withLock {
                guard let handle else { return }
                var failure: Int32 = 0
                _ = pa_simple_flush(handle, &failure)
            }
        }

        func free() {
            gate.withLock {
                guard let handle else { return }
                self.handle = nil
                pa_simple_free(handle)
            }
        }
    #else
        init(direction: Direction, device: String?, name: String) throws {
            throw VoiceAudioError.unavailable("this build has no PulseAudio support")
        }

        func read(into buffer: UnsafeMutableRawBufferPointer) -> String? { "unavailable" }

        func write(_ data: Data) -> String? { "unavailable" }

        func flush() {}

        func free() {}
    #endif
}

/// A level a screen reads each frame: the loudness of what is sounding now, eased by Core so a word
/// is seen when it starts and the light does not flicker between syllables.
final class PulseMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var target = 0.0
    private var targetUntil = 0.0
    private var shown = 0.0
    private var shownAt = 0.0

    private static var now: Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }

    func hear(_ level: Double, for seconds: Double) {
        lock.withLock {
            target = level
            targetUntil = Self.now + seconds
        }
    }

    func silence() {
        lock.withLock {
            target = 0
            targetUntil = 0
        }
    }

    var level: Double {
        lock.withLock {
            let now = Self.now
            let goal = now < targetUntil ? target : 0
            let elapsed = shownAt == 0 ? 0 : now - shownAt
            shown = VoiceCallLevels.smoothed(previous: shown, target: goal, dt: elapsed)
            shownAt = now
            return shown
        }
    }
}

/// The microphone. A dedicated thread does the blocking read, one 80 ms fragment at a time, so the
/// flag that ends it is looked at every 80 ms and a stop never waits on more than that.
final class PulseCapture: VoiceAudioCapture, @unchecked Sendable {
    private let lock = NSLock()
    private var finished: DispatchSemaphore?
    private var epoch = 0
    private let meter = PulseMeter()

    var level: Double { meter.level }

    func start() async throws -> AsyncStream<Data> {
        await stop()
        let device = PulseDevices.chosen("sources")
        AppLog.write(.session, "call microphone: \(device.name ?? "default source") (\(device.why))")
        let opened = try PulseStream(direction: .record, device: device.name, name: "Call microphone")
        let done = DispatchSemaphore(value: 0)
        let mine = lock.withLock {
            epoch += 1
            finished = done
            return epoch
        }
        let (chunks, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let thread = Thread { [weak self] in
            Self.read(opened, into: continuation, owner: self, epoch: mine)
            opened.free()
            continuation.finish()
            done.signal()
        }
        thread.name = "tailscode.voice.capture"
        thread.qualityOfService = .userInteractive
        thread.start()
        return chunks
    }

    private func isCurrent(_ mine: Int) -> Bool { lock.withLock { epoch == mine } }

    private static func read(
        _ stream: PulseStream, into continuation: AsyncStream<Data>.Continuation, owner: PulseCapture?,
        epoch: Int
    ) {
        var buffer = [UInt8](repeating: 0, count: PulseVoiceIO.chunkBytes)
        while owner?.isCurrent(epoch) == true {
            let failure = buffer.withUnsafeMutableBytes { stream.read(into: $0) }
            if let failure {
                if owner?.isCurrent(epoch) == true {
                    AppLog.write(.session, "call microphone read failed: \(failure)")
                }
                return
            }
            guard owner?.isCurrent(epoch) == true else { return }
            let chunk = Data(buffer)
            owner?.meter.hear(VoicePCM.rms(of: chunk), for: 0.2)
            continuation.yield(chunk)
        }
    }

    func stop() async {
        let pending: DispatchSemaphore? = lock.withLock {
            epoch += 1
            let pending = finished
            finished = nil
            return pending
        }
        guard let pending else { return }
        if pending.wait(timeout: .now() + 2) == .timedOut {
            AppLog.write(.session, "call microphone: the capture thread did not end in time; it frees itself when it does")
        }
        meter.silence()
    }
}

/// The speaker. Writes happen on one serial queue so chunks sound in the order they arrived, the
/// buffer is held to about 120 ms so a person talking over the voice is heard by it quickly, and a
/// flush drops what is queued and what the server has not played yet.
final class PulsePlayback: VoiceAudioPlayback, @unchecked Sendable {
    private let queue = DispatchQueue(label: "tailscode.voice.playback", qos: .userInteractive)
    private let lock = NSLock()
    private let meter = PulseMeter()
    private var stream: PulseStream?
    private var generation = 0
    private var stopping = false

    var level: Double { meter.level }

    func start() async throws {
        await stop()
        let device = PulseDevices.chosen("sinks")
        AppLog.write(.session, "call speaker: \(device.name ?? "default sink") (\(device.why))")
        let opened = try PulseStream(direction: .playback, device: device.name, name: "Call voice")
        lock.withLock {
            stream = opened
            stopping = false
            generation += 1
        }
    }

    func play(_ pcm: Data) async {
        let held: (PulseStream, Int)? = lock.withLock {
            guard let stream, !stopping else { return nil }
            return (stream, generation)
        }
        guard let (current, mine) = held else { return }
        meter.hear(VoicePCM.rms(of: pcm), for: Double(pcm.count) / Double(PulseVoiceIO.bytesPerSecond))
        queue.async { [weak self] in
            guard let self, self.lock.withLock({ self.generation == mine && !self.stopping }) else { return }
            if let failure = current.write(pcm) {
                AppLog.write(.session, "call speaker write failed: \(failure)")
            }
        }
    }

    func flush() async {
        let current: PulseStream? = lock.withLock {
            generation += 1
            return stopping ? nil : stream
        }
        meter.silence()
        current?.flush()
    }

    func stop() async {
        let doomed: PulseStream? = lock.withLock {
            stopping = true
            generation += 1
            let doomed = stream
            stream = nil
            return doomed
        }
        guard let doomed else { return }
        doomed.flush()
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            queue.async {
                doomed.free()
                finished.resume()
            }
        }
        meter.silence()
    }
}
