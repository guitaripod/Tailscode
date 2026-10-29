import UIKit

extension AgentsBoardViewController {
    /// The board's way into the wall: a button on its bar that opens it full screen from here, and on
    /// an iPad a menu with the same wall in a window of its own.
    func watchBarButton() -> UIBarButtonItem {
        var menu: UIMenu?
        if traitCollection.userInterfaceIdiom == .pad, UIApplication.shared.supportsMultipleScenes {
            menu = UIMenu(children: [
                UIAction(
                    title: String(localized: "Open in New Window"),
                    image: UIImage(systemName: "macwindow.badge.plus")
                ) { _ in WatchScene.openWindow() }
            ])
        }
        let item = UIBarButtonItem(
            image: UIImage(systemName: "tv"),
            primaryAction: UIAction { [weak self] _ in self?.presentWatch() }, menu: menu)
        item.accessibilityLabel = String(localized: "Watch")
        item.accessibilityIdentifier = "agents.watch"
        return item
    }

    func presentWatch() {
        guard presentedViewController == nil else { return }
        Theme.Haptics.tap()
        suspend()
        present(WatchViewController(), animated: true)
    }
}
