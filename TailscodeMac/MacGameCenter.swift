import AppKit
import GameKit
import TailscodeCore

/// Apple's Game Center behind the Mac's trophy case — the same contract as the phone's
/// coordinator: Core scores the merge (`TrophyRoom` riding `UsageAnalytics`), this object only
/// carries it out. Sign-in is lazy and never a wall; a dev build signed ad-hoc cannot
/// authenticate at all, and that becomes a stated line on the card rather than a hidden card.
@MainActor
final class MacGameCenter: NSObject {
    static let shared = MacGameCenter()

    static let standingChanged = Notification.Name("tailscode.gamecenter.standing")

    enum Standing {
        case unknown
        case ready
        case needsSignIn
        case unavailable(GameCenterReading)
    }

    private(set) var standing: Standing = .unknown
    private var signInSheet: NSViewController?
    private var latest: UsageAnalytics?
    private var started = false

    private static let reportedKey = "tailscode.gamecenter.reported"
    private static let scoresKey = "tailscode.gamecenter.scores"
    private static let playerKey = "tailscode.gamecenter.player"

    func start() {
        guard !started else { return }
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

    var actionTitle: String? {
        switch standing {
        case .ready: return Localized.text("Game Center")
        case .needsSignIn: return Localized.text("Sign in to Game Center")
        case .unknown, .unavailable: return nil
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

    var unavailableLine: String? {
        guard case .unavailable(let reading) = standing else { return nil }
        return reading.line
    }

    private func authenticated(viewController: NSViewController?, error: Error?) {
        if let viewController {
            signInSheet = viewController
            standing = .needsSignIn
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
        if grown.contains(where: { $0.percent >= 100 }) {
            MacReviewPrompt.shared.trophyEarned()
        }
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
