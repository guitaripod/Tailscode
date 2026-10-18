import Foundation
import TailscodeCore

/// The words only the account draws on this desk, beside Core's `NeuralAccount` and
/// `NeuralReading`: the header, the footer's key hints, the verbs of a note, and the nouns a work
/// line counts in.
extension BrainWords {
    static var theAccount: String { Localized.text("THE ACCOUNT") }
    static var whatItToldYou: String { Localized.text("WHAT IT TOLD YOU") }
    static var filtered: String { Localized.text("FILTERED") }
    static var following: String { Localized.text("following") }
    static var followingPausedShort: String { Localized.text("following paused") }
    static var show: String { Localized.text("Show") }
    static var hide: String { Localized.text("Hide") }
    static var justNow: String { Localized.text("just now") }
    static var saidVerb: String { Localized.text("said") }
    static var askVerb: String { Localized.text("ask") }
    static var itemsVerb: String { Localized.text("items") }
    static var detailVerb: String { Localized.text("detail") }
    static var answerLink: String { Localized.text("answer") }
    static var quoted: String { Localized.text("Quoted in the composer") }
    static var accountLabel: String { Localized.text("The agent's account of this turn") }
    static var nothingSaid: String { Localized.text("It said nothing in this turn.") }

    static func saidCount(_ count: Int) -> String {
        count == 1 ? Localized.text("1 said") : Localized.text("%lld said", count)
    }

    static func showStep(_ number: Int) -> String { Localized.text("Show step #%lld", number) }

    static func moreSteps(_ count: Int) -> String {
        count == 1 ? Localized.text("Show 1 more step") : Localized.text("Show %lld more steps", count)
    }

    static func replyingTo(_ speaker: String, clock: String?) -> String {
        guard let clock else { return Localized.text("Replying to %@", speaker) }
        return Localized.text("Replying to %1$@ · %2$@", speaker, clock)
    }

    /// "1 failed" and, when a later run cleared it, the words that say where.
    static func failedCount(_ count: Int) -> String {
        count == 1 ? Localized.text("1 failed") : Localized.text("%lld failed", count)
    }

    /// "1 error fixed" and "3 errors fixed", for a work line whose own words are not one sentence.
    static func fixedErrors(_ count: Int) -> String {
        count == 1 ? Localized.text("1 error fixed") : Localized.text("%lld errors fixed", count)
    }

    /// What is left of a work line's clauses when they do not all fit: "+2 more".
    static func moreClauses(_ count: Int) -> String {
        Localized.text("+%lld more", count)
    }

    /// "#7" for one step, "#3\u{2013}6" for a run.
    static func stepRange(_ numbers: [Int]) -> String {
        guard let first = numbers.first, let last = numbers.last else { return "" }
        return first == last ? "#\(first)" : "#\(first)\u{2013}\(last)"
    }
}
