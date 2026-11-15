import UIKit

/// Where the board opens from: any screen, over whatever is on top of its window, and closed again
/// by the same road. It is a sheet like Settings and the other panels, so a swipe down closes it as
/// it closes them; the peek rises over it as a second sheet.
@MainActor
enum AgentsPresenter {
    /// The board's mark wherever a button opens it.
    static let symbol = "person.2"

    @discardableResult
    static func present(from presenter: UIViewController, animated: Bool = true)
        -> AgentsBoardViewController?
    {
        let chain = presented(from: presenter)
        guard board(in: chain) == nil, let top = chain.last, !top.isBeingDismissed else { return nil }
        let board = AgentsBoardViewController()
        let navigation = AgentsBoardNavigation(rootViewController: board)
        Theme.Haptics.tap()
        top.present(navigation, animated: animated)
        return board
    }

    /// The wall, full screen over whatever is on top of the window: what Home's orb opens. A wall
    /// already up is left as it is.
    static func presentWall(from presenter: UIViewController) {
        let chain = presented(from: presenter)
        guard !chain.contains(where: { $0 is WatchViewController }), let top = chain.last,
            !top.isBeingDismissed
        else { return }
        Theme.Haptics.tap()
        top.present(WatchViewController(), animated: true)
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

    /// Posted with the window scene the board covers as its object and `covered` in its user info,
    /// as the board's sheet rises and as it starts to leave.
    static let boardCoverDidChange = Notification.Name("tailscode.agents.boardCover")

    private static func board(in chain: [UIViewController]) -> UIViewController? {
        chain.first { ($0 as? UINavigationController)?.viewControllers.first is AgentsBoardViewController }
    }
}

/// The board's sheet, which says when it covers the window it rose over, so what is drawn under it
/// can rest the way it rests under Settings. A wall opened over the board leaves it covering.
@MainActor
final class AgentsBoardNavigation: UINavigationController {
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        post(covered: true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isBeingDismissed else { return }
        post(covered: false)
    }

    private func post(covered: Bool) {
        guard let scene = presentingViewController?.view.window?.windowScene else { return }
        NotificationCenter.default.post(
            name: AgentsPresenter.boardCoverDidChange, object: scene, userInfo: ["covered": covered])
    }
}
