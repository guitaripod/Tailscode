#if DEBUG
import Foundation
import MidgarCore

/// What the conversations this phone is following cost its main thread while their turns stream.
/// Every state a view model takes off its stream is priced in the main thread's own CPU time, apart
/// for the chat on screen and the ones followed for a card or a pill, and each report says how much
/// of the main thread they took beside everything else it did in the same stretch.
///
/// `TAILSCODE_LIVE_PROBE=<seconds>` reports at that pace to the `performance` log as
/// `LIVE_LOAD` lines.
@MainActor
enum LiveLoadProbe {
    private struct Tally {
        var states = 0
        var spent: TimeInterval = 0
        var worst: TimeInterval = 0
        var sessions: Set<String> = []

        mutating func note(_ cost: TimeInterval, session: String) {
            states += 1
            spent += cost
            worst = max(worst, cost)
            sessions.insert(session)
        }

        var summary: String {
            "\(sessions.count) chat(s) \(states) state(s) \(LiveLoadProbe.ms(spent)) ms worst \(LiveLoadProbe.ms(worst)) ms"
        }
    }

    private static var interval: TimeInterval? = ProcessInfo.processInfo.environment["TAILSCODE_LIVE_PROBE"]
        .flatMap(TimeInterval.init).flatMap { $0 > 0 ? $0 : nil }
    private static var bound = Tally()
    private static var away = Tally()
    private static var reporter: Task<Void, Never>?
    private static var mainAt: TimeInterval = 0
    private static var wallAt: TimeInterval = 0

    static var isOn: Bool { interval != nil }

    static func begin() -> TimeInterval {
        guard interval != nil else { return 0 }
        startIfNeeded()
        return BoardBench.cpuTime()
    }

    static func end(_ began: TimeInterval, session: String, bound onScreen: Bool) {
        guard interval != nil else { return }
        let cost = BoardBench.cpuTime() - began
        if onScreen { bound.note(cost, session: session) } else { away.note(cost, session: session) }
    }

    private static func startIfNeeded() {
        guard reporter == nil, let interval else { return }
        mainAt = BoardBench.cpuTime()
        wallAt = Date().timeIntervalSinceReferenceDate
        reporter = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                report()
            }
        }
    }

    private static func report() {
        let main = BoardBench.cpuTime()
        let wall = Date().timeIntervalSinceReferenceDate
        let share = wall > wallAt ? (main - mainAt) / (wall - wallAt) : 0
        MidgarLog.notice(
            "LIVE_LOAD main \(Int((share * 100).rounded()))% (\(ms(main - mainAt)) ms) | on screen \(bound.summary) | followed \(away.summary)",
            category: .performance)
        mainAt = main
        wallAt = wall
        bound = Tally()
        away = Tally()
    }

    nonisolated fileprivate static func ms(_ time: TimeInterval) -> Int { Int((time * 1000).rounded()) }
}
#endif
