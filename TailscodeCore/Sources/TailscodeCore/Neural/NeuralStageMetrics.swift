import Foundation

/// A rectangle in the row's own coordinates: the origin is the row's top-left corner, y runs down,
/// and the unit is the point the client lays out in.
public struct NeuralRect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let zero = NeuralRect(x: 0, y: 0, width: 0, height: 0)

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public func contains(_ point: NeuralPoint) -> Bool {
        point.x >= x && point.x <= maxX && point.y >= y && point.y <= maxY
    }

    /// The rectangle `amount` of the way from this one to `other`, every edge on its own line.
    public func interpolated(to other: NeuralRect, _ amount: Double) -> NeuralRect {
        NeuralRect(
            x: x + (other.x - x) * amount, y: y + (other.y - y) * amount,
            width: width + (other.width - width) * amount,
            height: height + (other.height - height) * amount)
    }

    public func offsetBy(dx: Double = 0, dy: Double = 0) -> NeuralRect {
        NeuralRect(x: x + dx, y: y + dy, width: width, height: height)
    }
}

/// Where everything of a brain's row goes at a given row width: the collapsed card, and the open
/// stage with its readout and footer. Pure arithmetic from the width and the density, so the
/// breakpoints exist once and a client only lays out the rectangles it is handed.
///
/// A row is `width` wide and as tall as `rowHeight`; every rectangle is in the row's coordinates.
/// The stage keeps the head's 640 by 420 aspect exactly and is never cropped. The readout is
/// beside the stage when there is room (`split`) and under it as a strip when there is not.
public struct NeuralStageMetrics: Sendable, Equatable {
    public enum Arrangement: Sendable, Equatable {
        case split
        case stacked
    }

    /// The readout's type: one step down in the middle band, where the column is narrower.
    public enum ReadoutType: Sendable, Equatable {
        case regular
        case stepDown
    }

    /// The collapsed card.
    public struct Card: Sendable, Equatable {
        public let height: Double
        /// The 3 pt edge in the turn's tone.
        public let edge: Double
        /// The padding between the edge and the picture, and between the picture and the text.
        public let inset: Double
        /// The picture's rectangle in the row: the head's aspect, centred in the card's height.
        public let picture: NeuralRect
        /// The text column's rectangle: from the picture's right edge to the card's trailing inset.
        public let text: NeuralRect
    }

    /// The width a stacked stage starts to be capped at, and the stage's size limits.
    public static let designWidth = NeuralDesign.width
    public static let designHeight = NeuralDesign.height
    public static let aspect = NeuralDesign.height / NeuralDesign.width

    /// At this width and up the stage and the readout sit side by side at their full size.
    public static let wideBreakpoint = 860.0
    /// At this width and up the stage and the readout sit side by side at all.
    public static let splitBreakpoint = 560.0
    /// A card narrower than this drops its zone strip, then its digest at `cardDigestMinWidth`.
    public static let cardZoneStripMinWidth = 460.0
    public static let cardDigestMinWidth = 380.0

    public static let stageShare = 0.54
    public static let stageMidShare = 0.5
    public static let stageMin = 420.0
    public static let stageSplitMax = 720.0
    public static let stageCap = 760.0
    public static let gutter = 24.0
    public static let readoutMax = 560.0
    public static let readoutMin = 300.0
    /// How far the readout travels while it slides into place.
    public static let readoutTravel = 24.0
    /// The stacked readout's two-line strip.
    public static let stripHeight = 56.0

    public let width: Double
    public let density: ChatDensity
    public let arrangement: Arrangement
    public let readoutType: ReadoutType
    public let card: Card
    /// The stage: the open head, flush to the row's left edge and the top.
    public let stage: NeuralRect
    /// Where a pointer counts as over the stage: the stage and, beside a readout, the gutter, so
    /// moving from a node toward the readout never crosses a dead strip.
    public let stageHover: NeuralRect
    /// The readout; the two-line strip when stacked.
    public let readout: NeuralRect
    /// The readout as it grows when something is pinned in a stacked row; the same rectangle when
    /// the readout is beside the stage.
    public let readoutExpanded: NeuralRect
    public let footer: NeuralRect
    /// The height of the open row: the stage and readout region, the gap and the footer.
    public let rowHeight: Double
    /// The height of the collapsed row.
    public var cardHeight: Double { card.height }
    /// What one unit of the head's design space is in points on the stage.
    public var designScale: Double { stage.width / Self.designWidth }

    public var footerHeight: Double { footer.height }
    public var gutterWidth: Double { Self.gutter }
    public var readoutMinHeight: Double { Self.readoutMin }

    /// The row as the collapsed card: the picture is the head's resting place on the card.
    public var cardGeometry: NeuralTransition.Geometry {
        NeuralTransition.Geometry(picture: card.picture, rowHeight: card.height)
    }

    /// The row as the open stage: the head, and where the readout and the footer stand.
    public var stageGeometry: NeuralTransition.Geometry {
        NeuralTransition.Geometry(
            picture: stage, rowHeight: rowHeight, readout: readout, footer: footer,
            readoutTravel: arrangement == .split
                ? NeuralPoint(Self.readoutTravel, 0) : NeuralPoint(0, Self.readoutTravel))
    }

    /// Where a node of the head's design space is drawn in the row.
    public func point(forDesign point: NeuralPoint) -> NeuralPoint {
        NeuralPoint(stage.x + point.x * designScale, stage.y + point.y * designScale)
    }

    /// Where the leader line ends: the left edge of the readout, level with its header's dot, in
    /// the head's design space, which is what the router takes.
    public func leaderAnchor(headerOffset: Double = 14) -> NeuralPoint {
        let scale = designScale
        let x = (readout.x - stage.x) / scale
        return NeuralPoint(x, (readout.y + headerOffset - stage.y) / scale)
    }

    public static func make(width rawWidth: Double, density: ChatDensity) -> NeuralStageMetrics {
        let width = max(rawWidth, 0)
        let card = makeCard(width: width, density: density)
        let footerHeight: Double = density == .compact ? 30 : 36
        let footerGap: Double = density == .compact ? 6 : 8
        if width >= splitBreakpoint {
            let stageWidth = splitStageWidth(for: width)
            let stageHeight = stageWidth * aspect
            let readoutWidth = max(
                min(width - stageWidth - gutter, readoutMax), min(readoutMin, width))
            let region = max(stageHeight, readoutMin)
            let stage = NeuralRect(x: 0, y: 0, width: stageWidth, height: stageHeight)
            let readout = NeuralRect(
                x: stageWidth + gutter, y: 0, width: readoutWidth, height: region)
            let footer = NeuralRect(
                x: 0, y: region + footerGap, width: width, height: footerHeight)
            return NeuralStageMetrics(
                width: width, density: density, arrangement: .split,
                readoutType: width >= wideBreakpoint ? .regular : .stepDown, card: card,
                stage: stage,
                stageHover: NeuralRect(x: 0, y: 0, width: stageWidth + gutter, height: stageHeight),
                readout: readout, readoutExpanded: readout, footer: footer,
                rowHeight: footer.maxY)
        }
        let stageWidth = min(width, stageCap)
        let stageHeight = stageWidth * aspect
        let stage = NeuralRect(x: 0, y: 0, width: stageWidth, height: stageHeight)
        let strip = NeuralRect(
            x: 0, y: stageHeight + footerGap, width: stageWidth, height: stripHeight)
        let expanded = NeuralRect(
            x: 0, y: stageHeight + footerGap, width: stageWidth, height: readoutMin)
        let footer = NeuralRect(x: 0, y: strip.maxY + footerGap, width: width, height: footerHeight)
        return NeuralStageMetrics(
            width: width, density: density, arrangement: .stacked, readoutType: .regular,
            card: card, stage: stage, stageHover: stage, readout: strip, readoutExpanded: expanded,
            footer: footer, rowHeight: footer.maxY)
    }

    /// The row height when a stacked readout has grown to hold what is pinned; a split row is the
    /// same height either way.
    public var pinnedRowHeight: Double {
        guard arrangement == .stacked else { return rowHeight }
        return readoutExpanded.maxY + (footer.y - readout.maxY) + footer.height
    }

    /// The stage's width in a split: 54 percent of the row, between 420 and 720, growing to take
    /// the room a readout would leave over its 560 maximum, up to 760; in the middle band half
    /// the row, never leaving the readout under 300.
    private static func splitStageWidth(for width: Double) -> Double {
        if width < wideBreakpoint {
            return min(width * stageMidShare, width - gutter - readoutMin)
        }
        let base = min(max(width * stageShare, stageMin), stageSplitMax)
        if width - base - gutter > readoutMax {
            return min(width - gutter - readoutMax, stageCap)
        }
        return base
    }

    private static func makeCard(width: Double, density: ChatDensity) -> Card {
        let comfortable = density == .comfortable
        let height: Double = comfortable ? 112 : 84
        let pictureWidth: Double = comfortable ? 148 : 112
        let pictureHeight: Double = comfortable ? 97 : 73
        let edge = 3.0
        let inset: Double = comfortable ? 12 : 10
        let picture = NeuralRect(
            x: edge + inset, y: ((height - pictureHeight) / 2).rounded(.down),
            width: pictureWidth, height: pictureHeight)
        let textX = picture.maxX + inset + 2
        let text = NeuralRect(
            x: textX, y: 0, width: max(width - textX - inset, 0), height: height)
        return Card(
            height: height, edge: edge, inset: inset, picture: picture, text: text)
    }
}
