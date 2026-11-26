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
    /// the question box stays as near the pointer as the screen allows. The box's own growth is
    /// the editor's news (`boxGrew`); a status line or a chip asks again from where it is set.
    /// The same request is measured once, and the window moves only when its height moves.
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

    /// The box took a new height: the card is taller or shorter whatever its status line and its
    /// chips say, so the measure in hand is dropped before the room is asked for again.
    func boxGrew() {
        roomAsked = nil
        makeRoom()
    }

    /// A wrapping label is measured one line tall until it is told the width it wraps at, so the
    /// failure line is given the width it will be laid out at before the card is asked what it
    /// needs: the card is as wide as the panel less the head's own margins. The pin and the
    /// fitting size solve the layout once, and the panel is only resized when that height moves.
    private func fitHeight() {
        guard let card, let chosen = chosenSize, card.frame.width > 0 else { return }
        let room = QuickAskRoom(
            width: card.frame.width,
            status: status.isHidden ? "" : status.stringValue,
            chips: attachments.map(\.name).joined(separator: "\u{1}"),
            completion: completion.isShowing ? completion.fittingSize.height : 0)
        let needed: CGFloat
        if let asked = roomAsked, asked.room == room {
            needed = asked.needed
        } else {
            status.preferredMaxLayoutWidth = room.width - QuickAskRoom.headMargin
            let pin = card.widthAnchor.constraint(equalToConstant: room.width)
            pin.isActive = true
            needed = card.fittingSize.height
            pin.isActive = false
            roomAsked = (room, needed)
        }
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
