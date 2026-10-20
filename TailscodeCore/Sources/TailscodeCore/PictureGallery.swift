import Foundation

/// The pictures an agent made, as one square of small tiles rather than a poster per picture.
///
/// A turn that looked at sixteen screenshots used to spend sixteen pictures of height on them and
/// push the answer off the page; the pictures are one fact about the turn, so they rest as a single
/// pressable tile — four at most, the rest counted — and the whole set opens in the viewer, paged,
/// where a picture can actually be read. The arrangement is arithmetic, so a client only places
/// views at the rectangles it is handed.
public enum PictureGalleryLayout: Sendable {
    /// The tiles drawn: a two-by-two of squares, which is what makes the shape read as a grid
    /// rather than as one picture among the answer.
    public static let maximumTiles = 4

    public struct Tile: Sendable, Equatable {
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

    /// How many pictures the tile counts rather than shows, which is what its `+N` says.
    public static func hidden(count: Int) -> Int {
        max(0, count - maximumTiles)
    }

    /// The square's side: as tall as a picture the metrics allow, and never past the row it is
    /// drawn in, because a square wider than the transcript is a square cut off.
    public static func side(metrics: ChatMetrics, width: Double) -> Double {
        max(0, min(metrics.imageMaxHeight, width))
    }

    /// Rectangles for `count` pictures in a square `side` wide, a gutter of `gap` between
    /// neighbours: one picture fills it, two split it top to bottom, three give half the square to
    /// the first, and four or more are the two-by-two the tile is named for. A lone picture keeps
    /// its own shape instead — one screenshot cropped to a square would hide most of what it is —
    /// and is given `maxWidth` to spread into, which is the row's own width.
    public static func mosaic(
        count: Int, side: Double, gap: Double, shape: Double? = nil, maxWidth: Double? = nil
    ) -> [Tile] {
        guard count > 0, side > 0 else { return [] }
        guard count > 1 else {
            let room = max(side, maxWidth ?? side)
            let width = min(room, side * PictureShape.shape(of: shape))
            return [Tile(index: 0, x: 0, y: 0, width: width, height: side)]
        }
        let half = (side - gap) / 2
        guard half > 0 else { return [Tile(index: 0, x: 0, y: 0, width: side, height: side)] }
        let far = half + gap
        switch count {
        case 2:
            return [
                Tile(index: 0, x: 0, y: 0, width: half, height: side),
                Tile(index: 1, x: far, y: 0, width: half, height: side),
            ]
        case 3:
            return [
                Tile(index: 0, x: 0, y: 0, width: half, height: side),
                Tile(index: 1, x: far, y: 0, width: half, height: half),
                Tile(index: 2, x: far, y: far, width: half, height: half),
            ]
        default:
            return [
                Tile(index: 0, x: 0, y: 0, width: half, height: half),
                Tile(index: 1, x: far, y: 0, width: half, height: half),
                Tile(index: 2, x: 0, y: far, width: half, height: half),
                Tile(index: 3, x: far, y: far, width: half, height: half),
            ]
        }
    }
}

/// What a gallery tile says: how many pictures it holds, and what its corner counts.
public enum PictureGalleryReading {
    public static func label(count: Int) -> String {
        switch count {
        case 0: return Localized.text("No pictures")
        case 1: return Localized.text("1 picture")
        default: return Localized.text("%@ pictures", "\(count)")
        }
    }

    /// The tile's corner, wordless: `+12`, or nothing when every picture is already drawn.
    public static func badge(count: Int) -> String? {
        let hidden = PictureGalleryLayout.hidden(count: count)
        return hidden > 0 ? "+\(hidden)" : nil
    }

    /// What a screen reader hears: the count, then the pictures by name, because a picture the
    /// agent made is known by its file and the names are what tell sixteen screenshots apart.
    public static func spoken(count: Int, names: [String], limit: Int = 4) -> String {
        let said = names.prefix(limit).joined(separator: ", ")
        guard !said.isEmpty else { return label(count: count) }
        guard names.count > limit else { return label(count: count) + ", " + said }
        return Localized.text("%1$@, %2$@ and %3$@ more", label(count: count), said, "\(names.count - limit)")
    }
}
