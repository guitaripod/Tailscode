import CoreGraphics
import ImageIO
import TailscodeCore
import UIKit

/// The frame a picture is drawn into, in points, and the density it is drawn at: everything the
/// thumbnail needs to know to be exactly as many pixels as the screen will show of it.
///
/// A bubble pins its width and lets the shape of the picture set the height up to a ceiling; a
/// strip pins its height and lets the shape set the width up to the line. Both clamp the shape
/// with `PictureShape.shape(of:)` and crop what falls outside, so the thumbnail has to
/// cover the cropped frame rather than the box, or a panorama drawn into a bubble is enlarged
/// past its own pixels.
struct ThumbnailBox: Sendable, Hashable {
    enum Anchor: Sendable, Hashable {
        case width
        case height
    }

    let anchor: Anchor
    let extent: CGFloat
    let limit: CGFloat
    let scale: CGFloat

    /// A frame whose width is `width` and whose height follows the picture, up to `maxHeight`.
    static func pinnedWidth(_ width: CGFloat, maxHeight: CGFloat, scale: CGFloat) -> ThumbnailBox {
        ThumbnailBox(anchor: .width, extent: width, limit: maxHeight, scale: scale)
    }

    /// A frame whose height is `height` and whose width follows the picture, up to `maxWidth`.
    static func pinnedHeight(_ height: CGFloat, maxWidth: CGFloat, scale: CGFloat) -> ThumbnailBox {
        ThumbnailBox(anchor: .height, extent: height, limit: maxWidth, scale: scale)
    }

    /// Part of a cache key, so one picture at two densities or two frames is two entries.
    var pixelKey: String {
        let anchored = Int((extent * scale).rounded(.up))
        let bound = Int((limit * scale).rounded(.up))
        return anchor == .width ? "w\(anchored)h\(bound)" : "h\(anchored)w\(bound)"
    }

    /// The frame, in points, a picture of this shape is cropped into.
    func frame(forAspect aspect: Double) -> CGSize {
        let shape = CGFloat(PictureShape.shape(of: aspect))
        switch anchor {
        case .width:
            return CGSize(width: extent, height: min(extent / shape, limit))
        case .height:
            let width = extent * shape
            guard width > limit else { return CGSize(width: width, height: extent) }
            return CGSize(width: limit, height: limit / shape)
        }
    }

    /// The longest side, in pixels, a thumbnail of a picture this shape needs to cover its frame
    /// at this density.
    func pixelLimit(forAspect aspect: Double) -> Int {
        let frame = frame(forAspect: aspect)
        let wide = CGFloat(max(aspect, 0.0001))
        let needed: CGFloat =
            aspect >= 1
            ? max(frame.width, frame.height * wide) : max(frame.height, frame.width / wide)
        return max(1, Int((needed * scale).rounded(.up)))
    }
}

/// Reads a picture straight to the size it is drawn at with ImageIO, which decodes a JPEG or HEIC
/// at a reduced size from the start instead of making the full bitmap and shrinking it.
enum ImageThumbnail {
    /// The picture cut down to `box`, orientation applied, decoded now so the first draw on the main
    /// thread is a copy rather than a decode. Nil when ImageIO cannot read the bytes.
    static func make(from data: Data, box: ThumbnailBox) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
            let aspect = aspect(of: source)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: box.pixelLimit(forAspect: aspect),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: image, scale: box.scale, orientation: .up)
    }

    /// Width over height as the picture will be seen, read from the header alone: no pixel is
    /// decoded, so a surface may ask for it on the main thread to size a row before the thumbnail
    /// exists.
    static func aspect(of data: Data) -> Double? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        return CGImageSourceCreateWithData(data as CFData, options).flatMap { aspect(of: $0) }
    }

    /// Width over height as the picture will be seen, so an image stored on its side reads the
    /// shape it is shown in.
    private static func aspect(of source: CGImageSource) -> Double? {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Double,
            let height = properties[kCGImagePropertyPixelHeight] as? Double,
            width > 0, height > 0
        else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? UInt32) ?? 1
        return (5...8).contains(orientation) ? height / width : width / height
    }
}
