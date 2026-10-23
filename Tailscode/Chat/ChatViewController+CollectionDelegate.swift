import TailscodeCore
import UIKit

extension ChatViewController: UICollectionViewDelegate {
    /// A waiting message is the one row in a transcript that is still yours, so touching it opens
    /// it for rewriting rather than doing nothing. Everything else in the transcript has happened
    /// and a tap on it means nothing.
    func collectionView(
        _ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath
    ) -> Bool {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return false }
        return id.hasPrefix("queued:") || inspectableTable(id) != nil
    }

    func collectionView(
        _ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath
    ) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        if let table = inspectableTable(id) {
            Theme.Haptics.tap()
            workspace?.inspector.show(TableInspectorViewController(table: table))
            return
        }
        guard let message = viewModel.queueDisplay.row(key: id) else { return }
        editQueued(message)
    }

    func collectionView(
        _ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        let id = dataSource.itemIdentifier(for: indexPath)
        decorateFindRing(cell, on: id != nil && id == findHighlightedID)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
            let id = dataSource.itemIdentifier(for: indexPath)
        else { return nil }
        if id.hasPrefix("queued:"), let message = viewModel.queueDisplay.row(key: id) {
            return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) {
                [weak self] _ in
                var actions: [UIAction] = []
                if message.canEdit {
                    actions.append(
                        UIAction(
                            title: String(localized: "Edit"), image: UIImage(systemName: "pencil")
                        ) { _ in
                            self?.editQueued(message)
                        })
                }
                actions.append(
                    UIAction(
                        title: String(localized: "Remove from queue"),
                        image: UIImage(systemName: "trash"),
                        attributes: .destructive
                    ) { _ in
                        Theme.Haptics.warning()
                        self?.viewModel.removeQueued(message)
                    })
                return UIMenu(children: actions)
            }
        }
        guard let text = messageText(for: id), !text.isEmpty else { return nil }
        let source = collectionView.cellForItem(at: indexPath) ?? collectionView
        let revertMessage = chatMessage(for: id).flatMap { message in
            RevertReading.offersUndo(on: message, capabilities: viewModel.backend.capabilities)
                ? message : nil
        }

        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) {
            [weak self] _ in
            var actions: [UIAction] = [
                UIAction(
                    title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")
                ) { _ in
                    UIPasteboard.general.string = text
                    Theme.Haptics.success()
                }
            ]
            if let code = Self.firstCodeBlock(in: text) {
                actions.append(
                    UIAction(
                        title: String(localized: "Copy code"),
                        image: UIImage(systemName: "curlybraces")
                    ) { _ in
                        UIPasteboard.general.string = code
                        Theme.Haptics.success()
                    })
            }
            actions.append(
                UIAction(
                    title: String(localized: "Quote"),
                    image: UIImage(systemName: "quote.opening")
                ) { _ in
                    self?.composer.insertQuote(text)
                })
            actions.append(
                UIAction(
                    title: String(localized: "Share"),
                    image: UIImage(systemName: "square.and.arrow.up")
                ) { _ in
                    self?.shareText(text, from: source)
                })
            if let revertMessage {
                actions.append(
                    UIAction(
                        title: RevertReading.actionTitle,
                        image: UIImage(systemName: RevertReading.actionSymbol),
                        attributes: .destructive
                    ) { _ in
                        self?.confirmRevert(to: revertMessage)
                    })
            }
            return UIMenu(children: actions)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        syncFAB()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        keepEndClear()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        userScrolledUp = true
        settleUntil = 0
        canvasIntent = []
        canvasPinned = false
        canvasRiseDeadline = nil
        canvasRising = false
        followClock = nil
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if isAtBottom() { userScrolledUp = false }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate && isAtBottom() { userScrolledUp = false }
    }

    private func messageText(for id: String) -> String? {
        guard let row = rowsByID[id] else { return nil }
        switch row.content {
        case .text(let text):
            return text
        case .code(let block):
            return block.source
        case .table(let table):
            return table.markdown
        case .tableDraft(let draft):
            return draft.reading
        case .activity(let steps):
            return steps.map { step in
                switch step {
                case .reasoning(let text): return text
                case .tool(let call): return call.output ?? call.title ?? call.name
                }
            }.joined(separator: "\n\n")
        case .brain(let brainRow):
            return brain.markdown(for: brainRow.turnID)
        case .subagent(let card):
            return Self.subagentMarkdown(card)
        case .workflow(let run):
            return Self.workflowMarkdown(run)
        case .subagentGroup:
            return nil
        case .taskBoard(let board):
            return board.items.map(\.subject).joined(separator: "\n")
        case .file(let file), .image(let file):
            return file.filename ?? file.mime
        case .compaction(let row):
            return row.compaction?.summary
        case .answerless(let turn):
            return turn.detail
        case .designBoard(let sighting):
            let reading = DesignCardReading.make(sighting: sighting, board: nil)
            return "\(reading.title) — \(reading.detail)"
        case .responseStats(let stats):
            return stats.line
        case .linkRail(let run):
            return run.addresses.joined(separator: "\n")
        case .pictures(let files):
            return files.compactMap { $0.filename ?? $0.mime }.joined(separator: "\n")
        case .failed(let turn):
            return turn.reason
        case .timestamp, .note:
            return nil
        }
    }

    /// A shared transcript has to keep the seam: the messages above it are still there to read, but
    /// they stopped being what the agent knew.
    static func compactionMarkdown(_ row: CompactionRow) -> String {
        let compacted = String(localized: "Context compacted")
        guard let compaction = row.compaction else { return "---\n\n_\(compacted)._" }
        var line = "---\n\n_\(compacted)"
        if let before = compaction.tokensBefore, let after = compaction.tokensAfter {
            line += ": "
                + String(
                    localized:
                        "\(StatusFacts.tokens(before)) → \(StatusFacts.tokens(after)) tokens")
        }
        line += " — "
            + String(localized: "everything above this point was replaced by a summary.") + "_"
        guard let summary = compaction.summary, !summary.isEmpty else { return line }
        let heading = String(localized: "Summary")
        return line
            + "\n\n<details><summary>\(heading)</summary>\n\n\(summary)\n\n</details>"
    }

    /// A shared transcript keeps a spawned agent inside the conversation it
    /// belongs to, indented under the line that spawned it.
    static func subagentMarkdown(_ card: SubagentCard) -> String {
        var lines = [
            "_" + String(localized: "Agent") + "\(card.agentType.map { " · \($0)" } ?? "")"
                + "_: \(card.title)"
        ]
        for step in card.steps {
            switch step {
            case .reasoning(let text): lines.append("> \(text)")
            case .tool(let call): lines.append("> [\(call.title ?? call.name)]")
            }
        }
        if let report = card.report { lines.append("> \(report)") }
        return lines.joined(separator: "\n")
    }

    private func shareText(_ text: String, from source: UIView) {
        let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = source
        sheet.popoverPresentationController?.sourceRect = source.bounds
        present(sheet, animated: true)
    }

    private static func firstCodeBlock(in text: String) -> String? {
        let parts = text.components(separatedBy: "```")
        guard parts.count >= 3 else { return nil }
        var block = parts[1]
        if let newline = block.firstIndex(of: "\n") {
            block = String(block[block.index(after: newline)...])
        }
        let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension ChatViewController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        refreshAgentsChip()
    }
}

/// The press that reports a finger on the transcript watches rather than claims: it runs beside the
/// scroll view's pan, the keyboard-dismissing tap and every button inside a cell, so nothing it
/// observes is taken away from the row underneath it.
extension ChatViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }

    /// A tap on the transcript puts the keyboard away — except the tap that asked for it. A card
    /// with a field in it is part of the transcript, and a finger landing in that field means to
    /// type, not to dismiss.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
    ) -> Bool {
        guard gestureRecognizer === transcriptDismissTap else { return true }
        var view = touch.view
        while let candidate = view {
            if candidate is UITextInput { return false }
            view = candidate.superview
        }
        return true
    }
}
