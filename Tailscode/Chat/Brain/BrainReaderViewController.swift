import TailscodeCore
import UIKit

/// The account of a turn on a phone: the agent's words, its plan, what it did and what came of it,
/// in the sheet a person pulls up from the open Megatron. The transcript underneath never holds a
/// scroller of its own; reading at length is the sheet's, which is a page of its own that a swipe
/// puts away, so a long account is never a box inside the page the person is scrolling.
@MainActor
final class BrainReaderViewController: UIViewController {
    private let account: BrainAccountView
    private let focus: String?
    private var lastWidth: CGFloat = 0

    /// Called when the sheet has gone, however it went.
    var onDismiss: (() -> Void)?
    /// Called with the sheet's width whenever it changes, so the account can be set for it.
    var onLayout: ((Double) -> Void)?

    init(account: BrainAccountView, focus: String?) {
        self.account = account
        self.focus = focus
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.background
        view.accessibilityLabel = Localized.text("Megatron")
        view.addSubview(account)
        if let sheet = sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
            sheet.prefersEdgeAttachedInCompactHeight = true
            sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = true
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = view.safeAreaInsets.top + 18
        account.frame = CGRect(
            x: 0, y: top, width: view.bounds.width,
            height: max(0, view.bounds.height - top - view.safeAreaInsets.bottom))
        if abs(lastWidth - view.bounds.width) > 0.5 {
            lastWidth = view.bounds.width
            onLayout?(Double(view.bounds.width))
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let focus { account.reveal(step: focus, animated: false) }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || presentingViewController == nil else { return }
        account.removeFromSuperview()
        onDismiss?()
    }

    override func accessibilityPerformEscape() -> Bool {
        dismiss(animated: true)
        return true
    }
}
