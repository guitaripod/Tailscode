import Foundation

/// Where a tile's own glyph, words and heartbeat go, from its rectangle and the layout's unit alone,
/// so the words a client sets and the glyph the renderer draws agree on every screen.
public struct WallTileMetrics: Sendable, Equatable {
    public let glyphX: Double
    public let glyphY: Double
    public let glyphSize: Double
    public let padding: Double
    /// Where words start beside the glyph.
    public let textLeading: Double
    /// The area under the glyph row, for words.
    public let body: WallRect
    /// The heartbeat strip: the body's bottom left, 62 % of its width.
    public let beat: WallRect

    public static func tile(_ rect: WallRect, unit: Double) -> WallTileMetrics {
        let size = clamp(min(rect.width, rect.height) * 0.3, 22, max(28, 4.4 * unit))
        let padding = max(1.3 * unit, 9)
        let glyphX = rect.x + padding + size / 2
        let glyphY = rect.y + padding + size / 2
        let top = rect.y + padding + size + 1.0 * unit
        let body = WallRect(
            x: rect.x + padding, y: top, width: rect.width - 2 * padding, height: rect.maxY - padding - top)
        let beatHeight = min(clamp(2.4 * unit, 12, 30), body.height)
        let beat = WallRect(
            x: body.x, y: body.maxY - beatHeight, width: body.width * 0.62, height: beatHeight)
        return WallTileMetrics(
            glyphX: glyphX, glyphY: glyphY, glyphSize: size, padding: padding,
            textLeading: rect.x + padding + size + 1.4 * unit, body: body, beat: beat)
    }

    public static func worker(_ rect: WallRect, unit: Double) -> WallTileMetrics {
        let size = clamp(min(rect.height * 0.42, 3 * unit), 14, 30)
        let padding = max(0.9 * unit, 7)
        let leading = rect.x + padding + size + 0.8 * unit
        let body = WallRect(x: leading, y: rect.y, width: rect.maxX - padding - leading, height: rect.height)
        return WallTileMetrics(
            glyphX: rect.x + padding + size / 2, glyphY: rect.midY, glyphSize: size, padding: padding,
            textLeading: leading, body: body,
            beat: WallRect(x: body.x, y: body.maxY, width: 0, height: 0))
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }
}
