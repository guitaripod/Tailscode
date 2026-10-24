import MidgarCore
import TailscodeCore
import CodingAgentKit
import UIKit

extension ChatViewController {
    private static let liveCompactionID = "compaction:live"
    /// How long the card may outlive the clear while it waits for the seam it was promised.
    private static let seamPatience: TimeInterval = 6

    static func isSeam(_ row: ChatRow) -> Bool {
        if case .compaction = row.content { return true }
        return false
    }

    /// The card for the compaction the server is running right now, and when it may go.
    ///
    /// One identifier, always, with running and failed carried in the row's state: a compaction
    /// that fails is the same card changing what it says, and naming the two states differently
    /// made it a delete and an insert — the card jumped rather than turned over. And a compaction
    /// that succeeds is cleared by one event and laid into the transcript by the next, so the card
    /// is held until the seam it promised is actually among the rows. A refusal promises no seam
    /// and is dropped as soon as the server stops reporting it, and a promise nothing keeps expires
    /// rather than leaving the transcript claiming work that is not happening.
    func updateLiveCompaction(_ activity: CompactionActivity?, seams: Int, queued: Bool) {
        if let activity {
            if let failure = activity.failure {
                liveCompaction = CompactionRow(id: Self.liveCompactionID, state: .failed(failure))
                promisedSeamCount = nil
                unwatchSeamPromise()
            } else {
                liveCompaction = CompactionRow(
                    id: Self.liveCompactionID,
                    state: .running(startedAt: activity.startedAt, waiting: queued))
                if promisedSeamCount == nil { promisedSeamCount = seams + 1 }
                promisedSeamDeadline = Date().addingTimeInterval(Self.seamPatience)
                watchSeamPromise()
            }
            return
        }
        let waiting = promisedSeamCount.map { seams < $0 && Date() < promisedSeamDeadline } ?? false
        guard !waiting else {
            watchSeamPromise()
            return
        }
        unwatchSeamPromise()
        liveCompaction = nil
        promisedSeamCount = nil
    }

    /// Reads the promise's deadline on a clock of its own, and re-renders once when it runs out.
    ///
    /// The transcript is drawn from states arriving, so the only moment the card is asked to justify
    /// itself is a moment something else happened — and the whole point of the deadline is the case
    /// where nothing else is going to. One sleep to the deadline, re-armed if the promise was
    /// renewed while it slept (a running compaction pushes it out on every event), and a single
    /// re-render of the last state when it has genuinely expired, which is the render that lets the
    /// card go.
    private func watchSeamPromise() {
        guard seamWatch == nil else { return }
        seamWatch = Task { [weak self] in
            while true {
                guard let self, self.promisedSeamCount != nil else { break }
                let remaining = self.promisedSeamDeadline.timeIntervalSinceNow
                guard remaining > 0 else { break }
                do {
                    try await Task.sleep(for: .seconds(remaining))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, let self else { return }
            self.seamWatch = nil
            guard self.promisedSeamCount != nil, let state = self.lastRenderedState else { return }
            self.render(state)
        }
    }

    private func unwatchSeamPromise() {
        seamWatch?.cancel()
        seamWatch = nil
    }

    /// Re-runs one row's cell provider so a now-decoded image is laid out at
    /// its real aspect ratio instead of the placeholder's.
    func remeasureRow(_ id: String) {
        var snapshot = dataSource.snapshot()
        guard snapshot.itemIdentifiers.contains(id) else { return }
        snapshot.reconfigureItems([id])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Opens or folds a link rail in place. The reader's eyes are on the rail they tapped, so the
    /// transcript stops chasing the bottom, the change takes 160 ms (none under Reduce Motion),
    /// and the rail is held where it was on the screen: everything above it stays exactly where it
    /// is, and only when the opened rows would run past the end of the window does the page move,
    /// by the least that shows them.
    func toggleRail(_ id: String) {
        userScrolledUp = true
        let before = railAnchor(for: id)
        let opening = railExpansion.toggle(id)
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems([id])
        let change = { [weak self] in
            guard let self else { return }
            self.dataSource.apply(snapshot, animatingDifferences: false)
            self.collectionView.performBatchUpdates(nil)
            self.collectionView.layoutIfNeeded()
            self.holdRail(id, at: before)
        }
        if UIAccessibility.isReduceMotionEnabled {
            change()
        } else {
            UIView.animate(
                withDuration: 0.16, delay: 0, options: [.curveEaseOut, .allowUserInteraction],
                animations: change)
        }
        if opening { revealToggledRow(id) }
    }

    /// Where a row stands on the screen and which row heads the visible page, read before a
    /// change so it can be put back after.
    private struct RailAnchor {
        let screenY: CGFloat
        let firstVisibleID: String?
        let firstVisibleY: CGFloat
    }

    private func railAnchor(for id: String) -> RailAnchor? {
        guard let index = dataSource.snapshot().indexOfItem(id),
            let attributes = collectionView.layoutAttributesForItem(
                at: IndexPath(item: index, section: 0))
        else { return nil }
        let offset = collectionView.contentOffset.y
        let first = collectionView.indexPathsForVisibleItems.min()
            .flatMap { path -> (String, CGFloat)? in
                guard let itemID = dataSource.itemIdentifier(for: path),
                    let frame = collectionView.layoutAttributesForItem(at: path)?.frame
                else { return nil }
                return (itemID, frame.minY - offset)
            }
        return RailAnchor(
            screenY: attributes.frame.minY - offset, firstVisibleID: first?.0,
            firstVisibleY: first?.1 ?? 0)
    }

    private func holdRail(_ id: String, at before: RailAnchor?) {
        guard let before, let after = railAnchor(for: id) else { return }
        let drift = after.screenY - before.screenY
        if abs(drift) > 0.5 {
            collectionView.contentOffset.y += drift
        }
        #if DEBUG
            let held = railAnchor(for: id)
            MidgarLog.info(
                "rail anchor id=\(id) before=\(Int(before.screenY.rounded())) after=\(Int((held?.screenY ?? 0).rounded())) firstVisible=\(before.firstVisibleID ?? "-") firstBefore=\(Int(before.firstVisibleY.rounded())) firstAfter=\(Int((held?.firstVisibleY ?? 0).rounded())) session=\(viewModel.session.id)",
                category: .chat
            )
        #endif
    }

    /// Opening or closing a row is a reading gesture: the person's eyes are on the header they
    /// tapped, so the transcript stops chasing the bottom — a stream that kept scrolling would
    /// push the very card they opened out from under them — and the view moves only as far as
    /// `revealToggledRow` needs to show the opened body, never past the tapped header. Their own
    /// next prompt, or the jump pill, is what re-engages following.
    func toggleReasoning(_ id: String) {
        userScrolledUp = true
        let opened = !expandedReasoning.contains(id)
        if opened {
            expandedReasoning.insert(id)
        } else {
            expandedReasoning.remove(id)
        }
        refocusCascade(on: id)
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems([id])
        dataSource.apply(snapshot, animatingDifferences: false)
        if opened { revealToggledRow(id) }
    }

    /// The gentlest scroll that shows a just-opened body: down only as far as the row's end (or
    /// the screen can hold), and never past the point where the tapped header would leave the
    /// top — a header that flies off the screen is the person losing what they pointed at.
    func revealToggledRow(_ id: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.collectionView.layoutIfNeeded()
            guard let index = self.dataSource.snapshot().indexOfItem(id),
                let attributes = self.collectionView.layoutAttributesForItem(
                    at: IndexPath(item: index, section: 0))
            else { return }
            let inset = self.collectionView.adjustedContentInset
            let offset = self.collectionView.contentOffset.y
            let margin: CGFloat = 8
            let visibleTop = offset + inset.top
            let visibleBottom = offset + self.collectionView.bounds.height - inset.bottom
            let needed = attributes.frame.maxY + margin - visibleBottom
            let slack = attributes.frame.minY - margin - visibleTop
            let delta = min(needed, slack)
            guard delta > 0 else { return }
            let ceiling = max(
                -inset.top,
                self.collectionView.contentSize.height + inset.bottom
                    - self.collectionView.bounds.height)
            self.collectionView.setContentOffset(
                CGPoint(x: 0, y: min(offset + delta, ceiling)), animated: true)
        }
    }

    /// The air above the row at a place in the list, which is the whole of the transcript's
    /// vertical rhythm: each row is classified, the metrics answer for the pair, and nothing else
    /// picks a number.
    func gapAbove(forID id: String) -> CGFloat {
        guard let index = orderIndex(of: id) else { return 0 }
        return gap(before: index, in: renderedIDOrder)
    }

    func orderIndex(of id: String) -> Int? {
        if let table = renderedOrderIndex { return table[id] }
        var table: [String: Int] = [:]
        table.reserveCapacity(renderedIDOrder.count)
        for (index, key) in renderedIDOrder.enumerated() { table[key] = index }
        renderedOrderIndex = table
        return table[id]
    }

    func gap(
        before index: Int, in order: [String], metrics: ChatMetrics = Theme.Chat.metrics
    ) -> CGFloat {
        guard order.indices.contains(index) else { return 0 }
        let id = order[index]
        let previous = index > 0 ? order[index - 1] : nil
        return ChatSpacing.gap(
            from: previous.map(rowClass(ofID:)), to: rowClass(ofID: id),
            sameSend: previous.map { sharesSend($0, id) } ?? false,
            metrics: metrics,
            previousIsStamp: previous.map(isStamp(_:)) ?? false, nextIsStamp: isStamp(id))
    }

    private func isStamp(_ id: String) -> Bool {
        if case .timestamp = rowsByID[id]?.content { return true }
        return false
    }

    func gaps(for order: [String], metrics: ChatMetrics) -> [String: CGFloat] {
        var table: [String: CGFloat] = [:]
        table.reserveCapacity(order.count)
        for index in order.indices {
            table[order[index]] = gap(before: index, in: order, metrics: metrics)
        }
        return table
    }

    /// What a row is for the purpose of the space around it. A row the builder made says so
    /// itself; the rows this screen docks at the end — what is being sent, what is waiting, a
    /// question or a permission, a card about the turn — are named by their identity, and the
    /// cards that keep a plate take the block gap.
    private func rowClass(ofID id: String) -> ChatRowClass {
        if let row = rowsByID[id] { return ChatSpacing.rowClass(of: row) }
        if id.hasPrefix("pending:") { return id.contains(":img") ? .picture : .prompt }
        if id.hasPrefix("queued:") { return .prompt }
        if id == Self.liveCompactionID { return .seam }
        if id == "thinking" { return .furniture }
        return .code
    }

    /// Whether two rows are one person's send: a prompt and the pictures clipped to it, which sit
    /// close together instead of a turn apart.
    private func sharesSend(_ first: String, _ second: String) -> Bool {
        if first.hasPrefix("pending:"), second.hasPrefix("pending:") {
            return Self.sendKey(first) == Self.sendKey(second)
        }
        guard let a = rowsByID[first], let b = rowsByID[second] else { return false }
        return a.role == .user && b.role == .user && a.messageID == b.messageID
    }

    private static func sendKey(_ id: String) -> String {
        id.split(separator: ":", maxSplits: 2).prefix(2).joined(separator: ":")
    }
}
