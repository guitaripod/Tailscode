import TailscodeCore
import UIKit

/// Where a picture of the conversation stands in the transcript right now: the view that draws
/// it, the part of that view its pixels cover, its corners, and the pixels themselves.
///
/// The viewer opens a picture out of its home and puts it back there, so what it needs is where
/// the picture is at this moment and not where it was when it was pressed: a transcript scrolls,
/// streams and reflows under an open viewer.
@MainActor
struct PictureHome {
    let view: UIView
    let pixels: CGRect
    let cornerRadius: CGFloat
    let image: UIImage?

    /// The rectangle the picture covers in `space`, or nil while none of it is on the screen.
    func frame(in space: UIView) -> CGRect? {
        guard let window = view.window, pixels.width > 0, pixels.height > 0 else { return nil }
        let onScreen = view.convert(pixels, to: window)
        guard window.bounds.intersects(onScreen) else { return nil }
        return space.convert(onScreen, from: window)
    }

    /// The rectangle a picture covers inside a view that draws it: all of a view that crops it,
    /// and the fitted picture alone inside one that letterboxes it.
    static func pixels(of image: UIImage?, in bounds: CGRect, fitted: Bool) -> CGRect {
        guard fitted, let image, image.size.height > 0 else { return bounds }
        let room = PictureFlight.Rect(
            x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height)
        let covered = PictureFlight.stage(aspect: image.size.width / image.size.height, in: room)
        return CGRect(x: covered.x, y: covered.y, width: covered.width, height: covered.height)
    }
}

/// A cell that draws pictures and can say where one of them is.
@MainActor
protocol PictureHoming: AnyObject {
    /// The home of the picture at `index` among the ones this cell was handed, or nil when the
    /// cell draws no tile for it.
    func pictureHome(at index: Int) -> PictureHome?
}
