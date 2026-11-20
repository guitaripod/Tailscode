import Foundation
import Testing

@testable import TailscodeCore

@Suite struct ScheduleTimeTextTests {
    @Test func keptFormattersKeepEachZoneApart() throws {
        var helsinki = Calendar(identifier: .gregorian)
        helsinki.timeZone = try #require(TimeZone(identifier: "Europe/Helsinki"))
        var tokyo = helsinki
        tokyo.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let first = ScheduleWords.timeText(date, calendar: helsinki)
        #expect(ScheduleWords.timeText(date, calendar: tokyo) != first)
        #expect(ScheduleWords.timeText(date, calendar: helsinki) == first)
    }
}
