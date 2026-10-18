import Foundation

/// The move between a collapsed turn and its open stage, and back: one choreography Core owns
/// down to every curve, driven by a progress `p` from nothing to one that the client reads off its
/// display clock. A client applies the numbers a frame carries and decides nothing.
///
/// One value, `g`, runs the whole move: 0 is the card, 1 is the stage. Opening is
/// `g = easeOutCubic(t / 320 ms)`, closing is `g = g0 x (1 - easeInOutCubic(t / max(110, 220 g0)))`,
/// and every piece of content reads the opening timeline at the time `g` corresponds to
/// (`te = 320 x (1 - (1 - g)^(1/3))`), so closing is the opening played back faster and a reversal
/// is only `g` changing direction: it never restarts and never jumps. Opening takes 320 ms,
/// closing 220 ms, and a new turn arriving (the old one collapsing while the new one opens) 280 ms
/// for both halves; two moves that run together are a `NeuralCrossing`. Reduced motion is a 120 ms crossfade with no travel, no
/// sweep and no stagger; a strained or critical window is 160 ms with the travel and no sweep or
/// stagger. The head is the one element that travels: its rectangle runs from the card's picture
/// to the stage (or back) along an ease-out cubic (an ease-in cubic back, which is the same curve
/// run in reverse), and everything else is timed from the press in the table below, in
/// milliseconds of the full-length move:
///
/// | open (320) | what |
/// |---|---|
/// | 0 to 90 | card text, chips and edge fade out sliding 8 pt left; the card's surface fades |
/// | 40 to 200 | the sweep band crosses once; the zones come up from card brightness to rest |
/// | 90 to 190 | the filter panel and the list header fade in |
/// | 100 to 290 | list rows slide in 6 pt, 12 ms apart |
/// | 120 to 300 | nodes pop in step order across 150 ms (0.6 to 1.0 with a 6 percent overshoot) |
/// | 130 to 300 | the account fades in and slides in (24 pt, 12 pt up when stacked) |
/// | 140 to 300 | wires draw along their length, just behind the nodes; ties 240 to 320 |
/// | 240 to 320 | the footer fades in |
///
/// The sweep peaks at 42 percent strength. The head overscales 1.5 percent in a half sine over `g`
/// from 0.6 to 1.0, about its centre. Closing is the same table read backwards with no overshoot
/// on the nodes and no sweep. The card's tone edge rides the picture's left edge (12 pt left of
/// it) for 90 ms of `te` and is gone by 150.
public struct NeuralTransition: Sendable, Equatable {
    public enum Direction: Sendable, Equatable {
        case open
        case close
        /// The opening half of a swap: a newer turn arriving while the older one collapses.
        case swap
        /// The collapsing half of a swap.
        case swapClose

        public var isOpening: Bool { self == .open || self == .swap }

        public var reversed: Direction {
            switch self {
            case .open: return .close
            case .close: return .open
            case .swap: return .swapClose
            case .swapClose: return .swap
            }
        }
    }

    /// One end of the move: where the head is, how tall the row is, and where the readout and the
    /// footer will stand.
    public struct Geometry: Sendable, Equatable {
        /// The head: the card's picture, or the stage.
        public var picture: NeuralRect
        public var rowHeight: Double
        public var readout: NeuralRect
        public var footer: NeuralRect
        /// Where the readout slides in from, relative to where it stands.
        public var readoutTravel: NeuralPoint
        /// The step list and the filter panel (or chips) that fade in beside and under the head.
        public var list: NeuralRect
        public var panel: NeuralRect

        public init(
            picture: NeuralRect, rowHeight: Double, readout: NeuralRect = .zero,
            footer: NeuralRect = .zero, readoutTravel: NeuralPoint = NeuralPoint(0, 0),
            list: NeuralRect = .zero, panel: NeuralRect = .zero
        ) {
            self.list = list
            self.panel = panel
            self.picture = picture
            self.rowHeight = rowHeight
            self.readout = readout
            self.footer = footer
            self.readoutTravel = readoutTravel
        }
    }

    public static let openDuration: TimeInterval = 0.320
    public static let closeDuration: TimeInterval = 0.220
    public static let swapDuration: TimeInterval = 0.280
    public static let strainedDuration: TimeInterval = 0.160
    public static let crossfadeDuration: TimeInterval = 0.120
    /// How long the first content (Now or the digest) cross-fades in after the readout lands.
    public static let contentFadeDuration: TimeInterval = 0.090
    /// How far the card's text slides while it fades.
    public static let cardTextSlide = 8.0
    /// The scale a node pops in from.
    public static let nodeStartScale = 0.6
    /// How far past full size a node swells before it settles.
    public static let nodeOvershoot = 0.06
    /// How much the head overscales at `g = 0.8`, a half sine over `g` from 0.6 to 1.0.
    public static let travellerOverscale = 0.015
    /// The sweep band's peak strength.
    public static let sweepStrength = 0.42
    /// The shortest a reversal runs, however little of the distance is left.
    public static let reversalFloor: TimeInterval = 0.110
    /// How far left of the picture the card's tone edge rides, and for how long it follows.
    public static let edgeGap = 12.0
    public static let edgeFollowMs = 90.0
    public static let edgeFadeEndMs = 150.0
    /// The opening timeline's length in milliseconds: content time `te` runs `0...320`.
    public static let openMs = 320.0

    public let direction: Direction
    public let from: Geometry
    public let to: Geometry
    /// How many nodes are drawn: the stagger is spread over them.
    public let nodeCount: Int
    /// How many list rows are drawn: their slide is staggered over them.
    public let rowCount: Int
    public let reduceMotion: Bool
    public let level: ShedLevel
    /// Whether the turn is running: an opening is then `fromLive` (the traveller is the live head
    /// and keeps its swell) and a closing `toLive` (it lands on a live card).
    public let live: Bool

    private let table: Direction
    private let startG: Double

    /// Whether this window may not afford the sweep and the stagger.
    public var isStrained: Bool { level >= .strained }

    /// An opening from a live card: the head keeps breathing through the move.
    public var fromLive: Bool { live && direction.isOpening }
    /// A closing onto a live card.
    public var toLive: Bool { live && !direction.isOpening }

    /// A move from `from` to `to`: for an opening the card to the stage, for a closing the stage
    /// to the card.
    public init(
        direction: Direction, from: Geometry, to: Geometry, nodeCount: Int = 0, rowCount: Int = 0,
        reduceMotion: Bool = false, level: ShedLevel = .calm, live: Bool = false
    ) {
        self.rowCount = max(rowCount, 0)
        self.direction = direction
        self.from = from
        self.to = to
        self.nodeCount = max(nodeCount, 0)
        self.reduceMotion = reduceMotion
        self.level = level
        self.live = live
        table = direction
        startG = direction.isOpening ? 0 : 1
    }

    private init(copying other: NeuralTransition, direction: Direction, startG: Double) {
        self.direction = direction
        from = other.to
        to = other.from
        nodeCount = other.nodeCount
        rowCount = other.rowCount
        reduceMotion = other.reduceMotion
        level = other.level
        live = other.live
        table = direction
        self.startG = startG
    }

    /// How long the whole move takes, in seconds, for a client that drives it by a clock.
    public var fullDuration: TimeInterval {
        if reduceMotion { return Self.crossfadeDuration }
        if isStrained { return Self.strainedDuration }
        switch direction {
        case .open: return Self.openDuration
        case .close: return Self.closeDuration
        case .swap, .swapClose: return Self.swapDuration
        }
    }

    /// The share of the distance this move still has to cover.
    private var share: Double { direction.isOpening ? 1 - startG : startG }

    /// How long this move takes: the whole of it, or in proportion the distance a reversal still
    /// has to go, never under 110 ms (or the whole move when that is shorter).
    public var duration: TimeInterval {
        let full = fullDuration
        guard share < 1 else { return full }
        return max(min(Self.reversalFloor, full), full * share)
    }

    public static let minimumDuration: TimeInterval = 0.040

    /// `g` at progress `u` of this move: 0 is the card and 1 the stage.
    public func gradient(at u: Double) -> Double {
        let u = Self.clamp(u)
        let end = direction.isOpening ? 1.0 : 0.0
        if u <= 0 { return startG }
        if u >= 1 { return end }
        if reduceMotion { return startG + (end - startG) * u }
        if direction.isOpening { return startG + (1 - startG) * Self.easeOutCubic(u) }
        return startG * (1 - Self.easeInOutCubic(u))
    }

    /// The same move run back from `u`, so a press during it turns the head round where it is
    /// rather than restarting. The new move's frame at 0 is exactly this move's frame at `u`, its
    /// frame at 1 is the end the other way, and it takes the time the new direction needs for
    /// the distance left.
    public func reversed(from u: Double) -> NeuralTransition {
        NeuralTransition(copying: self, direction: direction.reversed, startG: gradient(at: u))
    }

    public static func clamp(_ value: Double, _ low: Double = 0, _ high: Double = 1) -> Double {
        min(max(value, low), high)
    }

    public static func easeOutCubic(_ t: Double) -> Double {
        let x = 1 - clamp(t)
        return 1 - x * x * x
    }

    public static func easeInCubic(_ t: Double) -> Double {
        let x = clamp(t)
        return x * x * x
    }

    /// The soft start and soft landing of a closing: cubic both ways.
    public static func easeInOutCubic(_ t: Double) -> Double {
        let x = clamp(t)
        if x >= 1 { return 1 }
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    /// The opening timeline's time, in milliseconds, that geometry progress `g` corresponds to:
    /// `320 x (1 - (1 - g)^(1/3))`. Opening runs it forward in real time and closing backwards.
    public static func contentTime(forGradient g: Double) -> Double {
        let g = clamp(g)
        if g >= 1 { return openMs }
        return openMs * (1 - pow(1 - g, 1.0 / 3.0))
    }

    /// How hard `easeOutBack` leans past its target; chosen so a node scaled from 0.6 to 1.0
    /// peaks 6 percent over.
    public static let backStrength = 2.18

    /// An ease-out that swells past 1 and settles back to it: the node's pop.
    public static func easeOutBack(_ t: Double) -> Double {
        let x = clamp(t) - 1
        return 1 + (backStrength + 1) * x * x * x + backStrength * x * x
    }

    /// The first content's alpha `seconds` after the readout landed: a 90 ms cross-fade, which is
    /// the client's to run because it begins when the move has ended.
    public static func firstContentAlpha(after seconds: TimeInterval) -> Double {
        clamp(seconds / contentFadeDuration)
    }

    /// The head's scale over the stage's about its centre at `g`: 1 outside `0.6...1`, and up to
    /// 1.015 at 0.8 in a half sine between.
    public static func overscale(at g: Double) -> Double {
        guard g > 0.6, g < 1 else { return 1 }
        return 1 + travellerOverscale * sin(Double.pi * (g - 0.6) / 0.4)
    }

    /// Every element at progress `u` of this move, from nothing to one. `clock` is the absolute
    /// time of the display's clock, which a live head's swell is read from; it changes nothing
    /// else.
    public func frame(at u: Double, clock: TimeInterval = 0) -> NeuralTransitionFrame {
        Timeline(self).frame(at: gradient(at: u), clock: clock)
    }

    /// The frame `seconds` into this move.
    public func frame(atTime seconds: TimeInterval, clock: TimeInterval = 0) -> NeuralTransitionFrame {
        frame(at: seconds / max(duration, 0.001), clock: clock)
    }

    /// The row height `seconds` into this move.
    public func rowHeight(atTime seconds: TimeInterval) -> Double {
        frame(atTime: seconds).rowHeight
    }
}

/// Two moves that run together: one turn closing while another opens, which shares the row's
/// height animation instead of fighting the scroll anchor. Each runs on its own curve and
/// duration from one clock; the content below both rows moves with the sum of their heights.
public struct NeuralCrossing: Sendable, Equatable {
    public let closing: NeuralTransition
    public let opening: NeuralTransition
    /// Whether the closing row sits above the opening one, so that the opening row is carried
    /// down or up as the one above it changes height.
    public let closingIsAbove: Bool

    public var duration: TimeInterval { max(closing.duration, opening.duration) }

    /// The heights of both rows `seconds` in.
    public func rowHeights(atTime seconds: TimeInterval) -> (closing: Double, opening: Double) {
        (closing.rowHeight(atTime: seconds), opening.rowHeight(atTime: seconds))
    }

    /// What both rows are tall together, which is what the transcript below stands on.
    public func totalHeight(atTime seconds: TimeInterval) -> Double {
        let heights = rowHeights(atTime: seconds)
        return heights.closing + heights.opening
    }

    /// How far the content below both rows has moved since the move began.
    public func belowShift(atTime seconds: TimeInterval) -> Double {
        totalHeight(atTime: seconds) - totalHeight(atTime: 0)
    }

    /// How far the opening row's top has moved: by the change of the closing row's height when it
    /// is above, not at all when it is below.
    public func openingRowShift(atTime seconds: TimeInterval) -> Double {
        guard closingIsAbove else { return 0 }
        return closing.rowHeight(atTime: seconds) - closing.rowHeight(atTime: 0)
    }

    public func closingFrame(atTime seconds: TimeInterval, clock: TimeInterval = 0) -> NeuralTransitionFrame {
        closing.frame(atTime: seconds, clock: clock)
    }

    public func openingFrame(atTime seconds: TimeInterval, clock: TimeInterval = 0) -> NeuralTransitionFrame {
        opening.frame(atTime: seconds, clock: clock)
    }

    /// Both moves turned round at `seconds`: each reverses from where it is. Closing becomes an
    /// opening and the other way, so the roles swap with the directions.
    public func reversed(atTime seconds: TimeInterval) -> NeuralCrossing {
        let back = closing.reversed(from: seconds / max(closing.duration, 0.001))
        let forward = opening.reversed(from: seconds / max(opening.duration, 0.001))
        return NeuralCrossing(closing: forward, opening: back, closingIsAbove: closingIsAbove)
    }
}

extension NeuralTransition {
    /// Two moves run together as one crossing.
    public static func crossing(
        closing: NeuralTransition, opening: NeuralTransition, closingIsAbove: Bool = true
    ) -> NeuralCrossing {
        NeuralCrossing(closing: closing, opening: opening, closingIsAbove: closingIsAbove)
    }

    /// The move for a row's metrics: an opening runs from the card to the stage, a closing from
    /// the stage to the card.
    public static func make(
        _ direction: Direction, metrics: NeuralStageMetrics, nodeCount: Int,
        reduceMotion: Bool = false, level: ShedLevel = .calm, live: Bool = false
    ) -> NeuralTransition {
        let card = metrics.cardGeometry
        let stage = metrics.stageGeometry
        return NeuralTransition(
            direction: direction, from: direction.isOpening ? card : stage,
            to: direction.isOpening ? stage : card, nodeCount: nodeCount,
            rowCount: metrics.rowsShown, reduceMotion: reduceMotion, level: level, live: live)
    }
}

/// One node's reveal: how far in, how big, how visible. Computed from the clock rather than stored
/// per node, so a frame is a handful of numbers whatever the turn's size.
public struct NeuralNodeReveal: Sendable, Equatable {
    public let count: Int
    let clock: Double
    let start: Double
    let stagger: Double
    let length: Double
    let closing: Bool
    let uniform: Double?
    var overshoots = true

    /// How far node `index` has come in, `0...1`, in step order when opening and last-first when
    /// closing.
    public func progress(_ index: Int) -> Double {
        if let uniform { return uniform }
        guard count > 0, index >= 0, index < count else { return 0 }
        let place = closing ? count - 1 - index : index
        let offset = count > 1 ? stagger * Double(place) / Double(count - 1) : 0
        let reached = NeuralTransition.clamp((clock - start - offset) / length)
        return closing ? 1 - reached : reached
    }

    /// How many nodes have begun to appear.
    public var revealed: Int {
        guard count > 0 else { return 0 }
        return (0..<count).reduce(0) { $0 + (progress($1) > 0 ? 1 : 0) }
    }

    /// The node's scale: from 0.6 to 1 with a 6 percent overshoot when opening, back to 0.6 with
    /// none when closing, and 1 for a crossfade.
    public func scale(_ index: Int) -> Double {
        if uniform != nil { return 1 }
        let p = progress(index)
        let start = NeuralTransition.nodeStartScale
        let curve =
            closing || !overshoots ? NeuralTransition.easeOutCubic(p) : NeuralTransition.easeOutBack(p)
        return start + (1 - start) * curve
    }

    /// The node's alpha: in a little before it has finished growing.
    public func alpha(_ index: Int) -> Double {
        NeuralTransition.clamp(progress(index) * 1.6)
    }
}

/// One list row's arrival: it slides in a few points while it fades, a little after the one above.
public struct NeuralRowReveal: Sendable, Equatable {
    /// How far a row slides, in points.
    public static let travel = 6.0

    public let count: Int
    let clock: Double
    let start: Double
    let stagger: Double
    let length: Double
    let closing: Bool
    let uniform: Double?

    /// How far row `index` has arrived, `0...1`.
    public func progress(_ index: Int) -> Double {
        if let uniform { return uniform }
        guard count > 0, index >= 0, index < count else { return 0 }
        let reached = NeuralTransition.clamp((clock - start - stagger * Double(index)) / length)
        return closing ? 1 - reached : reached
    }

    /// How far the row still has to slide down into place, `6...0`.
    public func offset(_ index: Int) -> Double {
        uniform != nil ? 0 : Self.travel * (1 - NeuralTransition.easeOutCubic(progress(index)))
    }

    public func alpha(_ index: Int) -> Double { progress(index) }

    /// How many rows have begun to arrive.
    public var revealed: Int { (0..<count).reduce(0) { $0 + (progress($1) > 0 ? 1 : 0) } }
}

/// Where the card's tone edge is and how visible: it rides the picture's left edge for the first
/// 90 ms of content time and is gone by 150.
public struct NeuralEdgeFollow: Sendable, Equatable {
    public let x: Double
    public let alpha: Double
}

/// The card's NOW line leaving and the account's Now item arriving in the same place, so a live
/// card's line becomes the header's without a jump.
public struct NeuralNowCrossfade: Sendable, Equatable {
    public let card: Double
    public let account: Double
}

/// Every element of the row at one instant of a transition.
public struct NeuralTransitionFrame: Sendable, Equatable {
    /// The move's geometry progress `g`, `0...1`: 0 is the card and 1 the stage, in both
    /// directions.
    public var progress: Double
    /// The content time this frame reads, `0...320` ms of the opening timeline.
    public var contentTime: Double
    /// The head: the one element that travels.
    public var traveller: NeuralRect
    /// The traveller's width over the stage's: about 0.23 at the card.
    public var travellerScale: Double
    public var travellerAlpha: Double
    /// How lit a live head's active zone is: the breath at the display clock, `0.34...1`, and 1
    /// for a head that is not live or when motion is reduced. A traveller that carries it keeps
    /// breathing through the whole move.
    public var travellerSwell: Double
    /// The card's own picture; zero through a move, because the traveller is the picture. Only a
    /// crossfade fades it.
    public var cardPictureAlpha: Double
    /// The card's zone lights and rings. A closing keeps them off until the head is near the card
    /// and brings them in as it lands, because the ring scales up with the traveller and would be
    /// heavy mid-move; an opening draws them inside the traveller, so they are off.
    public var cardLightsAlpha: Double
    public var cardTextAlpha: Double
    public var cardTextOffsetX: Double
    public var cardSurfaceAlpha: Double
    /// The card's tone edge, riding the picture.
    public var edge: NeuralEdgeFollow
    /// The card's NOW line against the account's Now item.
    public var nowCrossfade: NeuralNowCrossfade
    /// The card's counts leaving and the header's arriving, which is the same crossfade as the
    /// NOW line's.
    public var countsCrossfade: NeuralNowCrossfade
    public var rowHeight: Double
    /// How many points one design unit is inside the traveller: the stage is drawn inside it, so
    /// nodes, wires and the leader scale with the head from the first frame and never drift off it.
    public var designScale: Double { traveller.width / NeuralStageMetrics.designWidth }

    /// Where a point of the head's design space is in the row at this frame: inside the traveller,
    /// cropped the way the stage and the card's picture are.
    public func point(forDesign point: NeuralPoint) -> NeuralPoint {
        let crop = NeuralStageMetrics.designCrop
        return NeuralPoint(
            traveller.x + (point.x - crop.x) * traveller.width / crop.width,
            traveller.y + (point.y - crop.y) * traveller.height / crop.height)
    }

    /// The sweep band's envelope, `0...1`, and where it is on its one crossing.
    public var sweepAmount: Double
    public var sweepPhase: Double
    /// From the zones' card brightness (0) to their rest brightness (1).
    public var zoneLift: Double
    public var nodes: NeuralNodeReveal
    /// How much of every wire is drawn, and of every tie.
    public var wireDraw: Double
    public var tieDraw: Double
    /// The zone filter panel (or chips) and the list's header: they fade in from 90 to 190 ms.
    public var panelAlpha: Double
    public var listHeaderAlpha: Double
    /// The list's rows, each sliding in 6 points, 12 ms after the one above, from 100 ms.
    public var listRows: NeuralRowReveal
    /// How far the readout still has to slide, and how visible it is.
    public var readoutOffset: NeuralPoint
    public var readoutAlpha: Double
    public var footerAlpha: Double
}

extension NeuralTransition {
    /// The tables, evaluated at a geometry progress.
    fileprivate struct Timeline {
        let move: NeuralTransition
        let opening: Bool

        init(_ move: NeuralTransition) {
            self.move = move
            opening = move.table.isOpening
        }

        private func window(_ t: Double, _ start: Double, _ end: Double) -> Double {
            NeuralTransition.clamp((t - start) / (end - start))
        }

        private var card: Geometry { opening ? move.from : move.to }
        private var stage: Geometry { opening ? move.to : move.from }

        func frame(at g: Double, clock: TimeInterval) -> NeuralTransitionFrame {
            move.reduceMotion ? crossfade(at: g, clock: clock) : travel(at: g, clock: clock)
        }

        private func height(at g: Double) -> Double {
            card.rowHeight + (stage.rowHeight - card.rowHeight) * g
        }

        private func scale(of rect: NeuralRect) -> Double {
            let full = max(move.from.picture.width, move.to.picture.width)
            return full > 0 ? rect.width / full : 1
        }

        private func swell(_ clock: TimeInterval) -> Double {
            move.live && !move.reduceMotion ? NeuralMotion.breathLevel(at: clock) : 1
        }

        private func overscaled(_ rect: NeuralRect, at g: Double) -> NeuralRect {
            let factor = NeuralTransition.overscale(at: g)
            guard factor != 1 else { return rect }
            let width = rect.width * factor
            let height = rect.height * factor
            return NeuralRect(
                x: rect.x - (width - rect.width) / 2, y: rect.y - (height - rect.height) / 2,
                width: width, height: height)
        }

        private func edge(at te: Double, picture: NeuralRect) -> NeuralEdgeFollow {
            NeuralEdgeFollow(
                x: picture.x - NeuralTransition.edgeGap,
                alpha: 1 - window(te, NeuralTransition.edgeFollowMs, NeuralTransition.edgeFadeEndMs))
        }

        private func crossfade(at g: Double, clock: TimeInterval) -> NeuralTransitionFrame {
            let shown = g
            let cardShare = 1 - shown
            let rect = shown >= 0.5 ? stage.picture : card.picture
            let handoff = NeuralNowCrossfade(card: cardShare, account: shown)
            return NeuralTransitionFrame(
                progress: g, contentTime: NeuralTransition.contentTime(forGradient: g),
                traveller: rect, travellerScale: scale(of: rect), travellerAlpha: shown,
                travellerSwell: swell(clock), cardPictureAlpha: cardShare, cardLightsAlpha: cardShare,
                cardTextAlpha: cardShare, cardTextOffsetX: 0, cardSurfaceAlpha: cardShare,
                edge: NeuralEdgeFollow(x: card.picture.x - NeuralTransition.edgeGap, alpha: cardShare),
                nowCrossfade: handoff, countsCrossfade: handoff, rowHeight: height(at: g),
                sweepAmount: 0, sweepPhase: 0, zoneLift: shown,
                nodes: NeuralNodeReveal(
                    count: move.nodeCount, clock: 0, start: 0, stagger: 0, length: 1,
                    closing: !opening, uniform: shown),
                wireDraw: shown, tieDraw: shown, panelAlpha: shown, listHeaderAlpha: shown,
                listRows: NeuralRowReveal(
                    count: move.rowCount, clock: 0, start: 0, stagger: 0, length: 1,
                    closing: !opening, uniform: shown),
                readoutOffset: NeuralPoint(0, 0), readoutAlpha: shown, footerAlpha: shown)
        }

        private func travel(at g: Double, clock: TimeInterval) -> NeuralTransitionFrame {
            let te = NeuralTransition.contentTime(forGradient: g)
            let base = card.picture.interpolated(to: stage.picture, g)
            let rect = overscaled(base, at: g)
            let out = window(te, 0, 90)
            let sweepWindow = window(te, 40, 200)
            let sweeping = opening && !move.isStrained
            let accountWindow = NeuralTransition.easeOutCubic(window(te, 130, 300))
            let slide = stage.readoutTravel
            let handoff = NeuralNowCrossfade(card: 1 - out, account: accountWindow)
            let stagger = move.isStrained ? 0.0 : 150.0
            return NeuralTransitionFrame(
                progress: g, contentTime: te, traveller: rect, travellerScale: scale(of: rect),
                travellerAlpha: 1, travellerSwell: swell(clock), cardPictureAlpha: 0,
                cardLightsAlpha: opening ? 0 : NeuralTransition.clamp((0.4 - g) / 0.4),
                cardTextAlpha: 1 - out, cardTextOffsetX: -NeuralTransition.cardTextSlide * out,
                cardSurfaceAlpha: 1 - out, edge: edge(at: te, picture: base), nowCrossfade: handoff,
                countsCrossfade: handoff, rowHeight: height(at: g),
                sweepAmount: sweeping && sweepWindow > 0 && sweepWindow < 1
                    ? NeuralTransition.sweepStrength * sin(Double.pi * sweepWindow) : 0,
                sweepPhase: sweeping ? sweepWindow : 0,
                zoneLift: NeuralTransition.easeOutCubic(sweepWindow),
                nodes: NeuralNodeReveal(
                    count: move.nodeCount, clock: te, start: 120, stagger: stagger,
                    length: move.isStrained ? 180 : 30, closing: false, uniform: nil,
                    overshoots: opening),
                wireDraw: NeuralTransition.easeOutCubic(window(te, 140, 300)),
                tieDraw: NeuralTransition.easeOutCubic(window(te, 240, 320)),
                panelAlpha: window(te, 90, 190), listHeaderAlpha: window(te, 90, 190),
                listRows: NeuralRowReveal(
                    count: move.rowCount, clock: te, start: 100,
                    stagger: move.isStrained || move.rowCount < 2
                        ? 0 : min(12, 110 / Double(move.rowCount - 1)),
                    length: 80, closing: false, uniform: nil),
                readoutOffset: NeuralPoint(slide.x * (1 - accountWindow), slide.y * (1 - accountWindow)),
                readoutAlpha: accountWindow,
                footerAlpha: NeuralTransition.easeOutCubic(window(te, 240, 320)))
        }
    }
}
