import Foundation

/// The pictures an agent made, as one grid of small tiles rather than a poster per picture.
///
/// A turn that looked at sixteen screenshots used to spend sixteen pictures of height on them and
/// push the answer off the page; the pictures are one fact about the turn, so they rest as a single
/// block — a strip across the transcript when the pictures are few, a two-row sheet when they are
/// many, never taller than one picture — and a press on a tile opens that picture in the viewer,
/// paged, where it can actually be read. The arrangement is arithmetic, so a client only places
/// views at the rectangles it is handed and asks again when its width changes.
public enum PictureGalleryLayout: Sendable {
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

    /// What a group of pictures comes to in a given width: the tiles to draw, in order, and how
    /// many pictures the last one's corner has to count.
    public struct Arrangement: Sendable, Equatable {
        public let tiles: [Tile]
        public let hidden: Int

        public init(tiles: [Tile], hidden: Int) {
            self.tiles = tiles
            self.hidden = hidden
        }

        public var width: Double { tiles.map { $0.x + $0.width }.max() ?? 0 }
        public var height: Double { tiles.map { $0.y + $0.height }.max() ?? 0 }

        public static let empty = Arrangement(tiles: [], hidden: 0)
    }

    /// The block's height: as tall as a picture the metrics allow, and never past the row it is
    /// drawn in, because a picture taller than the transcript is a picture cut off.
    public static func side(metrics: ChatMetrics, width: Double) -> Double {
        max(0, min(metrics.imageMaxHeight, width))
    }

    /// The air between two tiles: two points of gutter, so a grid reads as one block of pictures
    /// rather than a shelf of separate ones.
    public static let tileGap: Double = 2

    /// The narrowest a two-row tile may be drawn before the grid stops taking more columns and
    /// counts the rest: a tile has to stay a picture and a press.
    public static let narrowestTile: Double = 40

    /// The narrowest a one-row tile may be as a share of the block's height before the pictures
    /// take a second row instead: a strip of needle-thin crops is not a gallery, a sheet is.
    public static let narrowestStripShare = 0.5

    /// How many tiles a two-row sheet may draw across, so a wall-sized window does not turn a
    /// group of pictures into a bead curtain of thumbnails.
    public static let maximumColumns = 12

    /// How much wider than tall a tile may be: a sheet grows into the row's width when there is
    /// room, and stops before its crops stop looking like pictures.
    public static let widestSheetTile = 1.25

    /// Rectangles for `count` pictures in a block `side` tall and `available` wide, a gutter of
    /// `gap` between neighbours.
    ///
    /// A lone picture keeps its own shape instead of being cropped — one screenshot squared would
    /// hide most of what it is — and is given `maxWidth` to spread into, which is the row's own
    /// width. A few pictures are one strip across the row while each tile stays at least
    /// `narrowestStripShare` of the height wide; more of them are a two-row grid that takes as many
    /// columns as the row has room for, shrinking the tiles to `narrowestTile` before it counts the
    /// rest on the last one's corner. Either way the block is one picture tall, never more.
    public static func grid(
        count: Int, side: Double, available: Double = 0, gap: Double = tileGap,
        shape: Double? = nil, maxWidth: Double? = nil
    ) -> Arrangement {
        guard count > 0, side > 0 else { return .empty }
        guard count > 1 else {
            let room = max(side, maxWidth ?? side)
            let width = min(room, side * PictureShape.shape(of: shape))
            return Arrangement(
                tiles: [Tile(index: 0, x: 0, y: 0, width: width, height: side)], hidden: 0)
        }
        let room = available > 0 ? available : side
        let strip = (room - Double(count - 1) * gap) / Double(count)
        if strip >= side * narrowestStripShare {
            let width = min(side, strip)
            let tiles = (0..<count).map { index in
                Tile(
                    index: index, x: Double(index) * (width + gap), y: 0, width: width,
                    height: side)
            }
            return Arrangement(tiles: tiles, hidden: 0)
        }
        let height = (side - gap) / 2
        guard height > 0 else {
            return Arrangement(
                tiles: [Tile(index: 0, x: 0, y: 0, width: side, height: side)],
                hidden: max(0, count - 1))
        }
        let fitting = max(1, Int(((room + gap) / (narrowestTile + gap)).rounded(.down)))
        let columns = max(1, min(maximumColumns, min((count + 1) / 2, fitting)))
        let shown = min(count, columns * 2)
        let share = (room - Double(columns - 1) * gap) / Double(columns)
        let width = max(1, min(height * widestSheetTile, share))
        let tiles = (0..<shown).map { index in
            Tile(
                index: index, x: Double(index % columns) * (width + gap),
                y: Double(index / columns) * (height + gap), width: width, height: height)
        }
        return Arrangement(tiles: tiles, hidden: count - shown)
    }
}

/// What a gallery says: how many pictures it holds, and what its corner counts.
public enum PictureGalleryReading {
    public static func label(count: Int) -> String {
        switch count {
        case 0: return Localized.text("No pictures")
        case 1: return Localized.text("1 picture")
        default: return Localized.text("%@ pictures", "\(count)")
        }
    }

    /// The last tile's corner, wordless: `+12`, or nothing when every picture is already drawn.
    public static func badge(hidden: Int) -> String? {
        hidden > 0 ? "+\(hidden)" : nil
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
