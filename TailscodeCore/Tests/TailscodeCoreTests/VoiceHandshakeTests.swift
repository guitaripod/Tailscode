import Foundation
import Testing

@testable import TailscodeCore

private struct Early: Error, Equatable {}
private struct Refused: Error, Equatable {}

private final class Pings: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let failures: Int
    private var over = false

    init(failing failures: Int) {
        self.failures = failures
    }

    var count: Int { lock.withLock { calls } }
    var isOver: Bool { lock.withLock { over } }

    func finish() { lock.withLock { over = true } }

    func ping() async throws {
        let call = lock.withLock { () -> Int in
            calls += 1
            return calls
        }
        if call <= failures { throw Early() }
    }
}

@Suite("Voice handshake")
struct VoiceHandshakeTests {
    @Test("A ping sent before the upgrade finished is tried again until the socket answers")
    func retriesUntilAnswered() async throws {
        let clock = ManualVoiceClock()
        let pings = Pings(failing: 3)
        let waiting = Task {
            try await VoiceHandshake.prove(
                ping: { try await pings.ping() }, isOver: { pings.isOver }, failure: { nil }, timeout: 8,
                clock: clock)
        }
        #expect(await eventually { pings.count == 1 && clock.sleepers == 1 })
        await clock.advance(by: 0.1)
        try await waiting.value
        #expect(pings.count == 4)
    }

    @Test("A socket that answers at once is not delayed")
    func answersAtOnce() async throws {
        let clock = ManualVoiceClock()
        let pings = Pings(failing: 0)
        try await VoiceHandshake.prove(
            ping: { try await pings.ping() }, isOver: { false }, failure: { nil }, timeout: 8, clock: clock)
        #expect(pings.count == 1)
        #expect(clock.sleepers == 0)
    }

    @Test("A task that is over ends the wait with its own error, not the ping's")
    func overTaskThrowsItsError() async {
        let clock = ManualVoiceClock()
        let pings = Pings(failing: 100)
        pings.finish()
        await #expect(throws: Refused.self) {
            try await VoiceHandshake.prove(
                ping: { try await pings.ping() }, isOver: { pings.isOver }, failure: { Refused() }, timeout: 8,
                clock: clock)
        }
        #expect(pings.count == 1)
    }

    @Test("A socket that never opens ends the wait at the timeout with the ping's error")
    func timesOut() async {
        let clock = ManualVoiceClock()
        let pings = Pings(failing: 10_000)
        let waiting = Task {
            try await VoiceHandshake.prove(
                ping: { try await pings.ping() }, isOver: { false }, failure: { nil }, timeout: 1, clock: clock)
        }
        for _ in 0..<60 { await clock.advance(by: 0.05) }
        await #expect(throws: Early.self) { try await waiting.value }
        #expect(pings.count > 10)
        #expect(pings.count < 60)
    }

    @Test("Cancelling a call that is still connecting ends the wait")
    func cancellation() async {
        let clock = ManualVoiceClock()
        let pings = Pings(failing: 10_000)
        let waiting = Task {
            try await VoiceHandshake.prove(
                ping: { try await pings.ping() }, isOver: { false }, failure: { nil }, timeout: 8, clock: clock)
        }
        #expect(await eventually { clock.sleepers == 1 })
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
    }
}
