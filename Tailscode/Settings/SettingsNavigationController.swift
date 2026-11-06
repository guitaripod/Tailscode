import UIKit

/// The sheet Settings is presented in. Its own appearance is the one honest account of whether
/// Settings stands over the board: it appears as the sheet rises, disappears the moment Done or a
/// swipe starts taking it down, and appears again when that swipe is let go, which the
/// presentation's delegate never says and a screen pushed inside the sheet never sees.
///
/// Like the iPhone's own Settings, the first page wears a large title and every page under it an
/// inline one, whether or not the screen pushed says which it wants.
@MainActor
final class SettingsNavigationController: UINavigationController {
    var onCover: ((Bool) -> Void)?

    override init(rootViewController: UIViewController) {
        super.init(rootViewController: rootViewController)
        navigationBar.prefersLargeTitles = true
    }

    override func pushViewController(_ viewController: UIViewController, animated: Bool) {
        if viewController.navigationItem.largeTitleDisplayMode == .automatic {
            viewController.navigationItem.largeTitleDisplayMode = .never
        }
        super.pushViewController(viewController, animated: animated)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        onCover?(true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        onCover?(false)
    }
}
