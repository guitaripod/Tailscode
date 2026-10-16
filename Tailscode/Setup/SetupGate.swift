import CodingAgentKitApple
import TailscodeCore
import UIKit

/// The one door into machine setup on the phone. It owns the process's single `SetupDesk`, made with
/// the keychain the rest of the app keeps its passwords in, and presents the checklist for a
/// capability on a machine from whatever screen asked.
@MainActor
enum SetupGate {
    static let desk = SetupDesk(secrets: KeychainSecretStore())

    /// Opens the checklist as a sheet over `presenter`. Finishing it dismisses it and runs
    /// `onFinish`, which is how a call that was pressed for starts once voice is ready.
    static func present(
        _ target: SetupTarget, from presenter: UIViewController, reportLines: @escaping () -> [String] = { [] },
        onFinish: (() -> Void)? = nil
    ) {
        var top = presenter
        while let above = top.presentedViewController, !above.isBeingDismissed { top = above }
        if top is SetupChecklistViewController { return }
        AppLogger.ui.info("setup opened capability=\(target.capability) host=\(target.host)")
        SetupChecklistViewController.present(target: target, from: top, reportLines: reportLines, onFinish: onFinish)
    }
}
