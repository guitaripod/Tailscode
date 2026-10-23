import TailscodeCore
import UIKit

extension ChatViewController {
    /// The transcript fills the screen behind the composer, so it reserves the
    /// composer's on-screen height at the bottom (the automatic inset adjustment
    /// already accounts for the home indicator) and — because a `.plain` list is
    /// top-aligned — pads the top so a short transcript rests just above the
    /// composer instead of stranding it under the navigation bar.
    func updateTranscriptInsets() {
        let composerTop = composerAccessories.bounds.height > 0
            ? min(composer.frame.minY, composerAccessories.frame.minY)
            : composer.frame.minY
        let transcriptEnd = collectionView.frame.maxY
        let chromeGap = factsRow.isHidden ? 0 : CGFloat(ChatChrome.transcriptToChrome)
        let composerInset =
            max(0, transcriptEnd - composerTop - collectionView.safeAreaInsets.bottom) + chromeGap
        emptyState.bottomClearance =
            composerAccessories.bounds.height > 0
            ? max(0, composer.frame.minY - composerAccessories.frame.minY) + chromeGap : 0
        let bannerInset: CGFloat = banner.isHidden ? 0 : banner.bounds.height
        let available =
            min(composerTop, transcriptEnd) - collectionView.safeAreaInsets.top - bannerInset
        canvasPadding = freshCanvasPadding(
            chrome: collectionView.safeAreaInsets.top + bannerInset + composerInset)
        let bottomInset = composerInset + canvasPadding
        if abs(collectionView.contentInset.bottom - bottomInset) > 0.5 {
            let parked = isParkedOnEnd()
            collectionView.contentInset.bottom = bottomInset
            collectionView.verticalScrollIndicatorInsets.bottom = composerInset
            if parked { carryEnd() }
        }

        let contentHeight = collectionView.collectionViewLayout.collectionViewContentSize.height
        let topInset =
            bannerInset + (canvasPromptIDs.isEmpty ? max(0, available - contentHeight) : 0)
        if abs(collectionView.contentInset.top - topInset) > 0.5 {
            collectionView.contentInset.top = topInset
        }
        pinFreshCanvas()
        keepEndClear()
    }

    /// A row that measured itself, a transcript that grew: a reader who was on the end of the page
    /// is still on it. While a live answer is being written the glide owns the end, and it
    /// follows the written edge rather than the laid-out one, so this leaves that alone.
    func contentHeightMoved(from old: CGFloat) {
        guard isViewLoaded, view.window != nil, hasRevealed else { return }
        if let unrevealed = unrevealedHeight(), unrevealed > 0 {
            updateTranscriptInsets()
            return
        }
        let inset = collectionView.adjustedContentInset
        let before = max(-inset.top, old + inset.bottom - collectionView.bounds.height)
        let wasOnEnd = collectionView.contentOffset.y >= before - 24
        let following =
            canvasPromptIDs.isEmpty && !userScrolledUp && !isFingerDown
            && (wasOnEnd || CACurrentMediaTime() < settleUntil)
        updateTranscriptInsets()
        if following { carryEnd() }
    }

    /// How far the page is from the offset at which its end rests against whatever stands in
    /// front of it. Measured against the real inset, which the reading `isNearBottom` takes for
    /// following a live answer deliberately does not: with the keyboard up that reading calls
    /// nearly every offset near the bottom.
    private func distanceFromRestingEnd() -> CGFloat {
        let inset = collectionView.adjustedContentInset
        let resting = collectionView.contentSize.height + inset.bottom - collectionView.bounds.height
        return max(-inset.top, resting) - collectionView.contentOffset.y
    }

    /// Whether the reader is on the end of the transcript, so that a change in what stands in
    /// front of it — a chip arriving above the composer, the pill row growing the box, the
    /// keyboard going — has to carry the end along. Without it the room under the transcript
    /// changes and the page stays where it was, which is how the last rows of a chat ended up
    /// behind the chips: the end was scrolled to before the chips had a height.
    func isParkedOnEnd() -> Bool {
        guard canvasPromptIDs.isEmpty, !userScrolledUp, !isFingerDown else { return false }
        return abs(distanceFromRestingEnd()) < 120
    }

    /// The end of the transcript is never left behind the composer: whoever scrolled last — the
    /// keyboard's own animation, a row finishing its measuring — a reader who is on the end is put
    /// back on it once the page has stopped moving.
    func keepEndClear() {
        guard isParkedOnEnd(), distanceFromRestingEnd() > 1 else { return }
        carryEnd()
    }

    /// Puts the end of the transcript back against whatever now stands in front of it.
    func carryEnd() {
        if let unrevealed = unrevealedHeight(), unrevealed > 0 {
            followVisibleEnd()
            return
        }
        let inset = collectionView.adjustedContentInset
        let end = collectionView.contentSize.height + inset.bottom - collectionView.bounds.height
        collectionView.contentOffset.y = max(-inset.top, end)
    }
}

extension ChatViewController {
    func scrollTo(id: String) {
        guard let index = dataSource.snapshot().indexOfItem(id) else { return }
        let path = IndexPath(item: index, section: 0)
        #if DEBUG
            if TourDriver.isFilming,
                let attributes = collectionView.layoutAttributesForItem(at: path)
            {
                tourGlide(
                    to: attributes.frame.minY - collectionView.adjustedContentInset.top - 10,
                    duration: 1.35)
                Theme.Haptics.selection()
                return
            }
        #endif
        collectionView.scrollToItem(at: path, at: .top, animated: true)
        Theme.Haptics.selection()
    }

    #if DEBUG
        /// UIKit's `scrollToItem(animated:)` covers any distance in the same ~0.3s, so
        /// a long jump lands as a snap and a growing transcript re-snaps on every
        /// render. A take needs the list to move like a camera instead: eased, and
        /// paced by how far it actually has to travel.
        private func tourGlide(to y: CGFloat, duration: Double) {
            let top = -collectionView.adjustedContentInset.top
            let bottom = max(
                top,
                collectionView.contentSize.height + collectionView.adjustedContentInset.bottom
                    - collectionView.bounds.height)
            let target = min(max(y, top), bottom)
            guard abs(target - collectionView.contentOffset.y) > 0.5 else { return }
            UIView.animate(
                withDuration: duration, delay: 0,
                options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
            ) {
                self.collectionView.contentOffset.y = target
            }
        }
    #endif
}

extension ChatViewController {
    /// A subagent transcript reads as a run of work plus one answer: its thoughts
    /// and tool calls become steps, and its final message is what it reported to
    /// the conversation that spawned it.
    /// Merges any adjacent activity rows into one, so a run of thinking/tool steps (even across
    /// message boundaries) reads as a single collapsible group.
    /// Following the bottom is suspended for as long as a finger is on the transcript.
    ///
    /// A tap is not a drag, so `userScrolledUp` never hears about it: the finger goes down on a
    /// tool row's header, the next arrival of the turn scrolls the transcript out from under it,
    /// the touch leaves the header's bounds and the release arrives as `touchUpOutside` — the row
    /// never opens, and it looks like an expander that does not work while the agent is busy. So a
    /// press is watched for its own sake: it holds the transcript still where it is, and letting go
    /// re-pins it to the bottom if that is still where the reader was. Opening a row is what turns
    /// following off for real, and it does that itself.
    @objc func transcriptTouchChanged(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            isFingerDown = true
        case .ended, .cancelled, .failed:
            isFingerDown = false
            guard canvasPromptIDs.isEmpty else { break }
            if !userScrolledUp, isNearBottom() { scrollToBottom(animated: true) }
        default:
            break
        }
    }

    func isNearBottom() -> Bool {
        distanceFromBottom() < 120
    }

    /// The page is pushed up by the writing, not by the layout. Every frame the reveal advances,
    /// the room under the prompt is measured again against what is now visible — which is what
    /// lets the canvas go exactly when the written words reach the end of the window — and once
    /// it has gone, a reader at the bottom is kept on the last written line rather than on the
    /// end of a paragraph they cannot see yet.
    func followWriting(revealMoved: Bool) {
        if !canvasPromptIDs.isEmpty {
            if revealMoved { updateTranscriptInsets() }
            pinFreshCanvas()
            return
        }
        guard !userScrolledUp, !isFingerDown, isNearBottom() else {
            followClock = nil
            followGliding = false
            return
        }
        guard revealMoved || followGliding else { return }
        followVisibleEnd(gliding: true)
    }

    /// Puts the last written line at the bottom of the viewport. Nothing happens when the live
    /// row is already whole, which is when following the bottom means what it always did.
    ///
    /// Gliding, the offset eases toward the written end on `FreshCanvas.followTime` rather than
    /// landing on it: the end moves a line at a time, and a page that jumped a line every time
    /// the reveal crossed one twitched under the writing. Either way it never moves back — the
    /// writing only grows, and a target behind the offset is a layout that has not caught up
    /// yet, not a place to go.
    private func followVisibleEnd(gliding: Bool = false) {
        guard let end = visibleEnd(), collectionView.contentSize.height - end > 0 else {
            followClock = nil
            followGliding = false
            return
        }
        let inset = collectionView.adjustedContentInset
        let total = inset.top + max(collectionView.contentSize.height, end) + inset.bottom
        let target =
            FreshCanvas.followOffset(
                visibleEnd: inset.top + end + inset.bottom, viewport: collectionView.bounds.height,
                contentHeight: total) - inset.top
        let current = collectionView.contentOffset.y
        let now = CACurrentMediaTime()
        let elapsed = gliding ? min(max(now - (followClock ?? now), 0), 0.1) : 0
        followClock = now
        let next = gliding && !UIAccessibility.isReduceMotionEnabled
            ? CGFloat(FreshCanvas.glide(current: current, target: target, elapsed: elapsed))
            : max(current, target)
        followGliding = gliding && abs(target - current) > 0.5
        guard abs(next - current) > 0.01 else { return }
        collectionView.contentOffset.y = next
    }

    /// Following resumes only from the bottom itself. A finger that lifted a few lines short of
    /// it has still scrolled up, and a render that yanks it the rest of the way is the transcript
    /// overruling the hand that just moved it.
    func isAtBottom() -> Bool {
        distanceFromBottom() < 8
    }

    private func distanceFromBottom() -> CGFloat {
        FreshCanvas.distanceFromVisibleEnd(
            offset: collectionView.contentOffset.y, viewport: collectionView.bounds.height,
            contentHeight: collectionView.contentSize.height, unrevealed: unrevealedHeight() ?? 0)
    }

    func scrollToBottom(animated: Bool) {
        // Going to the bottom is a decision, and the canvas is the other one. Every caller here
        // means it — the jump pill, a card that needs the keyboard, a reader letting go — so the
        // room goes rather than the two of them taking turns moving the page.
        releaseCanvas()
        let count = dataSource.snapshot().numberOfItems
        guard count > 0 else { return }
        if let unrevealed = unrevealedHeight(), unrevealed > 0 {
            followVisibleEnd()
            return
        }
        let indexPath = IndexPath(item: count - 1, section: 0)
        #if DEBUG
            if TourDriver.isFilming, animated,
                let attributes = collectionView.layoutAttributesForItem(at: indexPath)
            {
                tourGlide(
                    to: attributes.frame.maxY + collectionView.adjustedContentInset.bottom
                        - collectionView.bounds.height,
                    duration: 0.6)
                return
            }
        #endif
        collectionView.scrollToItem(at: indexPath, at: .bottom, animated: animated)
    }
}
