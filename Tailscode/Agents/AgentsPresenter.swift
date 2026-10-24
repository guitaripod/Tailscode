import UIKit

/// Where the board opens from: any screen, over whatever is on top of its window, and closed again
/// by the same road. It is a full-screen surface like the studios, because the peek is a sheet that
/// rises from it and the hour wants the width.
@MainActor
enum AgentsPresenter {
    @discardableResult
    static func present(from presenter: UIViewController) -> AgentsBoardViewController? {
        let chain = presented(from: presenter)
        guard board(in: chain) == nil, let top = chain.last, !top.isBeingDismissed else { return nil }
        let board = AgentsBoardViewController()
        let navigation = UINavigationController(rootViewController: board)
        navigation.modalPresentationStyle = .fullScreen
        Theme.Haptics.tap()
        top.present(navigation, animated: true)
        return board
    }

    static func toggle(from presenter: UIViewController) {
        if let shown = board(in: presented(from: presenter)) {
            shown.dismiss(animated: true)
        } else {
            present(from: presenter)
        }
    }

    private static func presented(from presenter: UIViewController) -> [UIViewController] {
        var chain = [presenter.view.window?.rootViewController ?? presenter]
        while let next = chain.last?.presentedViewController { chain.append(next) }
        return chain
    }

    private static func board(in chain: [UIViewController]) -> UIViewController? {
        chain.first { ($0 as? UINavigationController)?.viewControllers.first is AgentsBoardViewController }
    }
}
