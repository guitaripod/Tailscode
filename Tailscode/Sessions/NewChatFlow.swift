import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore
import UIKit

/// The one way a chat starts anywhere in the app: `NewChatViewController` as a sheet, which asks
/// both halves of the question — which machine, which folder — on one screen. Callers keep handing
/// in the server they think is meant; the modal pre-chooses it and lets it be changed.
@MainActor
enum NewChatFlow {
    static func begin(
        from presenter: UIViewController,
        profile: ConnectionProfile,
        viewModel: SessionListViewModel,
        onOpen: @escaping @MainActor (SessionEntry) -> Void
    ) {
        let chooser = NewChatViewController(viewModel: viewModel, preferredServer: profile.id)
        chooser.onStart = onOpen
        present(chooser, from: presenter)
    }

    /// The same screen used only to answer "where", for Home's docked composer: it creates the
    /// session when the message is sent, so it wants the server and folder rather than a chat.
    static func chooseDirectory(
        from presenter: UIViewController,
        profile: ConnectionProfile,
        viewModel: SessionListViewModel,
        onChoose: @escaping @MainActor (String, String?) -> Void
    ) {
        let chooser = NewChatViewController(
            viewModel: viewModel, preferredServer: profile.id, purpose: .choose)
        chooser.onChoose = onChoose
        present(chooser, from: presenter)
    }

    /// A sheet rather than a full-screen push: the list stays behind it, and it opens at the large
    /// detent because a keyboard over the medium one leaves two rows of the answer visible.
    private static func present(_ chooser: NewChatViewController, from presenter: UIViewController) {
        let nav = UINavigationController(rootViewController: chooser)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.selectedDetentIdentifier = .large
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        }
        presenter.present(nav, animated: true)
    }
}
