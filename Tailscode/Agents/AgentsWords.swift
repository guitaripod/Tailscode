import Foundation
import TailscodeCore

/// The few words and figures the board, its peek and its hour share, said one way so a row and its
/// peek never give the same time two readings.
enum AgentsWords {
    private static let spoken: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.maximumUnitCount = 1
        return formatter
    }()

    static func elapsed(since start: Date?, now: Date) -> String {
        guard let start else { return "" }
        return StatusFacts.age(now.timeIntervalSince(start))
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        return seconds < 3 ? String(localized: "now") : StatusFacts.age(seconds)
    }

    static func spokenAge(_ date: Date, now: Date) -> String {
        spokenDuration(now.timeIntervalSince(date))
    }

    static func spokenDuration(_ seconds: TimeInterval) -> String {
        spoken.string(from: max(1, seconds.rounded())) ?? StatusFacts.age(seconds)
    }

    static func waiting(since date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        return String(localized: "waiting \(StatusFacts.age(now.timeIntervalSince(date)))")
    }

    static func lastSeen(_ date: Date?, now: Date) -> String {
        guard let date else { return String(localized: "Not answering") }
        return String(
            localized: "Not answering · last seen \(StatusFacts.age(now.timeIntervalSince(date))) ago")
    }

    static func agents(_ count: Int) -> String {
        count == 1 ? String(localized: "1 agent") : String(localized: "\(count) agents")
    }

    static func beatSpoken(_ beat: [Int]) -> String {
        let active = beat.filter { $0 > 0 }.count
        guard active > 0 else { return String(localized: "No activity in the last minute") }
        return String(localized: "Active in \(active) of \(beat.count) moments of the last minute")
    }

    static func todosSpoken(_ todos: (done: Int, total: Int)) -> String {
        String(localized: "\(todos.done) of \(todos.total) steps done")
    }

    static func cost(_ amount: Double) -> String {
        String(localized: "≈ \(amount.formatted(.currency(code: "USD")))")
    }

    static func tokens(_ count: Int) -> String { StatusFacts.tokens(count) }
}
