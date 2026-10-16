import SwiftUI
import UIKit
import UserNotifications
import UserNotificationsUI

/// The long look: what pulling a notification down shows.
///
/// The system draws the buttons; everything above them is drawn here from the notice the
/// notification carries, with no network and no app launch, so it appears at once even when the
/// phone has just woken. A notification with no notice in it (an older push) still gets a plain
/// card made from its own title and body, because the default content is hidden in favour of this.
final class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private let model = NoticeCardModel()
    private var host: UIHostingController<NoticeCardView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: NoticeCardView(model: model))
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
        self.host = host
    }

    func didReceive(_ notification: UNNotification) {
        let content = notification.request.content
        model.show(
            title: content.title, subtitle: content.subtitle, body: content.body,
            wire: NoticeWire(userInfo: content.userInfo), date: notification.date)
        fit()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        fit()
    }

    private func fit() {
        guard let host, view.bounds.width > 0 else { return }
        let size = host.sizeThatFits(
            in: CGSize(width: view.bounds.width, height: .greatestFiniteMagnitude))
        if abs(preferredContentSize.height - size.height) > 0.5 {
            preferredContentSize = CGSize(width: view.bounds.width, height: size.height)
        }
    }
}
