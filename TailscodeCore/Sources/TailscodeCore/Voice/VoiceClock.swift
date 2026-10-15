import Foundation

/// The call's one source of time: monotonic seconds, and a sleep that a test can drive by hand.
/// `HostClock` asks a toolkit to drain a frame; a call has to wait for a debounce, a heartbeat and
/// a backoff, so it needs the other half.
public protocol VoiceClock: Sendable {
    func now() -> TimeInterval
    func sleep(for seconds: TimeInterval) async throws
}

public struct SystemVoiceClock: VoiceClock {
    public init() {}

    public func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    public func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}
