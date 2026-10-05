import Foundation
import Testing
@testable import TailscodeCore

@Suite("Tile primitives: mailbox, lifetime, pump")
struct TilePrimitivesTests {
    @Test("A mailbox keeps only the newest value and signals once per clean-to-dirty transition")
    func latestWins() {
        let box = LatestWins<Int>()
        #expect(box.take() == nil)
        #expect(box.post(1))
        #expect(!box.post(2))
        #expect(!box.post(3))
        #expect(box.isDirty)
        #expect(box.take() == 3)
        #expect(box.take() == nil)
        #expect(!box.isDirty)
        #expect(box.post(4))
        #expect(box.peek() == 4)
        #expect(box.take() == 4)
    }

    @Test("Concurrent posts signal exactly once before a take")
    func latestWinsConcurrent() {
        let box = LatestWins<Int>()
        let signals = Tally<Bool>()
        DispatchQueue.concurrentPerform(iterations: 1000) { index in
            if box.post(index) { signals.add(true) }
        }
        #expect(signals.count == 1)
        #expect(box.take() != nil)
    }

    @Test("A lifetime cancels everything once, is idempotent and reusable")
    func lifetime() {
        let lifetime = PaneLifetime()
        let fired = Tally<Int>()
        lifetime.add { fired.add(1) }
        lifetime.add { fired.add(2) }
        #expect(lifetime.count == 2)
        lifetime.cancelAll()
        #expect(fired.all == [1, 2])
        lifetime.cancelAll()
        #expect(fired.all == [1, 2])
        lifetime.add { fired.add(3) }
        lifetime.cancelAll()
        lifetime.cancelAll()
        #expect(fired.all == [1, 2, 3])
    }

    @Test("A cancel may register on its own lifetime without deadlocking")
    func lifetimeReentrant() {
        let lifetime = PaneLifetime()
        let fired = Tally<Int>()
        lifetime.add { lifetime.add { fired.add(9) } }
        lifetime.cancelAll()
        #expect(lifetime.count == 1)
        lifetime.cancelAll()
        #expect(fired.all == [9])
    }

    @Test("The build gate never runs more than its limit at once")
    func gateLimit() async {
        let gate = BuildGate(limit: 2)
        let lock = NSLock()
        nonisolated(unsafe) var active = 0
        nonisolated(unsafe) var peak = 0
        let done = Tally<Int>()
        for index in 0..<20 {
            gate.run {
                lock.lock()
                active += 1
                peak = max(peak, active)
                lock.unlock()
                usleep(2000)
                lock.lock()
                active -= 1
                lock.unlock()
                done.add(index)
            }
        }
        #expect(await eventually { done.count == 20 })
        #expect(peak <= 2)
        #expect(peak >= 1)
        #expect(await eventually { gate.inFlight == 0 })
    }

    @Test("The shared gate allows a quarter of the cores, at least one")
    func gateShared() {
        #expect(BuildGate.shared.limit == max(1, ProcessInfo.processInfo.activeProcessorCount / 4))
        #expect(BuildGate(limit: 0).limit == 1)
    }

    @Test("A pump never runs two works, always ends on the newest input, never builds a stale one")
    func pumpSingleFlight() async {
        let lock = NSLock()
        nonisolated(unsafe) var active = 0
        nonisolated(unsafe) var overlapped = false
        let built = Tally<Int>()
        let delivered = Tally<Int>()
        let pump = SingleFlightPump<Int, Int>(
            gate: BuildGate(limit: 4),
            work: { input in
                lock.lock()
                active += 1
                if active > 1 { overlapped = true }
                lock.unlock()
                usleep(3000)
                built.add(input)
                lock.lock()
                active -= 1
                lock.unlock()
                return input * 10
            },
            deliver: { delivered.add($0) })
        for input in 1...200 {
            pump.offer(input)
            if input % 20 == 0 { usleep(1000) }
        }
        #expect(await eventually { pump.isIdle })
        #expect(!overlapped)
        #expect(built.all.last == 200)
        #expect(delivered.all.last == 2000)
        #expect(built.count < 200)
        #expect(built.all == built.all.sorted())
        #expect(delivered.all == built.all.map { $0 * 10 })
    }

    @Test("A cancelled pump withholds the running build's delivery and ignores later offers")
    func pumpCancel() async {
        let started = Tally<Int>()
        let delivered = Tally<Int>()
        let release = DispatchSemaphore(value: 0)
        let pump = SingleFlightPump<Int, Int>(
            gate: BuildGate(limit: 1),
            work: { input in
                started.add(input)
                release.wait()
                return input
            },
            deliver: { delivered.add($0) })
        pump.offer(1)
        #expect(await eventually { started.count == 1 })
        pump.offer(2)
        pump.cancel()
        release.signal()
        #expect(await eventually { pump.isIdle })
        pump.offer(3)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(delivered.all.isEmpty)
        #expect(started.all == [1])
    }
}
