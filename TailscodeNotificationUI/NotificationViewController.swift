import SwiftUI
import UIKit
import UserNotifications
import UserNotificationsUI

#if !NOTICE_EXTENSION
    import TailscodeCore
#endif

/// The long look: what pulling a notification down shows.
///
/// The system draws the buttons; everything above them is drawn here from the notice the
/// notification carries, with no network and no app launch, so it appears at once even when the
/// phone has just woken. A notification with no notice in it (an older push) still gets a plain
/// card made from its own title and body, because the default content is hidden in favour of this.
final class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private let model = NoticeCardModel()
    private var host: UIHostingController<NoticeLongLookView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        let card = NoticeLongLookView(model: model) { [weak self] height in self?.fit(height: height) }
        let host = UIHostingController(rootView: card)
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        self.host = host
    }

    func didReceive(_ notification: UNNotification) {
        let content = notification.request.content
        show(
            title: content.title, subtitle: content.subtitle, body: content.body,
            wire: NoticeWire(userInfo: content.userInfo), date: notification.date)
    }

    func show(title: String, subtitle: String, body: String, wire: NoticeWire?, date: Date) {
        model.show(title: title, subtitle: subtitle, body: body, wire: wire, date: date)
    }

    /// The card says how tall it needs to be, every time its content or its width changes, and the
    /// system grows the long look to that. The look opens at the Info.plist's ratio of the width,
    /// and a height measured only when the notice arrived never grew it past that.
    private func fit(height: CGFloat) {
        guard height > 0, view.bounds.width > 0, abs(preferredContentSize.height - height) > 0.5
        else { return }
        preferredContentSize = CGSize(width: view.bounds.width, height: height)
    }
}
