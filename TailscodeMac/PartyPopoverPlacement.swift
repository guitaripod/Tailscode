import AppKit

/// Which side of its anchor the party stands on.
enum PartyPopoverSide: Sendable {
    case above
    case below

    var other: PartyPopoverSide { self == .above ? .below : .above }
}

/// Where the party goes for an anchor that can be anywhere on the display: the side it would like
/// if the cards fit there, the other side if they fit there, and otherwise the roomier one, with the
/// height held to what the display can show. A popover AppKit places alone slides over its anchor
/// when neither side has room; deciding the side first keeps it off the model pill whenever either
/// side could hold it, and the visible frame already leaves out the menu bar, the notch and the Dock.
struct PartyPopoverPlacement: Equatable {
    let side: PartyPopoverSide
    let maxHeight: CGFloat

    static let arrowRoom: CGFloat = 22
    static let margin: CGFloat = 8

    static func decide(
        anchor: NSRect, content: NSSize, visible: NSRect, prefers: PartyPopoverSide
    ) -> PartyPopoverPlacement {
        let above = visible.maxY - anchor.maxY - margin
        let below = anchor.minY - visible.minY - margin
        let need = content.height + arrowRoom
        func room(_ side: PartyPopoverSide) -> CGFloat { side == .above ? above : below }
        let side: PartyPopoverSide
        if room(prefers) >= need {
            side = prefers
        } else if room(prefers.other) >= need {
            side = prefers.other
        } else {
            side = above >= below ? .above : .below
        }
        return PartyPopoverPlacement(
            side: side, maxHeight: max(visible.height - 2 * margin - arrowRoom, 0))
    }

    /// Where the popover's content stands on the display for `size`, as AppKit places it: against
    /// the anchor on the chosen side, centred on it, then slid back inside the visible frame.
    func contentFrame(anchor: NSRect, size: NSSize, visible: NSRect) -> NSRect {
        let height = min(size.height, maxHeight)
        let y =
            side == .above
            ? anchor.maxY + Self.arrowRoom / 2
            : anchor.minY - Self.arrowRoom / 2 - height
        let x = anchor.midX - size.width / 2
        return NSRect(
            x: min(max(x, visible.minX + Self.margin), visible.maxX - Self.margin - size.width),
            y: min(max(y, visible.minY + Self.margin), visible.maxY - Self.margin - height),
            width: size.width, height: height)
    }

    /// The edge of the anchor's own bounds that faces the chosen side, which depends on whether the
    /// anchor's coordinates run down the screen or up it.
    func edge(for anchor: NSView) -> NSRectEdge {
        let top: NSRectEdge = anchor.isFlipped ? .minY : .maxY
        let bottom: NSRectEdge = anchor.isFlipped ? .maxY : .minY
        return side == .above ? top : bottom
    }

    /// The anchor and the room around it in screen coordinates, or nil for a view that is not on a
    /// display (a window never ordered in, a Mac with no screen to ask).
    @MainActor
    static func surroundings(of anchor: NSView) -> (anchor: NSRect, visible: NSRect)? {
        guard let window = anchor.window, let screen = window.screen ?? NSScreen.main else {
            return nil
        }
        return (
            window.convertToScreen(anchor.convert(anchor.bounds, to: nil)), screen.visibleFrame
        )
    }
}
