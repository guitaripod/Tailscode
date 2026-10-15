#if canImport(AVFoundation) && (os(iOS) || os(macOS))
    import Foundation
    import os

    /// A loudness any thread can write and any thread can read, that falls back to zero by itself when
    /// nothing has refreshed it, so a stopped stream never leaves the last word glowing.
    final class AppleVoiceMeter: Sendable {
        private struct Reading: Sendable {
            var value = 0.0
            var until: TimeInterval = 0
        }

        private let state = OSAllocatedUnfairLock(initialState: Reading())

        var value: Double {
            let now = ProcessInfo.processInfo.systemUptime
            return state.withLock { $0.until > now ? $0.value : 0 }
        }

        func set(_ value: Double, holdingFor seconds: TimeInterval) {
            let until = ProcessInfo.processInfo.systemUptime + seconds
            state.withLock { $0 = Reading(value: value, until: until) }
        }

        func clear() {
            state.withLock { $0 = Reading() }
        }
    }
#endif
