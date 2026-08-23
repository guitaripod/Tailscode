import TailscodeCore
import UIKit

/// The face a surface wears while it has nothing to show yet: the vocabulary's own open-work mark,
/// centred in the space the rows will land in.
///
/// `UIContentUnavailableConfiguration.loading()` is UIKit's indeterminate indicator, drawn by the
/// system at a rate this app has no say in and cannot read — the second tempo every badge in this
/// client was just taken off, standing on the screens a reader looks at longest, since a
/// placeholder is by definition up while nothing has arrived yet. This is the same placeholder in
/// this app's own mark, written once so no list can drift into loading differently from the one
/// beside it.
///
/// It goes in the collection view's background rather than over the whole screen, because the
/// surfaces that show it have a composer or a bar docked in front of them, and a placeholder that
/// covered those would take a press meant for one of them.
@MainActor
final class WorkingPlaceholderView: UIView {
    private let mark = ActivityBadgeView(pointSize: 24)
    private let spoken: String

    /// A placeholder nobody can see is not working. Every surface here already hides this view
    /// rather than releasing it, and a mark left turning behind a hidden view is thirty frames a
    /// second spent on nothing — so the mark follows the view's own visibility instead of asking
    /// each caller to remember to stop it.
    override var isHidden: Bool {
        didSet {
            guard isHidden != oldValue else { return }
            mark.working(!isHidden, spoken: spoken)
        }
    }

    init(spoken: String = String(localized: "Loading")) {
        self.spoken = spoken
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        mark.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mark)
        NSLayoutConstraint.activate([
            mark.centerXAnchor.constraint(equalTo: centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: safeAreaLayoutGuide.centerYAnchor),
        ])
        mark.working(true, spoken: spoken)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

extension UICollectionView {
    /// The face a list wears while it has nothing to show yet, in this app's own mark rather than
    /// UIKit's indeterminate one.
    ///
    /// The placeholder is kept and hidden rather than made and dropped: a list that decides its
    /// empty state on every snapshot would otherwise build a fresh view and a fresh clock several
    /// times a second, and each new mark would start its swell from the top instead of arriving in
    /// time with every other mark on screen.
    func showsWork(_ working: Bool) {
        if let placeholder = backgroundView as? WorkingPlaceholderView {
            placeholder.isHidden = !working
            return
        }
        guard working else { return }
        backgroundView = WorkingPlaceholderView()
    }
}
