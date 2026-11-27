import ActivityKit
import CodingAgentKit
import Foundation
import MidgarCore
import TailscodeCore
import UIKit

/// Every turn this device follows on the Lock Screen and in the Dynamic Island, one card per
/// conversation.
///
/// A card is live while its turn runs and settles in place when the turn ends, because an ending
/// is news until somebody reads it: it stays exactly where the turn left it until the conversation
/// is opened, until the conversation's next turn takes it back, or until `LiveActivityLinger` says
/// nobody is coming — first off the Dynamic Island, then off the Lock Screen. What a card says is
/// Core's (`LiveActivityReading`); this owns the platform's side of it.
///
/// The card itself is the truth. claude-bridge pushes to it while this process is suspended — it
/// settles a turn that ended in a pocket and takes the card back for a turn another machine
/// started — so every decision reads what the card last showed rather than what this process last
/// wrote, except while one of this process's own writes is still in flight.
///
/// A card is read, and so taken down, only where a person can be reading it: its conversation on
/// screen in the app in front. That is this controller's to know (`shown`/`hidden`) rather than
/// each caller's to guess, because the app merely being open says nothing about which chat it is
/// showing. A turn somebody stopped is not news to them, so its card goes at once.
@MainActor
final class AppActivityController {
    typealias State = ChatActivityAttributes.ContentState
    typealias Phase = State.Phase
    typealias PushTokenSink = @Sendable (String, Date) async -> Void

    static let shared = AppActivityController()

    private struct Entry {
        let activity: Activity<ChatActivityAttributes>
        var state: State
        /// What the card last showed, kept here because ActivityKit answers a read by waiting on
        /// its daemon, and a main thread that waits on a daemon still starting after a boot is a
        /// main thread the watchdog ends. Moved by this process's own writes, by the card's
        /// content stream, and by `catchUp` for whatever a push said while nothing was listening.
        var card: State
        var platform: ActivityState = .active
        var title: String?
        var pushedAt: Date
        var pushToken: String?
        var onPushToken: PushTokenSink?
        var followsTokens = false
        /// The server the card's token goes to pushes its ending itself — alert and all — so this
        /// process leaves the alert to it rather than opening the island twice.
        var serverAlerts = false
        /// Ended — by this process or by a push — and possibly still on the Lock Screen, where only
        /// a read takes it down early.
        var retired = false
        var retirement: Task<Void, Never>?
        var watchers: [Task<Void, Never>] = []
        /// The prompt of the turn this process last settled the card on, and the ending it wrote
        /// for it: while the card still shows that ending, a reading for a different prompt is a
        /// new turn, whatever the two clocks behind the ending and the new turn's start say.
        var settledTurn: (prompt: String, endedAt: Date)?
        /// Whether the person asked for this card — a send from here, the chat on screen — or the
        /// app or a server opened it for a turn elsewhere, which is what decides who gives way when
        /// iOS will hold no more.
        var claim: LiveActivityRoom.Claim = .followed
    }

    private var entries: [String: Entry] = [:]
    private var pendingWork: [String: Task<Void, Never>] = [:]
    private var pendingTokens: [String: UUID] = [:]
    private var tokenHandoffs: [String: Task<Void, Never>] = [:]
    private var starting: [String: Deferred] = [:]
    /// Cards a server started that are being taken up, by activity: standing but not yet followed.
    private var adopting: Set<String> = []
    /// Whether the cards a previous process left have been taken up, before which a card nothing
    /// here follows is not yet a stray.
    private var adoptedStanding = false
    /// Every surface showing a conversation and which one, held weakly and asked whether it is in
    /// a window when it matters, so a surface torn down without saying goodbye reads as gone.
    private let readers = NSMapTable<UIViewController, NSString>(
        keyOptions: .weakMemory, valueOptions: .strongMemory)

    /// The longest a live card goes before the platform redraws it as quiet, whatever it last
    /// said moved; a card waiting on the person waits this long before it admits it heard nothing.
    static let staleAfter: TimeInterval = 1800
    /// How far the moment a live card last moved may run ahead of what it shows before it is
    /// written again: the card counts "nothing new" from it, so it must not fall far behind a turn
    /// that is streaming words with nothing else changing.
    static let movedDrift: TimeInterval = 15
    /// How often a live card that says the same thing is written again anyway, so its stale date
    /// moves on while the turn really is running.
    private static let refreshAfter: TimeInterval = 600

    /// Whether a card for the conversation is standing, live or settled.
    func isTracking(_ sessionID: String) -> Bool {
        guard var entry = entries[sessionID], !entry.retired else { return false }
        guard Self.isStanding(entry.platform) else {
            entry.retired = true
            entry.retirement?.cancel()
            entry.retirement = nil
            entries[sessionID] = entry
            return false
        }
        return true
    }

    /// Conversations whose card the person swiped away or read, and until when: what they said
    /// about this turn, so nothing here opens another for it.
    private var declines: [String: Date] = [:]

    /// How long reading a card about a turn that has already ended keeps another from opening.
    /// The turn is over, so the only card the mark can stop is one a listing still saying it runs
    /// would open; the next turn may begin before any listing has seen the rest between them, and
    /// must have its card.
    static let readTurnHold: TimeInterval = 30

    /// Conversations no card is opened for by this process right now.
    var declined: Set<String> {
        let now = Date()
        return Set(declines.lazy.filter { $0.value > now }.map(\.key))
    }

    /// The conversation is at rest, as the listing says, so its next turn may have a card again.
    /// Only the listing says so: a chat's own idle states would clear the mark the moment the
    /// card was read, and a listing that has not caught up yet would open it again.
    func rested(_ sessionID: String) {
        declines[sessionID] = nil
    }

    /// Opens no card by itself for the conversation until it is at rest: the turn the card was
    /// opened for is still running, and the person said no to it.
    func decline(_ sessionID: String) {
        declines[sessionID] = .distantFuture
    }

    /// The card was read or swiped away after its turn had ended: held only as long as a listing
    /// can lag behind the ending.
    private func declineEnded(_ sessionID: String) {
        let now = Date()
        declines = declines.filter { $0.value > now }
        declines[sessionID] = max(
            declines[sessionID] ?? .distantPast, now.addingTimeInterval(Self.readTurnHold))
    }

    /// Whether iOS lets the app show Live Activities, as last read off the main thread: the
    /// person can turn them off for the app in iOS Settings, and a start asked for then is refused
    /// on every try. Assumed allowed until the first read says otherwise.
    nonisolated(unsafe) private(set) static var allowed = true

    /// Reads iOS's answer off the main thread and follows it for the life of the process, handing
    /// the bridges the change so they stop starting cards nobody can see.
    static func observeAuthorization() {
        Task.detached(priority: .utility) {
            let first = ActivityAuthorizationInfo().areActivitiesEnabled
            await MainActor.run { authorizationChanged(first) }
            for await enabled in ActivityAuthorizationInfo().activityEnablementUpdates {
                await MainActor.run { authorizationChanged(enabled) }
            }
        }
    }

    private static func authorizationChanged(_ enabled: Bool) {
        guard enabled != allowed else { return }
        allowed = enabled
        MidgarLog.info("Live Activities \(enabled ? "allowed" : "turned off") in iOS Settings", category: .chat)
        PushRegistrar.rulesChanged()
    }

    /// How many cards are on the Lock Screen or being asked for, live, settled or ended: what the
    /// cards this device opens by itself for turns it did not send are counted against, because iOS
    /// counts every one of them against the handful it lets the app keep.
    var standingCount: Int { starting.count + entries.count }

    /// How many cards are live or being asked for: what the free tier's single card is counted
    /// against, since its card gives an ending's place to the next turn it follows.
    var liveCount: Int {
        starting.count
            + entries.filter { !$0.value.retired && !current($0.key, $0.value).isSettled }.count
    }

    /// Whether the conversation has a card, standing or still being asked for: what it says in the
    /// moment the platform takes to answer is held and said to the card once it exists.
    func follows(_ sessionID: String) -> Bool {
        starting[sessionID] != nil || isTracking(sessionID)
    }

    /// Conversations whose card is live with nothing in this process having written to it — the
    /// cards a previous process left, taken up at launch. Something has to watch their turns end,
    /// or they stand at whatever they last said until the platform ends them.
    var unwatchedLiveSessions: [String] {
        entries.compactMap { sessionID, entry in
            guard !entry.retired, entry.pushedAt == .distantPast,
                !current(sessionID, entry).isSettled
            else { return nil }
            return sessionID
        }
    }

    /// Opens the conversation's card for a turn this device is starting: the card it already has
    /// is taken back rather than a second one stacked beside it, and a new one is asked for only
    /// when there is none. Starting one is the only thing ActivityKit allows solely in the
    /// foreground, which is why it happens at the send rather than when the server reports the
    /// turn running. The platform is asked off the main thread, so the card exists a moment after
    /// this returns; whatever the conversation says in that moment is held and said to it then.
    ///
    /// `startedAt` is when the turn began, for a card opened on a turn that was already running —
    /// one this device did not send — so its clock tells the turn's age rather than the card's.
    /// `claim` says whether the person asked for the card or the app is following a turn elsewhere
    /// by itself; only the first makes room among cards still running when iOS holds no more.
    func start(
        sessionID: String, sessionTitle: String, serverName: String, profileID: String? = nil,
        startedAt turnBegan: Date? = nil, onPushToken: PushTokenSink? = nil,
        serverAlerts: Bool = false, claim: LiveActivityRoom.Claim = .asked
    ) {
        guard AppPreferences.liveActivitiesEnabled else {
            MidgarLog.info("Live Activity disabled in settings", category: .chat)
            return
        }
        guard Self.allowed else {
            MidgarLog.info("Live Activity turned off for the app in iOS Settings", category: .chat)
            return
        }
        if isTracking(sessionID), var entry = entries[sessionID] {
            let startedAt = Date()
            let state = Self.liveState(
                LiveActivityReading(detail: .thinking), startedAt: startedAt, toolCount: 0,
                title: entry.title)
            entry.retirement?.cancel()
            entry.retirement = nil
            entry.state = state
            entry.pushedAt = startedAt
            if let onPushToken { entry.onPushToken = onPushToken }
            entry.serverAlerts = onPushToken != nil && serverAlerts
            if claim == .asked { entry.claim = .asked }
            entries[sessionID] = entry
            write(sessionID, entry.activity, state)
            if let token = entry.pushToken, let sink = entry.onPushToken {
                hand(token, startedAt: startedAt, to: sink, for: sessionID)
            }
            followTokens(sessionID)
            MidgarLog.info("Live Activity taken back for \(sessionID)", category: .chat)
            return
        }
        guard starting[sessionID] == nil else { return }
        if let lingering = entries[sessionID] {
            dismiss(sessionID, lingering)
        }
        if !ProAccess.shared.hasProAccess {
            let others = entries.filter { $0.key != sessionID && !$0.value.retired }
            guard others.allSatisfy({ current($0.key, $0.value).isSettled }),
                !starting.keys.contains(where: { $0 != sessionID })
            else {
                MidgarLog.info("second concurrent Live Activity gated (free tier)", category: .chat)
                return
            }
            for (other, entry) in others { dismiss(other, entry) }
        }
        let attributes = ChatActivityAttributes(
            sessionID: sessionID,
            sessionTitle: sessionTitle.isEmpty ? String(localized: "Agent session") : sessionTitle,
            serverName: serverName, profileID: profileID)
        let startedAt = min(turnBegan ?? Date(), Date())
        let state = Self.liveState(
            LiveActivityReading(detail: .thinking), startedAt: startedAt, toolCount: 0, title: nil)
        let request = CardRequest(
            attributes: attributes, content: Self.content(state),
            pushType: onPushToken == nil ? nil : .token)
        starting[sessionID] = Deferred()
        Task {
            await open(
                sessionID, request, state: state, startedAt: startedAt, onPushToken: onPushToken,
                serverAlerts: onPushToken != nil && serverAlerts, claim: claim)
        }
    }

    /// What the conversation did while its card was still being asked for, kept to be said to the
    /// card the moment it exists: a turn that ended in the time the platform took to answer must
    /// still settle the card it was about to get, and a conversation withdrawn in that time must
    /// not be left with one.
    private struct Deferred {
        var update: (reading: LiveActivityReading, title: String?, brief: LiveActivityBrief?)?
        var settle: (reading: LiveActivityReading, title: String?, brief: LiveActivityBrief?)?
        var withdrawn = false
    }

    private func whileStarting(_ sessionID: String, _ note: (inout Deferred) -> Void) -> Bool {
        guard entries[sessionID] == nil, var pending = starting[sessionID] else { return false }
        note(&pending)
        starting[sessionID] = pending
        return true
    }

    /// Asks the platform for the card off the main thread — in the first minute after a boot its
    /// daemon is not answering, and a main thread that waits on it is a main thread the watchdog
    /// ends — and brings the controller up to date with whatever happened meanwhile.
    private func open(
        _ sessionID: String, _ request: CardRequest, state: State, startedAt: Date,
        onPushToken: PushTokenSink?, serverAlerts: Bool, claim: LiveActivityRoom.Claim
    ) async {
        var answer = await Self.offMain("a new card") { Self.ask(request) }
        var gaveWay = 0
        while case .refused(let error) = answer, Self.isFull(error), gaveWay < Self.roomTries,
            let room = LiveActivityRoom.yielding(roomFacts(besides: sessionID), to: claim)
        {
            MidgarLog.info(
                "Live Activity refused (\(error)) \(await census()); \(room) gives way to \(sessionID)",
                category: .chat)
            await giveWay(room)
            gaveWay += 1
            answer = await Self.offMain("a new card") { Self.ask(request) }
        }
        let deferred = starting.removeValue(forKey: sessionID)
        switch answer {
        case .disabled:
            MidgarLog.info("Live Activity not authorized", category: .chat)
        case .refused(let error):
            MidgarLog.error(
                "Live Activity failed to start for \(sessionID): \(error) \(await census())",
                category: .chat)
        case .started(let activity):
            guard AppPreferences.liveActivitiesEnabled, deferred?.withdrawn != true else {
                let ending = Handles(activities: [activity])
                Task.detached { await ending.endAll() }
                return
            }
            entries[sessionID] = Entry(
                activity: activity, state: state, card: state, pushedAt: startedAt,
                onPushToken: onPushToken, serverAlerts: serverAlerts, claim: claim)
            watch(activity, sessionID: sessionID)
            MidgarLog.info("Live Activity started for \(sessionID)", category: .chat)
            if let held = deferred?.update {
                update(sessionID: sessionID, reading: held.reading, title: held.title, brief: held.brief)
            }
            if let held = deferred?.settle {
                settle(sessionID: sessionID, reading: held.reading, title: held.title, brief: held.brief)
            }
        }
    }

    /// What a running turn is doing now. A card that had settled is taken back — its conversation
    /// began another turn, sent from here or anywhere else — and its clock starts from the prompt
    /// that began it. Only a turn that began after the card settled can do that: a running state
    /// that arrives late for the turn that already ended — a stream catching up after the phone
    /// slept, a resync replaying what it held — is not a new turn, and must not stand the card
    /// back up over an ending the bridge already told it about.
    func update(
        sessionID: String, reading: LiveActivityReading, title: String?,
        brief: LiveActivityBrief? = nil
    ) {
        if whileStarting(sessionID, { $0.update = (reading, title, brief) }) { return }
        guard isTracking(sessionID), var entry = entries[sessionID] else { return }
        if let title, !title.isEmpty { entry.title = title }
        let shown = current(sessionID, entry)
        if let endedAt = shown.endedAt {
            guard Self.beganAfter(endedAt, reading, settled: entry.settledTurn) else {
                entries[sessionID] = entry
                return
            }
            MidgarLog.info(
                "Live Activity taken back by a turn begun elsewhere for \(sessionID)",
                category: .chat
            )
        }
        let revived = shown.isSettled
        let startedAt =
            revived
            ? min(reading.startedAt ?? Date(), Date())
            : Self.earlier(shown.startedAt, reading.startedAt)
        let toolCount = revived ? reading.toolCount : max(shown.toolCount, reading.toolCount)
        let state = Self.liveState(
            reading, startedAt: startedAt, toolCount: toolCount, title: entry.title,
            brief: brief ?? (revived ? nil : shown.brief))
        let becameWaiting = reading.detail.wantsYou && (revived || shown.phase != .approval)
        let due = Date().timeIntervalSince(entry.pushedAt) > Self.refreshAfter
        guard becameWaiting || due || revived || !Self.sameFacts(state, shown)
            || Self.movedOn(state, from: shown)
        else {
            entries[sessionID] = entry
            return
        }
        if revived {
            entry.retirement?.cancel()
            entry.retirement = nil
            entry.settledTurn = nil
        }
        entry.state = state
        entry.pushedAt = Date()
        entries[sessionID] = entry
        let alert: AlertConfiguration? =
            becameWaiting && AppPreferences.noticeRules.admitsAsk(sessionID: sessionID)
            ? AlertConfiguration(
                title: reading.detail == .question
                    ? LocalizedStringResource("The agent has a question")
                    : LocalizedStringResource("Approval needed"),
                body: LocalizedStringResource(
                    "\(entry.title ?? entry.activity.attributes.sessionTitle) is waiting for you."),
                sound: .default)
            : nil
        write(sessionID, entry.activity, state, alert: alert)
    }

    /// The turn ended: the card settles on how, and stays for somebody to read it. One that ends
    /// with its conversation on screen has been read already, and one somebody stopped was never
    /// news; both go at once.
    func settle(
        sessionID: String, reading: LiveActivityReading, title: String?,
        brief: LiveActivityBrief? = nil
    ) {
        if whileStarting(sessionID, { $0.settle = (reading, title, brief) }) { return }
        guard isTracking(sessionID), var entry = entries[sessionID] else { return }
        if Self.endsEarlierTurn(current(sessionID, entry), reading) {
            MidgarLog.info(
                "Live Activity kept for the turn it follows; the ending was for an earlier one \(sessionID)",
                category: .chat)
            return
        }
        if isBeingRead(sessionID) {
            MidgarLog.info("Live Activity read as it ended for \(sessionID)", category: .chat)
            declineEnded(sessionID)
            dismiss(sessionID, entry)
            return
        }
        if reading.detail == .cancelled {
            MidgarLog.info(
                "Live Activity ended with its stopped turn for \(sessionID)", category: .chat)
            dismiss(sessionID, entry)
            return
        }
        if let title, !title.isEmpty { entry.title = title }
        let shown = current(sessionID, entry)
        let now = Date()
        let endedAt =
            shown.endedAt
            ?? max(shown.startedAt, min(reading.endedAt ?? now, now))
        let toolCount = max(shown.toolCount, reading.toolCount)
        let face = reading.detail.face(tool: nil)
        let state = State(
            phase: Self.phase(reading.detail),
            statusText: reading.detail.line(
                tool: nil, toolCount: toolCount, background: reading.background),
            lastTool: nil, toolCount: toolCount, startedAt: shown.startedAt, endedAt: endedAt,
            title: entry.title, symbol: face.symbol, tone: face.tone.rawValue,
            detail: reading.detail.rawValue,
            background: reading.background > 0 ? reading.background : nil,
            brief: Self.settledBrief(brief ?? shown.brief))
        entry.settledTurn = reading.prompt.map { ($0, endedAt) }
        guard !(shown.isSettled && Self.sameFacts(state, shown)) else {
            entries[sessionID] = entry
            scheduleRetirement(sessionID, settledAt: endedAt)
            return
        }
        entry.state = state
        entry.pushedAt = now
        entries[sessionID] = entry
        let alert = shown.isSettled || entry.serverAlerts ? nil : endingAlert(sessionID, state, entry)
        write(sessionID, entry.activity, state, alert: alert)
        scheduleRetirement(sessionID, settledAt: endedAt)
        MidgarLog.info(
            "Live Activity settled for \(sessionID) (\(reading.detail.rawValue))", category: .chat)
    }

    /// Settles the card on an ending heard while this process was suspended, after reading what
    /// the card shows now: pushes moved it while nothing here was listening, and the next turn may
    /// already have taken it back.
    func settleHeardAway(
        sessionID: String, reading: LiveActivityReading, title: String?
    ) async {
        await readCard(sessionID)
        settle(sessionID: sessionID, reading: reading, title: title)
    }

    private func readCard(_ sessionID: String) async {
        guard let entry = entries[sessionID], pendingWork[sessionID] == nil else { return }
        let followed = Followed(cards: [(sessionID, entry.activity)])
        guard let (_, id, state, platform) = await Self.offMain("one card", { followed.read() }).first,
            var now = entries[sessionID], now.activity.id == id, pendingWork[sessionID] == nil
        else { return }
        now.card = state
        now.platform = platform
        entries[sessionID] = now
    }

    /// The conversation was looked at, which is what reads a card about it. A live card stays:
    /// the turn it follows is still running.
    func seen(_ sessionID: String) {
        guard let entry = entries[sessionID] else { return }
        guard entry.retired || current(sessionID, entry).isSettled else { return }
        MidgarLog.info("Live Activity read for \(sessionID)", category: .chat)
        declineEnded(sessionID)
        dismiss(sessionID, entry)
    }

    /// Takes the conversation's card down at once, whatever it says — a send the person stopped
    /// before it went, or a conversation that no longer exists.
    func withdraw(_ sessionID: String) {
        if whileStarting(sessionID, { $0.withdrawn = true }) { return }
        guard let entry = entries[sessionID] else { return }
        dismiss(sessionID, entry)
    }

    /// Takes down every card about a server this device no longer has: nothing here can follow
    /// its turns or open its chats any more.
    func withdraw(profileID: String) {
        for (sessionID, entry) in entries where entry.activity.attributes.profileID == profileID {
            withdraw(sessionID)
        }
    }

    /// Takes every card down — Live Activities were just turned off in Settings, and a card left
    /// standing would go on following its conversation's turns regardless.
    func withdrawAll() {
        for sessionID in starting.keys { starting[sessionID]?.withdrawn = true }
        for (sessionID, entry) in entries { dismiss(sessionID, entry) }
    }

    /// A surface began showing the conversation.
    func shown(_ sessionID: String, in surface: UIViewController) {
        readers.setObject(sessionID as NSString, forKey: surface)
    }

    /// A surface stopped showing whatever conversation it was showing.
    func hidden(_ surface: UIViewController) {
        readers.removeObject(forKey: surface)
    }

    /// Whether a person is looking at the conversation this moment: on screen, in the app in
    /// front. A chat left on screen under the Lock Screen is not being read.
    func isBeingRead(_ sessionID: String) -> Bool {
        guard UIApplication.shared.applicationState == .active else { return false }
        let surfaces = readers.keyEnumerator().allObjects.compactMap { $0 as? UIViewController }
        return surfaces.contains { surface in
            readers.object(forKey: surface) as String? == sessionID
                && surface.viewIfLoaded?.window != nil
        }
    }

    /// The conversation has a better name than the card started with.
    func retitle(sessionID: String, title: String) {
        guard !title.isEmpty, isTracking(sessionID), var entry = entries[sessionID] else { return }
        entry.title = title
        var state = current(sessionID, entry)
        guard state.title != title else {
            entries[sessionID] = entry
            return
        }
        state.title = title
        entry.state = state
        entries[sessionID] = entry
        write(sessionID, entry.activity, state)
    }

    /// Draws every standing card again in the look the person just chose. The widget reads the
    /// size from the shared container when it draws, so writing what each card already shows is
    /// what makes it draw again.
    func redrawAll() {
        for (sessionID, entry) in entries where !entry.retired {
            write(sessionID, entry.activity, current(sessionID, entry))
        }
    }

    /// Hands every standing card's token to its server again, so a server that pushes the ending
    /// learns the person's new choice for it; the server reads a token it already holds for the
    /// same turn as an address and changes nothing else.
    func reregisterAll() {
        for sessionID in entries.keys { reregister(sessionID) }
    }

    /// Hands one conversation's card token to its server again — the chat was muted or unmuted.
    func reregister(_ sessionID: String) {
        guard let entry = entries[sessionID], !entry.retired, let token = entry.pushToken,
            let sink = entry.onPushToken
        else { return }
        hand(token, startedAt: current(sessionID, entry).startedAt, to: sink, for: sessionID)
    }

    /// Whether the app is in front, where an ending is seen in the app itself. A server that pushes
    /// the ending is told to leave the island closed while it is, and told again when it is not.
    private(set) var inFront = false

    func setInFront(_ value: Bool) {
        guard value != inFront else { return }
        inFront = value
        reregisterAll()
    }

    /// Moves every card whose time is up along: a settled card nobody came for leaves the Dynamic
    /// Island, and one retired long enough leaves the Lock Screen. Run whenever the app comes
    /// forward, because a suspended process misses the moment its own timers were set for.
    func retireExpired(now: Date = Date()) {
        for (sessionID, entry) in entries {
            let shown = current(sessionID, entry)
            guard let endedAt = shown.endedAt else { continue }
            if entry.retired {
                if now >= LiveActivityLinger.lockScreenEnds(settledAt: endedAt) {
                    dismiss(sessionID, entry)
                }
            } else if now >= LiveActivityLinger.islandEnds(settledAt: endedAt) {
                retire(sessionID)
            }
        }
    }

    /// Takes up the cards a previous process left behind instead of sweeping them away: a turn
    /// that is still running keeps its card, and one that settled while nobody was here keeps
    /// waiting to be read. A second card for the same conversation — which only a crash between a
    /// request and its bookkeeping could leave — goes. Run again whenever the app comes forward to
    /// a card nothing here follows; a card being asked for or taken up is left to that.
    func adoptStanding() async {
        let visible = await Self.offMain("the standing cards") { Self.readStanding() }
            .filter { !adopting.contains($0.activity.id) }
        var extras: [Activity<ChatActivityAttributes>] = []
        for (sessionID, found) in Dictionary(grouping: visible, by: \.sessionID)
        where entries[sessionID] == nil && starting[sessionID] == nil {
            let newestFirst = found.sorted { $0.state.startedAt > $1.state.startedAt }
            let standing = newestFirst.filter { Self.isStanding($0.platform) }
            guard let kept = standing.first ?? newestFirst.first else { continue }
            extras += found.map(\.activity).filter { $0.id != kept.activity.id }
            let attributes = kept.activity.attributes
            let sink = attributes.profileID.flatMap {
                Self.tokenSink(
                    profileID: $0, sessionID: sessionID,
                    title: kept.state.title ?? attributes.sessionTitle)
            }
            entries[sessionID] = Entry(
                activity: kept.activity, state: kept.state, card: kept.state,
                platform: kept.platform, title: kept.state.title, pushedAt: .distantPast,
                pushToken: kept.pushToken, onPushToken: sink,
                serverAlerts: attributes.profileID.map(Self.serverAlerts(profileID:)) ?? false,
                retired: !Self.isStanding(kept.platform), claim: .followed)
            watch(kept.activity, sessionID: sessionID, tokens: false)
            if let sink, let token = kept.pushToken, Self.isStanding(kept.platform),
                !kept.state.isSettled
            {
                hand(token, startedAt: kept.state.startedAt, to: sink, for: sessionID)
            }
            if sink != nil, Self.isStanding(kept.platform) { followTokensLater(sessionID) }
            if Self.isStanding(kept.platform), let endedAt = kept.state.endedAt {
                scheduleRetirement(sessionID, settledAt: endedAt)
            }
            MidgarLog.info(
                "Live Activity adopted for \(sessionID) (\(kept.state.isSettled ? "settled" : "live"))",
                category: .chat)
        }
        if !extras.isEmpty {
            let ending = Handles(activities: extras)
            Task.detached { await ending.endAll() }
        }
        adoptedStanding = true
        retireExpired()
    }

    /// Brings every card's mirror up to what the platform shows, then moves expired cards along.
    /// Run whenever the app comes forward: a push may have changed a card while this process was
    /// suspended and its streams were not being read.
    func catchUp() async {
        let tracked = Followed(cards: entries.map { ($0.key, $0.value.activity) })
        let seen = await Self.offMain("the cards it follows") { tracked.read() }
        for (sessionID, id, state, platform) in seen {
            guard var entry = entries[sessionID], entry.activity.id == id,
                pendingWork[sessionID] == nil
            else { continue }
            entry.card = state
            entry.platform = platform
            entries[sessionID] = entry
        }
        await sweepStrays()
        retireExpired()
    }

    /// Settles every card iOS lists that nothing here follows, because each one holds one of the
    /// few places iOS gives the app and none of them would ever move again: a conversation's second
    /// card and a card the person already read or turned down are ended, and any other card for a
    /// conversation this process has no card for is taken up the way a launch takes them up. A
    /// card being asked for, taken up or written to is left alone.
    private func sweepStrays() async {
        guard adoptedStanding else { return }
        let listed = await Self.offMain("the standing cards") { Self.readStanding() }
        let declined = declined
        var extras: [Activity<ChatActivityAttributes>] = []
        var untracked = false
        for card in listed
        where !adopting.contains(card.activity.id) && starting[card.sessionID] == nil
            && pendingWork[card.sessionID] == nil
        {
            if let entry = entries[card.sessionID] {
                guard entry.activity.id != card.activity.id else { continue }
                MidgarLog.info(
                    "Live Activity a second card for \(card.sessionID) ended (\(card.platform))",
                    category: .chat)
            } else if declined.contains(card.sessionID) {
                MidgarLog.info(
                    "Live Activity left standing after it was read ended for \(card.sessionID)",
                    category: .chat)
            } else {
                untracked = true
                continue
            }
            extras.append(card.activity)
        }
        if !extras.isEmpty {
            let ending = Handles(activities: extras)
            await Task.detached { await ending.endAll() }.value
        }
        if untracked { await adoptStanding() }
    }

    private func retire(_ sessionID: String) {
        guard var entry = entries[sessionID], !entry.retired else { return }
        let shown = current(sessionID, entry)
        guard let endedAt = shown.endedAt else { return }
        entry.retired = true
        entry.retirement?.cancel()
        entry.retirement = nil
        entries[sessionID] = entry
        let leaves = LiveActivityLinger.lockScreenEnds(settledAt: endedAt)
        let policy: ActivityUIDismissalPolicy = leaves > Date() ? .after(leaves) : .immediate
        let content = Self.content(shown)
        let stamp = Date()
        enqueue(sessionID, entry.activity) { act in
            await act.end(content, dismissalPolicy: policy, timestamp: stamp)
        }
        MidgarLog.info("Live Activity left the Dynamic Island for \(sessionID)", category: .chat)
    }

    private func dismiss(_ sessionID: String, _ entry: Entry?) {
        guard let entry else { return }
        forget(sessionID)
        let stamp = Date()
        enqueue(sessionID, entry.activity) { act in
            await act.end(nil, dismissalPolicy: .immediate, timestamp: stamp)
        }
    }

    private func forget(_ sessionID: String) {
        guard let entry = entries.removeValue(forKey: sessionID) else { return }
        entry.retirement?.cancel()
        for watcher in entry.watchers { watcher.cancel() }
    }

    private func scheduleRetirement(_ sessionID: String, settledAt: Date) {
        guard var entry = entries[sessionID] else { return }
        entry.retirement?.cancel()
        let delay = LiveActivityLinger.islandEnds(settledAt: settledAt).timeIntervalSinceNow
        entry.retirement = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            self?.retire(sessionID)
        }
        entries[sessionID] = entry
    }

    /// How many cards one start may take down to make its own room: past that iOS is counting
    /// cards this process cannot see, and taking more of the person's cards down would not help.
    private static let roomTries = 2

    /// Every standing card but the one being asked for, as `LiveActivityRoom` weighs them.
    private func roomFacts(besides sessionID: String) -> [LiveActivityRoom.Standing] {
        entries.compactMap { key, entry in
            guard key != sessionID else { return nil }
            let shown = current(key, entry)
            return LiveActivityRoom.Standing(
                sessionID: key, claim: entry.claim, endedAt: shown.endedAt,
                movedAt: max(entry.pushedAt, shown.brief?.moved ?? shown.startedAt),
                waitsOnYou: shown.isWaitingOnYou)
        }
    }

    /// Takes a card down so another can stand, and waits until iOS has it down. A turn still
    /// running elsewhere is declined until it rests, so following it by itself does not take the
    /// place straight back.
    private func giveWay(_ sessionID: String) async {
        guard let entry = entries[sessionID] else { return }
        if !current(sessionID, entry).isSettled { decline(sessionID) }
        dismiss(sessionID, entry)
        await pendingWork[sessionID]?.value
    }

    /// What stands when iOS refuses a card, for the log: the cards this process follows by kind,
    /// and how many iOS itself lists, which says whether it is counting cards nothing here can see.
    private func census() async -> String {
        let listed = await Self.offMain("the standing cards") { Self.readStanding().count }
        var live = 0
        var settled = 0
        var ended = 0
        for (sessionID, entry) in entries {
            if entry.retired {
                ended += 1
            } else if current(sessionID, entry).isSettled {
                settled += 1
            } else {
                live += 1
            }
        }
        return "(following \(live) live, \(settled) settled, \(ended) ended; iOS lists \(listed))"
    }

    /// What the card shows. While one of this process's own writes is on its way, that write is
    /// the truth; otherwise the card is, because a push may have changed it since.
    private func current(_ sessionID: String, _ entry: Entry) -> State {
        pendingWork[sessionID] == nil ? entry.card : entry.state
    }

    /// Follows the card's own life: what it shows, and the moment a person swipes it away or the
    /// platform ends it, after which it is nobody's to write to. Every stream is subscribed off
    /// the main thread, because subscribing waits on ActivityKit's own queue while holding a lock
    /// that queue needs to hand an update over, and a main thread caught in that never returns.
    private func watch(
        _ activity: Activity<ChatActivityAttributes>, sessionID: String, tokens: Bool = true
    ) {
        let card = Card(activity: activity)
        let id = activity.id
        let contents = Task.detached { [weak self] in
            for await content in card.activity.contentUpdates {
                guard let self, await self.cardShowed(content.state, sessionID: sessionID, id: id)
                else { return }
            }
        }
        let lifecycle = Task.detached { [weak self] in
            for await state in card.activity.activityStateUpdates {
                guard let self, await self.platformMoved(to: state, sessionID: sessionID, id: id)
                else { return }
            }
        }
        entries[sessionID]?.watchers = [contents, lifecycle]
        if tokens { followTokens(sessionID) }
    }

    /// Follows a card's tokens once the launch has settled: a card taken up at launch hands over
    /// the token it already has at once, and listens for the next only after ActivityKit has
    /// finished handing the launch's tokens over, which is when subscribing deadlocks its queue.
    private func followTokensLater(_ sessionID: String) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.followTokens(sessionID)
        }
    }

    /// A card ActivityKit just started: one this process asked for, which it already follows, or
    /// one a server started while the app slept, which is taken up and its token handed back so
    /// the server can keep it current. A second card for a conversation that has one, a card the
    /// person turned off, and one past the free tier's single live card are ended at once.
    func adoptStarted(_ started: StartedCard) async {
        let activity = started.activity
        let sessionID = activity.attributes.sessionID
        adopting.insert(activity.id)
        defer { adopting.remove(activity.id) }
        var waited = 0
        while starting[sessionID] != nil, waited < 60 {
            try? await Task.sleep(for: .milliseconds(500))
            waited += 1
        }
        if let entry = entries[sessionID], entry.activity.id == activity.id { return }
        let read = await Self.offMain("a started card") {
            (state: started.activity.content.state, platform: started.activity.activityState,
             token: started.activity.pushToken.map(Self.hex))
        }
        guard Self.isStanding(read.platform) else { return }
        let standing = entries[sessionID].map { !$0.retired && !current(sessionID, $0).isSettled } ?? false
        let duplicate = standing || starting[sessionID] != nil
        let refused =
            !AppPreferences.liveActivitiesEnabled || !LiveActivitySettings.followsElsewhere
            || AppPreferences.noticeRules.isMuted(sessionID)
            || (!ProAccess.shared.hasProAccess
                && (entries.contains { $0.key != sessionID && !$0.value.retired && !current($0.key, $0.value).isSettled }
                    || starting.keys.contains { $0 != sessionID }))
        guard !duplicate, !refused else {
            MidgarLog.info(
                "Live Activity a server started for \(sessionID) ended (\(duplicate ? "one stands" : "not wanted"))",
                category: .chat)
            let ending = Handles(activities: [activity])
            Task.detached { await ending.endAll() }
            return
        }
        if let lingering = entries[sessionID] { dismiss(sessionID, lingering) }
        let title = read.state.title ?? activity.attributes.sessionTitle
        let sink = activity.attributes.profileID.flatMap {
            Self.tokenSink(profileID: $0, sessionID: sessionID, title: title)
        }
        entries[sessionID] = Entry(
            activity: activity, state: read.state, card: read.state, platform: read.platform,
            title: read.state.title, pushedAt: .distantPast, pushToken: read.token,
            onPushToken: sink,
            serverAlerts: activity.attributes.profileID.map(Self.serverAlerts(profileID:)) ?? true,
            claim: .followed)
        watch(activity, sessionID: sessionID, tokens: false)
        if let sink, let token = read.token {
            hand(token, startedAt: read.state.startedAt, to: sink, for: sessionID)
        }
        if sink != nil { followTokensLater(sessionID) }
        MidgarLog.info("Live Activity a server started was taken up for \(sessionID)", category: .chat)
    }

    /// Listens for the tokens the server needs to reach the card, from the moment there is
    /// somewhere to send them. A card taken up at launch has nowhere until its conversation takes
    /// it back, and subscribing while ActivityKit is still handing the launch's tokens over is
    /// exactly when its token queue deadlocks.
    private func followTokens(_ sessionID: String) {
        guard var entry = entries[sessionID], entry.onPushToken != nil, !entry.followsTokens
        else { return }
        let card = Card(activity: entry.activity)
        let id = entry.activity.id
        let tokens = Task.detached { [weak self] in
            for await token in card.activity.pushTokenUpdates {
                guard let self,
                    await self.tokenArrived(Self.hex(token), sessionID: sessionID, id: id)
                else { return }
            }
        }
        entry.followsTokens = true
        entry.watchers.append(tokens)
        entries[sessionID] = entry
    }

    private func tokenArrived(_ hex: String, sessionID: String, id: String) -> Bool {
        guard var entry = entries[sessionID], entry.activity.id == id else { return false }
        guard hex != entry.pushToken else { return true }
        entry.pushToken = hex
        entries[sessionID] = entry
        if let sink = entry.onPushToken {
            hand(hex, startedAt: current(sessionID, entry).startedAt, to: sink, for: sessionID)
        }
        return true
    }

    /// Gives the server a token only after every token handed to it before for the conversation,
    /// so the one a card was given at launch can never land after the one that replaced it.
    private func hand(
        _ token: String, startedAt: Date, to sink: @escaping PushTokenSink, for sessionID: String
    ) {
        let previous = tokenHandoffs[sessionID]
        tokenHandoffs[sessionID] = Task {
            await previous?.value
            await sink(token, startedAt)
        }
    }

    private func cardShowed(_ state: State, sessionID: String, id: String) -> Bool {
        guard var entry = entries[sessionID], entry.activity.id == id else { return false }
        guard pendingWork[sessionID] == nil else { return true }
        entry.card = state
        entries[sessionID] = entry
        return true
    }

    private func platformMoved(to state: ActivityState, sessionID: String, id: String) -> Bool {
        guard var entry = entries[sessionID], entry.activity.id == id else { return false }
        entry.platform = state
        entries[sessionID] = entry
        if state == .dismissed {
            if entry.retired || current(sessionID, entry).isSettled {
                declineEnded(sessionID)
            } else {
                decline(sessionID)
            }
            forget(sessionID)
            return false
        }
        guard state == .ended, !entry.retired else { return true }
        entry.retired = true
        entry.retirement?.cancel()
        entry.retirement = nil
        entries[sessionID] = entry
        return true
    }

    /// The alert that opens the Dynamic Island on how the turn ended, when the person asked for it
    /// and somebody can be looking: never with the app in front, where the island is not shown for
    /// the app's own card, and never for a chat they muted. The title and body are what an Apple
    /// Watch shows; the island draws the card itself.
    private func endingAlert(_ sessionID: String, _ state: State, _ entry: Entry) -> AlertConfiguration? {
        let ending = LiveActivitySettings.ending
        guard ending.alerts, UIApplication.shared.applicationState != .active,
            !AppPreferences.noticeRules.isMuted(sessionID), !DeskHold.shared.atDeskLately
        else { return nil }
        let headline = LiveActivityHeadline.line(
            detail: state.detail.flatMap(LiveActivityDetail.init(rawValue:)),
            statusText: state.statusText, brief: state.brief, tool: nil, toolCount: state.toolCount,
            background: state.background ?? 0, settled: state.isSettled)
        let title = state.title ?? entry.activity.attributes.sessionTitle
        MidgarLog.info("Live Activity alerts its ending for \(sessionID) (\(ending.rawValue))", category: .chat)
        return AlertConfiguration(
            title: LocalizedStringResource(stringLiteral: title),
            body: LocalizedStringResource(stringLiteral: headline),
            sound: ending == .expandWithSound ? .default : .named(LiveActivityEnding.silentSound))
    }

    private func write(
        _ sessionID: String, _ activity: Activity<ChatActivityAttributes>, _ state: State,
        alert: AlertConfiguration? = nil
    ) {
        let content = Self.content(state)
        let stamp = Date()
        entries[sessionID]?.card = state
        enqueue(sessionID, activity) { act in
            await act.update(content, alertConfiguration: alert, timestamp: stamp)
        }
    }

    /// Serializes ActivityKit calls per session so a slow earlier update can
    /// never land after a later one (or after end).
    private func enqueue(
        _ sessionID: String, _ act: sending Activity<ChatActivityAttributes>,
        _ op: @escaping @Sendable (Activity<ChatActivityAttributes>) async -> Void
    ) {
        let previous = pendingWork[sessionID]
        let token = UUID()
        pendingTokens[sessionID] = token
        pendingWork[sessionID] = Task.detached {
            await previous?.value
            await op(act)
            await MainActor.run { [weak self] in
                guard let self, self.pendingTokens[sessionID] == token else { return }
                self.pendingWork[sessionID] = nil
                self.pendingTokens[sessionID] = nil
            }
        }
    }
}
