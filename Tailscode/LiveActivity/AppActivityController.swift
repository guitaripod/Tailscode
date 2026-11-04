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
        /// Ended — by this process or by a push — and possibly still on the Lock Screen, where only
        /// a read takes it down early.
        var retired = false
        var retirement: Task<Void, Never>?
        var watchers: [Task<Void, Never>] = []
    }

    private var entries: [String: Entry] = [:]
    private var pendingWork: [String: Task<Void, Never>] = [:]
    private var pendingTokens: [String: UUID] = [:]
    private var tokenHandoffs: [String: Task<Void, Never>] = [:]
    private var starting: [String: Deferred] = [:]
    /// Every surface showing a conversation and which one, held weakly and asked whether it is in
    /// a window when it matters, so a surface torn down without saying goodbye reads as gone.
    private let readers = NSMapTable<UIViewController, NSString>(
        keyOptions: .weakMemory, valueOptions: .strongMemory)

    /// How long a live card may go unheard from before it admits it is waiting for news.
    private static let staleAfter: TimeInterval = 1800
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
    func start(
        sessionID: String, sessionTitle: String, serverName: String,
        onPushToken: PushTokenSink? = nil
    ) {
        guard AppPreferences.liveActivitiesEnabled else {
            MidgarLog.info("Live Activity disabled in settings", category: .chat)
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
            guard others.allSatisfy({ current($0.key, $0.value).isSettled }) else {
                MidgarLog.info("second concurrent Live Activity gated (free tier)", category: .chat)
                return
            }
            for (other, entry) in others { dismiss(other, entry) }
        }
        let attributes = ChatActivityAttributes(
            sessionID: sessionID,
            sessionTitle: sessionTitle.isEmpty ? String(localized: "Agent session") : sessionTitle,
            serverName: serverName)
        let startedAt = Date()
        let state = Self.liveState(
            LiveActivityReading(detail: .thinking), startedAt: startedAt, toolCount: 0, title: nil)
        let request = CardRequest(
            attributes: attributes, content: Self.content(state),
            pushType: onPushToken == nil ? nil : .token)
        starting[sessionID] = Deferred()
        Task {
            await open(
                sessionID, request, state: state, startedAt: startedAt, onPushToken: onPushToken)
        }
    }

    /// What the platform is asked for when a card is started.
    private struct CardRequest: @unchecked Sendable {
        let attributes: ChatActivityAttributes
        let content: ActivityContent<State>
        let pushType: PushType?
    }

    private enum Asked: @unchecked Sendable {
        case started(Activity<ChatActivityAttributes>)
        case disabled
        case refused(any Error)
    }

    private nonisolated static func ask(_ request: CardRequest) -> Asked {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return .disabled }
        do {
            return .started(
                try Activity.request(
                    attributes: request.attributes, content: request.content,
                    pushType: request.pushType))
        } catch {
            return .refused(error)
        }
    }

    /// What the conversation did while its card was still being asked for, kept to be said to the
    /// card the moment it exists: a turn that ended in the time the platform took to answer must
    /// still settle the card it was about to get, and a conversation withdrawn in that time must
    /// not be left with one.
    private struct Deferred {
        var update: (reading: LiveActivityReading, title: String?)?
        var settle: (reading: LiveActivityReading, title: String?)?
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
        onPushToken: PushTokenSink?
    ) async {
        var answer = await Self.offMain("a new card") { Self.ask(request) }
        if case .refused(let error) = answer, Self.isFull(error), let oldest = oldestSettled() {
            MidgarLog.info("Live Activity refused (\(error)); making room", category: .chat)
            dismiss(oldest, entries[oldest])
            let retried = await Self.offMain("a new card") { Self.ask(request) }
            if case .started = retried { answer = retried }
        }
        let deferred = starting.removeValue(forKey: sessionID)
        switch answer {
        case .disabled:
            MidgarLog.info("Live Activity not authorized", category: .chat)
        case .refused(let error):
            MidgarLog.error("Live Activity failed to start: \(error)", category: .chat)
        case .started(let activity):
            guard AppPreferences.liveActivitiesEnabled, deferred?.withdrawn != true else {
                let ending = Handles(activities: [activity])
                Task.detached { await ending.endAll() }
                return
            }
            entries[sessionID] = Entry(
                activity: activity, state: state, card: state, pushedAt: startedAt,
                onPushToken: onPushToken)
            watch(activity, sessionID: sessionID)
            MidgarLog.info("Live Activity started for \(sessionID)", category: .chat)
            if let held = deferred?.update {
                update(sessionID: sessionID, reading: held.reading, title: held.title)
            }
            if let held = deferred?.settle {
                settle(sessionID: sessionID, reading: held.reading, title: held.title)
            }
        }
    }

    /// What a running turn is doing now. A card that had settled is taken back — its conversation
    /// began another turn, sent from here or anywhere else — and its clock starts from the prompt
    /// that began it. Only a turn that began after the card settled can do that: a running state
    /// that arrives late for the turn that already ended — a stream catching up after the phone
    /// slept, a resync replaying what it held — is not a new turn, and must not stand the card
    /// back up over an ending the bridge already told it about.
    func update(sessionID: String, reading: LiveActivityReading, title: String?) {
        if whileStarting(sessionID, { $0.update = (reading, title) }) { return }
        guard isTracking(sessionID), var entry = entries[sessionID] else { return }
        if let title, !title.isEmpty { entry.title = title }
        let shown = current(sessionID, entry)
        if let endedAt = shown.endedAt {
            guard let began = reading.startedAt, began > endedAt else {
                entries[sessionID] = entry
                return
            }
            MidgarLog.info(
                "Live Activity taken back by a turn begun elsewhere for \(sessionID)",
                category: .chat
            )
        }
        let revived = shown.isSettled
        let startedAt = revived ? min(reading.startedAt ?? Date(), Date()) : shown.startedAt
        let toolCount = revived ? reading.toolCount : max(shown.toolCount, reading.toolCount)
        let state = Self.liveState(
            reading, startedAt: startedAt, toolCount: toolCount, title: entry.title,
            carrying: revived ? nil : shown.glyph)
        let becameWaiting = reading.detail.wantsYou && (revived || shown.phase != .approval)
        let due = Date().timeIntervalSince(entry.pushedAt) > Self.refreshAfter
        guard becameWaiting || due || revived || !Self.sameFacts(state, shown) else {
            entries[sessionID] = entry
            return
        }
        if revived {
            entry.retirement?.cancel()
            entry.retirement = nil
        }
        entry.state = state
        entry.pushedAt = Date()
        entries[sessionID] = entry
        let alert: AlertConfiguration? =
            becameWaiting
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
    func settle(sessionID: String, reading: LiveActivityReading, title: String?) {
        if whileStarting(sessionID, { $0.settle = (reading, title) }) { return }
        guard isTracking(sessionID), var entry = entries[sessionID] else { return }
        if isBeingRead(sessionID) {
            MidgarLog.info("Live Activity read as it ended for \(sessionID)", category: .chat)
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
            glyph: reading.glyph ?? shown.glyph.map { $0.retoned(Self.eye(of: face.tone)) })
        guard !(shown.isSettled && Self.sameFacts(state, shown)) else {
            entries[sessionID] = entry
            scheduleRetirement(sessionID, settledAt: endedAt)
            return
        }
        entry.state = state
        entry.pushedAt = now
        entries[sessionID] = entry
        write(sessionID, entry.activity, state)
        scheduleRetirement(sessionID, settledAt: endedAt)
        MidgarLog.info(
            "Live Activity settled for \(sessionID) (\(reading.detail.rawValue))", category: .chat)
    }

    /// The conversation was looked at, which is what reads a card about it. A live card stays:
    /// the turn it follows is still running.
    func seen(_ sessionID: String) {
        guard let entry = entries[sessionID] else { return }
        guard entry.retired || current(sessionID, entry).isSettled else { return }
        MidgarLog.info("Live Activity read for \(sessionID)", category: .chat)
        dismiss(sessionID, entry)
    }

    /// Takes the conversation's card down at once, whatever it says — a send the person stopped
    /// before it went, or a conversation that no longer exists.
    func withdraw(_ sessionID: String) {
        if whileStarting(sessionID, { $0.withdrawn = true }) { return }
        guard let entry = entries[sessionID] else { return }
        dismiss(sessionID, entry)
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

    /// What ActivityKit says about one standing card, read together so the daemon is asked once.
    ///
    /// `@unchecked` because ActivityKit's handle is not declared `Sendable`, though its reads are
    /// made from any thread by design.
    private struct Standing: @unchecked Sendable {
        let activity: Activity<ChatActivityAttributes>
        let sessionID: String
        let state: State
        let platform: ActivityState
        let pushToken: String?
    }

    private struct Handles: @unchecked Sendable {
        let activities: [Activity<ChatActivityAttributes>]

        func endAll() async {
            for activity in activities { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private struct Card: @unchecked Sendable {
        let activity: Activity<ChatActivityAttributes>
    }

    private struct Followed: @unchecked Sendable {
        let cards: [(String, Activity<ChatActivityAttributes>)]

        func read() -> [(String, String, State, ActivityState)] {
            cards.map { ($0.0, $0.1.id, $0.1.content.state, $0.1.activityState) }
        }
    }

    private nonisolated static func readStanding() -> [Standing] {
        Activity<ChatActivityAttributes>.activities.compactMap { activity in
            let platform = activity.activityState
            guard platform != .dismissed else { return nil }
            return Standing(
                activity: activity, sessionID: activity.attributes.sessionID,
                state: activity.content.state, platform: platform,
                pushToken: activity.pushToken.map(hex))
        }
    }

    /// Runs a read of ActivityKit off the main thread and says so when it was slow. Its reads are
    /// synchronous waits on a daemon that is not always up — in the first minute after a boot it
    /// is not — and the main thread is never allowed to be the one waiting.
    private static func offMain<T: Sendable>(
        _ what: String, _ read: @escaping @Sendable () -> T
    ) async -> T {
        let began = Date()
        let value = await Task.detached(priority: .userInitiated, operation: read).value
        let took = Date().timeIntervalSince(began)
        if took > 1 {
            MidgarLog.info(
                "ActivityKit took \(Int(took * 1000)) ms to answer \(what)", category: .performance)
        }
        return value
    }

    /// Takes up the cards a previous process left behind instead of sweeping them away: a turn
    /// that is still running keeps its card, and one that settled while nobody was here keeps
    /// waiting to be read. A second card for the same conversation — which only a crash between a
    /// request and its bookkeeping could leave — goes.
    func adoptStanding() async {
        let visible = await Self.offMain("the standing cards") { Self.readStanding() }
        var extras: [Activity<ChatActivityAttributes>] = []
        for (sessionID, found) in Dictionary(grouping: visible, by: \.sessionID)
        where entries[sessionID] == nil {
            let newestFirst = found.sorted { $0.state.startedAt > $1.state.startedAt }
            let standing = newestFirst.filter { Self.isStanding($0.platform) }
            guard let kept = standing.first ?? newestFirst.first else { continue }
            extras += found.map(\.activity).filter { $0.id != kept.activity.id }
            entries[sessionID] = Entry(
                activity: kept.activity, state: kept.state, card: kept.state,
                platform: kept.platform, title: kept.state.title, pushedAt: .distantPast,
                pushToken: kept.pushToken, retired: !Self.isStanding(kept.platform))
            watch(kept.activity, sessionID: sessionID)
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
        retireExpired()
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

    private func oldestSettled() -> String? {
        entries
            .filter { current($0.key, $0.value).isSettled }
            .min { (current($0.key, $0.value).endedAt ?? .distantPast)
                < (current($1.key, $1.value).endedAt ?? .distantPast) }?
            .key
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
    private func watch(_ activity: Activity<ChatActivityAttributes>, sessionID: String) {
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
        followTokens(sessionID)
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

    /// Whether the platform refused a card only because too many are standing — the one refusal
    /// that taking an old settled card down can answer.
    private static func isFull(_ error: Error) -> Bool {
        guard let refusal = error as? ActivityAuthorizationError else { return false }
        return refusal == .targetMaximumExceeded || refusal == .globalMaximumExceeded
    }

    private static func isStanding(_ platform: ActivityState) -> Bool {
        platform == .active || platform == .stale
    }

    private static func liveState(
        _ reading: LiveActivityReading, startedAt: Date, toolCount: Int, title: String?,
        carrying glyph: NeuralGlyphWire? = nil
    ) -> State {
        let face = reading.face
        return State(
            phase: phase(reading.detail),
            statusText: reading.detail.line(tool: reading.tool, toolCount: toolCount),
            lastTool: reading.tool, toolCount: toolCount, startedAt: startedAt, endedAt: nil,
            title: title, symbol: face.symbol, tone: face.tone.rawValue,
            detail: reading.detail.rawValue, background: nil,
            glyph: reading.glyph ?? glyph.map { $0.retoned(eye(of: face.tone)) })
    }

    /// The tone the head's eye wears for a card whose state names only the face's meaning.
    private static func eye(of tone: ActivityTone) -> NeuralTone {
        NeuralTone(rawValue: tone.rawValue) ?? .quiet
    }

    /// Whether two states draw the same card. The words and the face are written from the detail
    /// on the phone, so a push that carries the server's English and no face of its own is the
    /// same card as the one written here, and is not written over again — nor is one whose clock
    /// lost its fraction of a second on the way through the server.
    private static func sameFacts(_ a: State, _ b: State) -> Bool {
        a.phase == b.phase && a.detail == b.detail && a.lastTool == b.lastTool
            && a.toolCount == b.toolCount && a.title == b.title && a.background == b.background
            && a.glyph == b.glyph
            && sameMoment(a.startedAt, b.startedAt) && a.isSettled == b.isSettled
            && sameMoment(a.endedAt ?? a.startedAt, b.endedAt ?? b.startedAt)
    }

    private static func sameMoment(_ a: Date, _ b: Date) -> Bool {
        abs(a.timeIntervalSince(b)) < 1
    }

    private static func phase(_ detail: LiveActivityDetail) -> Phase {
        Phase(rawValue: detail.phase) ?? .thinking
    }

    /// A live card goes stale when nothing has been heard for a while; a settled one never does,
    /// because an ending does not get older in any way a person needs warning of.
    private static func content(_ state: State) -> ActivityContent<State> {
        let detail = state.detail.flatMap(LiveActivityDetail.init(rawValue:))
        let relevance = detail?.relevance ?? (state.isSettled ? 10 : 50)
        return ActivityContent(
            state: state,
            staleDate: state.isSettled ? nil : Date().addingTimeInterval(staleAfter),
            relevanceScore: relevance)
    }

    private nonisolated static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
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
