import TailscodeCore
import UIKit

/// The account of a turn on a phone: the agent's words, its plan, what it did and what came of it,
/// in the sheet a person pulls up from the open Megatron. The transcript underneath never holds a
/// scroller of its own; reading at length is the sheet's, which is a page of its own that a swipe
/// puts away, so a long account is never a box inside the page the person is scrolling.
@MainActor
final class BrainReaderViewController: UIViewController {
    /// What the sheet is of when it is a stage of the turn in short: the model's words for it and
    /// what the turn counts there.
    struct Heading {
        var title: String
        var detail: String
    }

    private let account: BrainAccountView
    private let focus: String?
    private var lastWidth: CGFloat = 0
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    var heading: Heading?

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
        if let heading {
            titleLabel.numberOfLines = 2
            titleLabel.attributedText = NSAttributedString(
                string: heading.title, attributes: Theme.Ramp.attributes(.headline, color: Theme.Color.label))
            detailLabel.numberOfLines = 2
            detailLabel.attributedText = NSAttributedString(
                string: heading.detail, attributes: Theme.Ramp.attributes(.rowStamp, color: Theme.Color.secondaryLabel))
            titleLabel.accessibilityTraits = .header
            view.addSubview(titleLabel)
            view.addSubview(detailLabel)
        }
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
        var top = view.safeAreaInsets.top + 18
        if heading != nil {
            let width = max(view.bounds.width - 36, 80)
            let title = titleLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            titleLabel.frame = CGRect(x: 18, y: top + 4, width: width, height: ceil(title.height))
            let detail = detailLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            detailLabel.frame = CGRect(x: 18, y: titleLabel.frame.maxY + 4, width: width, height: ceil(detail.height))
            top = detailLabel.frame.maxY + 10
        }
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
