import TailscodeCore
import CodingAgentKit
import UIKit

extension ChatViewController {
    /// A tapped item in the window's composition: the row it is, or failing that the first row of
    /// the message it belongs to, brought to the top like any jump inside the conversation.
    func revealInTranscript(id: String, messageID: String) {
        let target =
            dataSource.snapshot().indexOfItem(id) != nil
            ? id : orderedIDs.first { rowsByID[$0]?.messageID == messageID }
        guard let target else { return }
        userScrolledUp = true
        scrollTo(id: target)
    }

    /// A transcript that names the same row twice is a trap for the diffable data source and for
    /// `Dictionary(uniqueKeysWithValues:)` — both refuse duplicate keys. Keeping the first of each
    /// id preserves the order the builder intended and drops the later collision rather than
    /// crashing the chat a notification just opened.
    static func dedupeRows(_ rows: [ChatRow]) -> [ChatRow] {
        var seen = Set<String>()
        return rows.filter { seen.insert($0.id).inserted }
    }

    static func collectToolStatuses(from steps: some Sequence<ActivityStep>) -> [String: ToolStatus] {
        var map: [String: ToolStatus] = [:]
        for step in steps {
            if case .tool(let call) = step { map[call.id] = call.status }
        }
        return map
    }

    /// The transcript stays invisible through the initial empty → cached →
    /// refreshed snapshot churn, then fades in once, already scrolled to the
    /// bottom. The fallback timer reveals chats with nothing to show yet —
    /// a spinner while history is still loading, the empty state otherwise.
    /// A transcript opens on its end, and a first layout at the top of a long one makes a screenful
    /// of rows nobody will see, only to throw them away when the page moves to the end. The layout
    /// already knows how tall the page is before it makes a single row, so the page is put on its
    /// end first and that one pass makes the rows that are looked at.
    private func parkOnEndBeforeFirstLayout() {
        guard collectionView.bounds.height > 0 else { return }
        let inset = collectionView.adjustedContentInset
        let content = collectionView.collectionViewLayout.collectionViewContentSize.height
        let end = content + inset.bottom - collectionView.bounds.height
        collectionView.contentOffset.y = max(-inset.top, end)
    }

    /// The rows to hand the data source for a transcript of `ids`. A long one that has nothing on
    /// screen yet is shown from its end, a few rows at a time (`TranscriptOpening`), so the first
    /// layout makes the cells that are looked at and nothing else; once the window is whole this is
    /// the transcript itself.
    func idsToShow(from ids: [String]) -> [String] {
        if opening == nil, appliedIDs.isEmpty, ids.count > TranscriptOpening.firstStage {
            opening = TranscriptOpening(total: ids.count)
            openingStage = nil
        } else if var current = opening {
            current.retotal(ids.count)
            opening = current.isDone ? nil : current
        }
        guard let opening else { return ids }
        return Array(ids.suffix(opening.shown))
    }

    func scheduleOpeningStage() {
        guard !openingScheduled else { return }
        openingScheduled = true
        RunLoopTurn.next { [weak self] in self?.advanceOpening() }
    }

    /// The first rows are in the data source and their cells are not made yet: make them, say
    /// what that cost, and carry on from the end.
    func finishFirstOpeningStage() {
        guard let opening else { return }
        let covered = layOutOpeningWindow()
        openingStage = TranscriptOpening.Stage(
            rows: opening.shown,
            milliseconds: (CACurrentMediaTime() - openingStageStart) * 1000, covered: covered)
        if !hasRevealed, covered { revealTranscript() }
        scheduleOpeningStage()
    }

    /// One more slice of rows above the ones already shown, sized by what the last slice cost.
    private func advanceOpening() {
        openingScheduled = false
        guard var current = opening, isViewLoaded else { return }
        let started = CACurrentMediaTime()
        guard let rows = current.next(after: openingStage) else {
            opening = nil
            openingStage = nil
            return
        }
        opening = current
        let following = !hasRevealed || (!userScrolledUp && !isFingerDown && canvasPromptIDs.isEmpty)
        let anchor = following ? nil : visibleAnchor()
        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        snapshot.appendSections([.main])
        let shown = Array(renderedIDOrder.suffix(current.shown))
        snapshot.appendItems(shown, toSection: .main)
        appliedIDs = shown
        if let layout = collectionView.collectionViewLayout as? TranscriptLayout, following {
            layout.holdingEnd(of: collectionView.contentSize.height) {
                dataSource.apply(snapshot, animatingDifferences: false)
            }
        } else {
            dataSource.apply(snapshot, animatingDifferences: false)
        }
        let covered = layOutOpeningWindow(anchor: anchor)
        openingStage = TranscriptOpening.Stage(
            rows: rows, milliseconds: (CACurrentMediaTime() - started) * 1000, covered: covered)
        if !hasRevealed, covered || current.isDone { revealTranscript() }
        if current.isDone {
            opening = nil
            openingStage = nil
        } else {
            scheduleOpeningStage()
        }
    }

    /// Puts the window on its end, makes the cells it shows, and says whether they fill the page: a
    /// transcript shorter than the page is held against the composer by a top inset, so the page is
    /// full exactly when no such inset is needed.
    @discardableResult
    private func layOutOpeningWindow(anchor: (id: String, offset: CGFloat)? = nil) -> Bool {
        if let anchor {
            collectionView.layoutIfNeeded()
            restoreVisibleAnchor(anchor)
        } else {
            parkOnEndBeforeFirstLayout()
            collectionView.layoutIfNeeded()
            updateTranscriptInsets()
            carryEnd()
            collectionView.layoutIfNeeded()
        }
        updateTranscriptInsets()
        let bannerInset: CGFloat = banner.isHidden ? 0 : banner.bounds.height
        return collectionView.contentInset.top - bannerInset < 0.5
    }

    /// The row at the top of the page and how far down the window it starts, so rows added above it
    /// by a slice of the opening leave a reader who has scrolled looking at the same words.
    private func visibleAnchor() -> (id: String, offset: CGFloat)? {
        let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let first = collectionView.indexPathsForVisibleItems.sorted().first { path in
            (collectionView.layoutAttributesForItem(at: path)?.frame.maxY ?? 0) > top
        }
        guard let first, let id = dataSource.itemIdentifier(for: first),
            let frame = collectionView.layoutAttributesForItem(at: first)?.frame
        else { return nil }
        return (id, frame.minY - top)
    }

    private func restoreVisibleAnchor(_ anchor: (id: String, offset: CGFloat)) {
        guard let path = dataSource.indexPath(for: anchor.id),
            let frame = collectionView.layoutAttributesForItem(at: path)?.frame
        else { return }
        let inset = collectionView.adjustedContentInset
        collectionView.contentOffset.y = frame.minY - anchor.offset - inset.top
    }

    func revealTranscript() {
        guard !hasRevealed else { return }
        hasRevealed = true
        settleUntil = CACurrentMediaTime() + 4
        revealFallback?.cancel()
        parkOnEndBeforeFirstLayout()
        collectionView.layoutIfNeeded()
        scrollToBottom(animated: false)
        AppLogger.performance.info(
            "journey revealed session=\(viewModel.session.id) ms=\(FirstAnswerClock.milliseconds(since: openedAt)) rows=\(appliedIDs.count)/\(orderedIDs.count)")
        let hasRows =
            !orderedIDs.isEmpty || !viewModel.pendingSends.isEmpty || !viewModel.queued.isEmpty
        updatePlaceholders(hasRows: hasRows, for: viewModel.state)
        UIView.animate(withDuration: 0.22, delay: 0, options: .curveEaseOut) {
            self.collectionView.alpha = 1
        }
    }

    func withdrawResolvedRequests(previousPermission: String?, previousQuestion: String?) {
        var stale: [String] = []
        if let previousPermission, previousPermission != pendingPermission?.id {
            stale.append("perm:\(previousPermission)")
        }
        if let previousQuestion, previousQuestion != pendingQuestion?.id {
            stale.append("question:\(previousQuestion)")
        }
        NotificationManager.withdraw(identifiers: stale)
    }

    func isActivity(_ row: ChatRow) -> Bool {
        if case .activity = row.content { return true }
        return false
    }

    #if DEBUG
        /// Opens the first attached image full screen, so the viewer can be
        /// captured from a script the way every other screen already can be.
        func openFirstAttachment() {
            for cell in collectionView.visibleCells {
                if let gallery = cell as? PictureGalleryCell {
                    pictureGalleryCell(gallery, didTapPictureAt: 0)
                    return
                }
                guard let cell = cell as? ImageBubbleCell, let image = cell.displayedImage else {
                    continue
                }
                imageBubbleCell(cell, didTap: image, from: cell.imageContainer)
                return
            }
        }

        /// Runs the save an attachment's context menu would run, so the photo
        /// library path can be exercised from a script the way the viewer can.
        func saveFirstAttachment() {
            for cell in collectionView.visibleCells {
                guard let payload = (cell as? ImageBubbleCell)?.payload else { continue }
                saveToPhotos(payload)
                return
            }
        }
    #endif
}
