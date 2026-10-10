import Foundation

/// Where the pictures an agent made sit when consecutive ones share a row: a strip that wraps.
/// Every thumbnail is as tall as the metrics allow and as wide as its own shape asks, so a
/// screenshot reads as a screenshot beside a portrait photo, and a picture too wide for the line
/// shrinks to fit it rather than overflowing. The arithmetic is toolkit-free so a client only
/// places views at the frames it is handed.
public enum PictureStripLayout: Sendable {
    /// The shapes a thumbnail may take, width over height: a very tall or very wide picture is
    /// cropped to these rather than made a sliver or a banner.
    public static let aspectRange: ClosedRange<Double> = 0.55...2.4

    /// The shape assumed for a picture whose bytes have not arrived, so the row has a height to
    /// stand in before the picture does.
    public static let placeholderAspect = 1.4

    public struct Frame: Sendable, Equatable {
        public let index: Int
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(index: Int, x: Double, y: Double, width: Double, height: Double) {
            self.index = index
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public struct Result: Sendable, Equatable {
        public let frames: [Frame]
        public let height: Double

        public var lineCount: Int {
            Set(frames.map(\.y)).count
        }
    }

    /// The clamped width over height a picture is drawn at; nil is a picture still on its way.
    public static func shape(of aspect: Double?) -> Double {
        let raw = aspect ?? placeholderAspect
        guard raw.isFinite, raw > 0 else { return placeholderAspect }
        return min(max(raw, aspectRange.lowerBound), aspectRange.upperBound)
    }

    /// Frames for pictures of the given shapes in a line `width` wide: left to right in the order
    /// they were made, a new line when the next one would pass the right edge, a gutter of
    /// `imageStripGap` between neighbours and between lines. Each thumbnail is `imageMaxHeight`
    /// tall unless that would make it wider than the line, in which case it shrinks to the line.
    public static func layout(aspects: [Double?], width: Double, metrics: ChatMetrics) -> Result {
        guard width > 0, !aspects.isEmpty else { return Result(frames: [], height: 0) }
        let gap = metrics.imageStripGap
        var frames: [Frame] = []
        var x = 0.0
        var y = 0.0
        var lineHeight = 0.0
        for (index, aspect) in aspects.enumerated() {
            let shape = shape(of: aspect)
            var thumbWidth = metrics.imageMaxHeight * shape
            var thumbHeight = metrics.imageMaxHeight
            if thumbWidth > width {
                thumbWidth = width
                thumbHeight = width / shape
            }
            if x > 0, x + thumbWidth > width + 0.5 {
                y += lineHeight + gap
                x = 0
                lineHeight = 0
            }
            frames.append(Frame(index: index, x: x, y: y, width: thumbWidth, height: thumbHeight))
            x += thumbWidth + gap
            lineHeight = max(lineHeight, thumbHeight)
        }
        return Result(frames: frames, height: y + lineHeight)
    }
}
