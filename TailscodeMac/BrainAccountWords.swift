import Foundation
import TailscodeCore

/// The words only the account and its detail say on this desk, beside Core's `NeuralAccount` and
/// `NeuralReading`. The keys are the ones the Linux desk already translates, so a sentence is
/// spelled once.
enum AccountWords {
    static var whatItToldYou: String { Localized.text("WHAT IT TOLD YOU") }
    static var filtered: String { Localized.text("FILTERED") }
    static var show: String { Localized.text("Show") }
    static var hide: String { Localized.text("Hide") }
    static var justNow: String { Localized.text("just now") }
    static var saidVerb: String { Localized.text("said") }
    static var askVerb: String { Localized.text("ask") }
    static var itemsVerb: String { Localized.text("items") }
    static var detailVerb: String { Localized.text("detail") }
    static var accountLabel: String { Localized.text("The agent's account of this turn") }
    static var asked: String { Localized.text("ASKED") }
    static var plan: String { Localized.text("PLAN") }
    static var result: String { Localized.text("RESULT") }
    static var checks: String { Localized.text("CHECKS") }
    static var stillFailing: String { Localized.text("STILL FAILING") }
    static var needsYou: String { Localized.text("NEEDS YOU") }
    static var turn: String { Localized.text("TURN") }
    static var settled: String { Localized.text("Settled") }
    static var relations: String { Localized.text("RELATIONS") }
    static var output: String { Localized.text("OUTPUT") }
    static var diff: String { Localized.text("DIFF") }
    static var matches: String { Localized.text("MATCHES") }
    static var readLabel: String { Localized.text("READ") }
    static var whereTheWorkWent: String { Localized.text("WHERE THE WORK WENT") }
    static var failures: String { Localized.text("FAILURES") }
    static var changed: String { Localized.text("CHANGED") }
    static var answer: String { Localized.text("ANSWER") }
    static var soFar: String { Localized.text("SO FAR") }
    static var earlier: String { Localized.text("EARLIER") }
    static var copied: String { Localized.text("Copied") }
    static var hoverHint: String { Localized.text("hover a step to read it") }
    static var zoneHint: String { Localized.text("click a row to pin it on the stage") }
    static var surfaceHint: String { Localized.text("esc surfaces") }
    static var pinned: String { Localized.text("pinned") }
    static var followingPaused: String { Localized.text("Following paused · jump to latest") }
    static var search: String { Localized.text("Search") }
    static var failedWord: String { Localized.text("FAILED") }
    static var replaying: String { Localized.text("REPLAY") }

    static func steps(_ count: Int) -> String {
        count == 1 ? Localized.text("1 step") : Localized.text("%lld steps", count)
    }

    static func lines(_ count: Int) -> String {
        count == 1 ? Localized.text("1 line") : Localized.text("%lld lines", count)
    }

    static func lastLines(_ count: Int) -> String { Localized.text("live · last %lld lines", count) }

    static func zoneSteps(_ label: String) -> String { Localized.text("%@ · steps in order", label) }

    static func stepsOf(_ count: Int, _ total: Int) -> String {
        Localized.text("%1$lld of %2$lld steps", count, total)
    }

    static func waitingSince(_ clock: String) -> String {
        Localized.text("waiting since %@ · the approval itself is in the transcript", clock)
    }

    static func asked(_ clock: String) -> String { Localized.text("asked %@", clock) }

    static func earlier(_ count: Int) -> String { Localized.text("%lld earlier steps not shown", count) }

    static func moreFailures(_ count: Int) -> String { Localized.text("%lld more failures", count) }
    static func moreFiles(_ count: Int) -> String { Localized.text("%lld more files", count) }

    static func showStep(_ number: Int) -> String { Localized.text("Show step #%lld", number) }

    static func moreSteps(_ count: Int) -> String {
        count == 1 ? Localized.text("Show 1 more step") : Localized.text("Show %lld more steps", count)
    }

    static func failedCount(_ count: Int) -> String {
        count == 1 ? Localized.text("1 failed") : Localized.text("%lld failed", count)
    }

    static func fixedErrors(_ count: Int) -> String {
        count == 1 ? Localized.text("1 error fixed") : Localized.text("%lld errors fixed", count)
    }

    static func moreClauses(_ count: Int) -> String { Localized.text("+%lld more", count) }

    static func stepRange(_ numbers: [Int]) -> String {
        guard let first = numbers.first, let last = numbers.last else { return "" }
        return first == last ? "#\(first)" : "#\(first)\u{2013}\(last)"
    }

    static func timeline(_ count: Int) -> String { Localized.text("Timeline of %lld steps", count) }
}
