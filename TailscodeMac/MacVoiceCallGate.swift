import AppKit
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import MidgarCore
import TailscodeCore

/// The one door into calling on the Mac. It owns the process's single `VoiceCallDesk`, mirrors what
/// the desk knows into values the main thread can read without waiting on an actor, and keeps the
/// things a call must never leave behind when it ends by any road: the microphone running, the Mac
/// held awake, and a hang up nobody pressed when the Mac sleeps or the app quits.
///
/// A call belongs to the pane that started it. Two panes may show one chat, and the one that did not
/// start the call neither draws it nor ends it.
@MainActor
final class MacVoiceCallGate {
    static let shared = MacVoiceCallGate()
    static let didChange = Notification.Name("tailscode.mac.voicecall.didChange")

    let desk = VoiceCallDesk(secrets: KeychainSecretStore())

    private var reaches: [VoiceEndpoint: VoiceReach] = [:]
    private var reports: [VoiceEndpoint: [String]] = [:]
    private var running: ActiveCall?
    private weak var owner: AnyObject?
    private var followTask: Task<Void, Never>?
    private var tasks: [Task<Void, Never>] = []
    private var awake: NSObjectProtocol?

    private init() {
        let desk = self.desk
        tasks.append(
            Task { [weak self] in
                for await change in desk.reachChanges() { self?.mirror(change.reach, for: change.endpoint) }
            })
        tasks.append(
            Task { [weak self] in
                for await call in desk.activeChanges() { self?.follow(call) }
            })
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(machineWillSleep), name: NSWorkspace.willSleepNotification,
            object: nil)
    }

    /// Where the gateway for a profile's server is, or nil when the profile has no address a
    /// gateway could share.
    func endpoint(forProfileID profileID: String) -> VoiceEndpoint? {
        ServerDirectory.shared.profiles.first { $0.id == profileID }
            .flatMap { VoiceEndpoint(profileURL: $0.baseURL) }
    }

    func reach(for endpoint: VoiceEndpoint) -> VoiceReach {
        if endpoint.isDemo { return .ready(gateway: VoiceDemo.gatewayVersion) }
        return reaches[endpoint] ?? .unknown
    }

    func reportLines(for endpoint: VoiceEndpoint) -> [String] {
        reports[endpoint] ?? VoiceCallReport.lines(endpoint: endpoint, reach: reach(for: endpoint))
    }

    func hasCall(on endpoint: VoiceEndpoint) -> Bool { running?.endpoint == endpoint }

    /// A pane showing a server with a gateway asks to have its reach kept fresh while it is live.
    func watch(_ endpoint: VoiceEndpoint) {
        Task { [desk] in
            await desk.watchReach(of: endpoint)
            let reach = await desk.reach(for: endpoint)
            self.mirror(reach, for: endpoint)
        }
    }

    func unwatch(_ endpoint: VoiceEndpoint) {
        Task { [desk] in await desk.unwatchReach(of: endpoint) }
    }

    /// The pane that is about to start a call, named before the desk has heard of it so that no
    /// moment exists in which a call is up and belongs to nobody.
    func claim(for owner: AnyObject) {
        self.owner = owner
    }

    func isOwner(_ candidate: AnyObject) -> Bool { owner === candidate }

    /// Hangs up the call the desk holds for a chat, asked of the desk itself rather than of the
    /// mirror so a call that is still opening is ended too. Only the pane that started it may.
    func hangUp(chat: String, ownedBy pane: AnyObject, because reason: String) {
        guard owner === pane else { return }
        MidgarLog.info("call hang up chat=\(chat) because \(reason)", category: .connection)
        Task { [desk] in
            guard let call = await desk.active, call.chat == chat else { return }
            await call.session.hangUp()
        }
    }

    /// Ends whatever call there is, whoever owns it: the audio failed, the Mac is going to sleep,
    /// the app is quitting.
    func hangUp(because reason: String) {
        MidgarLog.info("call hang up because \(reason)", category: .connection)
        Task { [desk] in await desk.hangUp() }
    }

    func prepareToQuit() {
        endHold()
        guard running != nil else { return }
        hangUp(because: "the app is quitting")
    }

    private func mirror(_ reach: VoiceReach, for endpoint: VoiceEndpoint) {
        if reaches[endpoint] != reach {
            reaches[endpoint] = reach
            refreshReport(for: endpoint)
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private func refreshReport(for endpoint: VoiceEndpoint) {
        Task { [desk] in
            let lines = await desk.reportLines(for: endpoint)
            self.reports[endpoint] = lines
        }
    }

    private func follow(_ call: ActiveCall?) {
        followTask?.cancel()
        running = call
        guard let call else {
            endHold()
            NotificationCenter.default.post(name: Self.didChange, object: nil)
            return
        }
        beginHold()
        MidgarLog.info(
            "call tracked chat=\(call.chat) host=\(call.endpoint.host)", category: .connection)
        followTask = Task { [weak self] in
            for await snapshot in call.snapshots where snapshot.end != nil { break }
            self?.finished(call)
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private func finished(_ call: ActiveCall) {
        refreshReport(for: call.endpoint)
        guard running === call else { return }
        running = nil
        endHold()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// A call dies with the Mac's sleep and with App Nap, so for as long as one is up the Mac is
    /// told it is doing something the person started; the screen may still sleep.
    private func beginHold() {
        guard awake == nil else { return }
        awake = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated], reason: "A Tailscode voice call is in progress")
        MidgarLog.info("call hold on", category: .ui)
    }

    private func endHold() {
        guard let token = awake else { return }
        ProcessInfo.processInfo.endActivity(token)
        awake = nil
        MidgarLog.info("call hold off", category: .ui)
    }

    @objc private func machineWillSleep() {
        guard running != nil else { return }
        hangUp(because: "the Mac is going to sleep")
    }
}
