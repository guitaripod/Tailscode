import CodingAgentKit
import TailscodeCore
import UIKit

/// The one tap that a diagnosis, or a signed-out Claude, offers, wired to this device's doors.
/// The flow decides what is wrong and which fix applies; this only presses it.
@MainActor
enum SetupFixes {
    static func perform(
        _ fix: ConnectDiagnosis.Fix, flow: FirstRunFlow, from presenter: UIViewController,
        revealPassword: @escaping () -> Void, copied: @escaping (String) -> Void
    ) {
        Theme.Haptics.tap()
        switch fix {
        case .none:
            break
        case .openTailscale:
            TailnetStatus.openTailscaleApp()
        case .openAppSettings:
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        case .retry:
            Task { await flow.retry() }
        case .retryOtherPort(let url), .usePlainHTTP(let url):
            Task {
                await flow.typeAddress(url.absoluteString)
                await flow.retry()
            }
        case .revealPassword:
            revealPassword()
            Task { await flow.revealPassword() }
        case .copyCommand(let command):
            UIPasteboard.general.string = command
            Theme.Haptics.success()
            copied(command)
        case .seePro:
            ProUpgradeViewController.present(from: presenter)
        }
    }

    static func presentSignIn(flow: FirstRunFlow, from presenter: UIViewController) {
        Task { [weak presenter] in
            guard let saved = await flow.saved,
                let backend = ConnectionController.shared.makeBackend(for: saved.profile)
                    as? any AuthenticatingBackend
            else {
                AppLogger.connection.error("setup sign-in unavailable: no authenticating backend")
                return
            }
            let signIn = ServerSignInViewController(profile: saved.profile, backend: backend)
            signIn.onSignedIn = { auth in
                Task { await flow.signInFinished(account: auth.accountLabel) }
            }
            presenter?.present(UINavigationController(rootViewController: signIn), animated: true)
        }
    }
}
