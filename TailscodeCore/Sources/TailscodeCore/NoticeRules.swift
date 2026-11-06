import CodingAgentKit
import Foundation

/// What a person wants to be told about, one set of choices every client and every bridge reads.
///
/// A turn is not a piece of work. Claude Code answers, hands the prompt back and keeps a command,
/// an agent or a workflow running; when that ends it speaks again on its own, and the turn after
/// that may queue another. A notice per turn is a notice per step of somebody else's plan, so the
/// default is a notice when the work is over (`WorkSettle`), and the rest are honest variations a
/// person picks: every turn, failures only, or nothing — never fewer than the questions and
/// approvals that are waiting on them, unless they say so too.
public struct NoticeRules: Sendable, Equatable, Codable {
    public enum Finish: String, Sendable, CaseIterable, Codable {
        /// Once the agent and everything it started have stopped, and stayed stopped for
        /// `WorkSettle.grace`.
        case settled
        /// Whenever a turn ends, whatever it left running — what every client did before.
        case everyTurn
        /// Only work that ended in a failure.
        case failures
        case never
    }

    public var finish: Finish
    /// Work shorter than this ends without a notice: an answer that came back while the person was
    /// still switching apps was never news. A failure is news at any length.
    public var minimumWork: TimeInterval
    /// Approvals and questions. They are the one thing an agent cannot get past alone, so they are
    /// their own switch and a muted chat still raises them.
    public var needsYou: Bool
    /// Chats whose finished work says nothing, by session id. Session ids are the server's own and
    /// are unique across machines, which is what lets a bridge read the same list.
    public var muted: Set<String>

    public init(
        finish: Finish = .settled, minimumWork: TimeInterval = 0, needsYou: Bool = true,
        muted: Set<String> = []
    ) {
        self.finish = finish
        self.minimumWork = minimumWork
        self.needsYou = needsYou
        self.muted = muted
    }

    public static let standard = NoticeRules()

    /// The lengths a person chooses from; anything finer is noise nobody would tune.
    public static let minimumChoices: [TimeInterval] = [0, 30, 120, 600]

    /// Whether finished work earns a notice: what the person chose, how long it ran, and whether
    /// the chat is muted. A failure ignores the minimum, because a fast failure is still the end
    /// of what somebody walked away from.
    public func admits(failed: Bool, length: TimeInterval, sessionID: String) -> Bool {
        guard !muted.contains(sessionID) else { return false }
        switch finish {
        case .never: return false
        case .failures: return failed
        case .settled, .everyTurn: return failed || length >= minimumWork
        }
    }

    /// Whether an approval or a question earns a notice.
    public func admitsAsk(sessionID: String) -> Bool { needsYou }

    public func isMuted(_ sessionID: String) -> Bool { muted.contains(sessionID) }

    /// The same choices with one chat's mute flipped.
    public func togglingMute(_ sessionID: String) -> NoticeRules {
        var next = self
        if next.muted.remove(sessionID) == nil { next.muted.insert(sessionID) }
        return next
    }

    /// What a bridge is told when this device registers for pushes, so the server holding the
    /// work decides the same way the device would have. Only the chats that server holds are named.
    public func wire(sessionIDs: Set<String>? = nil) -> DevicePushRules {
        let named = sessionIDs.map { muted.intersection($0) } ?? muted
        return DevicePushRules(
            finish: finish.rawValue, minimumWork: Int(minimumWork.rounded()), needsYou: needsYou,
            muted: named.sorted())
    }
}

/// Where the choices live. Every client reads and writes the same keys through its own store —
/// `UserDefaults` on the Apple desks, the settings file on Linux — so the words, the defaults and
/// the migration from the old on/off switch are decided once.
public enum NoticeRulesKeys {
    public static let finish = "tailscode.notify.finish"
    public static let minimumWork = "tailscode.notify.minimumWork"
    public static let muted = "tailscode.notify.muted"
    /// The switches the rules grew out of, still read: a person who turned finished turns off
    /// before the rules existed keeps them off, and the approvals switch is the needs-you switch.
    public static let legacyTurnComplete = "pref.notify.turnComplete"
    public static let needsYou = "pref.notify.approvals"

    public static let didChange = Notification.Name("tailscode.notify.rules.didChange")

    public static func read(_ value: (String) -> Any?) -> NoticeRules {
        let finish =
            (value(finish) as? String).flatMap(NoticeRules.Finish.init(rawValue:))
            ?? ((value(legacyTurnComplete) as? Bool) == false ? .never : .settled)
        let minimum = (value(minimumWork) as? NSNumber)?.doubleValue ?? 0
        return NoticeRules(
            finish: finish, minimumWork: max(0, minimum),
            needsYou: value(needsYou) as? Bool ?? true,
            muted: Set(value(muted) as? [String] ?? []))
    }

    /// Writes every key, the legacy switch included, so a build from before the rules that reads
    /// this store still says nothing when the person chose nothing.
    public static func write(_ rules: NoticeRules, _ store: (String, Any?) -> Void) {
        store(finish, rules.finish.rawValue)
        store(minimumWork, Int(rules.minimumWork.rounded()))
        store(needsYou, rules.needsYou)
        store(legacyTurnComplete, rules.finish != .never)
        store(muted, rules.muted.isEmpty ? nil : rules.muted.sorted())
    }
}

/// Every word the rules are offered in, so the three settings pages read the same.
public enum NoticeRulesWords {
    public static var finishTitle: String { Localized.text("Finished work") }
    public static var finishSubtitle: String {
        Localized.text("When to tap your shoulder once the agent stops")
    }
    public static var minimumTitle: String { Localized.text("Only for work longer than") }
    public static var minimumSubtitle: String {
        Localized.text("Quick answers end quietly. A failure always says so.")
    }
    public static var needsYouTitle: String { Localized.text("Approvals and questions") }
    public static var needsYouSubtitle: String {
        Localized.text("When an agent is waiting on you, even in a muted chat")
    }

    public static func title(_ finish: NoticeRules.Finish) -> String {
        switch finish {
        case .settled: return Localized.text("When it’s done")
        case .everyTurn: return Localized.text("Every turn")
        case .failures: return Localized.text("Only failures")
        case .never: return Localized.text("Never")
        }
    }

    public static func detail(_ finish: NoticeRules.Finish) -> String {
        switch finish {
        case .settled:
            return Localized.text(
                "Once the agent and everything it started in the background have stopped.")
        case .everyTurn:
            return Localized.text("Each time a turn ends, even with work still running.")
        case .failures: return Localized.text("Only when work ends in a failure.")
        case .never: return Localized.text("Finished work ends quietly.")
        }
    }

    public static func minimum(_ seconds: TimeInterval) -> String {
        switch Int(seconds.rounded()) {
        case ..<1: return Localized.text("Any length")
        case 30: return Localized.text("30 seconds")
        case 120: return Localized.text("2 minutes")
        case 600: return Localized.text("10 minutes")
        case let other where other % 60 == 0: return Localized.text("%d min", other / 60)
        case let other: return Localized.text("%d s", other)
        }
    }

    public static var groupDescription: String {
        Localized.text(
            "Only while the app is not in front. When it’s done waits until the agent and everything it started have stopped: one piece of work, one notification.")
    }

    public static var mute: String { Localized.text("Mute Notifications") }
    public static var unmute: String { Localized.text("Unmute Notifications") }
    public static var mutedTitle: String { Localized.text("Muted chats") }
    public static var unmuteAll: String { Localized.text("Unmute All") }

    public static func mutedCount(_ count: Int) -> String {
        count == 1
            ? Localized.text("One chat ends its work quietly")
            : Localized.text("%d chats end their work quietly", count)
    }

    public static func muteTitle(muted: Bool) -> String { muted ? unmute : mute }

    public static func muteDetail(muted: Bool) -> String {
        muted
            ? Localized.text("Finished work here notifies you again")
            : Localized.text("Finished work here ends quietly. Approvals and questions still reach you")
    }
}
