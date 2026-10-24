import CodingAgentKit
import CodingAgentKitApple
import Foundation
import MidgarCore
import TailscodeCore
import UIKit

/// The one door into calling on the phone. It owns the process's single `VoiceCallDesk`, mirrors
/// what the desk knows into values the main thread can read without waiting on an actor, and keeps
/// the three things a call must never leave behind when it ends by any road: the screen held awake,
/// the microphone running, and a hang up nobody pressed when the app goes away.
@MainActor
final class VoiceCallGate {
    static let shared = VoiceCallGate()
    static let didChange = Notification.Name("tailscode.voicecall.didChange")

    let desk = VoiceCallDesk(secrets: KeychainSecretStore())

    private var reaches: [VoiceEndpoint: VoiceReach] = [:]
    private var reports: [VoiceEndpoint: [String]] = [:]
    private var running: ActiveCall?
    private var followTask: Task<Void, Never>?
    private var tasks: [Task<Void, Never>] = []

    private init() {
        tasks.append(
            Task { [weak self] in
                guard let desk = self?.desk else { return }
                for await change in desk.reachChanges() { self?.mirror(change.reach, for: change.endpoint) }
            })
        tasks.append(
            Task { [weak self] in
                guard let desk = self?.desk else { return }
                for await call in desk.activeChanges() { self?.follow(call) }
            })
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillTerminate),
            name: UIApplication.willTerminateNotification, object: nil)
    }

    /// Where the gateway for a profile's server is, or nil when the profile has no address a
    /// gateway could share.
    func endpoint(forProfile profileID: String) -> VoiceEndpoint? {
        let controller = ConnectionController.shared
        let profile = controller.profiles.first { $0.id == profileID } ?? controller.activeProfile
        return profile.flatMap { VoiceEndpoint(profileURL: $0.baseURL) }
    }

    func reach(for endpoint: VoiceEndpoint) -> VoiceReach {
        if endpoint.isDemo { return .ready(gateway: VoiceDemo.gatewayVersion) }
        return reaches[endpoint] ?? .unknown
    }

    func reportLines(for endpoint: VoiceEndpoint) -> [String] {
        reports[endpoint] ?? VoiceCallReport.lines(endpoint: endpoint, reach: reach(for: endpoint))
    }

    func hasCall(on endpoint: VoiceEndpoint) -> Bool { running?.endpoint == endpoint }

    func hasCall(inChat chat: String) -> Bool { running?.chat == chat }

    /// A chat on a server with a gateway asks to have its reach kept fresh while it is on screen.
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

    func hangUp(because reason: String) {
        guard running != nil else { return }
        MidgarLog.info("call hang up because \(reason)", category: .connection)
        Task { [desk] in await desk.hangUp() }
    }

    /// Hangs up the call for a chat that is being left, and only that chat's.
    func hangUp(chat: String, because reason: String) {
        guard running?.chat == chat else { return }
        hangUp(because: reason)
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
            setAwake(false)
            return
        }
        setAwake(true)
        MidgarLog.info(
            "call tracked chat=\(call.chat) host=\(call.endpoint.host)", category: .connection)
        followTask = Task { [weak self] in
            for await snapshot in call.snapshots where snapshot.end != nil { break }
            self?.finished(call)
        }
    }

    private func finished(_ call: ActiveCall) {
        refreshReport(for: call.endpoint)
        guard running === call else { return }
        running = nil
        setAwake(false)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private func setAwake(_ awake: Bool) {
        guard UIApplication.shared.isIdleTimerDisabled != awake else { return }
        UIApplication.shared.isIdleTimerDisabled = awake
        MidgarLog.info("call screen awake=\(awake)", category: .ui)
    }

    /// Whether the app declared that it keeps playing and recording with the screen off. Without
    /// it the system would take the microphone the moment the scene left the front, so the call is
    /// ended by hand instead of being left to die half open.
    private static var keepsAudioInBackground: Bool {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        return modes.contains("audio")
    }

    @objc private func sceneDidEnterBackground() {
        guard running != nil, !Self.keepsAudioInBackground else { return }
        hangUp(because: "the app left the front without the audio background mode")
    }

    @objc private func appWillTerminate() {
        guard running != nil else { return }
        setAwake(false)
        hangUp(because: "the app is terminating")
    }
}
