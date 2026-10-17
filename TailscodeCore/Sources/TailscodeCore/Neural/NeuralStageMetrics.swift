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
/// The stage shows the head trimmed to its own bounds, design x 64 to 640 over the full 420
/// height (`designCrop`, an aspect of 576:420, held exactly), so the chassis is flush with the
/// column's left edge and nothing of the head is cut. Every place a design point meets the stage or
/// the card's picture goes through `designCrop`. The readout is beside the stage when there is
/// room (`split`) and under it as a strip when there is not.
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

    /// How a card sets its picture and its two small buttons: the wide card has them beside the
    /// headline, the narrow one has the Compact picture and puts Replay and Rows under the headline.
    public enum CardLayout: Sendable, Equatable {
        case wide
        case narrow
    }

    /// The collapsed card.
    public struct Card: Sendable, Equatable {
        public let layout: CardLayout
        public let height: Double
        /// The 3 pt edge in the turn's tone.
        public let edge: Double
        /// The padding between the edge and the picture, and between the picture and the text.
        public let inset: Double
        /// The picture's rectangle in the row: the head's trimmed bounds, centred in the card's
        /// height.
        public let picture: NeuralRect
        /// The text column's rectangle: from the picture's right edge to the card's trailing inset.
        public let text: NeuralRect

        /// Where a point of the head's design space is drawn on the card's picture.
        public func point(forDesign point: NeuralPoint) -> NeuralPoint {
            let crop = NeuralStageMetrics.designCrop
            return NeuralPoint(
                picture.x + (point.x - crop.x) * picture.width / crop.width,
                picture.y + (point.y - crop.y) * picture.height / crop.height)
        }

        /// How many points one design unit is on the picture, across and down.
        public var scale: (x: Double, y: Double) {
            let crop = NeuralStageMetrics.designCrop
            return (picture.width / crop.width, picture.height / crop.height)
        }
    }

    /// One thing in the open row's footer.
    public struct FooterPart: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case replay
            case scrubber
            case time
            case answerChips
            case rows
            case share
            case close
        }

        public let kind: Kind
        /// Replay as its icon alone.
        public let isIcon: Bool
    }

    /// The part of the head's design space the stage and the card's picture show.
    public static let designCrop = NeuralRect(
        x: 64, y: 0, width: NeuralDesign.width - 64, height: NeuralDesign.height)
    public static let designWidth = designCrop.width
    public static let designHeight = designCrop.height
    public static let aspect = designCrop.height / designCrop.width

    /// At this width and up the stage and the readout sit side by side at their full size.
    public static let wideBreakpoint = 860.0
    /// At this width and up the stage and the readout sit side by side at all.
    public static let splitBreakpoint = 560.0
    /// A card narrower than this is the narrow layout and drops its zone strip; its digest goes
    /// below `cardDigestMinWidth`.
    public static let cardZoneStripMinWidth = 460.0
    public static let cardDigestMinWidth = 380.0
    /// Under this width the footer loses Close; under `footerCompactWidth` Replay is its icon and
    /// the answer chips go as well.
    public static let footerCloseMinWidth = 960.0
    public static let footerCompactWidth = 640.0

    public static let stageShare = 0.54
    public static let stageMidShare = 0.5
    public static let stageMin = 420.0
    public static let stageSplitMax = 720.0
    public static let stageCap = 760.0
    public static let gutter = 24.0
    public static let readoutMax = 560.0
    /// The readout is never narrower than this beside the stage.
    public static let readoutMin = 300.0
    /// The readout is never shorter than this beside the stage, and so neither is the row.
    public static let readoutMinHeight = 420.0
    /// A readout narrower than this shows five lines of output instead of eight.
    public static let readoutNarrowWidth = 480.0
    public static let outputLinesWide = 8
    public static let outputLinesNarrow = 5
    /// The fade at the foot of the readout's scroll region, where more lies below.
    public static let readoutFade = 16.0
    public static let readoutHeaderHeight = 40.0
    public static let readoutFooterHeight = 32.0
    /// How far inside the header and the footer a leader's row is held.
    public static let leaderInset = 16.0
    /// The leader's tab on the hairline.
    public static let tabSize = (width: 3.0, height: 24.0)
    /// How far the readout travels while it slides into place.
    public static let readoutTravel = 24.0
    /// The stacked readout's two-line strip, and how tall it grows to when something is pinned.
    public static let stripHeight = 56.0
    public static let stackedPinnedHeight = 340.0

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
    /// The readout as it grows when something is pinned in a stacked row, capped at 340; the same
    /// rectangle when the readout is beside the stage.
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
    public var readoutMinHeight: Double { Self.readoutMinHeight }

    /// Whether a leader line ties the node being read to the readout: only beside it.
    public var hasLeader: Bool { arrangement == .split }

    /// How many lines of output the readout shows before "N more lines": five in a column under 480
    /// points wide, eight otherwise. A client passes it to `NeuralReadout.make`.
    public var outputLinesShown: Int {
        readout.width < Self.readoutNarrowWidth ? Self.outputLinesNarrow : Self.outputLinesWide
    }

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

    /// Where a node of the head's design space is drawn in the row: the crop's origin is the
    /// stage's.
    public func point(forDesign point: NeuralPoint) -> NeuralPoint {
        NeuralPoint(
            stage.x + (point.x - Self.designCrop.x) * designScale,
            stage.y + (point.y - Self.designCrop.y) * designScale)
    }

    /// The design point under a point of the row: what a pointer's hit test asks the head.
    public func designPoint(forRow point: NeuralPoint) -> NeuralPoint {
        NeuralPoint(
            Self.designCrop.x + (point.x - stage.x) / designScale,
            Self.designCrop.y + (point.y - stage.y) / designScale)
    }

    /// A length in points as design units: the slop a hit test allows.
    public func designLength(forPoints points: Double) -> Double { points / designScale }

    /// The row's y, in points, a leader ends on for a node: the node's own row, held 16 points
    /// inside the readout's header and footer.
    public func leaderRow(forNodeAt design: NeuralPoint) -> Double {
        let low = readout.y + Self.readoutHeaderHeight + Self.leaderInset
        let high = readout.maxY - Self.readoutFooterHeight - Self.leaderInset
        return min(max(point(forDesign: design).y, low), max(low, high))
    }

    /// Where the leader ends, in the head's design space: on the readout's hairline, on the node's
    /// own row. Nil in a stacked row, which has no leader.
    public func leaderAnchor(forNodeAt design: NeuralPoint) -> NeuralPoint? {
        guard hasLeader else { return nil }
        let scale = designScale
        return NeuralPoint(
            Self.designCrop.x + (readout.x - stage.x) / scale,
            (leaderRow(forNodeAt: design) - stage.y) / scale + Self.designCrop.y)
    }

    /// The 3 by 24 tab the leader lands on, centred on the hairline, in the row's points.
    public func leaderTab(forNodeAt design: NeuralPoint) -> NeuralRect? {
        guard hasLeader else { return nil }
        let size = Self.tabSize
        return NeuralRect(
            x: readout.x - (size.width - 1) / 2, y: leaderRow(forNodeAt: design) - size.height / 2,
            width: size.width, height: size.height)
    }

    /// The card layout a row of this width uses: the narrow one below 460.
    public static func cardLayout(width: Double) -> CardLayout {
        width < cardZoneStripMinWidth ? .narrow : .wide
    }

    /// What the open row's footer holds at this row width, left to right. Rows and Share always
    /// stay; Close goes under 960; under 640 Replay is its icon and the answer chips go.
    public static func footerParts(width: Double) -> [FooterPart] {
        let compact = width < footerCompactWidth
        var parts = [
            FooterPart(kind: .replay, isIcon: compact), FooterPart(kind: .scrubber, isIcon: false),
            FooterPart(kind: .time, isIcon: false),
        ]
        if !compact { parts.append(FooterPart(kind: .answerChips, isIcon: false)) }
        parts.append(FooterPart(kind: .rows, isIcon: false))
        parts.append(FooterPart(kind: .share, isIcon: false))
        if width >= footerCloseMinWidth { parts.append(FooterPart(kind: .close, isIcon: false)) }
        return parts
    }

    public func footerParts() -> [FooterPart] { Self.footerParts(width: width) }

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
            let region = max(stageHeight, readoutMinHeight)
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
            x: 0, y: stageHeight + footerGap, width: stageWidth, height: stackedPinnedHeight)
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

    /// The stage's width in a split: 54 percent of the row between 420 and 720, growing to take
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
        let layout = cardLayout(width: width)
        let comfortable = density == .comfortable
        let height: Double = comfortable ? 112 : 84
        let spacious = comfortable && layout == .wide
        let pictureWidth: Double = spacious ? 132 : 100
        let pictureHeight: Double = spacious ? 96 : 72
        let edge = 3.0
        let inset: Double = comfortable ? 12 : 10
        let picture = NeuralRect(
            x: edge + inset, y: ((height - pictureHeight) / 2).rounded(.down),
            width: pictureWidth, height: pictureHeight)
        let textX = picture.maxX + inset + 2
        let text = NeuralRect(
            x: textX, y: 0, width: max(width - textX - inset, 0), height: height)
        return Card(
            layout: layout, height: height, edge: edge, inset: inset, picture: picture, text: text)
    }
}

extension NeuralBrainModel {
    /// The node under a point of the row, with the slop given in points: the pointer's hit test,
    /// mapped through the stage's crop into the head's design space.
    public func hit(
        atRow point: NeuralPoint, in metrics: NeuralStageMetrics, slopPoints: Double = 4
    ) -> String? {
        hit(
            at: metrics.designPoint(forRow: point), slop: metrics.designLength(forPoints: slopPoints))
    }

    /// The leader for the node the readout is about, when there is one and the row has a leader.
    public func leader(
        forStep id: String, in metrics: NeuralStageMetrics,
        labels: [NeuralRect] = NeuralZone.labelRects
    ) -> NeuralLeader.Line? {
        guard let design = point(of: id) else { return nil }
        let nodes = steps.compactMap { point(of: $0.id) }
        return NeuralLeader.line(forNodeAt: design, in: metrics, around: nodes, labels: labels)
    }
}
