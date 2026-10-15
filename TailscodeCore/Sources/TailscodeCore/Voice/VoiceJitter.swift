import Foundation

/// How the speaker rides out an uneven network: how much voice to hold back before starting, how
/// much may wait to be heard before the oldest is thrown away, and how old a waiting frame may get
/// before it is too late to be worth saying. Pure numbers, so the policy is tested on its own.
public struct VoiceJitter: Sendable, Equatable {
    public let prebufferMilliseconds: Int
    public let lateAfterMilliseconds: Int
    public let maxQueuedMilliseconds: Int
    public let lookaheadMilliseconds: Int

    public static let standard = VoiceJitter(
        prebufferMilliseconds: 120, lateAfterMilliseconds: 1000, maxQueuedMilliseconds: 1500,
        lookaheadMilliseconds: 240)

    public init(
        prebufferMilliseconds: Int, lateAfterMilliseconds: Int, maxQueuedMilliseconds: Int,
        lookaheadMilliseconds: Int
    ) {
        let lookahead = max(VoicePCM.chunkMilliseconds, lookaheadMilliseconds)
        let prebuffer = max(0, prebufferMilliseconds)
        self.prebufferMilliseconds = prebuffer
        self.lookaheadMilliseconds = lookahead
        self.maxQueuedMilliseconds = max(maxQueuedMilliseconds, prebuffer + lookahead)
        self.lateAfterMilliseconds = max(0, lateAfterMilliseconds)
    }

    public func shouldStart(queuedMilliseconds: Double) -> Bool {
        queuedMilliseconds >= Double(prebufferMilliseconds)
    }

    public func isLate(waitedMilliseconds: Double) -> Bool {
        waitedMilliseconds > Double(lateAfterMilliseconds)
    }

    /// How much of the oldest audio to throw away so no more than `maxQueuedMilliseconds` waits.
    public func overflow(queuedMilliseconds: Double) -> Double {
        max(0, queuedMilliseconds - Double(maxQueuedMilliseconds))
    }
}

/// The speaker's queue as a state machine over a `VoiceJitter`: frames arrive, `take` says which to
/// hand to the audio device now, and `consumed` says how much of what was handed over has been
/// heard. It starts only after the prebuffer is held, keeps the device a short way ahead and no
/// further, drops the oldest waiting audio when too much has queued or when a frame has waited
/// too long, and goes back to prebuffering after the device runs dry.
public struct VoiceJitterQueue: Sendable {
    public let policy: VoiceJitter
    public private(set) var droppedFrames = 0
    public private(set) var isPlaying = false
    private var waiting: [Waiting] = []
    private var handedOverMilliseconds = 0.0

    private struct Waiting: Sendable {
        let pcm: Data
        let arrivedAt: TimeInterval
    }

    public init(policy: VoiceJitter = .standard) {
        self.policy = policy
    }

    public var waitingMilliseconds: Double {
        waiting.reduce(0) { $0 + VoicePCM.milliseconds(forBytes: $1.pcm.count) }
    }

    public var queuedMilliseconds: Double { waitingMilliseconds + handedOverMilliseconds }

    public mutating func push(_ pcm: Data, at now: TimeInterval) {
        let usable = pcm.count - pcm.count % VoicePCM.bytesPerSample
        guard usable > 0 else { return }
        waiting.append(Waiting(pcm: usable == pcm.count ? pcm : pcm.prefix(usable), arrivedAt: now))
        var excess = policy.overflow(queuedMilliseconds: queuedMilliseconds)
        while excess > 0, !waiting.isEmpty {
            excess -= VoicePCM.milliseconds(forBytes: waiting.removeFirst().pcm.count)
            droppedFrames += 1
        }
    }

    public mutating func take(at now: TimeInterval) -> [Data] {
        dropLate(at: now)
        if !isPlaying {
            guard !waiting.isEmpty, policy.shouldStart(queuedMilliseconds: queuedMilliseconds) else { return [] }
            isPlaying = true
        }
        var frames: [Data] = []
        while handedOverMilliseconds < Double(policy.lookaheadMilliseconds), !waiting.isEmpty {
            let next = waiting.removeFirst().pcm
            handedOverMilliseconds += VoicePCM.milliseconds(forBytes: next.count)
            frames.append(next)
        }
        return frames
    }

    public mutating func consumed(milliseconds: Double) {
        handedOverMilliseconds = max(0, handedOverMilliseconds - max(0, milliseconds))
        if handedOverMilliseconds < 0.5, waiting.isEmpty { isPlaying = false }
    }

    public mutating func reset() {
        waiting.removeAll()
        handedOverMilliseconds = 0
        isPlaying = false
    }

    private mutating func dropLate(at now: TimeInterval) {
        let before = waiting.count
        waiting.removeAll { policy.isLate(waitedMilliseconds: (now - $0.arrivedAt) * 1000) }
        droppedFrames += before - waiting.count
    }
}
