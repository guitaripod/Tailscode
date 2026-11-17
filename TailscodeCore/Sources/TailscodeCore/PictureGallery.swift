import Foundation

/// The pictures an agent made, as one compact strip rather than a poster per picture.
///
/// A turn that looked at sixteen screenshots used to spend sixteen pictures of height on them, and
/// then a two-row sheet as tall as one picture, which still read as a wall in the middle of a
/// conversation. The pictures are one fact about the turn, so they rest as a single row of small
/// rounded squares under the turn's card, and a press on a tile opens that picture in the viewer,
/// paged, where it can actually be read. The arrangement is arithmetic, so a client only places
/// views at the rectangles it is handed and asks again when its width changes.
///
/// The contract every client draws, in one place:
/// - A lone picture is one tile as tall as `side` and as wide as its own shape asks
///   (`PictureShape`) and the row allows, flush left. It is fitted whole inside that tile, so it is
///   letterboxed only when its shape is wider than the row can hold at that height; it is never
///   cropped, and the block is `side` tall whatever the picture turns out to be.
/// - Two pictures or more are one row of squares `stripSide(for:)` tall, `stripGap` apart, flush
///   left, as many as the row holds (never more than `maximumColumns`). The block is that one tile
///   tall, so a turn's pictures cost a line or two of text, not a picture.
/// - What the row cannot draw is counted in a corner chip on the last tile (`badge(on:textWidth:)`),
///   never over the whole tile.
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

        /// The same tiles with every edge moved to a whole unit, so a toolkit that places views on
        /// whole pixels keeps the gutter the layout asked for: each tile's origin and far edge are
        /// rounded rather than its origin and its width, which would let two roundings disagree
        /// and leave one gap a unit wider than the next.
        public func snapped(to unit: Double = 1) -> Arrangement {
            guard unit > 0 else { return self }
            let tiles = tiles.map { tile -> Tile in
                let left = (tile.x / unit).rounded() * unit
                let top = (tile.y / unit).rounded() * unit
                let right = ((tile.x + tile.width) / unit).rounded() * unit
                let bottom = ((tile.y + tile.height) / unit).rounded() * unit
                return Tile(
                    index: tile.index, x: left, y: top, width: max(unit, right - left),
                    height: max(unit, bottom - top))
            }
            return Arrangement(tiles: tiles, hidden: hidden)
        }
    }

    /// The corner chip that counts what the grid could not draw: where it sits on its tile, from
    /// the width the client measured the words at `chipFontSize`.
    public struct Chip: Sendable, Equatable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
    }

    /// The point size the chip's words are set in, bold, on every client.
    public static let chipFontSize: Double = 13

    /// The air between a chip and its tile's edges.
    public static let chipInset: Double = 4

    /// The chip on `tile`'s bottom-trailing corner for words `textWidth` wide: a capsule at most
    /// 22 points tall and half the tile, no wider than the tile less its insets, so the picture
    /// stays the thing a tile shows.
    public static func badge(on tile: Tile, textWidth: Double) -> Chip {
        let height = max(1, min(22, tile.height / 2))
        let room = max(height, tile.width - 2 * chipInset)
        let width = min(room, max(height, textWidth + height * 0.7))
        return Chip(
            x: tile.x + tile.width - chipInset - width,
            y: tile.y + tile.height - chipInset - height, width: width, height: height)
    }

    /// The block's height: as tall as a picture the metrics allow, and never past the row it is
    /// drawn in, because a picture taller than the transcript is a picture cut off.
    public static func side(metrics: ChatMetrics, width: Double) -> Double {
        max(0, min(metrics.imageMaxHeight, width))
    }

    /// The air between two tiles of a strip: enough that each rounded square reads as its own
    /// picture and its own press.
    public static let stripGap: Double = 6

    /// How tall a strip of several pictures is as a share of the block a lone picture gets.
    public static let stripShare = 0.4

    /// The smallest and largest a strip tile may be drawn: small enough that a turn's pictures cost
    /// a line or two of text, large enough to tell one screenshot from another.
    public static let smallestStripTile: Double = 56
    public static let largestStripTile: Double = 104

    /// How many tiles a strip may draw across, so a wall-sized window does not turn a turn's
    /// pictures into a bead curtain of thumbnails.
    public static let maximumColumns = 12

    /// The side of a strip tile for a block `side` tall.
    public static func stripSide(for side: Double) -> Double {
        min(side, max(smallestStripTile, min(largestStripTile, side * stripShare)))
    }

    /// Rectangles for `count` pictures in a block `side` tall and `available` wide, a gutter of
    /// `gap` between neighbours.
    ///
    /// A lone picture keeps its own shape instead of being cropped (one screenshot squared would
    /// hide most of what it is) and is given `maxWidth` to spread into, which is the row's own
    /// width. Several pictures are one row of `stripSide(for:)` squares, as many as fit, and the
    /// last one's corner counts the rest.
    public static func grid(
        count: Int, side: Double, available: Double = 0, gap: Double = stripGap,
        shape: Double? = nil, maxWidth: Double? = nil
    ) -> Arrangement {
        guard count > 0, side > 0 else { return .empty }
        guard count > 1 else {
            let room = max(side, maxWidth ?? side)
            let width = min(room, side * PictureShape.shape(of: shape))
            return Arrangement(
                tiles: [Tile(index: 0, x: 0, y: 0, width: width, height: side)], hidden: 0)
        }
        let tile = stripSide(for: side)
        let room = available > 0 ? available : tile
        let fitting = max(1, Int(((room + gap) / (tile + gap)).rounded(.down)))
        let shown = min(count, fitting, maximumColumns)
        let width = min(tile, room)
        let tiles = (0..<shown).map { index in
            Tile(index: index, x: Double(index) * (width + gap), y: 0, width: width, height: tile)
        }
        return Arrangement(tiles: tiles, hidden: count - shown)
    }
}

/// Where a turn's pictures are drawn: together, in one place, whichever way the turn's work is drawn.
///
/// An agent looks at a picture between steps, so the pictures of one turn arrive between the notes
/// and cards the chat keeps, and each run of them used to become its own gallery: three walls of
/// thumbnails in one turn, none of them next to the work that made them. A turn's pictures are one
/// thing to see, so every picture after the turn's anchor moves up to stand right under it, in the
/// order it arrived, and the client's gallery fold then makes them one strip. The anchor is the
/// turn's Megatron card when it has one, and the turn's first picture when its work is drawn as
/// lines, so the strip is the same strip with Megatron on or off and a picture arriving later
/// changes the strip rather than adding a row. A boundary (the person's next prompt, a turn break)
/// ends the turn.
public enum TurnPictureGathering {
    public enum Mark: Sendable, Equatable {
        case card
        case picture
        case boundary
        case other
    }

    /// The order to draw rows in, as indices into `marks`.
    public static func order(_ marks: [Mark]) -> [Int] {
        var order: [Int] = []
        order.reserveCapacity(marks.count)
        var insertion: Int?
        for (index, mark) in marks.enumerated() {
            switch mark {
            case .card:
                order.append(index)
                insertion = order.count
            case .picture:
                if let at = insertion {
                    order.insert(index, at: at)
                    insertion = at + 1
                } else {
                    order.append(index)
                    insertion = order.count
                }
            case .boundary:
                insertion = nil
                order.append(index)
            case .other:
                order.append(index)
            }
        }
        return order
    }

    /// `rows` with every turn's pictures moved under its card, or under its first picture when the
    /// turn has no card.
    public static func gathered<Row>(_ rows: [Row], mark: (Row) -> Mark) -> [Row] {
        let marks = rows.map(mark)
        guard marks.contains(.picture) else { return rows }
        return order(marks).map { rows[$0] }
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

    /// The words in the last tile's corner chip: `+12`, or nothing when every picture is already
    /// drawn.
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
