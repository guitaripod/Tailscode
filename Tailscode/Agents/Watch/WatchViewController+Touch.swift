import QuartzCore
import TailscodeCore
import UIKit

extension WatchViewController: UIGestureRecognizerDelegate {
    static let armsAfter: Duration = .milliseconds(180)
    static let hintLasts: Duration = .milliseconds(1600)

    func configureTouch() {
        let recogniser = UILongPressGestureRecognizer(target: self, action: #selector(handleTouch(_:)))
        recogniser.minimumPressDuration = 0
        recogniser.allowableMovement = 10_000
        recogniser.cancelsTouchesInView = false
        recogniser.delegate = self
        view.addGestureRecognizer(recogniser)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(touch.view is UIControl)
    }

    @objc private func handleTouch(_ recogniser: UILongPressGestureRecognizer) {
        let point = recogniser.location(in: view)
        switch recogniser.state {
        case .began: touchBegan(at: point)
        case .changed: touchMoved(to: point)
        case .ended: touchEnded(at: point)
        case .cancelled, .failed: touchCancelled()
        default: break
        }
    }

    private func touchBegan(at point: CGPoint) {
        let t = CACurrentMediaTime()
        wake()
        resetControlsTimer()
        if controls.alpha > 0.05, !controls.isHidden, controls.frame.contains(point) {
            let tile = controls.holdFrame?.insetBy(dx: -6, dy: -6).contains(point) == true ? controls.holdTile : nil
            touch = Touch(target: nil, capsuleTile: tile, start: t, point: point)
            if let tile { beginHold(tile: tile, at: point) }
            return
        }
        let target = wordsView.target(at: point)
        touch = Touch(target: target, capsuleTile: nil, start: t, point: point)
        switch target {
        case .pill(let id, .hold)?:
            beginHold(tile: id, at: point)
        case .tile(let id)?:
            armHold(tile: id, at: point)
        default:
            break
        }
    }

    private func touchMoved(to point: CGPoint) {
        guard stage.held != nil else { return }
        stage.moveHold(to: point)
    }

    private func touchEnded(at point: CGPoint) {
        armTask?.cancel()
        armTask = nil
        defer { touch = nil }
        if stage.held != nil {
            cancelHold(early: true)
            return
        }
        guard let touch, !touch.didHold, hypot(point.x - touch.point.x, point.y - touch.point.y) < 30 else { return }
        if touch.capsuleTile != nil { return }
        if controls.alpha > 0.05, !controls.isHidden, controls.frame.contains(point) { return }
        tap(touch.target)
    }

    private func touchCancelled() {
        armTask?.cancel()
        armTask = nil
        touch = nil
        if stage.held != nil { cancelHold(early: false) }
    }

    private func tap(_ target: WatchTarget?) {
        switch target {
        case .pill(let id, .deny)?:
            deny(id)
        case .pill(let id, .chat)?:
            openChat(tile: id)
        case .pill(_, .hold)?:
            break
        case .tile(let id)?, .worker(let id)?:
            Theme.Haptics.tap()
            presentPeek(tile: id)
        case .chip(let kind)?:
            tapChip(kind)
        case nil:
            toggleControls()
        }
    }

    private func tapChip(_ kind: WatchChipView.Kind) {
        switch kind {
        case .listed(let id):
            Theme.Haptics.tap()
            presentPeek(session: id)
        case .recent(let id):
            openChat(key: id)
        case .count:
            break
        }
    }

    func wake() {
        stage.noteActivity(at: CACurrentMediaTime())
        syncWordsAlpha()
        updateCadence()
    }

    private func armHold(tile id: String, at point: CGPoint) {
        guard canHold(id) else { return }
        armTask?.cancel()
        armTask = Task { [weak self] in
            try? await Task.sleep(for: Self.armsAfter)
            guard !Task.isCancelled, let self, self.touch != nil else { return }
            self.beginHold(tile: id, at: self.touch?.point ?? point)
        }
    }

    func canHold(_ id: String) -> Bool {
        guard let tile = stage.wall.tiles.first(where: { $0.id == id }), tile.state.isNeedsYou,
            tile.ask?.isApproval == true, style.approvals == .hold
        else { return false }
        return !(actions[id]?.isBusy ?? false)
    }

    func beginHold(tile id: String, at point: CGPoint) {
        guard canHold(id), stage.held == nil else { return }
        stage.beginHold(tile: id, at: point, t: CACurrentMediaTime())
        touch?.didHold = true
        Theme.Haptics.selection()
        holdTask?.cancel()
        holdTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(WatchStage.holdLasts))
            guard !Task.isCancelled, let self else { return }
            self.completeHold(id)
        }
        updateCadence()
    }

    private func completeHold(_ id: String) {
        guard stage.held?.tile == id else { return }
        stage.endHold()
        holdTask = nil
        Theme.Haptics.success()
        approve(id)
        updateCadence()
    }

    func cancelHold(early: Bool) {
        holdTask?.cancel()
        holdTask = nil
        let id = stage.held?.tile
        stage.endHold()
        updateCadence()
        guard early, let id else { return }
        flash(.hint, for: id, lasts: Self.hintLasts)
    }

    func flash(_ action: WatchAction, for id: String, lasts: Duration) {
        actions[id] = action
        applyWordsNow()
        Task { [weak self] in
            try? await Task.sleep(for: lasts)
            guard let self, self.actions[id] == action else { return }
            self.actions[id] = nil
            self.applyWordsNow()
        }
    }
}
