import ActivityKit
import CodingAgentKit
import Foundation
import MidgarCore
import TailscodeCore
import UIKit

extension AppActivityController {
    /// What the platform is asked for when a card is started.
    struct CardRequest: @unchecked Sendable {
        let attributes: ChatActivityAttributes
        let content: ActivityContent<State>
        let pushType: PushType?
    }

    enum Asked: @unchecked Sendable {
        case started(Activity<ChatActivityAttributes>)
        case disabled
        case refused(any Error)
    }

    nonisolated static func ask(_ request: CardRequest) -> Asked {
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

    /// What ActivityKit says about one standing card, read together so the daemon is asked once.
    ///
    /// `@unchecked` because ActivityKit's handle is not declared `Sendable`, though its reads are
    /// made from any thread by design.
    struct Standing: @unchecked Sendable {
        let activity: Activity<ChatActivityAttributes>
        let sessionID: String
        let state: State
        let platform: ActivityState
        let pushToken: String?
    }

    struct Handles: @unchecked Sendable {
        let activities: [Activity<ChatActivityAttributes>]

        func endAll() async {
            for activity in activities { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    struct Card: @unchecked Sendable {
        let activity: Activity<ChatActivityAttributes>
    }

    struct Followed: @unchecked Sendable {
        let cards: [(String, Activity<ChatActivityAttributes>)]

        func read() -> [(String, String, State, ActivityState)] {
            cards.map { ($0.0, $0.1.id, $0.1.content.state, $0.1.activityState) }
        }
    }

    nonisolated static func readStanding() -> [Standing] {
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
    static func offMain<T: Sendable>(
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
}
