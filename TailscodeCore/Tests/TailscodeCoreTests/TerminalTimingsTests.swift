import Foundation
import Testing

@testable import TailscodeCore

@Suite struct TerminalTimingsTests {
    @Test func openAndEchoAreMeasuredFromTheFirstKeyToTheNextBytes() {
        var timings = TerminalTimings()
        let start = Date(timeIntervalSince1970: 1000)
        timings.asked(at: start)
        timings.bytesArrived(at: start.addingTimeInterval(0.120))
        #expect(timings.openMilliseconds == 120)
        timings.keyLeft(at: start.addingTimeInterval(1))
        timings.keyLeft(at: start.addingTimeInterval(1.05))
        timings.bytesArrived(at: start.addingTimeInterval(1.3))
        timings.bytesArrived(at: start.addingTimeInterval(1.4))
        #expect(timings.echoMilliseconds == [300])
        #expect(timings.line == "open=120 echo n=1 p50=300 p90=300 max=300")
    }

    @Test func noKeysSaysSo() {
        #expect(TerminalTimings().line == "open=- echo n=0")
    }
}
