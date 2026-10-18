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
        clipsToBounds = false
        contentView.clipsToBounds = false
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
        if rowView.bounds.width != laidOutWidth(real: width) {
            place(realWidth: width, height: rowView.bounds.height)
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
        if rowView.bounds.width != laidOutWidth(real: width) {
            place(realWidth: width, height: rowView.bounds.height)
            rowView.layoutIfNeeded()
        }
        let laid = laidOutWidth(real: width)
        let shrink = BrainDebug.forcedWidth == nil ? 1 : width / laid
        attributes.size.height = gapAbove + rowView.height(forWidth: laid) * shrink
        return attributes
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        place(
            realWidth: max(contentView.bounds.width - 2 * Self.inset, 0),
            height: max(0, contentView.bounds.height - gapAbove))
    }

    /// How the row sits in the cell: its width, and how far the card stands in from its sides.
    /// Ordinarily the row is the cell's content width. In a window wider than the transcript's
    /// readable column, where the open brain would split its account in two, the row is as wide
    /// as the window and the card keeps the column's place in the middle of it.
    private struct Fit {
        var width: CGFloat
        var cardInset: CGFloat
    }

    private func fit(real: CGFloat) -> Fit {
        if let forced = BrainDebug.forcedWidth, forced > 0 { return Fit(width: forced, cardInset: 0) }
        guard let collection = collectionView, real > 0 else { return Fit(width: real, cardInset: 0) }
        let wide = collection.bounds.width - collection.adjustedContentInset.left
            - collection.adjustedContentInset.right - 2 * Self.inset
        guard wide > real + 1 else { return Fit(width: real, cardInset: 0) }
        let split = NeuralStageMetrics.make(
            width: Double(wide), density: ChatDensitySetting.current, input: .touch, zonesWithSteps: 6)
        guard split.arrangement == .split, split.accountLayout == .split else {
            return Fit(width: real, cardInset: 0)
        }
        return Fit(width: wide, cardInset: (wide - real) / 2)
    }

    private var collectionView: UICollectionView? {
        var view: UIView? = superview
        while let current = view {
            if let collection = current as? UICollectionView { return collection }
            view = current.superview
        }
        return nil
    }

    private func laidOutWidth(real: CGFloat) -> CGFloat { fit(real: real).width }

    /// Puts the row in the cell, scaled down to fit when its width is forced.
    private func place(realWidth: CGFloat, height: CGFloat) {
        let layout = fit(real: realWidth)
        rowView.cardInset = layout.cardInset
        if let forced = BrainDebug.forcedWidth, forced > 0, realWidth > 0 {
            let scale = realWidth / forced
            rowView.transform = .identity
            rowView.layer.anchorPoint = .zero
            rowView.bounds = CGRect(x: 0, y: 0, width: forced, height: height / scale)
            rowView.layer.position = CGPoint(x: Self.inset, y: gapAbove)
            rowView.transform = CGAffineTransform(scaleX: scale, y: scale)
            return
        }
        rowView.transform = .identity
        rowView.frame = CGRect(
            x: Self.inset - layout.cardInset, y: gapAbove, width: layout.width, height: height)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -rowView.cardInset - Self.inset, dy: 0).contains(point)
    }
}
