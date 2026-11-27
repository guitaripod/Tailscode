import Testing

@testable import TailscodeCore

@Suite("Running clocks")
struct RunningClockTests {
    @Test("A span past the hour reads in hours, never in hundreds of minutes")
    func clock() {
        #expect(StatusFacts.clock(42) == "42s")
        #expect(StatusFacts.clock(252) == "4m 12s")
        #expect(StatusFacts.clock(7_392) == "2h 03m")
        #expect(StatusFacts.clock(-5) == "0s")
    }

    @Test("A stopwatch face grows an hour column instead of a three-digit minute")
    func stopwatch() {
        #expect(StatusFacts.stopwatch(81) == "1:21")
        #expect(StatusFacts.stopwatch(3_599) == "59:59")
        #expect(StatusFacts.stopwatch(7_392) == "2:03:12")
    }
}
