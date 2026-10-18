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
/// brain with its three regions (the head and the step list in a left column, the readout beside
/// it) and its footer. Pure arithmetic from the width, the density and the input, so the
/// breakpoints exist once and a client only lays out the rectangles it is handed.
///
/// A row is `width` wide; every rectangle is in the row's coordinates. The head is a map: it shows
/// the head trimmed to its own bounds, design x 64 to 640 over the full 420 height (`designCrop`,
/// an aspect of 576:420, held exactly), 280 to 340 points wide. From 860 the brain is a `split`:
/// a left column of `Lw = W - 24 - R` holding the zone filter panel and the head side by side (the
/// head flush with the gutter, so the leader never crosses the panel) with the step list under
/// them, and the readout, R = clamp(0.5 W, 360, 640) wide, beside it. Under 860 it is an
/// `accordion`: the head on top, centred, the zone chips under it and the list at full width,
/// where the cursor row expands in place to carry the readout's content.
public struct NeuralStageMetrics: Sendable, Equatable {
    public enum Arrangement: Sendable, Equatable {
        case split
        /// Narrow rows: head, chips, list; the readout expands inside the cursor's row.
        case accordion

        /// The older name of the narrow arrangement.
        public static let stacked = Arrangement.accordion
    }

    /// How the zone filters are drawn: a panel of one row per zone beside the head, or a row of
    /// glyph-and-count chips above the list.
    public enum FilterStyle: Sendable, Equatable {
        case panel
        case chips
    }

    /// The readout's type: one step down in a column under 440.
    public enum ReadoutType: Sendable, Equatable {
        case regular
        case stepDown
    }

    /// How the account beside the head is laid out: one column with the open step's card unfolded
    /// under its row, or two, the story on the left and the card on the right.
    public enum AccountLayout: Sendable, Equatable {
        case single
        case split
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

    /// The part of the head's design space the head and the card's picture show.
    public static let designCrop = NeuralRect(
        x: 64, y: 0, width: NeuralDesign.width - 64, height: NeuralDesign.height)
    public static let designWidth = designCrop.width
    public static let designHeight = designCrop.height
    public static let aspect = designCrop.height / designCrop.width

    /// From this width the brain is a split; under it, an accordion.
    public static let splitBreakpoint = 860.0
    /// A card narrower than this is the narrow layout and drops its zone strip; its digest goes
    /// below `cardDigestMinWidth`.
    public static let cardZoneStripMinWidth = 460.0
    public static let cardDigestMinWidth = 380.0
    /// Under this width the footer loses Close; under `footerCompactWidth` Replay is its icon and
    /// the answer chips go as well.
    public static let footerCloseMinWidth = 960.0
    public static let footerCompactWidth = 640.0

    /// The head's width is `headShare` of the row between these, and 280 at most in an accordion.
    public static let headShare = 0.27
    public static let headMin = 280.0
    public static let headMax = 340.0
    public static let gutter = 24.0
    /// The readout is `readoutShare` of the row between these.
    public static let readoutShare = 0.5
    public static let readoutMin = 360.0
    public static let readoutMax = 640.0
    /// The open brain is never shorter than this, and the readout with it.
    public static let readoutMinHeight = 460.0
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
    /// How far the account rises into place when the readout is stacked under the head.
    public static let stackedReadoutTravel = 12.0

    /// The filter panel needs this much width beside the head, and the row this much width to
    /// have one at all; a turn with fewer zones than `panelMinZones` has chips.
    public static let panelMinWidth = 150.0
    public static let panelMinRowWidth = 900.0
    public static let panelMinZones = 3
    public static let panelGap = 16.0
    public static let chipsHeight = 28.0
    /// The air between the regions of the column.
    public static let regionGap = 8.0

    /// The left column (the head, the filter chips and the list) is `columnShare` of the row
    /// between these, and the head is as wide as the column.
    public static let columnShare = 0.27
    public static let columnMin = 320.0
    public static let columnMax = 360.0
    /// The account takes everything the left column leaves, and is never narrower than this.
    public static let accountMin = 360.0
    /// From an account this wide it is two columns: the story, then the open step's card.
    public static let storyMin = 440.0
    public static let detailMin = 460.0
    public static let splitAccountMin = storyMin + gutter + detailMin
    public static let storyShare = 0.42
    public static let storySplitMax = 680.0
    /// In one column the story is held to this width and the rest stays quiet canvas.
    public static let storyMax = 760.0
    /// Prose stops at 36 em, 540 points at the answer's 15, which is about 78 characters.
    public static let proseMeasure = 540.0
    public static let proseMeasureCharacters = 78
    /// The zone chips and the air under them, which is what the list starts below.
    public static let chipsBlock = 34.0
    /// The card under the cursor row hangs off it: its left margin, which narrows it in one column.
    public static let cardHang = 36.0
    /// Rows a split lists by default.
    public static let rowsSplit = 9
    public static let rowsAccordion = 8

    public static let listHeaderHeight = 36.0
    public static let listHintHeight = 24.0
    public static let listFootPadding = 4.0
    /// The list sits this far short of the readout's gutter, which is scrollbar room.
    public static let listScrollbarRoom = 12.0
    /// The hint line under the list is hidden in a row narrower than this.
    public static let hintMinWidth = 520.0
    public static let rowsMin = 8
    public static let rowsMax = 14
    /// An accordion's expanded row: its content is at most this tall, inside a 3 pt zone edge.
    public static let accordionContentMaxHeight = 340.0
    public static let accordionContentInset = 16.0

    /// A list row's height: 28 for a pointer, 32 for a finger.
    public static func listRowHeight(input: ChatInput) -> Double { input == .touch ? 32 : 28 }

    /// The most the list's rows may take of an accordion: 300 for a pointer, 340 for a finger,
    /// which is about ten rows of either.
    public static func listMaxHeight(input: ChatInput) -> Double { input == .touch ? 340 : 300 }

    public let width: Double
    public let density: ChatDensity
    public let input: ChatInput
    public let arrangement: Arrangement
    public let filterStyle: FilterStyle
    public let readoutType: ReadoutType
    public let card: Card
    /// The head: in a split flush with the gutter, in an accordion on top and centred.
    public let stage: NeuralRect
    /// Where a pointer counts as over the head: the head and, beside a readout, the gutter, so
    /// moving from a node toward the readout never crosses a dead strip.
    public let stageHover: NeuralRect
    /// The left column of a split, the whole row of an accordion.
    public let column: NeuralRect
    /// The zone filter panel left of the head; nil when the filters are chips.
    public let filterPanel: NeuralRect?
    /// The row of zone chips above the list; nil when the filters are a panel.
    public let filterChips: NeuralRect?
    /// The step list: header, rows, foot padding and hint.
    public let list: NeuralRect
    public let listHeader: NeuralRect
    public let listRows: NeuralRect
    /// The key-cap hint under the list; nil in a row under 520.
    public let listHint: NeuralRect?
    public let listRowHeight: Double
    /// How many rows the list shows.
    public let rowsShown: Int
    /// The readout; zero in an accordion, where the cursor's row carries it. In a split it is the
    /// whole account beside the column, whether one column or two.
    public let readout: NeuralRect
    /// One column or two.
    public let accountLayout: AccountLayout
    /// The account's region: beside the left column in a split, the list itself in an accordion.
    public let account: NeuralRect
    /// The story: the notes, the thoughts, the work lines; where the cursor's card unfolds in
    /// place when there is no detail column.
    public let story: NeuralRect
    /// The open step's card, in its own column; nil unless the account splits.
    public let detail: NeuralRect?
    public let footer: NeuralRect
    /// The height of the open brain without its footer: the larger of 460 and the column's.
    public let brainHeight: Double
    /// The height of the open row: the brain, the gap and the footer.
    public let rowHeight: Double
    /// The height of the collapsed row.
    public var cardHeight: Double { card.height }
    /// What one unit of the head's design space is in points on the head.
    public var designScale: Double { stage.width / Self.designWidth }

    public var footerHeight: Double { footer.height }
    public var gutterWidth: Double { Self.gutter }
    public var readoutMinHeight: Double { Self.readoutMinHeight }

    /// The head, by its other name.
    public var head: NeuralRect { stage }

    /// Whether a leader line ties the node being read to the readout: only beside it.
    public var hasLeader: Bool { arrangement == .split }

    /// The most the list's rows may take of this layout's input in an accordion.
    public var listMaxHeight: Double { Self.listMaxHeight(input: input) }

    /// How wide the readout's content is: the readout, or an expanded accordion row's content.
    public var readoutContentWidth: Double {
        arrangement == .split
            ? (detail?.width ?? max(story.width - Self.cardHang, 0)) : accordionContentWidth
    }

    /// The width prose is set to: the story's, held to 36 em.
    public var proseWidth: Double { min(story.width, Self.proseMeasure) }

    /// The width of an expanded accordion row's content: the list's, less the zone edge and the
    /// padding.
    public var accordionContentWidth: Double {
        max(list.width - 3 - Self.accordionContentInset, 0)
    }

    /// The tallest an expanded accordion row's content grows, which the row takes from the list.
    public var accordionContentMaxHeight: Double { Self.accordionContentMaxHeight }

    /// How many lines of output the readout shows before "N more lines": five in a column under 480
    /// points wide, eight otherwise. A client passes it to `NeuralReadout.make`.
    public var outputLinesShown: Int {
        readoutContentWidth < Self.readoutNarrowWidth ? Self.outputLinesNarrow : Self.outputLinesWide
    }

    /// The row as the collapsed card: the picture is the head's resting place on the card.
    public var cardGeometry: NeuralTransition.Geometry {
        NeuralTransition.Geometry(
            picture: card.picture, rowHeight: card.height, list: .zero, panel: .zero)
    }

    /// The row as the open brain: the head, the column's list and panel, and where the readout and
    /// the footer stand.
    public var stageGeometry: NeuralTransition.Geometry {
        NeuralTransition.Geometry(
            picture: stage, rowHeight: rowHeight, readout: readout, footer: footer,
            readoutTravel: arrangement == .split
                ? NeuralPoint(Self.readoutTravel, 0) : NeuralPoint(0, Self.stackedReadoutTravel),
            list: list, panel: filterPanel ?? filterChips ?? .zero)
    }

    /// Where a node of the head's design space is drawn in the row: the crop's origin is the
    /// head's.
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
    /// own row. Nil in an accordion, which has no leader.
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

    /// The left column's width at a row width: 27 percent of it between 320 and 360.
    public static func columnWidth(rowWidth width: Double) -> Double {
        min(max((width * columnShare).rounded(), columnMin), columnMax)
    }

    /// The head's width at a row width: as wide as the left column in a split, 280 at most in an
    /// accordion.
    public static func headWidth(rowWidth width: Double) -> Double {
        if width < splitBreakpoint { return min(headMin, width) }
        return columnWidth(rowWidth: width)
    }

    /// The account's width in a split: what the left column and the gutter leave.
    public static func readoutWidth(rowWidth width: Double) -> Double {
        max(width - gutter - columnWidth(rowWidth: width), accountMin)
    }

    /// One column below an account of 924, two from it.
    public static func accountLayout(accountWidth: Double) -> AccountLayout {
        accountWidth >= splitAccountMin ? .split : .single
    }

    /// The story's width: 42 percent of the account between 440 and 680 when it splits, otherwise
    /// the account held to 760.
    public static func storyWidth(accountWidth: Double) -> Double {
        switch accountLayout(accountWidth: accountWidth) {
        case .split: return min(max((accountWidth * storyShare).rounded(), storyMin), storySplitMax)
        case .single: return min(accountWidth, storyMax)
        }
    }

    /// How many list rows a viewport of this height asks for: the rule
    /// `clamp(floor((height x 0.55 - head - 80) / row), 8, 14)`.
    public static func rows(
        forViewportHeight height: Double, head: Double, rowHeight: Double = 28
    ) -> Int {
        let asked = Int(((height * 0.55 - head - 80) / rowHeight).rounded(.down))
        return min(max(asked, rowsMin), rowsMax)
    }

    /// - Parameters:
    ///   - input: touch lists have 32 point rows and a taller accordion list.
    ///   - zonesWithSteps: how many zones the turn has steps in; under three the filters are
    ///     chips rather than a panel.
    ///   - rows: the number of list rows to show; by default 8, or 9 from a 1200 row, or the
    ///     viewport rule when `viewportHeight` is given.
    ///   - cardMinHeight: the height the card's own words need where the type is larger than the
    ///     design's; the card is never shorter than its density says and grows to this.
    public static func make(
        width rawWidth: Double, density: ChatDensity, input: ChatInput = .pointer,
        zonesWithSteps: Int = NeuralZone.allCases.count, rows: Int? = nil,
        viewportHeight: Double? = nil, cardMinHeight: Double = 0
    ) -> NeuralStageMetrics {
        let width = max(rawWidth, 0)
        let card = makeCard(width: width, density: density, minHeight: cardMinHeight)
        let rowHeight = listRowHeight(input: input)
        let footerHeight: Double = density == .compact ? 30 : 36
        let footerGap: Double = density == .compact ? 6 : 8
        let split = width >= splitBreakpoint
        let headWidth = headWidth(rowWidth: width)
        let headHeight = headWidth * aspect
        let gap = regionGap

        var shown = rows ?? viewportHeight.map {
            Self.rows(forViewportHeight: $0, head: headHeight, rowHeight: rowHeight)
        } ?? (split ? rowsSplit : rowsAccordion)
        let hintShown = width >= hintMinWidth
        if !split {
            shown = min(shown, Int((listMaxHeight(input: input) / rowHeight).rounded(.down)))
        }
        shown = max(shown, 1)

        let columnWidth: Double
        let readoutWidth: Double
        if split {
            readoutWidth = Self.readoutWidth(rowWidth: width)
            columnWidth = max(width - gutter - readoutWidth, 0)
        } else {
            readoutWidth = 0
            columnWidth = width
        }
        let headX = split ? 0 : max((width - headWidth) / 2, 0)
        let head = NeuralRect(x: headX, y: 0, width: headWidth, height: headHeight)
        let style = FilterStyle.chips
        let panel: NeuralRect? = nil
        var cursor = headHeight + gap
        let chips = NeuralRect(x: 0, y: cursor, width: columnWidth, height: chipsHeight)
        cursor += chipsBlock
        let listWidth = split ? max(columnWidth - listScrollbarRoom, 0) : columnWidth
        let header = NeuralRect(x: 0, y: cursor, width: listWidth, height: listHeaderHeight)
        let rowsRect = NeuralRect(
            x: 0, y: header.maxY, width: listWidth, height: Double(shown) * rowHeight)
        let hintHeight = hintShown ? listHintHeight : 0
        let blockHeight = listHeaderHeight + rowsRect.height + listFootPadding + hintHeight
        let list = NeuralRect(x: 0, y: cursor, width: listWidth, height: blockHeight)
        let hint = hintShown
            ? NeuralRect(
                x: 0, y: rowsRect.maxY + listFootPadding, width: listWidth, height: listHintHeight)
            : nil
        let brain = split ? max(list.maxY, readoutMinHeight) : list.maxY
        let footer = NeuralRect(
            x: 0, y: brain + footerGap, width: width, height: footerHeight)
        let readout = split
            ? NeuralRect(x: columnWidth + gutter, y: 0, width: readoutWidth, height: brain) : .zero
        let region = split ? readout : NeuralRect(x: 0, y: list.y, width: list.width, height: list.height)
        let layout = split ? accountLayout(accountWidth: region.width) : AccountLayout.single
        let storyRect = NeuralRect(
            x: region.x, y: region.y,
            width: split ? storyWidth(accountWidth: region.width) : region.width,
            height: region.height)
        let detailRect: NeuralRect? = layout == .split
            ? NeuralRect(
                x: storyRect.maxX + gutter, y: region.y,
                width: region.width - storyRect.width - gutter, height: region.height)
            : nil
        return NeuralStageMetrics(
            width: width, density: density, input: input, arrangement: split ? .split : .accordion,
            filterStyle: style, readoutType: split && readoutWidth < 440 ? .stepDown : .regular,
            card: card, stage: head,
            stageHover: split
                ? NeuralRect(x: head.x, y: 0, width: head.width + gutter, height: head.height) : head,
            column: NeuralRect(x: 0, y: 0, width: columnWidth, height: brain), filterPanel: panel,
            filterChips: chips, list: list, listHeader: header, listRows: rowsRect, listHint: hint,
            listRowHeight: rowHeight, rowsShown: shown, readout: readout, accountLayout: layout,
            account: region, story: storyRect, detail: detailRect, footer: footer,
            brainHeight: brain, rowHeight: footer.maxY)
    }

    /// The row height while an accordion row is expanded to its content's largest; a split row is
    /// the same height either way.
    public var pinnedRowHeight: Double {
        arrangement == .split ? rowHeight : rowHeight + accordionContentMaxHeight
    }

    private static func makeCard(width: Double, density: ChatDensity, minHeight: Double) -> Card {
        let layout = cardLayout(width: width)
        let comfortable = density == .comfortable
        let height = max(comfortable ? 112.0 : 84.0, minHeight.rounded(.up))
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
