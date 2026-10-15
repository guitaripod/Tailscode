import Foundation
import TailscodeCore

extension SelfTest {
    /// What the call's audio promises without a sound card: the echo-cancelling device is found in a
    /// listing and a monitor never is, a chunk's level is arithmetic, the meter rises quicker than
    /// it falls, and a build without PulseAudio says so rather than failing. With
    /// `TAILSCODE_SELFTEST_AUDIO` naming a null sink's monitor and the sink, the microphone and the
    /// speaker are also run against them for real.
    static func checkVoiceAudio() async throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("voice audio: \(label)") }
            checks += 1
        }
        let listing = """
            52\talsa_output.pci.monitor\tPipeWire\ts32le 2ch 48000Hz\tRUNNING
            53\talsa_input.usb-Scarlett\tPipeWire\ts32le 4ch 48000Hz\tIDLE
            61\techo-cancel-source\tPipeWire\ts16le 1ch 24000Hz\tIDLE
            """
        try expect(PulseDevices.echoCancelled(in: listing) == "echo-cancel-source", "an echo-cancelling source is preferred")
        try expect(
            PulseDevices.echoCancelled(in: "9\techo-cancel-sink.monitor\tx\ty\tz") == nil,
            "a monitor is never the answer")
        try expect(PulseDevices.echoCancelled(in: "53\talsa_input.usb\tPipeWire\ts32le\tIDLE") == nil, "no such device leaves the default")
        try expect(PulseDevices.echoCancelled(in: "") == nil, "an empty listing leaves the default")

        let silence = Data(count: PulseVoiceIO.chunkBytes)
        var loud = Data()
        for index in 0..<(PulseVoiceIO.chunkBytes / 2) {
            var sample = Int16(index % 2 == 0 ? 16000 : -16000).littleEndian
            withUnsafeBytes(of: &sample) { loud.append(contentsOf: $0) }
        }
        try expect(PCMLevel.rms(silence) == 0, "silence reads zero")
        try expect(abs(PCMLevel.rms(loud) - 16000.0 / 32768) < 1e-6, "a square wave reads its amplitude")
        try expect(PCMLevel.level(loud) == 1, "the gain brings speech to the meter and clamps at one")
        try expect(PCMLevel.rms(Data()) == 0 && PCMLevel.rms(Data([1])) == 0, "an empty or half-sample chunk reads zero")
        try expect(PulseVoiceIO.chunkBytes == 3840 && PulseVoiceIO.playbackLatencyBytes == 5760, "80 ms fragments and 120 ms of buffer at 24 kHz")

        let meter = PulseMeter()
        meter.hear(1, for: 5)
        _ = meter.level
        usleep(60_000)
        let risen = meter.level
        try expect(risen > 0.5, "the meter rises within a frame or two of a word")
        meter.silence()
        usleep(60_000)
        let fallen = meter.level
        try expect(fallen < risen && fallen > 0.2, "and falls more slowly than it rose")

        let capture = PulseCapture()
        let playback = PulsePlayback()
        await capture.stop()
        await playback.stop()
        await playback.flush()
        try expect(capture.level == 0 && playback.level == 0, "a stopped microphone and speaker are silent, and stopping twice is harmless")
        if !PulseVoiceIO.isAvailable {
            do {
                _ = try await capture.start()
                try expect(false, "a build without PulseAudio refuses to open the microphone")
            } catch let error as VoiceAudioError {
                if case .unavailable = error { checks += 1 } else { try expect(false, "and says unavailable") }
            }
        }
        if let pair = ProcessInfo.processInfo.environment["TAILSCODE_SELFTEST_AUDIO"] {
            checks += try await checkVoiceAudioLoop(pair)
        }
        return checks
    }

    private static func checkVoiceAudioLoop(_ pair: String) async throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("voice audio loop: \(label)") }
            checks += 1
        }
        let io = PulseVoiceIO()
        try await io.playback.start()
        let chunks = try await io.capture.start()
        var tone = Data()
        for index in 0..<PulseVoiceIO.chunkBytes / 2 {
            var sample = Int16(8000 * sin(2 * Double.pi * 440 * Double(index) / Double(PulseVoiceIO.rate))).littleEndian
            withUnsafeBytes(of: &sample) { tone.append(contentsOf: $0) }
        }
        let player = Task {
            for _ in 0..<25 {
                await io.playback.play(tone)
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
        var heard = 0.0
        var received = 0
        let started = Date()
        for await chunk in chunks {
            received += 1
            heard = max(heard, PCMLevel.rms(chunk))
            if received >= 20 || Date().timeIntervalSince(started) > 4 { break }
        }
        player.cancel()
        try expect(received >= 10, "the microphone delivers 80 ms chunks (\(received))")
        try expect(heard > 0.05, "what the speaker played is what the microphone heard (\(heard))")
        await io.playback.flush()
        await io.stop()
        await io.stop()
        try expect(io.capture.level < 0.01, "stopped, the level falls back to nothing")
        return checks
    }
}
