import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore
import UIKit
import UserNotifications

/// The phone-held half of ``AppCapability/turnEndWhileAway``: one background-`URLSession` request
/// per running turn, answered only when it ends or needs the person, over the tailnet, with no
/// relay anywhere in the middle.
///
/// A task is armed while the app is still in front — a background session's task started there
/// runs at once, like a foreground request; one started after the app has already backgrounded is
/// merely discretionary and may never run at all — and is read back by whichever process is alive
/// when the daemon delivers the answer, this one or a fresh one the system launched to receive it.
/// Every wait is idempotent and carries no side effect, so two of them at once, a silent retry, or
/// one that simply drops is never a fault to fix, only a gap this device closes at the next chance.
@MainActor
final class TurnWaitCenter {
    static let shared = TurnWaitCenter()

    static let sessionIdentifier = "com.guitaripod.tailscode.turnwait"
    private static let maxConcurrentWaits = 8
    /// Comfortably past the bridges' own three-hour hold, so a `running` answer is read as the cap
    /// having been hit server-side rather than this session giving up first.
    private static let resourceTimeout: TimeInterval = 3 * 60 * 60 + 5 * 60

    private struct TaskInfo: Codable {
        var profileID: String
        var sessionID: String
        var backend: String
        var armedAt: Date
    }

    private struct Armed {
        let task: URLSessionTask
        let armedAt: Date
    }

    private let sessionDelegate = TurnWaitSessionDelegate()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.httpMaximumConnectionsPerHost = Self.maxConcurrentWaits
        config.timeoutIntervalForResource = Self.resourceTimeout
        return URLSession(configuration: config, delegate: sessionDelegate, delegateQueue: nil)
    }()

    private var armed: [String: Armed] = [:]
    /// Keys claimed between the synchronous decision to arm and `armAsync` actually storing an
    /// `Armed` entry — without this, two calls to `arm` for the same turn (`SessionActivity`
    /// noticing `.running` and `sceneWillResignActive` walking every running conversation, say)
    /// can both pass the `armed[key] == nil` check across the `await`s in between and open two
    /// wait requests for one turn.
    private var arming: Set<String> = []
    private var unsupportedProfiles: Set<String> = []
    private var retriedOnce: Set<String> = []
    private var pendingSystemCompletion: (() -> Void)?
    private var inFlight: [Task<Void, Never>] = []

    private(set) var lastCompletion: (sessionID: String, title: String?, state: String, at: Date)?

    private init() {
        sessionDelegate.center = self
    }

    /// Materializes the background session so its delegate reconnects to whatever the daemon is
    /// still holding for `sessionIdentifier` — an ordinary launch with waits still in flight, or
    /// one the system caused by delivering an answer. Idempotent: the session is a `lazy var`, so
    /// this only ever builds it once per process.
    func start() {
        _ = session
    }

    /// Called from `AppDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    /// The handler is called once every completion this wake delivered has become a notification, a
    /// settled Live Activity and a diagnostics line — never before, or the process may be suspended
    /// mid-write.
    func awaitBackgroundEvents(completion: @escaping () -> Void) {
        pendingSystemCompletion = completion
        start()
    }

    // MARK: Arming

    /// Every conversation this device is driving whose turn the server has confirmed is running,
    /// most recently active first.
    private func armableSessions() -> [ChatViewModel] {
        SessionActivity.shared.runningConversations.sorted {
            ($0.state.messages.last?.createdAt ?? .distantPast)
                > ($1.state.messages.last?.createdAt ?? .distantPast)
        }
    }

    /// Called from `sceneWillResignActive`: everything already running when the app leaves the
    /// foreground needs a wait armed for it now, because nothing else will tell this device when it
    /// ends.
    func armForBackground() {
        let sessions = armableSessions()
        for viewModel in sessions.prefix(Self.maxConcurrentWaits) {
            arm(profileID: viewModel.contextID, sessionID: viewModel.session.id, backend: viewModel.backend)
        }
        for viewModel in sessions.dropFirst(Self.maxConcurrentWaits) {
            AppLogger.lifecycle.info(
                "turnwait cap reached, not arming profile=\(viewModel.contextID) session=\(viewModel.session.id)"
            )
        }
    }

    /// One task per `(profileID, sessionID)` — a session already held, already known unsupported,
    /// or pressed against the cap is left alone. Safe to call for a turn seen running while the app
    /// is not active from anywhere: arming twice for the same turn is exactly what idempotent means
    /// here.
    func arm(profileID: String, sessionID: String, backend: any CodingAgentBackend) {
        let key = Self.key(profileID, sessionID)
        guard armed[key] == nil, !arming.contains(key), !unsupportedProfiles.contains(profileID)
        else { return }
        guard armed.count + arming.count < Self.maxConcurrentWaits else {
            AppLogger.lifecycle.info(
                "turnwait cap reached, not arming profile=\(profileID) session=\(sessionID)")
            return
        }
        arming.insert(key)
        inFlight.append(
            Task { [weak self] in
                await self?.armAsync(profileID: profileID, sessionID: sessionID, backend: backend)
            })
    }

    private func armAsync(profileID: String, sessionID: String, backend: any CodingAgentBackend) async {
        let key = Self.key(profileID, sessionID)
        defer { arming.remove(key) }
        let support = await backend.turnWaitSupport()
        guard support == .supported else {
            markUnsupported(profileID: profileID, support: support)
            return
        }
        guard let request = try? await backend.turnWaitRequest(for: sessionID) else { return }
        guard armed[key] == nil else { return }
        start()
        let kind =
            ConnectionController.shared.profiles.first { $0.id == profileID }?.backend.rawValue
            ?? "unknown"
        let info = TaskInfo(profileID: profileID, sessionID: sessionID, backend: kind, armedAt: Date())
        guard let description = Self.encode(info) else { return }
        let task: URLSessionTask
        if request.uploadsEmptyBody {
            task = session.uploadTask(with: request.request, fromFile: Self.emptyBodyFile())
        } else {
            task = session.downloadTask(with: request.request)
        }
        task.taskDescription = description
        armed[key] = Armed(task: task, armedAt: info.armedAt)
        retriedOnce.remove(key)
        task.resume()
        AppLogger.connection.info("turnwait armed profile=\(profileID) session=\(sessionID)")
    }

    /// The conversation was watched to its end from here, so the wait held for it is redundant —
    /// cancelled rather than left to complete on its own and risk a second, later notification.
    func cancel(sessionID: String) {
        for key in armed.keys where key.hasSuffix("|\(sessionID)") {
            let profileID = Self.profileID(fromKey: key)
            armed.removeValue(forKey: key)?.task.cancel()
            AppLogger.lifecycle.info(
                "turnwait cancelled profile=\(profileID) session=\(sessionID) (seen ending locally)"
            )
        }
    }

    private func markUnsupported(profileID: String, support: TurnWaitSupport) {
        guard !unsupportedProfiles.contains(profileID) else { return }
        unsupportedProfiles.insert(profileID)
        AppLogger.connection.info(
            "turnwait unsupported profile=\(profileID) reason=\(Self.describe(support))")
    }

    // MARK: Completion

    fileprivate func registerCompletion(
        description: String?, status: Int, headers: [String: String], data: Data, error: Error?
    ) {
        inFlight.append(
            Task { [weak self] in
                await self?.taskDidComplete(
                    description: description, status: status, headers: headers, data: data,
                    error: error)
            })
    }

    private func taskDidComplete(
        description: String?, status: Int, headers: [String: String], data: Data, error: Error?
    ) async {
        guard let description, let info = Self.decode(description) else {
            AppLogger.connection.error("turnwait completion carried no task info (status=\(status))")
            return
        }
        armed.removeValue(forKey: Self.key(info.profileID, info.sessionID))
        guard
            let profile = ConnectionController.shared.profiles.first(where: {
                $0.id == info.profileID
            }),
            let backend = ConnectionController.shared.makeBackend(for: profile)
        else {
            AppLogger.connection.info(
                "turnwait completion for a profile no longer on this device: \(info.profileID)")
            return
        }
        if let error {
            handleTransportFailure(info: info, error: error, backend: backend)
            return
        }
        do {
            let result = try await backend.turnWaitResult(
                status: status, headers: headers, body: data, sessionID: info.sessionID)
            await apply(result, info: info, profile: profile, backend: backend)
        } catch let agentError as AgentError {
            if case .http(let code, _) = agentError, code == 401 || code == 404 {
                markUnsupported(profileID: info.profileID, support: .serverTooOld)
            } else {
                AppLogger.connection.error(
                    "turnwait result error profile=\(info.profileID) session=\(info.sessionID): \(agentError)"
                )
                rearmAfterFailure(info: info, backend: backend)
            }
        } catch {
            AppLogger.connection.error(
                "turnwait decode failed profile=\(info.profileID) session=\(info.sessionID): \(error)"
            )
            rearmAfterFailure(info: info, backend: backend)
        }
    }

    /// A dropped connection is unknown, never an ending: a Tailscale tunnel reconfiguration or a
    /// force-quit can both kill the socket outright, and only the second of those should stay
    /// silent forever.
    private func handleTransportFailure(info: TaskInfo, error: Error, backend: any CodingAgentBackend) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled,
            nsError.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] != nil
        {
            AppLogger.lifecycle.info(
                "turnwait cancelled by the system (force-quit or Background App Refresh off) profile=\(info.profileID) session=\(info.sessionID)"
            )
            return
        }
        AppLogger.connection.info(
            "turnwait transport failure profile=\(info.profileID) session=\(info.sessionID): \(error.localizedDescription)"
        )
        rearmAfterFailure(info: info, backend: backend)
    }

    private func rearmAfterFailure(info: TaskInfo, backend: any CodingAgentBackend) {
        guard UIApplication.shared.applicationState != .active else { return }
        let key = Self.key(info.profileID, info.sessionID)
        guard !retriedOnce.contains(key) else {
            AppLogger.lifecycle.info(
                "turnwait already retried once, not arming again profile=\(info.profileID) session=\(info.sessionID)"
            )
            return
        }
        retriedOnce.insert(key)
        arm(profileID: info.profileID, sessionID: info.sessionID, backend: backend)
    }

    private func apply(
        _ result: TurnWaitResult, info: TaskInfo, profile: ConnectionProfile,
        backend: any CodingAgentBackend
    ) async {
        switch result.state {
        case .running:
            AppLogger.lifecycle.info(
                "turnwait still running, re-arming profile=\(info.profileID) session=\(info.sessionID)"
            )
            guard UIApplication.shared.applicationState != .active else { return }
            arm(profileID: info.profileID, sessionID: info.sessionID, backend: backend)
        case .ended, .needsYou:
            await complete(result, info: info, profile: profile)
        }
    }

    private func complete(_ result: TurnWaitResult, info: TaskInfo, profile: ConnectionProfile) async {
        lastCompletion = (
            sessionID: info.sessionID, title: result.title, state: result.state.rawValue, at: Date()
        )
        let detail =
            result.ending.flatMap { LiveActivityDetail(rawValue: $0.rawValue) }
            ?? (result.state == .needsYou ? .question : .lost)
        let toolCount = result.toolCount ?? 0
        let background = result.background ?? 0
        let body = detail.line(tool: nil, toolCount: toolCount, background: background)
        let title = MissedActivity.name(title: result.title ?? "", latestPrompt: nil)
        let onScreen = UIApplication.shared.applicationState == .active
        AppActivityController.shared.settle(
            sessionID: info.sessionID,
            reading: LiveActivityReading(
                detail: detail, toolCount: toolCount, background: background,
                endedAt: result.endedAt),
            title: result.title, onScreen: onScreen)

        if result.state == .ended, PushRegistrar.covers(profileID: info.profileID) {
            AppLogger.lifecycle.info(
                "turnwait ended profile=\(info.profileID) session=\(info.sessionID); the bridge's own push covers it"
            )
            recordMissedIfAway(
                identifier: "done:\(info.sessionID)", profileID: info.profileID,
                sessionID: info.sessionID, title: title, body: body, reason: .turnEnded)
            return
        }

        guard !(await alreadyNotified(sessionID: info.sessionID, since: info.armedAt)) else {
            AppLogger.lifecycle.info(
                "turnwait profile=\(info.profileID) session=\(info.sessionID) already notified since it was armed; skipping"
            )
            return
        }

        let (kind, identifier, reason) = Self.notification(for: result, sessionID: info.sessionID)
        NotificationManager.notify(
            kind: kind, title: title, body: body, identifier: identifier,
            sessionID: info.sessionID, profileID: info.profileID, activity: reason)
        AppLogger.lifecycle.info(
            "turnwait posted for profile=\(info.profileID) session=\(info.sessionID) (\(result.state))")
    }

    private static func notification(for result: TurnWaitResult, sessionID: String) -> (
        NotificationManager.Kind, String, MissedActivity.Reason
    ) {
        switch (result.state, result.ending) {
        case (.needsYou, .approval):
            return (.approval, "turnwait-approval:\(sessionID)", .needsApproval)
        case (.needsYou, _):
            return (.question, "turnwait-question:\(sessionID)", .needsAnswer)
        default:
            let reason: MissedActivity.Reason = result.ending == .failed ? .turnFailed : .turnEnded
            return (.turnComplete, "done:\(sessionID)", reason)
        }
    }

    /// Mirrors the local-notification path's own bookkeeping for a turn a remote push already
    /// covers: still worth remembering in the inbox, never worth a second banner.
    private func recordMissedIfAway(
        identifier: String, profileID: String, sessionID: String, title: String, body: String,
        reason: MissedActivity.Reason
    ) {
        guard AppPreferences.notifyTurnComplete, UIApplication.shared.applicationState != .active
        else { return }
        ActivityInbox.record([
            MissedActivity(
                identifier: identifier, profileID: profileID, sessionID: sessionID, title: title,
                body: body, reason: reason)
        ])
    }

    /// Whether this session already has a delivered notification raised since the wait was armed —
    /// the in-process live-stream path and this background wait can both notice the same ending,
    /// and only one of them may say so.
    private func alreadyNotified(sessionID: String, since: Date) async -> Bool {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        return delivered.contains { notice in
            notice.date >= since
                && notice.request.content.userInfo["sessionID"] as? String == sessionID
        }
    }

    // MARK: Background wake bookkeeping

    fileprivate func finishBackgroundEvents() {
        guard let completion = pendingSystemCompletion else { return }
        pendingSystemCompletion = nil
        let handles = inFlight
        inFlight.removeAll()
        let box = BackgroundTaskBox()
        box.identifier = UIApplication.shared.beginBackgroundTask(withName: "TurnWaitCenter.finish") {
            MainActor.assumeIsolated { box.end() }
        }
        Task {
            for handle in handles { await handle.value }
            completion()
            box.end()
        }
    }

    // MARK: Diagnostics

    var armedDescriptions: [String] {
        armed.keys.sorted().map { $0.replacingOccurrences(of: "|", with: " → ") }
    }

    var lastCompletionDescription: String? {
        guard let lastCompletion else { return nil }
        return
            "\(lastCompletion.sessionID) — \(lastCompletion.state) at \(lastCompletion.at.formatted(date: .omitted, time: .shortened))"
    }

    // MARK: Encoding

    private static func key(_ profileID: String, _ sessionID: String) -> String {
        "\(profileID)|\(sessionID)"
    }

    private static func profileID(fromKey key: String) -> String {
        String(key.split(separator: "|", maxSplits: 1).first ?? "")
    }

    private static let coder: (encoder: JSONEncoder, decoder: JSONDecoder) = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (encoder, decoder)
    }()

    private static func encode(_ info: TaskInfo) -> String? {
        (try? coder.encoder.encode(info)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func decode(_ text: String) -> TaskInfo? {
        text.data(using: .utf8).flatMap { try? coder.decoder.decode(TaskInfo.self, from: $0) }
    }

    private static func emptyBodyFile() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "turnwait-empty-body")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        return url
    }

    private static func describe(_ support: TurnWaitSupport) -> String {
        switch support {
        case .supported: return "supported"
        case .serverTooOld: return "serverTooOld"
        case .unavailable(.generation): return "unavailable(generation)"
        case .unavailable(.none): return "unavailable(none)"
        }
    }
}

extension TurnWaitAvailability {
    /// Translates the Kit's own verdict into the words Core owns — Core is pinned behind the Kit
    /// version this capability shipped in, so this mapping lives here rather than there.
    /// `.unavailable(.none)` is the protocol-extension default for a backend that never overrides
    /// any of this (nothing this app talks to takes that road today), read as `.unknown` since
    /// Core's vocabulary has no case for "no server to wait on at all".
    static func from(_ support: TurnWaitSupport, agent: AgentType) -> TurnWaitAvailability {
        switch support {
        case .supported: return .waits
        case .serverTooOld: return .serverTooOld(product: UpdateProduct.name(for: agent))
        case .unavailable(.generation): return .openCodeGeneration
        case .unavailable(.none): return .unknown
        }
    }
}

/// Ends the one background task `finishBackgroundEvents` opens to cover its async cleanup, from
/// whichever of its two callers gets there first — the expiration handler, if the cleanup
/// overruns, or the ordinary completion path once every wait has resolved. A class rather than a
/// captured local: a `UIBackgroundTaskIdentifier` variable written after being captured by the
/// expiration handler's `@Sendable` closure is a data race by the compiler's own reading, even
/// though both callers reach this in practice from the main thread.
private final class BackgroundTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UIBackgroundTaskIdentifier = .invalid

    var identifier: UIBackgroundTaskIdentifier {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }

    /// `beginBackgroundTask`'s own expiration handler is documented to run synchronously on the
    /// main thread, which is what lets `MainActor.assumeIsolated` call this from it directly.
    @MainActor
    func end() {
        lock.lock()
        let current = value
        value = .invalid
        lock.unlock()
        guard current != .invalid else { return }
        UIApplication.shared.endBackgroundTask(current)
    }
}

/// Forwards background-session callbacks to `TurnWaitCenter` on the main actor. A plain `NSObject`
/// rather than the center itself, since `URLSessionDelegate` conformance requires one and its
/// methods arrive on the session's own delegate queue, never the main actor.
private final class TurnWaitSessionDelegate: NSObject, URLSessionDataDelegate,
    URLSessionDownloadDelegate, @unchecked Sendable
{
    weak var center: TurnWaitCenter?

    private let lock = NSLock()
    private var buffers: [Int: Data] = [:]

    /// The wait's response body arrives as ordinary streamed data — a heartbeat's blank lines
    /// followed eventually by the real JSON — for the upload tasks opencode's POST route rides.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        buffers[dataTask.taskIdentifier, default: Data()].append(data)
        lock.unlock()
    }

    /// The GET routes ride a download task, whose body lands in a temp file the system deletes the
    /// moment this method returns — read in full before that happens.
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let data = (try? Data(contentsOf: location)) ?? Data()
        lock.lock()
        buffers[downloadTask.taskIdentifier] = data
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let data = buffers.removeValue(forKey: task.taskIdentifier) ?? Data()
        lock.unlock()
        let response = task.response as? HTTPURLResponse
        let status = response?.statusCode ?? -1
        var headers: [String: String] = [:]
        for (key, value) in response?.allHeaderFields ?? [:] {
            if let key = key as? String { headers[key] = "\(value)" }
        }
        let description = task.taskDescription
        Task { @MainActor [center] in
            center?.registerCompletion(
                description: description, status: status, headers: headers, data: data, error: error)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [center] in
            center?.finishBackgroundEvents()
        }
    }
}
