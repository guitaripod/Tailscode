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

    #if DEBUG
        nonisolated(unsafe) private static var debugOpened = false

        /// `TAILSCODE_OPEN_DELEGATE=<host>` opens that machine's board once Home is up, and
        /// `TAILSCODE_DELEGATE_PASSWORD` seeds the daemon's password, so a simulator can be
        /// photographed on a real dispatcher without a finger.
        static func debugOpenIfAsked(from home: UIViewController) {
            let env = ProcessInfo.processInfo.environment
            guard !debugOpened, let host = env["TAILSCODE_OPEN_DELEGATE"], !host.isEmpty else { return }
            debugOpened = true
            let name = ConnectionController.shared.profiles.first { $0.baseURL.host == host }?.name ?? host
            if let password = env["TAILSCODE_DELEGATE_PASSWORD"], !password.isEmpty {
                desk.remember(password: password, host: host, serverName: name)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                open(from: home, host: host, serverName: name)
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
        if let reach = desk.reach[host] { return reach.line }
        return DelegateAccessStore.access(host: host) == nil
            ? DelegateEntryPoint.subtitle : Localized.text("Not checked yet")
    }
}
