import AppKit
import TailscodeCore

extension QuickAskPanel {
    /// The screen the quick ask opens on: the one the person is working on — the screen of the
    /// window it was asked over, else the one holding the key window, else the one under the
    /// pointer.
    static func activeScreen(near window: NSWindow?) -> NSScreen? {
        if let screen = window?.screen { return screen }
        if let screen = NSScreen.main { return screen }
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? NSScreen.screens.first
    }

    /// Opens at the size it was last given and where it was last left on this screen — or, on a
    /// screen it never stood on, at the same share of it as where it was left last — measured
    /// against the part of the screen the menu bar and the Dock leave, the way Core keeps it.
    func place(on screen: NSScreen?) {
        guard let screen else {
            center()
            return
        }
        let area = screen.visibleFrame
        let placement = QuickAskPlacementStore.load()
        let size = QuickAskGeometry.size(
            placement, screenWidth: area.width, screenHeight: area.height)
        let origin = QuickAskGeometry.origin(
            placement, screen: screen.localizedName, screenWidth: area.width,
            screenHeight: area.height, width: size.width, height: size.height)
        setFrame(
            NSRect(
                x: area.minX + origin.x, y: area.maxY - origin.y - size.height,
                width: size.width, height: size.height),
            display: false)
        chosenSize = frame.size
        isPlaced = true
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
    /// do. The box measures itself a runloop pass after the keystroke that changed it, so the room
    /// is made now and once more after that pass.
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
            grown.origin.y = max(area.minY, area.maxY - height)
        }
        setFrame(grown, display: true)
    }

    /// What the person did to the panel is kept as it closes: its size, and its place on the screen
    /// it stands on, measured from that screen's top-left so a taller or shorter screen keeps the
    /// panel under the menu bar where it was.
    func remember() {
        guard isPlaced, let screen = screen ?? Self.activeScreen(near: nil) else { return }
        let area = screen.visibleFrame
        let size = chosenSize ?? frame.size
        QuickAskPlacementStore.recordSize(width: size.width, height: size.height)
        QuickAskPlacementStore.recordSpot(
            x: frame.minX - area.minX, y: area.maxY - frame.maxY, screen: screen.localizedName,
            screenWidth: area.width, screenHeight: area.height)
    }
}
