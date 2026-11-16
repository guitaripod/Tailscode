import AppKit
import TailscodeCore

/// The picture in the air between the tile it was pressed in and the page the viewer fits it into
/// (`PictureFlight`). It is the tile's own pixels, drawn filling the view, so as the view's shape
/// nears the picture's own the crop opens and the last frame is the picture whole. It takes no
/// presses and is never part of the key loop: it is on screen for a quarter of a second.
@MainActor
final class FlightPictureView: NSView {
    /// A flight as the sheet was asked to draw it: between two rectangles of the sheet's own
    /// space, tile first, with the corners the tile has.
    struct Plan {
        let picture: NSImage
        let tile: NSRect
        let stage: NSRect
        let tileRadius: CGFloat
        let opening: Bool
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
        isHidden = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var picture: NSImage? {
        didSet { layer?.contents = picture }
    }

    /// Stands at one instant of a plan with no motion, for a held frame.
    func stand(in plan: Plan, time: Double) {
        let moment = PictureFlight.moment(
            time: time, opening: plan.opening, origin: Self.rect(plan.tile), stage: Self.rect(plan.stage),
            tileRadius: Double(plan.tileRadius))
        frame = NSRect(
            x: moment.frame.x, y: moment.frame.y, width: moment.frame.width, height: moment.frame.height)
        layer?.cornerRadius = CGFloat(moment.cornerRadius)
    }

    private static func rect(_ rect: NSRect) -> PictureFlight.Rect {
        PictureFlight.Rect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }
}
