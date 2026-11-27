import ActivityKit
import Foundation
import TailscodeCore

/// One card `AppActivityController` follows: the platform's activity, what this process last wrote
/// and what the card last showed, and who asked for it.
@MainActor
struct AppActivityEntry {
    let activity: Activity<ChatActivityAttributes>
    var state: AppActivityController.State
    /// What the card last showed, kept here because ActivityKit answers a read by waiting on
    /// its daemon, and a main thread that waits on a daemon still starting after a boot is a
    /// main thread the watchdog ends. Moved by this process's own writes, by the card's
    /// content stream, and by `catchUp` for whatever a push said while nothing was listening.
    var card: AppActivityController.State
    var platform: ActivityState = .active
    var title: String?
    var pushedAt: Date
    var pushToken: String?
    var onPushToken: AppActivityController.PushTokenSink?
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
