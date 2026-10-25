import AppKit
import GameKit
import TailscodeCore

/// Apple's Game Center behind the Mac's trophy case — the same contract as the phone's
/// coordinator: Core scores the merge (`TrophyRoom` riding `UsageAnalytics`), this object only
/// carries it out. Nothing authenticates until the person turns Game Center on
/// (`GameCenterConsent`), and a sign-in GameKit offers when nobody just asked for one turns it
/// back off rather than raise Apple's banner again. Sign-in is never a wall; a dev build signed
/// ad-hoc cannot authenticate at all, and that becomes a stated line on the card rather than a
/// hidden card.
@MainActor
final class MacGameCenter: NSObject {
    static let shared = MacGameCenter()

    static let standingChanged = Notification.Name("tailscode.gamecenter.standing")

    enum Standing {
        case off
        case unknown
        case ready
        case needsSignIn
        case unavailable(GameCenterReading)
    }

    private(set) var standing: Standing
    private var signInSheet: NSViewController?
    private weak var presenter: NSWindow?
    private var requested = false
    private var latest: UsageAnalytics?
    private var started = false
    private let consent = GameCenterConsent.shared

    private override init() {
        standing = GameCenterConsent.shared.isOn ? .unknown : .off
        super.init()
    }

    private static let reportedKey = "tailscode.gamecenter.reported"
    private static let scoresKey = "tailscode.gamecenter.scores"
    private static let playerKey = GameCenterConsent.reportedPlayerKey

    func start() {
        #if DEBUG
            guard !LiveShot.holdsBack("Game Center") else { return }
        #endif
        guard consent.isOn, !started else { return }
        started = true
        GKLocalPlayer.local.authenticateHandler = { viewController, error in
            Task { @MainActor in
                self.authenticated(viewController: viewController, error: error)
            }
        }
    }

    /// Every analytics fetch passes its merge through here; whether it is reported now or held
    /// for a later sign-in is this object's business, not the window's.
    func note(_ analytics: UsageAnalytics?) {
        guard let analytics else { return }
        latest = analytics
        if case .ready = standing {
            report(analytics)
        }
    }

    func openDashboard(from window: NSWindow?) {
        switch standing {
        case .off:
            connect(from: window)
        case .ready:
            let dashboard = GKGameCenterViewController(state: .achievements)
            dashboard.gameCenterDelegate = self
            let dialog = GKDialogController.shared()
            dialog.parentWindow = window
            dialog.present(dashboard)
        case .needsSignIn:
            if let sheet = signInSheet {
                window?.contentViewController?.presentAsSheet(sheet)
            }
        case .unknown, .unavailable:
            break
        }
    }

    /// The person asked for Game Center, so the sign-in Apple hands over next is theirs to see:
    /// it is presented on `window` the moment it arrives.
    private func connect(from window: NSWindow?) {
        consent.turnOn()
        presenter = window
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
        standing = .off
        NotificationCenter.default.post(name: Self.standingChanged, object: nil)
    }

    var actionTitle: String? {
        switch standing {
        case .off: return Localized.text("Connect Game Center")
        case .ready: return Localized.text("Game Center")
        case .needsSignIn: return Localized.text("Sign in to Game Center")
        case .unknown, .unavailable: return nil
        }
    }

    var turnOffTitle: String? {
        switch standing {
        case .ready, .needsSignIn, .unavailable: return Localized.text("Turn off Game Center")
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

    private func authenticated(viewController: NSViewController?, error: Error?) {
        let wasRequested = requested
        requested = false
        if let viewController {
            guard wasRequested else {
                turnOff()
                return
            }
            signInSheet = viewController
            standing = .needsSignIn
            presenter?.contentViewController?.presentAsSheet(viewController)
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
        NotificationCenter.default.post(name: Self.standingChanged, object: nil)
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
            } catch {
            }
        }
    }
}

extension MacGameCenter: GKGameCenterControllerDelegate {
    nonisolated func gameCenterViewControllerDidFinish(
        _ gameCenterViewController: GKGameCenterViewController
    ) {
        Task { @MainActor in
            GKDialogController.shared().dismiss(gameCenterViewController)
        }
    }
}
