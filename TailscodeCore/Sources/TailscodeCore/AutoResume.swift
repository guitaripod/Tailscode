import CodingAgentKit
import Foundation

/// What a wall stopped, and therefore what sending it again would mean.
///
/// The two are not the same act and must never be confused: one message is still on this device
/// and has demonstrably never reached a server, and the other reached a server, was written into
/// the transcript, and bought nothing. Sending the first again is finishing what was asked for.
/// Sending the second again is asking a second time, which is only honest where the turn produced
/// nothing at all — a turn that wrote half an answer before the window closed is continued by a
/// person who has read the half, not by a clock.
public enum ResumeTrigger: String, Sendable, Hashable, Codable {
    /// The send never left. The words are in this device's own ledger and nothing in the
    /// transcript stands in for them.
    case refused
    /// The prompt landed, the turn ran into the wall, and the turn produced nothing — no answer,
    /// no tool call, nothing to continue from. The words come from the transcript, so the resume
    /// works on a conversation opened from another machine.
    case answerless
}

/// A message that did not get answered because a provider window was spent, and the moment it
/// goes again.
///
/// The moment is the provider's, never ours. Every field here exists so the plan can be rendered
/// without asking anything else a question, and so a client that was closed when the window opened
/// can pick the plan up off disk and still know what it is waiting for and why.
public struct ResumePlan: Sendable, Hashable, Codable, Identifiable {
    /// The row this plan belongs to — the pending send that failed, or the conversation itself
    /// where the wall killed a turn that had already been handed over.
    public let id: UUID
    public let profileID: String
    public let sessionID: String
    public let provider: String
    public let window: String
    /// When the provider says the window opens, plus the grace this policy adds to it.
    public let resumesAt: Date
    /// Whether the provider stated the reset or we read it out of its prose. An untrusted clock is
    /// still a clock — it is simply spoken about with "about".
    public let trustedReset: Bool
    public let trigger: ResumeTrigger
    /// How many times this plan has already fired and found the wall still up. Zero is the first
    /// wait, which is the only one that runs on the provider's own stated clock; every later one
    /// runs on the backoff, because a provider that named a time and then refused at it has
    /// stopped being a source of times.
    public let attempt: Int
    public let plannedAt: Date

    public init(
        id: UUID, profileID: String, sessionID: String, provider: String, window: String,
        resumesAt: Date, trustedReset: Bool, trigger: ResumeTrigger, attempt: Int = 0,
        plannedAt: Date
    ) {
        self.id = id
        self.profileID = profileID
        self.sessionID = sessionID
        self.provider = provider
        self.window = window
        self.resumesAt = resumesAt
        self.trustedReset = trustedReset
        self.trigger = trigger
        self.attempt = attempt
        self.plannedAt = plannedAt
    }

    /// How long is left, floored at zero — a plan whose moment has passed is due, never overdue.
    public func remaining(at now: Date = Date()) -> TimeInterval {
        max(0, resumesAt.timeIntervalSince(now))
    }

    public func isDue(at now: Date = Date()) -> Bool { now >= resumesAt }

    /// Whether this plan is still worth holding. A plan is abandoned rather than kept forever:
    /// a window that was going to open hours ago and a device that has been closed for a week are
    /// the same evidence, and re-sending a message somebody wrote last Tuesday because a laptop
    /// finally woke up is the one behaviour that would make this feature untrustworthy.
    public func isStale(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(resumesAt) > AutoResume.staleAfter
    }
}

/// What the policy decided to do about a wall.
public enum ResumeVerdict: Sendable, Hashable {
    /// It will go again, at this moment, because of this wall.
    case resume(ResumePlan)
    /// It will not go again, and this is the reason — which is a sentence somebody reads, not a
    /// silence they have to interpret.
    case cannot(ResumeObstacle)
    /// Nothing here is a wall. The failure keeps its own sentence and this policy says nothing at
    /// all, because a countdown printed over a refused connection sends somebody to wait three
    /// hours for a window that was never in their way.
    case notAWall
}

/// Why a wall will not be waited out. Every case is a fact about the world rather than a policy
/// preference, except the first, which is the person's own decision and says so.
public enum ResumeObstacle: Sendable, Hashable, Codable {
    /// The setting is off. Named rather than silent: a person who turned it off last month and a
    /// person who never knew it existed read the same screen.
    case turnedOff
    /// The wall states no reset. A prepaid balance is the honest example — it does not open on a
    /// clock, it opens when somebody pays — and inventing a time for it would be the one lie this
    /// surface can tell.
    case noReset
    /// The turn had already written something before the window closed, so what it needs is a
    /// person who has read the half-answer, not the same question asked again.
    case turnHadStarted
    /// The window opened, the message went, and the wall was still there — as many times as this
    /// policy is willing to find that out.
    case attemptsSpent(Int)
    /// The reset is further out than this policy will wait without being asked again.
    case tooFarOut(Date)
}

/// When a message that a spent window stopped goes again.
///
/// The whole of this is arithmetic on a time the provider stated. Nothing here guesses, nothing
/// polls hopefully, and nothing retries a failure that was not a wall: a resume is deterministic
/// or it is not offered, because the alternative — a client that quietly re-sends prompts on a
/// timer it made up — is a client nobody should leave a conversation with.
///
/// Three rules do most of the work.
///
/// **The clock is the provider's.** The fire moment is the reset the provider named plus
/// ``grace``, and the grace exists because a wall's clock and this device's clock are not the same
/// clock and a send one second early is a wasted attempt.
///
/// **The wall is checked before the message goes, never assumed gone.** ``recheck(_:quotas:...)``
/// re-reads the gauges at the fire moment: a wall that has actually lifted is sent through, a wall
/// still standing with a *newer* reset re-plans onto that reset, and a wall still standing with
/// nothing new to say falls onto ``backoff(attempt:)`` — which is bounded, because a provider that
/// named a time and then refused at it has stopped being a source of times.
///
/// **Only what was never answered is re-sent.** A send this device is still holding, or a turn
/// that reached the server and produced nothing at all. A turn that had begun writing is not
/// resumed by a clock at any attempt count.
public enum AutoResume {
    /// Added to every provider-stated reset. Small enough that nobody notices it and large enough
    /// to cover the clock skew between a phone and a datacentre, plus the rounding a provider does
    /// when it says a window opens "at 3pm".
    public static let grace: TimeInterval = 45

    /// How many times the message may go before this policy stops trying. Deliberately small: each
    /// attempt is a real request against a wall that has already refused once, and a person who
    /// comes back to five failures has been told nothing they could not have been told after two.
    public static let maxAttempts = 4

    /// A reset further out than this is not waited on without being asked. A weekly window can be
    /// days away, and holding a message somebody wrote on Monday to send it on Friday is not a
    /// convenience — it is a conversation nobody remembers starting.
    public static let horizon: TimeInterval = 26 * 60 * 60

    /// How long past its own moment a plan stays worth acting on. Past this the machine was asleep
    /// or the app was closed for so long that the message is stale, and it is left as a failed row
    /// with its words intact rather than sent into a conversation that has moved on.
    public static let staleAfter: TimeInterval = 45 * 60

    /// The wait after an attempt that found the wall still up and learned nothing new about when
    /// it lifts. Grows, because the one thing a provider that lied about its reset has proved is
    /// that asking it sooner is not information.
    public static func backoff(attempt: Int) -> TimeInterval {
        switch max(0, attempt) {
        case 0: return 60
        case 1: return 5 * 60
        case 2: return 15 * 60
        default: return 30 * 60
        }
    }

    /// Whether a turn that ran into a wall is one a clock may ask again.
    ///
    /// The answer is the turn's own output. A turn that produced nothing is a question the
    /// provider never took, and asking it again is finishing the send. A turn that produced
    /// anything at all — a paragraph, a tool call, a picture — is half of an answer, and half an
    /// answer is a thing a person reads before deciding what the next message should be.
    public static func mayAskAgain(_ turn: ChatMessage?) -> Bool {
        guard let turn else { return false }
        return turn.isAnswerless
    }

    /// The decision, from the same three things every client already has: what failed, what the
    /// gauges say, and what this conversation is sending with.
    ///
    /// - Parameters:
    ///   - failure: the server's own words for what went wrong, or nil when nothing failed and
    ///     this is being asked pre-emptively — in which case the standing gauges decide.
    ///   - enabled: the person's own setting. Answered as an obstacle rather than as `notAWall`,
    ///     so a client can still say why nothing is being waited for.
    ///   - attempt: how many times this conversation has already been sent into this wall and
    ///     bounced. It is the caller's to carry, because a plan that fires and dies produces a
    ///     *fresh* failure, and a policy that read each fresh failure as a first attempt would
    ///     wait, send, fail and wait again for as long as the wall stood — which is the one way a
    ///     bounded retry turns into an unbounded one.
    public static func decide(
        row: UUID, profileID: String, sessionID: String, trigger: ResumeTrigger,
        failure: String?, quotas: [UsageQuota], model: String? = nil, named name: String? = nil,
        selection: ModelSelection? = nil, enabled: Bool = true, attempt: Int = 0,
        now: Date = Date()
    ) -> ResumeVerdict {
        guard
            let wall = QuotaSurface.resolve(
                failureMessage: failure, quotas: quotas, model: model, named: name,
                selection: selection, now: now)
        else { return .notAWall }
        return decide(
            row: row, profileID: profileID, sessionID: sessionID, trigger: trigger, wall: wall,
            enabled: enabled, attempt: attempt, now: now)
    }

    /// The same decision where the wall has already been read — which is the shape a client in the
    /// middle of drawing a banner is already holding.
    public static func decide(
        row: UUID, profileID: String, sessionID: String, trigger: ResumeTrigger,
        wall: QuotaExhaustion, enabled: Bool = true, attempt: Int = 0, now: Date = Date()
    ) -> ResumeVerdict {
        guard enabled else { return .cannot(.turnedOff) }
        guard attempt < maxAttempts else { return .cannot(.attemptsSpent(maxAttempts)) }
        guard let reset = wall.resetsAt else { return .cannot(.noReset) }
        let fires = max(reset, now).addingTimeInterval(grace)
        guard fires.timeIntervalSince(now) <= horizon else { return .cannot(.tooFarOut(reset)) }
        return .resume(
            ResumePlan(
                id: row, profileID: profileID, sessionID: sessionID, provider: wall.provider,
                window: wall.window, resumesAt: fires, trustedReset: wall.trustedReset,
                trigger: trigger, attempt: attempt, plannedAt: now))
    }

    /// What a plan whose moment has arrived should actually do, decided against the gauges as they
    /// read now rather than against the reading that planned it.
    ///
    /// This is the whole determinism claim. A plan is a bet that a window opens at a stated time;
    /// this is where the bet is settled by looking, and a wall that turns out to still be standing
    /// re-plans onto whatever the provider now says instead of sending into it.
    public static func recheck(
        _ plan: ResumePlan, quotas: [UsageQuota], model: String? = nil, named name: String? = nil,
        selection: ModelSelection? = nil, enabled: Bool = true, now: Date = Date()
    ) -> ResumeCheck {
        guard enabled else { return .cancel(.turnedOff) }
        guard !plan.isStale(at: now) else { return .cancel(.tooFarOut(plan.resumesAt)) }
        let billed = QuotaSurface.billingQuotas(
            in: quotas, selection: selection, model: model, named: name)
        guard
            let wall = QuotaSurface.hottestExhausted(
                in: billed, model: model, named: name, now: now)
        else { return .send }
        let next = plan.attempt + 1
        guard next < maxAttempts else { return .cancel(.attemptsSpent(maxAttempts)) }
        let stated = wall.resetsAt.map { max($0, now).addingTimeInterval(grace) }
        let fires =
            stated.map { $0 > plan.resumesAt ? $0 : now.addingTimeInterval(backoff(attempt: next)) }
            ?? now.addingTimeInterval(backoff(attempt: next))
        guard fires.timeIntervalSince(now) <= horizon else { return .cancel(.tooFarOut(fires)) }
        return .wait(
            ResumePlan(
                id: plan.id, profileID: plan.profileID, sessionID: plan.sessionID,
                provider: wall.provider, window: wall.window, resumesAt: fires,
                trustedReset: wall.trustedReset, trigger: plan.trigger, attempt: next,
                plannedAt: now))
    }
}

/// What to do with a plan whose moment has come.
public enum ResumeCheck: Sendable, Hashable {
    /// The window is open. Send the words.
    case send
    /// It is not. Wait again, on this plan.
    case wait(ResumePlan)
    /// Stop waiting, and say this.
    case cancel(ResumeObstacle)
}

/// Every plan a client is holding, keyed by the row it belongs to.
///
/// A value, like every other ledger in this app: a pane owns one, each change to it is a change a
/// client renders from, and nothing in here talks to a server or owns a timer. What fires the
/// plans is the client's own clock, because the client is the process that is awake.
public struct ResumeLedger: Sendable, Hashable, Codable {
    public private(set) var plans: [UUID: ResumePlan] = [:]

    public init(plans: [UUID: ResumePlan] = [:]) {
        self.plans = plans
    }

    public var isEmpty: Bool { plans.isEmpty }
    public var count: Int { plans.count }

    public func plan(for row: UUID) -> ResumePlan? { plans[row] }

    public mutating func hold(_ plan: ResumePlan) {
        plans[plan.id] = plan
    }

    @discardableResult
    public mutating func drop(_ row: UUID) -> ResumePlan? {
        plans.removeValue(forKey: row)
    }

    public mutating func removeAll() {
        plans.removeAll()
    }

    /// The plans whose moment has come, oldest first so a conversation that queued two of them
    /// sends them in the order they were written.
    public func due(at now: Date = Date()) -> [ResumePlan] {
        plans.values.filter { $0.isDue(at: now) && !$0.isStale(at: now) }
            .sorted { $0.plannedAt < $1.plannedAt }
    }

    /// Plans that were going to fire while nobody was watching. Reported rather than fired: their
    /// words are still on the row, and a person coming back to a closed laptop is told the window
    /// opened and nothing was sent.
    public func stale(at now: Date = Date()) -> [ResumePlan] {
        plans.values.filter { $0.isStale(at: now) }.sorted { $0.plannedAt < $1.plannedAt }
    }

    /// The soonest moment anything here needs the clock, which is all a client needs to arm one
    /// timer for a whole pane rather than one per row.
    public func nextWake(after now: Date = Date()) -> Date? {
        plans.values.filter { !$0.isStale(at: now) }.map(\.resumesAt).min()
    }
}

/// Everything a client says about a message waiting on a window, written once so three clients say
/// it the same.
///
/// A wait is a settled state, not work in progress, and the words are chosen to keep that clear:
/// the message did not go, it is being held, and there is a time. Nothing here reads as activity,
/// nothing implies the machine is busy on your behalf, and the countdown is the only part that
/// changes — which is why it is the only part with a clock behind it.
public enum ResumeReading {
    /// The face. A wait on somebody else's clock is settled — nothing is running — so it holds
    /// perfectly still, and it wears attention rather than danger, because nothing failed that is
    /// not going to be tried again.
    public static let symbol = "clock.arrow.circlepath"
    public static let glyph = "⏲"
    public static let tone = ActivityTone.attention

    public static var icon: ActivityIcon {
        ActivityIcon(symbol: symbol, glyph: glyph, tone: tone, motion: .still)
    }

    /// The word a row too narrow for a sentence wears.
    public static var badge: String { Localized.text("waiting for the window") }

    /// The line under a held message: what is used up, and when this device will try again.
    public static func caption(_ plan: ResumePlan, now: Date = Date()) -> String {
        let clock = QuotaSurface.countdown(to: plan.resumesAt, now: now)
        let when =
            plan.trustedReset
            ? Localized.text("sending again in %@", clock)
            : Localized.text("sending again in about %@", clock)
        guard plan.attempt > 0 else {
            return Localized.text(
                "Not sent — %@ %@ is used up · %@", plan.provider, plan.window, when)
        }
        return Localized.text(
            "%@ %@ is still used up · %@ (try %d of %d)", plan.provider, plan.window, when,
            plan.attempt + 1, AutoResume.maxAttempts)
    }

    /// The same fact where the surface is a band rather than a row.
    public static func short(_ plan: ResumePlan, now: Date = Date()) -> String {
        Localized.text(
            "%@ %@ used up · sending again in %@", plan.provider, plan.window,
            QuotaSurface.countdown(to: plan.resumesAt, now: now))
    }

    /// The whole of it for a screen reader: what was written, and what is going to happen to it.
    public static func spoken(_ plan: ResumePlan, words: String, now: Date = Date()) -> String {
        let line = caption(plan, now: now)
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? line : "\(trimmed). \(line)"
    }

    /// What a waiting row offers. Three verbs, and each is a whole decision: send it into the wall
    /// now anyway, change what is going to be sent, or stop waiting and leave the words where they
    /// are. Deliberately not four — a row that is holding somebody's message is not the place to
    /// lay out every combination, and discarding is still one press away on the ordinary failed
    /// row that stopping the wait leaves behind.
    public enum Act: String, Sendable, Hashable, CaseIterable {
        case sendNow
        case edit
        case stopWaiting
    }

    public static let acts = Act.allCases

    public static func title(_ act: Act) -> String {
        switch act {
        case .sendNow: return Localized.text("Send now")
        case .edit: return Localized.text("Edit")
        case .stopWaiting: return Localized.text("Don't wait")
        }
    }

    public static func symbol(_ act: Act) -> String {
        switch act {
        case .sendNow: return "paperplane"
        case .edit: return "pencil"
        case .stopWaiting: return "clock.badge.xmark"
        }
    }

    /// What the row says once the person has stopped waiting: the ordinary not-sent line, so a row
    /// that was waiting a second ago does not keep a countdown that no longer means anything.
    public static func stopped(_ plan: ResumePlan) -> String {
        Localized.text("Not sent — %@ %@ is used up.", plan.provider, plan.window)
    }

    /// What the app says the moment the window opens and the message goes on its own.
    public static func firing(_ plan: ResumePlan) -> String {
        Localized.text("%@ %@ reset — sending your message", plan.provider, plan.window)
    }

    /// Why nothing is being waited for. Every case says the thing a person would otherwise have to
    /// work out from a silence.
    public static func obstacle(_ obstacle: ResumeObstacle, now: Date = Date()) -> String {
        switch obstacle {
        case .turnedOff:
            return Localized.text(
                "Not sent. Tailscode isn't set to wait for the window — turn on Resume when the window opens to have it sent for you.")
        case .noReset:
            return Localized.text(
                "Not sent, and nothing here says when it opens again — a balance opens when it is topped up, not on a clock. Switch model, or top up.")
        case .turnHadStarted:
            return Localized.text(
                "The window closed part-way through the answer. What is above is real and half-written, so the next message is yours to write rather than this one sent again.")
        case .attemptsSpent(let tries):
            return Localized.text(
                "Tried %d times as the window reopened and it was still closed. Your message is still here — send it when you're ready.",
                tries)
        case .tooFarOut(let reset):
            return Localized.text(
                "That window doesn't open for %@, which is too long to hold a message you wrote now. It's still here when you want it.",
                QuotaSurface.countdown(to: reset, now: now))
        }
    }

    /// What the person is told when a plan's moment passed while the app was closed. It names the
    /// two facts that matter — the window did open, and nothing was sent — because a message found
    /// unsent hours later with no explanation reads as the app having eaten it.
    public static func missed(_ plan: ResumePlan, now: Date = Date()) -> String {
        Localized.text(
            "%@ %@ reopened %@ ago while Tailscode wasn't running, so nothing was sent. Your message is still here.",
            plan.provider, plan.window, QuotaSurface.countdown(to: now, now: plan.resumesAt))
    }

    /// The notification a device posts so a window opening is news even when nothing is on screen.
    public static func notificationTitle(_ plan: ResumePlan) -> String {
        Localized.text("%@ %@ has reset", plan.provider, plan.window)
    }

    public static func notificationBody(_ plan: ResumePlan) -> String {
        switch plan.trigger {
        case .refused: return Localized.text("Tailscode is sending the message you were holding.")
        case .answerless: return Localized.text("Tailscode is asking again.")
        }
    }

    /// The setting's own words, so three clients label it identically.
    public static var settingTitle: String { Localized.text("Resume when the window opens") }
    public static var settingDetail: String {
        Localized.text(
            "A message a spent quota stopped is held and sent again the moment the provider's window resets — checked against the gauges first, never blind, and never a message the agent already started answering.")
    }
}

/// Whether this device waits out a spent window on the person's behalf.
///
/// On by default, because the alternative is worse in both directions: the message a wall stopped
/// is one the person already pressed send on, it demonstrably did not get answered, and leaving it
/// to be rediscovered hours later is not caution — it is the app choosing to forget. Nothing here
/// happens invisibly: the wait is drawn on the row that is holding the words, the countdown is
/// there, and one press ends it.
public enum AutoResumeSetting {
    public static let defaultsKey = "tailscode.autoResume"
    public static let didChange = Notification.Name("tailscode.autoResume.didChange")

    /// Absent means on, so a device that has never been asked behaves the way the product does.
    public static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    public static func setEnabled(_ value: Bool) {
        if value {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.set(false, forKey: defaultsKey)
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    public static var title: String { ResumeReading.settingTitle }
    public static var explanation: String { ResumeReading.settingDetail }
}
