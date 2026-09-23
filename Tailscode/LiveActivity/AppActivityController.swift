import ActivityKit
import CodingAgentKit
import Foundation
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
@MainActor
final class AppActivityController {
    typealias State = ChatActivityAttributes.ContentState
    typealias Phase = State.Phase
    typealias PushTokenSink = @Sendable (String, Date) async -> Void

    static let shared = AppActivityController()

    private struct Entry {
        let activity: Activity<ChatActivityAttributes>
        var state: State
        var title: String?
        var pushedAt: Date
        var pushToken: String?
        var onPushToken: PushTokenSink?
        /// Ended — by this process or by a push — and possibly still on the Lock Screen, where only
        /// a read takes it down early.
        var retired = false
        var retirement: Task<Void, Never>?
        var watchers: [Task<Void, Never>] = []
    }

    private var entries: [String: Entry] = [:]
    private var pendingWork: [String: Task<Void, Never>] = [:]
    private var pendingTokens: [String: UUID] = [:]

    /// How long a live card may go unheard from before it admits it is waiting for news.
    private static let staleAfter: TimeInterval = 1800
    /// How often a live card that says the same thing is written again anyway, so its stale date
    /// moves on while the turn really is running.
    private static let refreshAfter: TimeInterval = 600

    /// Whether a card for the conversation is standing, live or settled.
    func isTracking(_ sessionID: String) -> Bool {
        guard var entry = entries[sessionID], !entry.retired else { return false }
        guard Self.isStanding(entry.activity) else {
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
    /// turn running.
    @discardableResult
    func start(
        sessionID: String, sessionTitle: String, serverName: String,
        onPushToken: PushTokenSink? = nil
    ) -> Bool {
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
                Task { await sink(token, startedAt) }
            }
            AppLogger.chat.info("Live Activity taken back for \(sessionID)")
            return true
        }
        guard AppPreferences.liveActivitiesEnabled else {
            AppLogger.chat.info("Live Activity disabled in settings")
            return false
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            AppLogger.chat.info("Live Activity not authorized")
            return false
        }
        if let lingering = entries[sessionID] {
            dismiss(sessionID, lingering)
        }
        if !ProStore.shared.isPro {
            let others = entries.filter { $0.key != sessionID && !$0.value.retired }
            guard others.allSatisfy({ current($0.key, $0.value).isSettled }) else {
                AppLogger.chat.info("second concurrent Live Activity gated (free tier)")
                return false
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
        let content = Self.content(state)
        let pushType: PushType? = onPushToken == nil ? nil : .token
        let activity: Activity<ChatActivityAttributes>
        do {
            activity = try Activity.request(attributes: attributes, content: content, pushType: pushType)
        } catch {
            guard Self.isFull(error), let oldest = oldestSettled() else {
                AppLogger.chat.error("Live Activity failed to start: \(error)")
                return false
            }
            AppLogger.chat.info("Live Activity refused (\(error)); making room")
            dismiss(oldest, entries[oldest])
            guard
                let retried = try? Activity.request(
                    attributes: attributes, content: content, pushType: pushType)
            else {
                AppLogger.chat.error("Live Activity failed to start: \(error)")
                return false
            }
            activity = retried
        }
        entries[sessionID] = Entry(
            activity: activity, state: state, pushedAt: startedAt, onPushToken: onPushToken)
        watch(activity, sessionID: sessionID)
        AppLogger.chat.info("Live Activity started for \(sessionID)")
        return true
    }

    /// What a running turn is doing now. A card that had settled is taken back — its conversation
    /// began another turn, sent from here or anywhere else — and its clock starts from the prompt
    /// that began it.
    func update(sessionID: String, reading: LiveActivityReading, title: String?) {
        guard isTracking(sessionID), var entry = entries[sessionID] else { return }
        if let title, !title.isEmpty { entry.title = title }
        let shown = current(sessionID, entry)
        let revived = shown.isSettled
        let startedAt = revived ? min(reading.startedAt ?? Date(), Date()) : shown.startedAt
        let toolCount = revived ? reading.toolCount : max(shown.toolCount, reading.toolCount)
        let state = Self.liveState(
            reading, startedAt: startedAt, toolCount: toolCount, title: entry.title)
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
                title: LocalizedStringResource("Approval needed"),
                body: LocalizedStringResource(
                    "\(entry.title ?? entry.activity.attributes.sessionTitle) is waiting for you."),
                sound: .default)
            : nil
        write(sessionID, entry.activity, state, alert: alert)
    }

    /// The turn ended: the card settles on how, and stays for somebody to read it. One that ends
    /// with its conversation on screen has been read already and goes at once.
    func settle(sessionID: String, reading: LiveActivityReading, title: String?, onScreen: Bool) {
        guard isTracking(sessionID), var entry = entries[sessionID] else { return }
        if onScreen, UIApplication.shared.applicationState == .active {
            AppLogger.chat.info("Live Activity read as it ended for \(sessionID)")
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
            background: reading.background > 0 ? reading.background : nil)
        entry.state = state
        entry.pushedAt = now
        entries[sessionID] = entry
        write(sessionID, entry.activity, state)
        scheduleRetirement(sessionID, settledAt: endedAt)
        AppLogger.chat.info(
            "Live Activity settled for \(sessionID) (\(reading.detail.rawValue))")
    }

    /// The conversation was looked at, which is what reads a card about it. A live card stays:
    /// the turn it follows is still running.
    func seen(_ sessionID: String) {
        guard let entry = entries[sessionID] else { return }
        guard entry.retired || current(sessionID, entry).isSettled else { return }
        AppLogger.chat.info("Live Activity read for \(sessionID)")
        dismiss(sessionID, entry)
    }

    /// Takes the conversation's card down at once, whatever it says — a send the person stopped
    /// before it went.
    func withdraw(_ sessionID: String) {
        guard let entry = entries[sessionID] else { return }
        dismiss(sessionID, entry)
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

    /// Takes up the cards a previous process left behind instead of sweeping them away: a turn
    /// that is still running keeps its card, and one that settled while nobody was here keeps
    /// waiting to be read. A second card for the same conversation — which only a crash between a
    /// request and its bookkeeping could leave — goes.
    func adoptStanding() {
        let visible = Activity<ChatActivityAttributes>.activities.filter {
            $0.activityState != .dismissed
        }
        var extras = Set<String>()
        for (sessionID, activities) in Dictionary(grouping: visible, by: \.attributes.sessionID)
        where entries[sessionID] == nil {
            let newestFirst = activities.sorted {
                $0.content.state.startedAt > $1.content.state.startedAt
            }
            let standing = newestFirst.filter(Self.isStanding)
            guard let kept = standing.first ?? newestFirst.first else { continue }
            extras.formUnion(activities.map(\.id).filter { $0 != kept.id })
            let state = kept.content.state
            entries[sessionID] = Entry(
                activity: kept, state: state, title: state.title, pushedAt: .distantPast,
                pushToken: kept.pushToken.map(Self.hex), retired: !Self.isStanding(kept))
            watch(kept, sessionID: sessionID)
            if Self.isStanding(kept), let endedAt = state.endedAt {
                scheduleRetirement(sessionID, settledAt: endedAt)
            }
            AppLogger.chat.info(
                "Live Activity adopted for \(sessionID) (\(state.isSettled ? "settled" : "live"))")
        }
        if !extras.isEmpty {
            Task.detached {
                for activity in Activity<ChatActivityAttributes>.activities
                where extras.contains(activity.id) {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
            }
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
        AppLogger.chat.info("Live Activity left the Dynamic Island for \(sessionID)")
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
        pendingWork[sessionID] == nil ? entry.activity.content.state : entry.state
    }

    /// Follows the card's own life: a token the server needs to reach it, and the moment a person
    /// swipes it away or the platform ends it, after which it is nobody's to write to.
    private func watch(_ activity: Activity<ChatActivityAttributes>, sessionID: String) {
        let id = activity.id
        let tokens = Task { [weak self] in
            for await token in activity.pushTokenUpdates {
                guard let self, var entry = self.entries[sessionID], entry.activity.id == id else {
                    return
                }
                let hex = Self.hex(token)
                entry.pushToken = hex
                self.entries[sessionID] = entry
                if let sink = entry.onPushToken {
                    let startedAt = self.current(sessionID, entry).startedAt
                    await sink(hex, startedAt)
                }
            }
        }
        let lifecycle = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard let self, var entry = self.entries[sessionID], entry.activity.id == id else {
                    return
                }
                if state == .dismissed {
                    self.forget(sessionID)
                    return
                }
                guard state == .ended, !entry.retired else { continue }
                entry.retired = true
                entry.retirement?.cancel()
                entry.retirement = nil
                self.entries[sessionID] = entry
            }
        }
        entries[sessionID]?.watchers = [tokens, lifecycle]
    }

    /// Whether the platform refused a card only because too many are standing — the one refusal
    /// that taking an old settled card down can answer.
    private static func isFull(_ error: Error) -> Bool {
        guard let refusal = error as? ActivityAuthorizationError else { return false }
        return refusal == .targetMaximumExceeded || refusal == .globalMaximumExceeded
    }

    private static func isStanding(_ activity: Activity<ChatActivityAttributes>) -> Bool {
        let state = activity.activityState
        return state == .active || state == .stale
    }

    private static func liveState(
        _ reading: LiveActivityReading, startedAt: Date, toolCount: Int, title: String?
    ) -> State {
        let face = reading.face
        return State(
            phase: phase(reading.detail),
            statusText: reading.detail.line(tool: reading.tool, toolCount: toolCount),
            lastTool: reading.tool, toolCount: toolCount, startedAt: startedAt, endedAt: nil,
            title: title, symbol: face.symbol, tone: face.tone.rawValue,
            detail: reading.detail.rawValue, background: nil)
    }

    /// Whether two states draw the same card. The words and the face are written from the detail
    /// on the phone, so a push that carries the server's English and no face of its own is the
    /// same card as the one written here, and is not written over again — nor is one whose clock
    /// lost its fraction of a second on the way through the server.
    private static func sameFacts(_ a: State, _ b: State) -> Bool {
        a.phase == b.phase && a.detail == b.detail && a.lastTool == b.lastTool
            && a.toolCount == b.toolCount && a.title == b.title && a.background == b.background
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

    private static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    private func write(
        _ sessionID: String, _ activity: Activity<ChatActivityAttributes>, _ state: State,
        alert: AlertConfiguration? = nil
    ) {
        let content = Self.content(state)
        let stamp = Date()
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
