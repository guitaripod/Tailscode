import CodingAgentKit
import MidgarCore
import TailscodeCore
import UIKit

extension ChatViewController {
    /// The conversation's chapter count, last in the facts row and quiet, shown from two chapters.
    func configureChaptersChip() {
        chaptersChip.setSymbol("book.pages")
        chaptersChip.accessibilityHint = String(localized: "Shows how this chat got here.")
        chaptersChip.addAction(
            UIAction { [weak self] _ in self?.presentChapters(at: nil) }, for: .touchUpInside)
        chaptersChip.isHidden = true
    }

    func updateChaptersChip() {
        let count = chapterSource.count
        let shown = count >= 2
        let words = shown ? Localized.text("%d chapters", count) : nil
        guard chaptersChip.isHidden == shown || chaptersChip.text != words else { return }
        defer { factsRow.refresh(); syncFactsScrim() }
        chaptersChip.isHidden = !shown
        chaptersChip.text = words
        chaptersChip.accessibilityLabel = words
    }

    /// How a long chat got here: every chapter the server keeps, in a sheet that opens on the
    /// chapter a heading named or on the current one. A row takes the transcript to where its
    /// chapter began.
    func presentChapters(at anchor: String?) {
        guard chapterSource.count >= 2 else {
            presentToast(String(localized: "This chat is still in its first chapter."))
            return
        }
        if let sheet = chaptersSheet {
            sheet.focus(on: anchor)
            return
        }
        Theme.Haptics.tap()
        let sheet = ChaptersViewController(
            focus: anchor,
            read: { [weak self] in self?.chapterReading() },
            reveal: { [weak self] messageID in
                self?.dismiss(animated: true) { self?.scrollToChapter(messageID) }
            })
        let nav = UINavigationController(rootViewController: sheet)
        nav.modalPresentationStyle = .pageSheet
        nav.sheetPresentationController?.detents = [.medium(), .large()]
        nav.sheetPresentationController?.prefersGrabberVisible = true
        chaptersSheet = sheet
        present(nav, animated: true)
        MidgarLog.info(
            "chapters: opened \(chapterSource.count) for session=\(viewModel.session.id)", category: .chat)
    }

    func chapterReading() -> ChapterReading {
        let state = lastRenderedState ?? viewModel.state
        return ChapterReading.read(
            chapterSource, turns: state.messages.reduce(0) { $0 + ($1.role == .user ? 1 : 0) })
    }

    /// The heading where a chapter began, or failing that the first row its opening message drew.
    func scrollToChapter(_ messageID: String) {
        revealInTranscript(id: "chapter:\(messageID)", messageID: messageID)
    }

    /// Where a reader who has scrolled up is reading, taken just before rows land, when one of
    /// them is a chapter heading arriving above the screen: a heading opens a few messages back,
    /// so it can land above the very words being read and push them down by its height.
    func readingPlace(before ids: [String]) -> (id: String, offset: CGFloat)? {
        guard userScrolledUp else { return nil }
        let headings = ids.filter { $0.hasPrefix("chapter:") }
        guard !headings.isEmpty else { return nil }
        let snapshot = dataSource.snapshot()
        guard headings.contains(where: { snapshot.indexOfItem($0) == nil }),
            let first = collectionView.indexPathsForVisibleItems.min(),
            let id = dataSource.itemIdentifier(for: first),
            let frame = collectionView.layoutAttributesForItem(at: first)?.frame
        else { return nil }
        return (id, frame.minY - collectionView.contentOffset.y)
    }

    /// Puts the row the reader was on back where it stood on screen.
    func restoreReadingPlace(_ place: (id: String, offset: CGFloat)?) {
        guard let place, let index = dataSource.snapshot().indexOfItem(place.id) else { return }
        collectionView.layoutIfNeeded()
        guard let frame = collectionView.layoutAttributesForItem(
            at: IndexPath(item: index, section: 0))?.frame
        else { return }
        let target = frame.minY - place.offset
        guard abs(target - collectionView.contentOffset.y) > 0.5 else { return }
        collectionView.setContentOffset(
            CGPoint(x: collectionView.contentOffset.x, y: target), animated: false)
    }
}
