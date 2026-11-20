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

    @Test func aDateBeyondTomorrowKeepsItsOwnFormatter() throws {
        var helsinki = Calendar(identifier: .gregorian)
        helsinki.timeZone = try #require(TimeZone(identifier: "Europe/Helsinki"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let later = now.addingTimeInterval(5 * 86_400)
        let moment = ScheduleWords.moment(later, calendar: helsinki, now: now)
        #expect(moment != ScheduleWords.timeText(later, calendar: helsinki))
        #expect(moment.contains(ScheduleWords.timeText(later, calendar: helsinki).prefix(2)))
        #expect(ScheduleWords.moment(later, calendar: helsinki, now: now) == moment)
    }
}
