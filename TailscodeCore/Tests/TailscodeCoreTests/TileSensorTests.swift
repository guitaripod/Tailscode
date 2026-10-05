import Foundation
import Testing
@testable import TailscodeCore

@Suite("Tile sensors")
struct TileSensorTests {
    @Test("Busy share over one and two seconds from reported slices")
    func loopBusy() {
        var load = LoopLoad()
        var time: TimeInterval = 100
        for _ in 0..<100 {
            load.record(.busy, from: time, to: time + 0.007)
            load.record(.idle, from: time + 0.007, to: time + 0.010)
            time += 0.010
        }
        let reading = load.reading(now: time)
        #expect(abs(reading.busy1 - 0.7) < 0.02)
        #expect(abs(reading.busy2 - 0.7) < 0.02)
        #expect(abs(reading.worst1 - 0.007) < 1e-9)
    }

    @Test("Old slices age out of the window and a long slice is the worst")
    func loopWindow() {
        var load = LoopLoad()
        load.record(.busy, from: 10, to: 10.4)
        load.record(.idle, from: 10.4, to: 11.9)
        #expect(abs(load.worstSlice(over: 2, now: 11.9) - 0.4) < 1e-9)
        #expect(load.worstSlice(over: 1, now: 11.9) == 0)
        #expect(abs(load.busy(over: 2, now: 11.9) - 0.4 / 1.9) < 0.01)
        #expect(load.busy(over: 1, now: 11.9) == 0)
        load.record(.idle, from: 11.9, to: 20)
        #expect(load.busy(over: 2, now: 20) == 0)
        #expect(load.worstSlice(over: 2, now: 20) == 0)
        #expect(LoopLoad().busy(over: 2, now: 5) == 0)
    }

    @Test("A slice longer than the window still counts whole as the worst")
    func loopLongSlice() {
        var load = LoopLoad()
        load.record(.busy, from: 0, to: 5)
        #expect(load.worstSlice(over: 1, now: 5) == 5)
        #expect(load.busy(over: 2, now: 5) == 1)
    }

    @Test("The stall policy's thresholds")
    func stallPolicy() {
        let policy = StallPolicy()
        #expect(policy.ping == 0.5)
        #expect(policy.verdict(lastAnswer: 0, now: 2.9) == .healthy)
        #expect(policy.verdict(lastAnswer: 0, now: 3) == .stalled(3))
        #expect(policy.verdict(lastAnswer: 0, now: 10.5) == .deep(10.5))
    }

    @Test("A stall episode writes stall once, deep once, then recovers")
    func stallWatch() {
        var watch = StallWatch()
        #expect(watch.check(lastAnswer: 0, now: 1) == nil)
        #expect(watch.check(lastAnswer: 0, now: 3.2) == .stall(3.2))
        #expect(watch.isStalled)
        #expect(watch.check(lastAnswer: 0, now: 5) == nil)
        #expect(watch.check(lastAnswer: 0, now: 10) == .deep(10))
        #expect(watch.check(lastAnswer: 0, now: 12) == nil)
        #expect(watch.check(lastAnswer: 12.5, now: 12.6) == .recovered(12.5))
        #expect(!watch.isStalled)
        #expect(watch.check(lastAnswer: 12.5, now: 23) == .stall(10.5))
        #expect(watch.check(lastAnswer: 12.5, now: 23.5) == .deep(11))
    }

    @Test("PSI and meminfo parse and classify by the thresholds")
    func pressure() throws {
        let psi = try #require(HostPressureReading.parse(psi: """
            some avg10=21.50 avg60=3.00 avg300=1.00 total=123
            full avg10=1.00 avg60=0.10 avg300=0.00 total=45
            """))
        #expect(psi == .init(someAvg10: 21.5, fullAvg10: 1))
        #expect(HostPressureReading.classify(psi: psi, meminfo: nil) == .strained)
        #expect(HostPressureReading.classify(psi: .init(someAvg10: 30, fullAvg10: 5), meminfo: nil) == .critical)
        #expect(HostPressureReading.classify(psi: .init(someAvg10: 19.9, fullAvg10: 4.9), meminfo: nil) == .nominal)
        let mem = try #require(HostPressureReading.parse(meminfo: """
            MemTotal:       65000000 kB
            MemFree:         1000000 kB
            MemAvailable:    7000000 kB
            """))
        #expect(mem == .init(totalKiB: 65_000_000, availableKiB: 7_000_000))
        #expect(HostPressureReading.classify(psi: nil, meminfo: mem) == .strained)
        #expect(HostPressureReading.classify(psi: nil, meminfo: .init(totalKiB: 100, availableKiB: 5)) == .critical)
        #expect(HostPressureReading.classify(psi: nil, meminfo: .init(totalKiB: 100, availableKiB: 12)) == .nominal)
        #expect(HostPressureReading.classify(psi: psi, meminfo: .init(totalKiB: 100, availableKiB: 5)) == .critical)
        #expect(HostPressureReading.classify(psiText: nil, meminfoText: nil) == .nominal)
        #expect(HostPressureReading.parse(psi: "garbage") == nil)
        #expect(HostPressureReading.parse(meminfo: "MemTotal: 5 kB") == nil)
    }

    @Test("Own memory ratio and the files it reads")
    func ownMemory() {
        #expect(OwnMemory.ratio(current: 7, high: 10) == 0.7)
        #expect(OwnMemory.ratio(current: 7, high: nil) == nil)
        #expect(OwnMemory.ratio(current: 7, high: 0) == nil)
        #expect(OwnMemory.parse(cgroupValue: "123456\n") == 123_456)
        #expect(OwnMemory.parse(cgroupValue: "max\n") == nil)
        #expect(OwnMemory.parse(statm: "1000 250 30 1 0 400 0\n", pageSize: 4096) == 250 * 4096)
        #expect(OwnMemory.fallbackHigh(memTotalBytes: 62 * ResourceLimits.gib) == ResourceLimits.plan(memTotalBytes: 62 * ResourceLimits.gib).memoryHigh)
        #expect(OwnMemory.appleHigh(physicalBytes: 16 * ResourceLimits.gib) == UInt64(Double(16 * ResourceLimits.gib) * 0.15))
        #expect(OwnMemory.appleHigh(physicalBytes: 128 * ResourceLimits.gib) == 8 * ResourceLimits.gib)
    }

    @Test("Relief trims at 3, empties at 4, does nothing below, and is thread-safe")
    func relief() {
        let relief = MemoryRelief()
        let depths = Tally<ReliefDepth>()
        let token = relief.register(name: "images") { depths.add($0) }
        relief.register(name: "rows") { depths.add($0) }
        #expect(relief.relieve(level: .loaded).isEmpty)
        #expect(relief.relieve(level: .strained) == ["images", "rows"])
        #expect(relief.relieve(level: .critical) == ["images", "rows"])
        #expect(depths.all == [.half, .half, .all, .all])
        token.cancel()
        token.cancel()
        #expect(relief.names == ["rows"])
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            let token = relief.register(name: "c\(index)") { _ in }
            relief.relieve(.half)
            token.cancel()
        }
        #expect(relief.names == ["rows"])
    }
    @Test("Slices on awkward boundaries always finish and keep the share between 0 and 1")
    func loopBoundaries() {
        for seed in 1...200 {
            var state = UInt64(seed)
            func next() -> Double {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Double(state >> 11) / Double(1 << 53)
            }
            var load = LoopLoad()
            var time = Double(seed) * 0.05
            for _ in 0..<200 {
                let span = [0.05, 0.15, 0.001, next() * 0.3, 1e-12][Int(next() * 5) % 5]
                load.record(next() < 0.5 ? .busy : .idle, from: time, to: time + span)
                time += span
            }
            let share = load.busy(over: 2, now: time)
            #expect(share >= 0 && share <= 1)
        }
    }
}
