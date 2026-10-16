import TailscodeCore
import UIKit

/// The one road to what a machine can make. Every way in (the video button on a machine that cannot
/// render, the machine control in the picture studio, a render's "See what is missing", the server
/// screen's Capabilities row) opens the shared checklist for images and video, led by the lane the
/// person came from. The checklist names the machine it checks and offers Change, which opens the
/// renderer picker that already exists and, once a machine is saved, returns to the checklist for it.
@MainActor
enum MediaSetupGate {
    /// Opens the checklist for `endpoint`, or the picker first when no renderer was ever named.
    static func present(
        endpoint: ForgeEndpoint? = ForgeRunner.shared.endpoint, focus: SetupFocus?, from presenter: UIViewController,
        onFinish: (() -> Void)? = nil, onChanged: (() -> Void)? = nil
    ) {
        guard let endpoint else {
            choose(from: presenter, focus: focus, onFinish: onFinish, onChanged: onChanged)
            return
        }
        SetupGate.present(
            .media(endpoint), focus: focus, from: presenter, onFinish: onFinish,
            onChange: { checklist in
                let host = checklist.presentingViewController ?? presenter
                checklist.dismiss(animated: true) {
                    choose(from: host, focus: focus, onFinish: onFinish, onChanged: onChanged)
                }
            })
    }

    private static func choose(
        from presenter: UIViewController, focus: SetupFocus?, onFinish: (() -> Void)?, onChanged: (() -> Void)?
    ) {
        let picker = ForgeSetupViewController()
        picker.onSaved = {
            onChanged?()
            present(endpoint: ForgeRunner.shared.endpoint, focus: focus, from: presenter, onFinish: onFinish, onChanged: onChanged)
        }
        picker.onCancelled = {
            present(endpoint: ForgeRunner.shared.endpoint, focus: focus, from: presenter, onFinish: onFinish, onChanged: onChanged)
        }
        let nav = UINavigationController(rootViewController: picker)
        nav.navigationBar.prefersLargeTitles = true
        presenter.present(nav, animated: true)
    }
}
