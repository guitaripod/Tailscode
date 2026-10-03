import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore
import UIKit

/// The one door into delegation on the phone. Every road — the server row, Home's button — comes
/// through here, so a free copy meets the Pro sheet with the delegate pitch and a Pro copy meets
/// the board, and neither meets half of the feature.
@MainActor
enum DelegateGate {
    static let desk = DelegateDesk(secrets: KeychainSecretStore())

    static var isOpen: Bool {
        DelegateProGate.allows(isPro: ProStore.shared.isPro, sells: true, demo: ConnectionController.shared.isDemoMode)
    }

    nonisolated(unsafe) private static var noticeWatcher: NSObjectProtocol?

    /// A run this phone follows taps its shoulder: a wait for a person under the approvals switch,
    /// an end nobody chose under the turn-complete switch, never while the app is on screen.
    static func watchNotices() {
        guard noticeWatcher == nil else { return }
        noticeWatcher = NotificationCenter.default.addObserver(
            forName: DelegateDesk.didNotice, object: nil, queue: .main
        ) { note in
            guard let notice = note.userInfo?["notice"] as? DelegateNotice,
                let runID = note.userInfo?["runID"] as? String
            else { return }
            MainActor.assumeIsolated {
                NotificationManager.notify(
                    kind: notice.kind == .asks ? .approval : .turnComplete, title: notice.title, body: notice.body,
                    identifier: "delegate:\(runID):\(notice.kind)")
            }
        }
    }

    static func open(from presenter: UIViewController, profile: ConnectionProfile) {
        guard let host = DelegateAccess.host(of: profile.baseURL) else { return }
        open(from: presenter, host: host, serverName: profile.name)
    }

    static func open(from presenter: UIViewController, host: String, serverName: String) {
        Theme.Haptics.tap()
        guard isOpen else {
            AppLogger.ui.info("delegate gated: free copy, presenting Pro")
            ProUpgradeViewController.present(from: presenter, lead: .delegate)
            return
        }
        let board = DelegateBoardViewController(host: host, serverName: serverName)
        if let nav = presenter.navigationController {
            nav.pushViewController(board, animated: true)
        } else {
            let nav = UINavigationController(rootViewController: board)
            nav.navigationBar.prefersLargeTitles = true
            presenter.present(nav, animated: true)
        }
    }

    /// A chat handing its task over: the composer opens on that chat's machine with the goal and
    /// the chat's directory already written, behind the same gate as every other door.
    static func compose(from presenter: UIViewController, handoff: DelegateHandoff) {
        Theme.Haptics.tap()
        guard isOpen else {
            AppLogger.ui.info("delegate handoff gated: free copy, presenting Pro")
            ProUpgradeViewController.present(from: presenter, lead: .delegate)
            return
        }
        let board = desk.board(host: handoff.host, serverName: handoff.serverName)
        if board.phase == .idle { desk.probe(host: handoff.host, serverName: handoff.serverName) }
        presentComposer(
            from: presenter, host: handoff.host, serverName: handoff.serverName,
            draft: handoff.draft(capabilities: board.capabilities))
    }

    /// The packet form over whatever asked for it; a packet that starts lands on its run, pushed
    /// where the asker lives.
    static func presentComposer(from presenter: UIViewController, host: String, serverName: String, draft: DelegateDraft?) {
        let composer = DelegateComposerViewController(host: host, serverName: serverName, draft: draft)
        composer.onStarted = { [weak presenter] runID in
            guard let presenter else { return }
            showRun(runID, host: host, serverName: serverName, from: presenter)
        }
        let nav = UINavigationController(rootViewController: composer)
        nav.navigationBar.prefersLargeTitles = false
        presenter.present(nav, animated: true)
    }

    static func showRun(_ runID: String, host: String, serverName: String, from presenter: UIViewController) {
        let run = DelegateRunViewController(host: host, serverName: serverName, runID: runID)
        if let nav = presenter.navigationController {
            nav.pushViewController(run, animated: true)
        } else {
            presenter.present(UINavigationController(rootViewController: run), animated: true)
        }
    }

    #if DEBUG
        nonisolated(unsafe) private static var debugOpened = false

        /// `TAILSCODE_OPEN_DELEGATE=<host>` opens that machine's board once Home is up,
        /// `TAILSCODE_DELEGATE_PASSWORD` seeds the daemon's password and `TAILSCODE_DELEGATE_BETA=1`
        /// opens the beta sheet over the board and `TAILSCODE_DELEGATE_COMPOSE=1` the composer, so a
        /// simulator can be photographed on a real dispatcher without a finger.
        /// `TAILSCODE_DELEGATE_HANDOFF=<goal>` (with `TAILSCODE_DELEGATE_REPO=<path>`) opens the
        /// composer the way a chat's `/delegate` does instead of the board.
        static func debugOpenIfAsked(from home: UIViewController) {
            let env = ProcessInfo.processInfo.environment
            guard !debugOpened, let host = env["TAILSCODE_OPEN_DELEGATE"], !host.isEmpty else { return }
            debugOpened = true
            let name = ConnectionController.shared.profiles.first { $0.baseURL.host == host }?.name ?? host
            if let password = env["TAILSCODE_DELEGATE_PASSWORD"], !password.isEmpty {
                desk.remember(password: password, host: host, serverName: name)
            }
            if let goal = env["TAILSCODE_DELEGATE_HANDOFF"], !goal.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    compose(
                        from: home,
                        handoff: DelegateHandoff(
                            host: host, serverName: name, goal: goal, repo: env["TAILSCODE_DELEGATE_REPO"] ?? ""))
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                open(from: home, host: host, serverName: name)
                if env["TAILSCODE_DELEGATE_BETA"] == "1" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        (home.navigationController?.topViewController as? DelegateBoardViewController)?.explainBeta()
                    }
                }
                if env["TAILSCODE_DELEGATE_COMPOSE"] == "1" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        (home.navigationController?.topViewController as? DelegateBoardViewController)?.compose()
                    }
                }
                guard let runID = env["TAILSCODE_OPEN_DELEGATE_RUN"], !runID.isEmpty else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    home.navigationController?.pushViewController(
                        DelegateRunViewController(host: host, serverName: name, runID: runID), animated: true)
                    guard env["TAILSCODE_DELEGATE_APPROVE"] == "1" else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        Task { try? await desk.approve(runID: runID, host: host, approved: true) }
                    }
                }
            }
        }
    #endif

    /// What the server row says under its title before the board is opened.
    static func rowDetail(host: String) -> String {
        guard isOpen else { return DelegateProGate.requirement }
        if let reach = desk.reach[host] { return DelegateBeta.marked(reach.line) }
        return DelegateBeta.marked(
            DelegateAccessStore.access(host: host) == nil
                ? DelegateEntryPoint.subtitle : Localized.text("Not checked yet"))
    }
}
