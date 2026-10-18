import TailscodeCore
import UIKit

/// One turn's brain in the transcript: a card while it is collapsed and the open brain while it is
/// open, which is `BrainRowView`'s business. The cell is the row's place in the list: it holds the
/// row inside the transcript's margins, carries the air above it, and tells the list how tall the
/// row is, which is the card's height, the open brain's, or, while the two trade places, the
/// move's own at this frame.
@MainActor
final class NeuralBrainCell: UICollectionViewCell, RowGapCell {
    static let reuseID = "NeuralBrainCell"

    private let rowView = BrainRowView()
    private weak var store: BrainStore?
    private var row: BrainRow?

    var brainRow: BrainRowView { rowView }

    var gapAbove: CGFloat = 0 {
        didSet {
            guard gapAbove != oldValue else { return }
            setNeedsLayout()
            invalidateIntrinsicContentSize()
        }
    }

    private static let inset = Theme.Spacing.s

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(rowView)
        rowView.onHeightChange = { [weak self] in self?.heightChanged() }
        isAccessibilityElement = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        rowView.prepareForReuse()
        row = nil
        store = nil
    }

    /// Draws a brain row. The model is read from the store, never copied here, so a cursor or a
    /// replay the person started survives the cell being configured again.
    func configure(_ new: BrainRow, store newStore: BrainStore, actions: BrainActions) {
        row = new
        store = newStore
        layoutIfNeeded()
        let width = max(contentView.bounds.width, bounds.width) - 2 * Self.inset
        if rowView.bounds.width != width {
            rowView.frame = CGRect(x: Self.inset, y: gapAbove, width: max(width, 0), height: rowView.bounds.height)
        }
        rowView.configure(row: new, store: newStore, actions: actions, viewport: viewportHeight)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// The conversation moved without this row changing: the card's counts and the brain's account
    /// are read again, and nothing is rebuilt.
    func refreshLive() {
        rowView.refreshLive()
    }

    private var viewportHeight: CGFloat {
        var view: UIView? = superview
        while let current = view {
            if let collection = current as? UICollectionView {
                return max(
                    collection.bounds.height - collection.adjustedContentInset.top
                        - collection.adjustedContentInset.bottom, 320)
            }
            view = current.superview
        }
        return 800
    }

    private func heightChanged() {
        setNeedsLayout()
        invalidateIntrinsicContentSize()
    }

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        let attributes = layoutAttributes.copy() as! UICollectionViewLayoutAttributes
        let width = attributes.size.width - 2 * Self.inset
        if rowView.bounds.width != width {
            rowView.frame = CGRect(x: Self.inset, y: gapAbove, width: width, height: rowView.bounds.height)
            rowView.layoutIfNeeded()
        }
        attributes.size.height = gapAbove + rowView.height(forWidth: width)
        return attributes
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = contentView.bounds.width - 2 * Self.inset
        let height = max(0, contentView.bounds.height - gapAbove)
        rowView.frame = CGRect(x: Self.inset, y: gapAbove, width: max(width, 0), height: height)
    }
}
