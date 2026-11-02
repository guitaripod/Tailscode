import Foundation
import Testing

@testable import TailscodeCore

@Suite("Quick ask later", .serialized)
struct QuickAskLaterTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Helsinki")!
        return calendar
    }

    private func date(_ text: String) -> Date {
        let format = ISO8601DateFormatter()
        format.timeZone = TimeZone(identifier: "Europe/Helsinki")!
        format.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        return format.date(from: text)!
    }

    private func withFile(_ body: () throws -> Void) rethrows {
        let previous = QuickAskLaterStore.fileURL
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("later-\(UUID().uuidString)")
        QuickAskLaterStore.fileURL = folder.appendingPathComponent("quick-later.json")
        defer {
            try? FileManager.default.removeItem(at: folder)
            QuickAskLaterStore.fileURL = previous
        }
        try body()
    }

    @Test("Each choice lands on the hour it names, never in the past")
    func choices() {
        let morning = date("2026-11-02T07:30:00")
        let evening = date("2026-11-02T22:10:00")
        #expect(QuickAskLaterChoice.inAnHour.fireDate(now: morning, calendar: calendar) == date("2026-11-02T08:30:00"))
        #expect(QuickAskLaterChoice.tonight.fireDate(now: morning, calendar: calendar) == date("2026-11-02T21:00:00"))
        #expect(QuickAskLaterChoice.tonight.fireDate(now: evening, calendar: calendar) == date("2026-11-03T21:00:00"))
        #expect(QuickAskLaterChoice.tomorrowMorning.fireDate(now: evening, calendar: calendar) == date("2026-11-03T08:00:00"))
        #expect(QuickAskLaterChoice.everyMorning.fireDate(now: morning, calendar: calendar) == date("2026-11-02T08:00:00"))
        #expect(QuickAskLaterChoice.everyWeek.fireDate(now: evening, calendar: calendar) == date("2026-11-03T08:00:00"))
        #expect(QuickAskLaterChoice.everyWeek.repeats == .weekly)
        #expect(QuickAskLaterChoice.tonight.repeats == .once)
    }

    @Test("A repeat that slept through several hours asks once and moves past now")
    func repeatsStepPastNow() {
        let later = QuickAskLater(
            text: "iPad mini rumours", profileID: "p", fireAt: date("2026-10-28T08:00:00"), repeats: .daily)
        let now = date("2026-11-02T13:00:00")
        #expect(later.next(after: now, now: now, calendar: calendar) == date("2026-11-03T08:00:00"))
        let weekly = QuickAskLater(text: "prices", profileID: "p", fireAt: date("2026-11-02T08:00:00"), repeats: .weekly)
        #expect(weekly.next(after: date("2026-11-02T08:00:05"), now: date("2026-11-02T08:00:05"), calendar: calendar) == date("2026-11-09T08:00:00"))
        let once = QuickAskLater(text: "once", profileID: "p", fireAt: now)
        #expect(once.next(after: now, now: now, calendar: calendar) == nil)
    }

    @Test("What is due is asked; a single question leaves and a repeat moves on")
    func storeLifecycle() {
        withFile {
            let now = date("2026-11-02T09:00:00")
            let single = QuickAskLater(text: "Start the benchmark", profileID: "p", fireAt: date("2026-11-02T03:00:00"))
            let daily = QuickAskLater(text: "Rumours\nmore", profileID: "p", fireAt: date("2026-11-02T08:00:00"), repeats: .daily)
            let future = QuickAskLater(text: "Later still", profileID: "p", fireAt: date("2026-11-05T08:00:00"))
            for item in [future, daily, single] { QuickAskLaterStore.save(item) }
            #expect(QuickAskLaterStore.all().map(\.id) == [single.id, daily.id, future.id])
            #expect(QuickAskLaterStore.due(now: now).map(\.id) == [single.id, daily.id])
            for item in QuickAskLaterStore.due(now: now) { QuickAskLaterStore.asked(item, at: now, calendar: calendar) }
            #expect(QuickAskLaterStore.due(now: now).isEmpty)
            #expect(QuickAskLaterStore.all().map(\.id) == [daily.id, future.id])
            #expect(QuickAskLaterStore.all().first?.fireAt == date("2026-11-03T08:00:00"))
            #expect(QuickAskLaterStore.all().first?.lastAsked == now)
            #expect(daily.headline == "Rumours")
            QuickAskLaterStore.remove(id: future.id)
            #expect(QuickAskLaterStore.all().count == 1)
            let held = QuickAskLaterStore.all()[0]
            QuickAskLaterStore.postpone(held, by: 600, now: now)
            #expect(QuickAskLaterStore.all()[0].fireAt == held.fireAt)
            #expect(QuickAskLaterStore.due(now: now.addingTimeInterval(601)).count == 1)
            QuickAskLaterStore.askNow(id: held.id, now: now)
            #expect(QuickAskLaterStore.all().count == 2)
            #expect(QuickAskLaterStore.all().first { $0.id == held.id }?.fireAt == held.fireAt)
            #expect(QuickAskLaterStore.due(now: now).map(\.repeats) == [.once])
        }
    }
}
