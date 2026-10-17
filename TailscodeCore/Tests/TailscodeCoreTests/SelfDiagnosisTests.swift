import Foundation
import Testing
@testable import TailscodeCore

@Suite("Self-diagnosis")
struct SelfDiagnosisTests {
    @Test("Five busy seconds in a row fire once, and again only after a minute")
    func sustained() {
        var watch = SustainedBusy()
        var fired: [TimeInterval] = []
        for second in 1...130 {
            if watch.record(busy: 1, now: Double(second)) != nil { fired.append(Double(second)) }
        }
        #expect(fired == [5, 65, 125])
    }

    @Test("A calm second resets the run")
    func reset() {
        var watch = SustainedBusy()
        var early: [TimeInterval?] = []
        for second in 1...4 { early.append(watch.record(busy: 0.95, now: Double(second))) }
        #expect(early.allSatisfy { $0 == nil })
        #expect(watch.isRising)
        let calm = watch.record(busy: 0.3, now: 5)
        #expect(calm == nil)
        #expect(!watch.isRising)
        var again: [TimeInterval?] = []
        for second in 6...9 { again.append(watch.record(busy: 0.95, now: Double(second))) }
        #expect(again.allSatisfy { $0 == nil })
        let fired = watch.record(busy: 0.95, now: 10)
        #expect(fired == 5)
    }

    @Test("A tick that arrives late counts for the time it covers")
    func late() {
        var watch = SustainedBusy()
        let first = watch.record(busy: 1, now: 1)
        let second = watch.record(busy: 1, now: 6)
        #expect(first == nil)
        #expect(second == 6)
    }

    @Test("Below the threshold nothing runs")
    func below() {
        var watch = SustainedBusy()
        var answers: [TimeInterval?] = []
        for second in 1...30 { answers.append(watch.record(busy: 0.89, now: Double(second))) }
        #expect(answers.allSatisfy { $0 == nil })
    }

    @Test("A thread's stat line is read past a name with spaces and parentheses")
    func parse() throws {
        let stat = "4021 (pool (spawn) x) S 1 4021 4021 0 -1 4194560 100 0 0 0 700 120 0 0 20 0 1 0 5 1000 100 18446744073709551615"
        let sample = try #require(ThreadCPU.parse(stat: stat))
        #expect(sample == ThreadSample(id: 4021, name: "pool_(spawn)_x", ticks: 820))
        #expect(ThreadCPU.parse(stat: "garbage") == nil)
        #expect(ThreadCPU.parse(stat: "1 (x) S 1") == nil)
    }

    @Test("The hottest threads are ranked by their delta, not their total")
    func hottest() {
        let earlier: [Int32: UInt64] = [1: 1000, 2: 10, 3: 50]
        let now = [
            ThreadSample(id: 1, name: "main", ticks: 1450),
            ThreadSample(id: 2, name: "glycin", ticks: 510),
            ThreadSample(id: 3, name: "idle", ticks: 50),
            ThreadSample(id: 4, name: "new", ticks: 100),
            ThreadSample(id: 5, name: "tiny", ticks: 4),
        ]
        let hot = ThreadCPU.hottest(since: earlier, now: now, seconds: 5, ticksPerSecond: 100, count: 3)
        #expect(hot.map(\.name) == ["glycin", "main", "new"])
        #expect(hot.map(\.percent) == [100, 90, 20])
        #expect(hot[0].phrase == "glycin(2) 100%")
        #expect(ThreadCPU.hottest(since: [:], now: now, seconds: 0, ticksPerSecond: 100).isEmpty)
    }

    @Test("Frames are module-relative and read back")
    func frames() throws {
        let frame = StackReport.frame(module: "libgtk-4.so.1", offset: 0x2f6ab9)
        #expect(frame == "libgtk-4.so.1+0x2f6ab9")
        let parsed = try #require(StackReport.parseFrame(Substring(frame)))
        #expect(parsed.module == "libgtk-4.so.1" && parsed.offset == 0x2f6ab9)
        #expect(StackReport.parseFrame("nothing") == nil)
        #expect(StackReport.parseFrame("+0x10") == nil)
        #expect(StackReport.parseFrame("a+0x") == nil)
    }

    @Test("A capture reads back as its summary and the stacks that follow")
    func captures() {
        let hot = [HotThread(id: 7, name: "gmain", percent: 88)]
        let summary = StackReport.summary(
            reason: "sustained busy 5.0 s", mainThread: "R ? cpu=812", rssKiB: 1_300_000, threads: 188,
            hot: hot, build: "1.79")
        #expect(summary == "watchdog: sustained busy 5.0 s · main R ? cpu=812 · rss 1269 MB · 188 threads · hot: gmain(7) 88% · build 1.79")
        let log = """
            2026-10-17T10:00:00Z [lifecycle] watchdog: stall 3000ms R ? cpu=1
            2026-10-17T10:00:01Z [lifecycle] \(summary)
            2026-10-17T10:00:01Z [lifecycle] \(StackReport.stackLine(index: 1, of: 2, frames: ["tailscode+0x10", "libc.so.6+0x20"]))
            2026-10-17T10:00:01Z [lifecycle] \(StackReport.stackLine(index: 2, of: 2, frames: []))
            2026-10-17T10:01:30Z [lifecycle] watchdog: loop silent 1.2 s · main D folio_wait_bit cpu=3
            2026-10-17T10:01:30Z [lifecycle] \(StackReport.stackLine(index: 1, of: 1, frames: ["tailscode+0x30"]))
            """
        let groups = StackReport.captures(in: log, last: 5)
        #expect(groups.count == 2)
        #expect(groups[0].count == 3)
        #expect(groups[0][2].hasSuffix("main: no reply"))
        #expect(groups[1].count == 2)
        #expect(StackReport.captures(in: log, last: 1) == [groups[1]])
        #expect(StackReport.captures(in: "stack 1/1 · main: x", last: 1).isEmpty)
    }

    @Test("Background work stretches as the governor sheds")
    func cadence() {
        #expect(ShedLevel.allCases.map(BackgroundCadence.factor) == [1, 1, 1, 3, 6])
        #expect(BackgroundCadence.period(120, level: .strained) == 360)
        #expect(BackgroundCadence.period(15, level: .critical) == 90)
        #expect(BackgroundCadence.period(15, level: .loaded) == 15)
    }

    @Test("A crash is a capture the reader groups with its stack")
    func crashCapture() {
        let log = """
            2026-10-17T20:21:42.000Z [lifecycle] launch 1.78
            2026-10-17T20:21:45.000Z [lifecycle] watchdog: crash signal 11 at 0x18 · build 1.78
            2026-10-17T20:21:45.000Z [lifecycle] watchdog: stack 1/1 · main: libgtk-4.so.1+0x1a4127 tailscode+0x6ecdae
            """
        let groups = StackReport.captures(in: log, last: 3)
        #expect(groups.count == 1)
        #expect(groups.first?.count == 2)
        #expect(groups.first?.first?.contains("crash signal 11") == true)
    }
}
