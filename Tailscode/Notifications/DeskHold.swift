import CodingAgentKit
import CodingAgentKitApple
import Foundation
import MidgarCore
import TailscodeCore
import UIKit
import UserNotifications

/// The phone's own half of quiet at the desk: a notice this device raises itself — for a server
/// that cannot push (opencode, omp-bridge, a bridge without a push key) — asks the servers whether
/// its person is at a computer first, and waits while they are. A bridge that pushes to this
/// device takes the notice and sends it once they leave (`POST /push/hold`); without one the
/// phone keeps it, and a background wait on a server that keeps desks (`GET /presence/wait`) wakes
/// the app when they leave. A notice whose chat a desk had on screen, or that was opened here,
/// since it was held is no longer news and goes nowhere. Coming back to the phone clears what
/// waits, here and on the bridges: the Missed list already holds it.
@MainActor
final class DeskHold {
    static let shared = DeskHold()

    private struct Held: Codable {
        var identifier: String
        var sessionID: String?
        var heldAt: Date
        var content: Data
    }

    /// A notice a bridge took, by the profile it was handed to.
    private struct Handed: Codable {
        var profileID: String
        var sessionID: String
        var identifier: String?
    }

    private static let storeKey = "tailscode.deskHold.held"
    private static let handedKey = "tailscode.deskHold.handed"
    private static let limit = 40
    /// A burst of endings asks the servers once.
    private static let answerKept: TimeInterval = 20

    private var held: [Held]
    private var handed: [Handed]
    private var answer: (value: DeskLookout.Answer?, at: Date)?
    /// Notices being decided right now, and the ones of them taken back while that ran.
    private var routing: Set<String> = []
    private var withdrawnWhileRouting: Set<String> = []
    /// How many times a desk wait came back unread in a row; a few, then what waits goes out.
    private var unreadWaits = 0
    private static let unreadWaitLimit = 3

    private init() {
        held = Self.load()
        handed = Self.loadHanded()
    }

    /// Whether the last look, still fresh, found the person at a computer — for an ending that
    /// has to decide at once, like a Live Activity's alert.
    var atDeskLately: Bool {
        guard let answer, Date().timeIntervalSince(answer.at) < 60,
            AppPreferences.noticeRules.quietAtDesk
        else { return false }
        return answer.value?.presence.occupied(awayAfter: AppPreferences.noticeRules.awayAfter) != nil
    }

    /// Sends the request now, or holds it while the person is at a computer.
    func route(_ request: UNNotificationRequest, holdable: Bool) {
        guard holdable, AppPreferences.noticeRules.quietAtDesk else {
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
            return
        }
        let box = HoldTaskBox()
        box.identifier = UIApplication.shared.beginBackgroundTask(withName: "DeskHold.route") {
            MainActor.assumeIsolated { box.end() }
        }
        let identifier = request.identifier
        routing.insert(identifier)
        Task { @MainActor in
            defer {
                routing.remove(identifier)
                withdrawnWhileRouting.remove(identifier)
                box.end()
            }
            let rules = AppPreferences.noticeRules
            let answer = await look()
            guard !withdrawnWhileRouting.contains(identifier),
                UIApplication.shared.applicationState != .active
            else { return }
            guard let waiter = answer?.waiter,
                let desk = answer?.presence.occupied(awayAfter: rules.awayAfter)
            else {
                UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
                return
            }
            if await handOff(request) {
                MidgarLog.info(
                    "desk: \(request.identifier) handed to a bridge while at \(desk.name)",
                    category: .lifecycle)
                return
            }
            hold(request)
            MidgarLog.info(
                "desk: held \(request.identifier) while at \(desk.name) (idle \(desk.idle ?? -1) s)",
                category: .lifecycle)
            await TurnWaitCenter.shared.armDeskWait(
                profileID: waiter.key, backend: waiter.backend, awayAfter: rules.awayAfter)
        }
    }

    /// A notice taken back before it was ever shown — work that started again, a question that
    /// was answered — is taken back from what waits too.
    func withdraw(_ identifiers: [String]) {
        let wanted = Set(identifiers)
        withdrawnWhileRouting.formUnion(routing.intersection(wanted))
        let before = held.count
        held.removeAll { wanted.contains($0.identifier) }
        if held.count != before { persist() }
        let taken = handed.filter { $0.identifier.map(wanted.contains) ?? false }
        guard !taken.isEmpty else { return }
        handed.removeAll { $0.identifier.map(wanted.contains) ?? false }
        persistHanded()
        Task { await self.markLooked(taken) }
    }

    /// The person is on the phone: what waited is in the Missed list, and banners now would be
    /// news about the screen in their hand.
    func cameForward() {
        if !held.isEmpty {
            MidgarLog.info(
                "desk: \(held.count) held notice(s) dropped, the app is in front", category: .lifecycle)
            held = []
            persist()
            TurnWaitCenter.shared.cancelDeskWait()
        }
        guard !handed.isEmpty else { return }
        let seen = handed
        handed = []
        persistHanded()
        Task { await self.markLooked(seen) }
    }

    /// Refreshes what is known about the desks as the app leaves the front, so an ending that has
    /// to decide at once — a Live Activity's alert — reads a fresh answer.
    func wentBack() {
        guard AppPreferences.noticeRules.quietAtDesk else { return }
        let box = HoldTaskBox()
        box.identifier = UIApplication.shared.beginBackgroundTask(withName: "DeskHold.look") {
            MainActor.assumeIsolated { box.end() }
        }
        Task { @MainActor in
            _ = await look(fresh: true)
            box.end()
        }
    }

    /// Tells each bridge that took a notice that its chat has been seen, in the words a desk uses
    /// for a look: a report from no desk, leaving at once, carrying the looks as made just now.
    /// A bridge that could not be told keeps its entries for the next chance.
    private func markLooked(_ seen: [Handed]) async {
        let phone = "phone-\(LiveActivityDevice.id)"
        var untold: [Handed] = []
        for (profileID, entries) in Dictionary(grouping: seen, by: \.profileID) {
            guard
                let profile = ConnectionController.shared.profiles.first(where: { $0.id == profileID }),
                let backend = ConnectionController.shared.makeBackend(for: profile)
            else { continue }
            let sessions = Array(Set(entries.map(\.sessionID)))
            let report = DeskReport(
                desk: phone, name: "", idle: nil, leaving: true, looked: sessions,
                lookedAgo: Dictionary(uniqueKeysWithValues: sessions.map { ($0, 0) }))
            if (try? await backend.reportDesk(report)) != true { untold += entries }
        }
        guard !untold.isEmpty else { return }
        handed += untold
        persistHanded()
    }

    /// Hands the notice to a bridge that pushes to this device, which holds it until the person
    /// leaves their desk. The first that takes it keeps it.
    private func handOff(_ request: UNNotificationRequest) async -> Bool {
        guard let token = PushRegistrar.activeToken else { return false }
        let content = request.content
        let notice = DeskHeldNotice(
            token: token, identifier: request.identifier, title: content.title, body: content.body,
            sessionID: content.userInfo["sessionID"] as? String,
            threadID: content.threadIdentifier.isEmpty ? nil : content.threadIdentifier,
            category: content.categoryIdentifier.isEmpty ? nil : content.categoryIdentifier,
            userInfo: Self.json(content.userInfo))
        var tried = Set<URL>()
        for entry in ConnectionController.shared.allBackends()
        where entry.profile.backend == .claudeCode
            && !entry.profile.id.hasPrefix(DemoWorld.profilePrefix)
            && tried.insert(entry.profile.baseURL).inserted
        {
            guard (try? await entry.backend.holdNotice(notice)) == true else { continue }
            if let sessionID = notice.sessionID {
                handed.append(
                    Handed(
                        profileID: entry.profile.id, sessionID: sessionID,
                        identifier: request.identifier))
                if handed.count > Self.limit { handed.removeFirst(handed.count - Self.limit) }
                persistHanded()
            }
            return true
        }
        return false
    }

    /// The fields a tap reads, as the one JSON object a bridge carries; whatever JSON cannot
    /// hold is left out.
    private static func json(_ userInfo: [AnyHashable: Any]) -> String? {
        var fields: [String: Any] = [:]
        for (key, value) in userInfo {
            guard let key = key as? String,
                JSONSerialization.isValidJSONObject(["value": value])
            else { continue }
            fields[key] = value
        }
        guard !fields.isEmpty, let data = try? JSONSerialization.data(withJSONObject: fields)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The background wait answered. Away, or a wait that could not be read, lets go of what is
    /// still news; a wait the server ended at its cap while the person is still there is held
    /// again.
    func waitAnswered(
        _ presence: DeskPresence?, profileID: String, backend: (any CodingAgentBackend)?
    ) async {
        guard !held.isEmpty else { return }
        let awayAfter = AppPreferences.noticeRules.awayAfter
        if let presence, presence.away != false {
            unreadWaits = 0
            release(looks: presence)
            return
        }
        if presence == nil {
            unreadWaits += 1
            let fresh = await look(fresh: true)
            guard unreadWaits < Self.unreadWaitLimit,
                fresh?.presence.occupied(awayAfter: awayAfter) != nil, let waiter = fresh?.waiter
            else {
                MidgarLog.info("desk: the wait came back unread and nobody is known to be at a desk", category: .lifecycle)
                unreadWaits = 0
                release(looks: fresh?.presence)
                return
            }
            await TurnWaitCenter.shared.armDeskWait(
                profileID: waiter.key, backend: waiter.backend, awayAfter: awayAfter)
            return
        }
        guard let backend else {
            release(looks: presence)
            return
        }
        await TurnWaitCenter.shared.armDeskWait(
            profileID: profileID, backend: backend, awayAfter: awayAfter)
    }

    private func release(looks presence: DeskPresence?) {
        guard !held.isEmpty else { return }
        let waiting = held
        held = []
        persist()
        guard UIApplication.shared.applicationState != .active else { return }
        let seen = SessionSeenStore.values()
        var sent = 0
        for notice in waiting {
            if let sessionID = notice.sessionID {
                if presence?.looked(at: sessionID, since: notice.heldAt) == true { continue }
                if let looked = seen[sessionID], looked >= notice.heldAt.timeIntervalSince1970 {
                    continue
                }
            }
            guard
                let content = try? NSKeyedUnarchiver.unarchivedObject(
                    ofClass: UNNotificationContent.self, from: notice.content)
            else { continue }
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: notice.identifier, content: content, trigger: nil))
            sent += 1
        }
        MidgarLog.info(
            "desk: the person left; \(sent) of \(waiting.count) held notice(s) were still news",
            category: .lifecycle)
    }

    private func hold(_ request: UNNotificationRequest) {
        let content = request.content.mutableCopy() as? UNMutableNotificationContent
        content?.attachments = content?.attachments.filter {
            FileManager.default.fileExists(atPath: $0.url.path)
        } ?? []
        guard let content,
            let data = try? NSKeyedArchiver.archivedData(
                withRootObject: content, requiringSecureCoding: true)
        else {
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
            return
        }
        held.removeAll { $0.identifier == request.identifier }
        held.append(
            Held(
                identifier: request.identifier,
                sessionID: request.content.userInfo["sessionID"] as? String, heldAt: Date(),
                content: data))
        if held.count > Self.limit {
            MidgarLog.info("desk: \(held.count - Self.limit) oldest held notice(s) dropped at the cap", category: .lifecycle)
            held.removeFirst(held.count - Self.limit)
        }
        persist()
    }

    /// What the servers this device holds know about desks, asked at most once a burst.
    func look(fresh: Bool = false) async -> DeskLookout.Answer? {
        if !fresh, let answer, Date().timeIntervalSince(answer.at) < Self.answerKept {
            return answer.value
        }
        var seen = Set<URL>()
        let servers = ConnectionController.shared.allBackends()
            .filter { entry in
                !entry.profile.id.hasPrefix(DemoWorld.profilePrefix)
                    && (entry.profile.backend == .claudeCode || entry.profile.backend == .omp)
                    && seen.insert(entry.profile.baseURL).inserted
            }
            .map { DeskServer(key: $0.profile.id, backend: $0.backend) }
        let found = await DeskLookout.ask(servers, awayAfter: AppPreferences.noticeRules.awayAfter)
        answer = (found, Date())
        return found
    }

    private func persist() {
        let defaults = UserDefaults.standard
        guard !held.isEmpty, let data = try? JSONEncoder().encode(held) else {
            defaults.removeObject(forKey: Self.storeKey)
            return
        }
        defaults.set(data, forKey: Self.storeKey)
    }

    private func persistHanded() {
        let defaults = UserDefaults.standard
        guard !handed.isEmpty, let data = try? JSONEncoder().encode(handed) else {
            defaults.removeObject(forKey: Self.handedKey)
            return
        }
        defaults.set(data, forKey: Self.handedKey)
    }

    private static func loadHanded() -> [Handed] {
        guard let data = UserDefaults.standard.data(forKey: handedKey),
            let handed = try? JSONDecoder().decode([Handed].self, from: data)
        else { return [] }
        return handed
    }

    private static func load() -> [Held] {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
            let held = try? JSONDecoder().decode([Held].self, from: data)
        else { return [] }
        return held.filter { Date().timeIntervalSince($0.heldAt) < 7 * 86400 }
    }
}

/// The background task a hold runs under, ended by whichever comes first: the decision, or the
/// system running out of patience.
private final class HoldTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UIBackgroundTaskIdentifier = .invalid

    var identifier: UIBackgroundTaskIdentifier {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    @MainActor
    func end() {
        let current = lock.withLock {
            let current = value
            value = .invalid
            return current
        }
        guard current != .invalid else { return }
        UIApplication.shared.endBackgroundTask(current)
    }
}
