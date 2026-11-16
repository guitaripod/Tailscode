import AppKit
import TailscodeCore

/// Where a picture of the conversation stands in the transcript right now: the view that draws
/// it, the part of that view its pixels cover, its corners, the pixels themselves, and a way to
/// stop drawing it while the picture is in the viewer.
///
/// The viewer opens a picture out of where it stands and puts it back there, so it asks each time
/// rather than keeping an answer: a transcript streams and reflows under an open viewer.
@MainActor
struct PictureStand {
    let view: NSView
    let rect: NSRect
    let radius: CGFloat
    let picture: NSImage?
    let setOut: (Bool) -> Void

    /// How much of a tile has to show for a picture to fly to it.
    static let inSight: CGFloat = 0.5

    /// The rectangle the picture covers in `space`, or nil while less than half of it shows.
    func frame(in space: NSView) -> NSRect? {
        guard view.window != nil, rect.width > 0, rect.height > 0 else { return nil }
        let seen = view.visibleRect.intersection(rect)
        guard !seen.isNull, seen.width * seen.height >= Self.inSight * rect.width * rect.height else {
            return nil
        }
        return view.convert(rect, to: space)
    }

    /// The part of `bounds` a picture of this size covers: all of it when the picture is cropped
    /// to it, the fitted picture alone when it is letterboxed inside.
    static func covered(by size: NSSize, in bounds: NSRect, fitted: Bool) -> NSRect {
        guard fitted, size.width > 0, size.height > 0 else { return bounds }
        let room = PictureFlight.Rect(
            x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height)
        let covered = PictureFlight.stage(aspect: size.width / size.height, in: room)
        return NSRect(x: covered.x, y: covered.y, width: covered.width, height: covered.height)
    }
}

/// A view that draws pictures of the conversation and can say where one of them is.
@MainActor
protocol PictureStanding: NSView {
    func pictureStand(for key: String) -> PictureStand?
}

extension NSView {
    /// The first place under this view where the picture `key` is drawn.
    @MainActor
    func pictureStand(under key: String) -> PictureStand? {
        if let standing = self as? PictureStanding, let stand = standing.pictureStand(for: key) {
            return stand
        }
        for child in subviews {
            if let stand = child.pictureStand(under: key) { return stand }
        }
        return nil
    }
}
