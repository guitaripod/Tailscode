#if os(macOS)
import CoreGraphics
import CoreText
import Foundation
import TailscodeCore

/// Words over a rendered still, so a reviewer can tell which tile is which. The apps draw their own;
/// this only stands in for them and never belongs in the library.
enum Overlay {
    static func annotate(_ image: CGImage, staged: Staged, scale: Double) -> CGImage? {
        let width = image.width
        let height = image.height
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let layout = staged.layout
        let text = staged.scene.palette.text
        let dim = staged.scene.palette.dim
        let pen = Pen(context: context, scale: scale, height: Double(height))
        pen.draw(
            staged.wall.headline, in: layout.headline, size: layout.type(3.4), ink: text, weight: 0.3)
        pen.draw(staged.wall.watchLine, in: layout.watchLine, size: layout.type(1.7), ink: dim, weight: 0)
        for (index, tile) in staged.wall.tiles.enumerated() where index < layout.tiles.count {
            let rect = layout.tiles[index]
            let metrics = WallTileMetrics.tile(rect, unit: layout.unit)
            let titleRect = WallRect(
                x: metrics.textLeading, y: metrics.glyphY - metrics.glyphSize / 2,
                width: rect.maxX - metrics.textLeading - metrics.padding, height: metrics.glyphSize)
            pen.draw(tile.title, in: titleRect, size: layout.type(2.1), ink: text, weight: 0.3)
            pen.draw(tile.words, in: metrics.body, size: layout.type(1.7), ink: dim, weight: 0)
        }
        return context.makeImage()
    }

    private struct Pen {
        let context: CGContext
        let scale: Double
        let height: Double

        func draw(_ string: String, in rect: WallRect, size: Double, ink: WallInk, weight: Double) {
            guard !string.isEmpty, rect.width > 4 else { return }
            let font = CTFontCreateWithName("Helvetica Neue" as CFString, size * scale, nil)
            let colour = CGColor(red: ink.red, green: ink.green, blue: ink.blue, alpha: 1)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): colour,
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
            let truncated =
                CTLineCreateTruncatedLine(
                    line, rect.width * scale, .end,
                    CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes)))
                ?? line
            context.textPosition = CGPoint(x: rect.x * scale, y: height - (rect.y * scale + size * scale * 0.95))
            CTLineDraw(truncated, context)
        }
    }
}
#endif
