import QuartzCore
import TailscodeCore
import UIKit

extension WatchViewController {
    static let controlsLast: Duration = .seconds(3)

    func wireControls() {
        controls.onDone = { [weak self] in self?.close() }
        controls.onDim = { [weak self] in self?.toggleDim() }
        controls.onStyle = { [weak self] in self?.presentStyle() }
        controls.dimButton.addAction(UIAction { [weak self] _ in self?.resetControlsTimer() }, for: .touchDown)
    }

    var isLaptop: Bool { stage.layout.mode == .laptop }

    func toggleControls() {
        if isLaptop { return }
        if controls.isHidden || controls.alpha < 0.5 {
            showControls()
        } else {
            hideControls()
        }
    }

    func showControls() {
        updateControls(now: Date())
        controls.isHidden = false
        UIView.animate(withDuration: 0.25) { self.controls.alpha = 1 }
        resetControlsTimer()
    }

    func hideControls() {
        controlsTask?.cancel()
        controlsTask = nil
        guard !isLaptop else { return }
        UIView.animate(
            withDuration: 0.25, animations: { self.controls.alpha = 0 },
            completion: { _ in if self.controls.alpha < 0.05 { self.controls.isHidden = true } })
    }

    func resetControlsTimer() {
        controlsTask?.cancel()
        controlsTask = nil
        guard !isLaptop, !controls.isHidden, controls.alpha > 0.05 else { return }
        controlsTask = Task { [weak self] in
            try? await Task.sleep(for: Self.controlsLast)
            guard !Task.isCancelled, let self else { return }
            self.hideControls()
        }
    }

    /// Places the capsule: at the foot of the laptop's stable half when the screen is folded that way,
    /// and otherwise centred at the bottom of the safe area (on the right page of a book, never across
    /// the fold).
    func updateControls(now: Date) {
        let layout = stage.layout
        let ask = stage.wall.tiles.first { $0.state.isNeedsYou && $0.ask?.isApproval == true }
        let shown = isLaptop ? ask : nil
        controls.update(dimmed: stage.dimTarget > 0.5, ask: shown, palette: stage.palette)
        if isLaptop, let rect = layout.controls, rect.width > 0 {
            controls.frame = rect.cgRect.rounded()
            controlsPinned = true
            controlsTask?.cancel()
            controlsTask = nil
            if controls.isHidden || controls.alpha < 1 {
                controls.isHidden = false
                controls.alpha = 1
            }
            controls.setNeedsLayout()
            return
        }
        if controlsPinned {
            controlsPinned = false
            hideControls()
        }
        let insets = view.safeAreaInsets
        let height = WatchControlsView.height
        let area: CGRect
        if layout.mode == .book, let page = layout.pages.last {
            area = page.cgRect
        } else {
            area = CGRect(
                x: insets.left, y: 0, width: view.bounds.width - insets.left - insets.right,
                height: view.bounds.height)
        }
        let width = controls.contentWidth(limit: max(160, area.width - 32))
        let y = view.bounds.height - max(insets.bottom, 14) - height - 10
        controls.frame = CGRect(x: area.midX - width / 2, y: y, width: width, height: height).rounded()
        controls.setNeedsLayout()
    }

    func toggleDim() {
        let t = CACurrentMediaTime()
        if stage.dimTarget > 0.5 {
            stage.noteActivity(at: t)
        } else {
            stage.dimNow(at: t)
        }
        syncWordsAlpha()
        updateControls(now: Date())
        updateCadence()
    }

    func presentStyle() {
        guard styleSheet == nil, presentedViewController == nil else { return }
        let sheet = WatchStyleViewController.present(from: self)
        sheet.onClose = { [weak self] in
            self?.refresh(.style)
        }
        styleSheet = sheet
        controlsTask?.cancel()
    }
}
