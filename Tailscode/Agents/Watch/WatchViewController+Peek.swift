import QuartzCore
import TailscodeCore
import UIKit

extension AgentsPeekTarget {
    /// The peek of a tile: the board's own row or card when the tower has one, so its facts are
    /// there, and the tile's own words when it has not.
    init(tile: WallTile, board: AgentBoard) {
        if let row = board.row(tile.id) {
            self.init(row: row)
        } else if let card = board.ask(tile.id) {
            self.init(ask: card)
        } else {
            self.init(tile: tile)
        }
    }
}

/// Sees every touch in the peek and takes none of them, so the wall can tell the person is still there.
final class WatchTouchSpy: UIGestureRecognizer {
    var onTouch: (() -> Void)?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { onTouch?() }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { onTouch?() }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
}

extension WatchViewController {
    static let peekIdle: TimeInterval = 20

    func presentPeek(tile id: String) {
        guard let tile = stage.wall.tiles.first(where: { $0.id == id }) else { return }
        present(target: AgentsPeekTarget(tile: tile, board: feed.board), anchor: wordsView.frame(ofTile: id))
    }

    func presentPeek(session id: String) {
        let key = id
        if let row = feed.board.row(key) {
            present(target: AgentsPeekTarget(row: row), anchor: nil)
        } else if let card = feed.board.ask(key) {
            present(target: AgentsPeekTarget(ask: card), anchor: nil)
        }
    }

    private func present(target: AgentsPeekTarget, anchor: CGRect?) {
        guard peek == nil, presentedViewController == nil else { return }
        let sheet = AgentPeekViewController(target: target, hub: AgentsHub.shared)
        sheet.onOpenChat = { [weak self] _, sessionID in self?.openChat(sessionID: sessionID) }
        if let anchor, traitCollection.userInterfaceIdiom == .pad, traitCollection.horizontalSizeClass == .regular {
            sheet.modalPresentationStyle = .popover
            sheet.preferredContentSize = CGSize(width: 420, height: 640)
            sheet.popoverPresentationController?.sourceView = wordsView
            sheet.popoverPresentationController?.sourceRect = anchor
            sheet.popoverPresentationController?.permittedArrowDirections = [.left, .right, .up, .down]
        } else {
            sheet.modalPresentationStyle = .pageSheet
            if let presentation = sheet.sheetPresentationController {
                presentation.detents = [.medium(), .large()]
                presentation.prefersGrabberVisible = true
                presentation.prefersScrollingExpandsWhenScrolledToEdge = true
            }
        }
        sheet.onDismiss = { [weak self] in self?.peekEnded() }
        peek = sheet
        stage.peeking = true
        syncWordsAlpha()
        lastPeekTouch = Date()
        present(sheet, animated: true) { [weak self, weak sheet] in
            guard let self, let sheet else { return }
            let spy = WatchTouchSpy(target: nil, action: nil)
            spy.onTouch = { [weak self] in self?.lastPeekTouch = Date() }
            sheet.view.addGestureRecognizer(spy)
            self.watchPeek()
        }
    }

    /// The peek goes back to the wall by itself after twenty seconds with no touch in it and no
    /// words being typed.
    private func watchPeek() {
        peekTask?.cancel()
        peekTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, let peek = self.peek else { return }
                if peek.nudgeField.isFirstResponder { self.lastPeekTouch = Date() }
                if Date().timeIntervalSince(self.lastPeekTouch) >= Self.peekIdle {
                    peek.dismiss(animated: true)
                    return
                }
            }
        }
    }

    private func peekEnded() {
        peekTask?.cancel()
        peekTask = nil
        stage.peeking = false
        syncWordsAlpha()
        wake()
    }
}
