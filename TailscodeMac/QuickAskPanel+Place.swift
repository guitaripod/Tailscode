import AppKit
import TailscodeCore

extension QuickAskPanel {
    /// The screen the quick ask opens on: the one under the pointer, else the one the person is
    /// working on — the screen of the window it was asked over, else the one holding the key window.
    static func screen(under pointer: NSPoint, near window: NSWindow?) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? window?.screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Opens under the pointer at the size it was last given: the head of the question box where
    /// the pointer is, so what is typed starts beside it, and the panel slid in from any edge it
    /// would cross — measured against the part of the screen the menu bar and the Dock leave, the
    /// way Core keeps it.
    func place(at pointer: NSPoint, near window: NSWindow?) {
        guard let screen = Self.screen(under: pointer, near: window) else {
            center()
            return
        }
        let area = screen.visibleFrame
        let size = QuickAskGeometry.size(
            QuickAskPlacementStore.load(), screenWidth: area.width, screenHeight: area.height)
        setFrame(
            NSRect(x: area.minX, y: area.maxY - size.height, width: size.width, height: size.height),
            display: false)
        let origin = QuickAskGeometry.origin(
            pointer: (Double(pointer.x - area.minX), Double(area.maxY - pointer.y)),
            anchor: questionAnchor(), screenWidth: area.width, screenHeight: area.height,
            width: size.width, height: size.height)
        setFrame(
            NSRect(
                x: area.minX + origin.x, y: area.maxY - origin.y - size.height,
                width: size.width, height: size.height),
            display: false)
        chosenSize = frame.size
        isPlaced = true
    }

    /// Where the mark at the head of the question box stands on the panel, from its top-left
    /// corner, once the panel is laid out at the size it opens at.
    func questionAnchor() -> (x: Double, y: Double) {
        contentView?.layoutSubtreeIfNeeded()
        let centre = spark.convert(NSPoint(x: spark.bounds.midX, y: spark.bounds.midY), to: nil)
        return (Double(centre.x), Double(frame.height - centre.y))
    }

    /// The size the person last gave the panel by hand, which is the size it keeps and the size
    /// it is remembered at, whatever it grew to for a while to hold the question.
    func sizeChosen() {
        chosenSize = frame.size
        makeRoom()
    }

    /// The panel is the person's size but never too small for the question: when the box, a
    /// failure, the attachments or the command list need more height than the list can give up,
    /// the panel grows down to hold them, and it goes back to the chosen size once they no longer
    /// do. A panel that would grow past the foot of the screen rises by only what it overflows, so
    /// the question box stays as near the pointer as the screen allows. The box measures itself a
    /// runloop pass after the keystroke that changed it, so the room is made now and once more after
    /// that pass.
    func makeRoom() {
        fitHeight()
        guard !roomScheduled else { return }
        roomScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.roomScheduled = false
            self.fitHeight()
        }
    }

    /// A wrapping label is measured one line tall until it is told the width it wraps at, so the
    /// failure line is given its laid-out width before the card is asked what it needs.
    private func fitHeight() {
        guard let card, let chosen = chosenSize, card.frame.width > 0 else { return }
        card.layoutSubtreeIfNeeded()
        status.preferredMaxLayoutWidth = status.frame.width
        let pin = card.widthAnchor.constraint(equalToConstant: card.frame.width)
        pin.isActive = true
        let needed = card.fittingSize.height
        pin.isActive = false
        let height = max(chosen.height, needed)
        guard abs(height - frame.height) > 0.5 else { return }
        var grown = frame
        grown.origin.y = frame.maxY - height
        grown.size.height = height
        if let area = screen?.visibleFrame, grown.minY < area.minY {
            grown.origin.y = min(area.minY, area.maxY - height)
        }
        setFrame(grown, display: true)
    }

    /// What the person did to the panel is kept as it closes: its size. Its place is not, because
    /// the panel opens under the pointer every time and the Mac always knows where that is.
    func remember() {
        guard isPlaced else { return }
        let size = chosenSize ?? frame.size
        QuickAskPlacementStore.recordSize(width: size.width, height: size.height)
    }
}
