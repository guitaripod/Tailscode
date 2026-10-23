import UIKit

/// The chat's list layout, which can be told to leave the end of the page where it is while rows
/// are added above it.
///
/// A list that gains rows above what is on screen keeps its offset, so everything the reader was
/// looking at slides down by the height of what arrived, and the cells UIKit makes while it
/// applies the update are made for whatever now sits at the old offset: an opening transcript
/// made six cells nobody would see with every slice it added. The layout learns the new height in
/// `prepare(forCollectionViewUpdates:)`, before any cell is made, and moves the page the same
/// distance, so the update leaves the reader's end of the page exactly where it was.
final class TranscriptLayout: UICollectionViewCompositionalLayout {
    private var holdsEnd = false
    private var heightBefore: CGFloat = 0

    convenience init(config: UICollectionLayoutListConfiguration) {
        self.init { _, environment in
            UICollectionViewCompositionalLayout.readableSection(
                using: config, environment: environment)
        }
    }

    func holdingEnd(of height: CGFloat, during update: () -> Void) {
        holdsEnd = true
        heightBefore = height
        update()
        holdsEnd = false
    }

    override func prepare(forCollectionViewUpdates updateItems: [UICollectionViewUpdateItem]) {
        super.prepare(forCollectionViewUpdates: updateItems)
        guard holdsEnd, let collectionView else { return }
        let inset = collectionView.adjustedContentInset
        let height = collectionViewContentSize.height
        let lowest = -inset.top
        let highest = max(lowest, height + inset.bottom - collectionView.bounds.height)
        let held = collectionView.contentOffset.y + height - heightBefore
        collectionView.contentOffset.y = min(max(held, lowest), highest)
    }
}
