import ActivityKit
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import MidgarCore
import TailscodeCore
import UIKit

/// Which installation this is, as a server following a conversation on several devices tells
/// their cards apart: the vendor identifier, or a name of its own kept on the device when the
/// system has none to give.
enum LiveActivityDevice {
    private static let key = "tailscode.liveActivity.deviceID"

    @MainActor
    static var id: String {
        if let vendor = UIDevice.current.identifierForVendor?.uuidString { return vendor }
        if let kept = UserDefaults.standard.string(forKey: key) { return kept }
        let made = UUID().uuidString
        UserDefaults.standard.set(made, forKey: key)
        return made
    }
}

/// ActivityKit's push-to-start token for this installation: what a server needs to start a card
/// here by itself, for a turn this device did not send. Kept so every bridge registration carries
/// the latest, and handed to the bridges again whenever it changes.
enum LiveActivityStartToken {
    private static let key = "tailscode.liveActivity.startToken"

    static var current: String? { UserDefaults.standard.string(forKey: key) }

    /// Follows the token for the life of the process, off the main thread like every other
    /// ActivityKit stream here.
    static func observe() {
        Task.detached(priority: .utility) {
            for await token in Activity<ChatActivityAttributes>.pushToStartTokenUpdates {
                let hex = token.map { String(format: "%02x", $0) }.joined()
                await MainActor.run { adopt(hex) }
            }
        }
    }

    @MainActor
    private static func adopt(_ hex: String) {
        guard current != hex else { return }
        UserDefaults.standard.set(hex, forKey: key)
        MidgarLog.info("Live Activity start token changed; handing it to the bridges", category: .chat)
        PushRegistrar.rulesChanged()
    }

    /// How a bridge on this profile may start cards here, or nil while there is no token to give.
    /// A person who turned the cards off, or turns started elsewhere, is still sent the token with
    /// `follows` off, so the bridge stops rather than going on with an older answer.
    @MainActor
    static func starter(for profile: ConnectionProfile) -> LiveActivityStarter? {
        guard let token = current else { return nil }
        let follows = AppPreferences.liveActivitiesEnabled && LiveActivitySettings.followsElsewhere
            && AppActivityController.allowed
        return LiveActivityStarter(
            token: token, deviceID: LiveActivityDevice.id, profileID: profile.id,
            profileName: profile.name, follows: follows,
            cardLimit: ProAccess.shared.hasProAccess ? nil : 1,
            muted: Array(AppPreferences.noticeRules.muted).sorted())
    }
}

extension AppActivityController {
    /// Where a card's update token goes: to the server holding the conversation, which keeps the
    /// card current while this process is asleep, with the person's choice for the ending and the
    /// installation it is on. A simulator build is unsigned, and asking for a token there refuses
    /// the card outright rather than starting one without it.
    static func tokenSink(
        backend: any CodingAgentBackend, sessionID: String, title: String
    ) -> PushTokenSink? {
        #if targetEnvironment(simulator)
            return nil
        #else
            return { token, startedAt in
                #if DEBUG
                    let environment = "development"
                #else
                    let environment = "production"
                #endif
                let (endAlert, deviceID) = await MainActor.run {
                    (Self.endAlert(sessionID: sessionID), LiveActivityDevice.id)
                }
                try? await backend.registerLiveActivity(
                    LiveActivityRegistration(
                        token: token, environment: environment, startedAt: startedAt, title: title,
                        endAlert: endAlert, deviceID: deviceID),
                    for: sessionID)
            }
        #endif
    }

    /// The sink for a card that names its profile, when this device still has that profile.
    static func tokenSink(profileID: String, sessionID: String, title: String) -> PushTokenSink? {
        guard
            let backend = ConnectionController.shared.allBackends()
                .first(where: { $0.profile.id == profileID })?.backend
        else { return nil }
        return tokenSink(backend: backend, sessionID: sessionID, title: title)
    }

    /// Whether the server holding the profile pushes the card's ending itself, alert included.
    static func serverAlerts(profileID: String) -> Bool {
        #if targetEnvironment(simulator)
            return false
        #else
            return PushRegistrar.covers(profileID: profileID)
        #endif
    }

    /// What the server that pushes the card is asked to do at the ending, read when the token is
    /// handed over so a change in Settings, a mute or the app coming forward reaches it with the
    /// next hand-over: nothing for a chat the person muted, or while the app is in front.
    static func endAlert(sessionID: String) -> String? {
        guard !AppPreferences.noticeRules.isMuted(sessionID), !shared.inFront else { return nil }
        return LiveActivitySettings.ending.wire
    }

    /// Follows every card started from now on, for the ones a server starts while the app is
    /// asleep: iOS starts the card and wakes the app, which takes it up and hands its token over.
    static func observeStarts() {
        Task.detached(priority: .utility) {
            for await activity in Activity<ChatActivityAttributes>.activityUpdates {
                let card = StartedCard(activity: activity)
                await shared.adoptStarted(card)
            }
        }
    }

    /// An activity handed over from ActivityKit's stream; its handle is not declared `Sendable`,
    /// though its reads are made from any thread by design.
    struct StartedCard: @unchecked Sendable {
        let activity: Activity<ChatActivityAttributes>
    }
}
