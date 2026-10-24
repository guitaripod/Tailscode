import GameKit
import MidgarCore
import TailscodeCore
import UIKit

/// Apple's Game Center behind the trophy case. The catalog, the percentages and every word are
/// Core's (`TrophyRoom` riding `UsageAnalytics`); this coordinator only carries them out — it
/// signs in only for a person who turned Game Center on (`GameCenterConsent`), reports changed
/// percentages whenever an analytics haul lands, submits the window's scores to the
/// leaderboards, and opens Apple's own dashboard. Reporting is deduplicated per player so a
/// pull-to-refresh costs no requests, and nothing here is ever a wall: with no account the
/// trophy case still renders whole from Core.
///
/// Authenticating is what makes iOS raise its "Sign in to Game Center" banner over whatever is on
/// screen, so it never happens for a person who did not ask, and a sign-in that GameKit offers
/// when nobody just asked for one turns Game Center back off instead of raising the banner again.
@MainActor
final class GameCenterCoordinator: NSObject {
    static let shared = GameCenterCoordinator()

    static let standingChanged = Notification.Name("tailscode.gamecenter.standing")

    enum Standing {
        case off
        case unknown
        case ready
        case needsSignIn
        case unavailable(GameCenterReading)
    }

    private(set) var standing: Standing
    private var signInSheet: UIViewController?
    private weak var presenter: UIViewController?
    private var requested = false
    private var latest: UsageAnalytics?
    private var started = false
    private var waiting = false
    private let consent = GameCenterConsent.shared

    private override init() {
        standing = GameCenterConsent.shared.isOn ? .unknown : .off
        super.init()
    }

    /// How long after the app is first in front or first behind the user the sign-in waits, so the
    /// first frames of the first screen are never drawn beside Game Center's own start-up.
    private static let settleDelay: Duration = .milliseconds(500)

    private static let reportedKey = "tailscode.gamecenter.reported"
    private static let scoresKey = "tailscode.gamecenter.scores"
    private static let playerKey = GameCenterConsent.reportedPlayerKey

    /// Starts Game Center once the first screen has been drawn rather than inside launch, and only
    /// for a person who has it on.
    ///
    /// Authenticating spends the launch's main-thread budget on an account the first screen does
    /// not need, and nothing here is a wall. Waits for the app's first activation, then a moment
    /// more; an app launched straight into the background has no first frame to wait for and
    /// starts on the next turn, and one sent to the background before it was ever active starts
    /// then. Whichever of those comes first runs `start()`, which runs once.
    func startWhenIdle() {
        guard consent.isOn, !started, !waiting else { return }
        waiting = true
        if UIApplication.shared.applicationState == .background {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.start() } }
            return
        }
        let center = NotificationCenter.default
        nonisolated(unsafe) var tokens: [NSObjectProtocol] = []
        let fire: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated {
                tokens.forEach { center.removeObserver($0) }
                tokens = []
                Task {
                    try? await Task.sleep(for: Self.settleDelay)
                    self.start()
                }
            }
        }
        tokens = [
            UIApplication.didBecomeActiveNotification, UIApplication.didEnterBackgroundNotification,
        ].map { center.addObserver(forName: $0, object: nil, queue: .main, using: fire) }
    }

    func start() {
        guard consent.isOn, !started else { return }
        started = true
        GKLocalPlayer.local.authenticateHandler = { viewController, error in
            Task { @MainActor in
                self.authenticated(viewController: viewController, error: error)
            }
        }
    }

    /// Every road that fetches the month passes its merge through here; whether it is reported
    /// now or held for a later sign-in is this coordinator's business, not the caller's.
    func note(_ analytics: UsageAnalytics?) {
        guard let analytics else { return }
        latest = analytics
        if case .ready = standing {
            report(analytics)
        }
    }

    /// The one gesture the surface offers: the dashboard when signed in, the sign-in sheet when
    /// Apple handed one over, turning Game Center on when it is off, and nothing when Game Center
    /// itself said no — the card already carries the reason in words.
    func openDashboard(from presenter: UIViewController) {
        switch standing {
        case .off:
            connect(from: presenter)
        case .ready:
            let dashboard = GKGameCenterViewController(state: .achievements)
            dashboard.gameCenterDelegate = self
            presenter.present(dashboard, animated: true)
        case .needsSignIn:
            if let sheet = signInSheet {
                presenter.present(sheet, animated: true)
            }
        case .unknown, .unavailable:
            break
        }
    }

    /// The person asked for Game Center, so the sign-in Apple hands over next is theirs to see:
    /// it is presented on `presenter` the moment it arrives.
    private func connect(from presenter: UIViewController) {
        consent.turnOn()
        self.presenter = presenter
        requested = true
        standing = .unknown
        start()
        NotificationCenter.default.post(name: Self.standingChanged, object: nil)
    }

    /// Takes Game Center back out of the app: nothing authenticates on the next launch and
    /// nothing more is reported.
    func turnOff() {
        consent.turnOff()
        GKLocalPlayer.local.authenticateHandler = nil
        presenter = nil
        requested = false
        signInSheet = nil
        started = false
        waiting = false
        standing = .off
        MidgarLog.info("gamecenter: turned off", category: .session)
        NotificationCenter.default.post(name: Self.standingChanged, object: nil)
    }

    var actionTitle: String? {
        switch standing {
        case .off: return String(localized: "Connect Game Center")
        case .ready: return String(localized: "Game Center")
        case .needsSignIn: return String(localized: "Sign in to Game Center")
        case .unknown, .unavailable: return nil
        }
    }

    var turnOffTitle: String? {
        switch standing {
        case .ready, .needsSignIn, .unavailable: return String(localized: "Turn off Game Center")
        case .off, .unknown: return nil
        }
    }

    /// GameKit's refusal, turned into one of the four states Core has words for. The error's own
    /// text is kept for the log and never for the screen.
    private static func reading(for error: Error?) -> GameCenterReading {
        guard let error = error as NSError? else {
            return GameCenterReading.read(domain: nil, code: 0, description: "")
        }
        return GameCenterReading.read(
            domain: error.domain, code: error.code, description: error.localizedDescription)
    }

    var statusLine: String? {
        switch standing {
        case .off: return GameCenterReading.off.line
        case .unavailable(let reading): return reading.line
        case .unknown, .ready, .needsSignIn: return nil
        }
    }

    private func authenticated(viewController: UIViewController?, error: Error?) {
        let wasRequested = requested
        requested = false
        if let viewController {
            guard wasRequested else {
                withdrawUnasked()
                return
            }
            signInSheet = viewController
            standing = .needsSignIn
            presenter?.present(viewController, animated: true)
        } else if GKLocalPlayer.local.isAuthenticated {
            signInSheet = nil
            standing = .ready
            GKAccessPoint.shared.isActive = false
            if let latest {
                report(latest)
            }
        } else {
            signInSheet = nil
            standing = .unavailable(Self.reading(for: error))
        }
        MidgarLog.info(
            "gamecenter: standing \(String(describing: self.standing))", category: .session)
        NotificationCenter.default.post(name: Self.standingChanged, object: nil)
    }

    /// GameKit offered a sign-in nobody just asked for — the banner is on its way or already up —
    /// so Game Center goes back to off and does not ask again on the next launch or return.
    private func withdrawUnasked() {
        MidgarLog.info("gamecenter: sign-in offered unasked, turning off", category: .session)
        turnOff()
    }

    /// Game Center keeps the best value it has ever been told, so the only mistake possible is
    /// wasted requests — a per-player cache forwards a trophy only when its percentage grew and
    /// a score only when it beat the one already sent.
    private func report(_ analytics: UsageAnalytics) {
        let defaults = UserDefaults.standard
        let player = GKLocalPlayer.local.gamePlayerID
        if defaults.string(forKey: Self.playerKey) != player {
            defaults.set(player, forKey: Self.playerKey)
            defaults.removeObject(forKey: Self.reportedKey)
            defaults.removeObject(forKey: Self.scoresKey)
        }
        let reported = defaults.dictionary(forKey: Self.reportedKey) as? [String: Double] ?? [:]
        let submitted = defaults.dictionary(forKey: Self.scoresKey) as? [String: Int] ?? [:]

        let grown = analytics.trophies.filter { $0.percent > (reported[$0.id] ?? 0) + 0.5 }
        let achievements = grown.map { trophy in
            let achievement = GKAchievement(identifier: trophy.id)
            achievement.percentComplete = trophy.percent
            achievement.showsCompletionBanner = true
            return achievement
        }
        let beaten = analytics.scores.filter { $0.value > (submitted[$0.leaderboardID] ?? 0) }
        guard !achievements.isEmpty || !beaten.isEmpty else { return }

        Task {
            do {
                if !achievements.isEmpty {
                    try await GKAchievement.report(achievements)
                    var reported = reported
                    for trophy in grown { reported[trophy.id] = trophy.percent }
                    defaults.set(reported, forKey: Self.reportedKey)
                }
                var submitted = submitted
                for score in beaten {
                    try await GKLeaderboard.submitScore(
                        score.value, context: 0, player: GKLocalPlayer.local,
                        leaderboardIDs: [score.leaderboardID])
                    submitted[score.leaderboardID] = score.value
                }
                defaults.set(submitted, forKey: Self.scoresKey)
                MidgarLog.info(
                    "gamecenter: reported \(achievements.count) trophies, \(beaten.count) scores", category: .session)
            } catch {
                MidgarLog.error(
                    "gamecenter: report failed: \(error.localizedDescription)", category: .session)
            }
        }
    }
}

extension GameCenterCoordinator: GKGameCenterControllerDelegate {
    nonisolated func gameCenterViewControllerDidFinish(
        _ gameCenterViewController: GKGameCenterViewController
    ) {
        Task { @MainActor in
            gameCenterViewController.dismiss(animated: true)
        }
    }
}
