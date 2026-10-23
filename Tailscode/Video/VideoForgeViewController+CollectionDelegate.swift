import TailscodeCore
import UIKit

extension VideoForgeViewController: UICollectionViewDelegate, UICollectionViewDelegateFlowLayout {
    /// Pressing a clip puts it on the stage, where it plays, and decides nothing about the next
    /// render: continuing it or using its settings is the verb's, pressed on purpose. A render that
    /// made no clip says why instead. While a render is out the stage is the render's, so the clip
    /// opens in the system player over it. Pressing the clip already on the stage does nothing —
    /// it would ask the machine for the file again and restart a loop that is playing.
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard case .clip(let id) = stripSource.itemIdentifier(for: indexPath),
            let entry = board.history.first(where: { $0.id == id })
        else { return }
        Theme.Haptics.selection()
        view.endEditing(true)
        if runner.isRendering { return peek(entry) }
        let settled = stageClip != nil || locating != nil || !entry.isPlayable
        if stageEntry?.id == entry.id, settled { return }
        showOnStage(entry)
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath)
        -> Bool
    {
        if case .clip = stripSource.itemIdentifier(for: indexPath) { return true }
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

    func collectionView(
        _ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard case .clip(let id) = stripSource.itemIdentifier(for: indexPath),
            let entry = board.history.first(where: { $0.id == id })
        else { return nil }
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) {
            [weak self] _ in
            var actions: [UIAction] = []
            if entry.isPlayable {
                actions.append(
                    UIAction(
                        title: String(localized: "Share"),
                        image: UIImage(systemName: "square.and.arrow.up")
                    ) { _ in self?.share(entry) })
                if self?.runner.isRendering == false {
                    actions.append(
                        UIAction(
                            title: ForgeWords.extendTitle, subtitle: ForgeWords.extendHint,
                            image: UIImage(systemName: "forward.end.fill")
                        ) { _ in self?.continueIt(entry) })
                }
            }
            actions.append(
                UIAction(
                    title: String(localized: "Use these settings"),
                    image: UIImage(systemName: "arrow.uturn.backward")
                ) { _ in self?.reuse(entry) })
            actions.append(
                UIAction(
                    title: String(localized: "Remove"), image: UIImage(systemName: "trash"),
                    attributes: .destructive
                ) { _ in self?.forget(entry) })
            return UIMenu(title: entry.title, children: actions)
        }
    }
}
