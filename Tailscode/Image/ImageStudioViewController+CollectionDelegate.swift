import TailscodeCore
import UIKit

extension ImageStudioViewController: UICollectionViewDelegate, UICollectionViewDelegateFlowLayout {
    /// A tile is a picture made this session when the session made it, else the kept file.
    private func exhibitFor(_ kept: ImageGenLibraryItem) -> ImageExhibit {
        if let made = slot.pictures.first(where: { $0.remoteName == kept.id }) { return .made(made) }
        return .kept(kept)
    }

    /// Pressing a tile puts that picture on the stage, because the stage is directly above it and
    /// the answer is the stage changing — tapping the stage opens it full size, and nothing about
    /// choosing a picture decides what the next render is about: that is the reference verb's,
    /// pressed on purpose.
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard case .tile(let id) = stripSource.itemIdentifier(for: indexPath),
            let kept = library.item(named: id)
        else { return }
        Theme.Haptics.selection()
        view.endEditing(true)
        putOnStage(exhibitFor(kept))
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath)
        -> Bool
    {
        if case .tile = stripSource.itemIdentifier(for: indexPath) { return true }
        return false
    }

    func collectionView(
        _ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath
    ) -> Bool {
        if case .tile = stripSource.itemIdentifier(for: indexPath) { return true }
        return false
    }

    func collectionView(
        _ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        if case .note = stripSource.itemIdentifier(for: indexPath) {
            return CGSize(
                width: max(120, collectionView.bounds.width - 2 * Theme.Spacing.m), height: Self.tile)
        }
        return CGSize(width: Self.tile, height: Self.tile)
    }

    /// A tile that comes into view learns its own words, so a screen reader and a press-and-hold
    /// name the picture rather than the file. One ranged read each, kept on disk afterwards.
    func collectionView(
        _ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard case .tile(let id) = stripSource.itemIdentifier(for: indexPath),
            let kept = library.item(named: id)
        else { return }
        library.describe(kept)
    }

    /// Press and hold a tile for its verbs: the caption names it, the first verb puts it on the
    /// stage, and the rest are the ones the stage offers.
    func collectionView(
        _ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard case .tile(let id) = stripSource.itemIdentifier(for: indexPath),
            let kept = library.item(named: id)
        else { return nil }
        library.describe(kept)
        let exhibit = exhibitFor(kept)
        let facts = library.facts(of: kept)
        let words: String
        switch exhibit {
        case .made(let made): words = ImageGenFacts.caption(for: made)
        case .kept: words = ImageGenFacts.caption(for: facts)
        }
        let offered = [ImageGenAction.stage, .open] + ImageGenAction.offered(
            kept: true, hasWords: exhibit.isKept ? facts?.recipe?.prompt?.isEmpty == false : true,
            sharing: true, tapOpens: true)
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) {
            [weak self] _ in
            var children: [UIMenuElement] = offered.map { action in
                UIAction(
                    title: action.phoneTitle, image: UIImage(systemName: action.symbol),
                    attributes: action.isDestructive ? .destructive : []
                ) { _ in self?.perform(action, on: exhibit) }
            }
            children.append(
                UIAction(
                    title: ForgeWords.animateTitle, image: UIImage(systemName: "film")
                ) { _ in self?.animate(exhibit) })
            return UIMenu(title: words.ellipsized(to: 80), children: children)
        }
    }
}
