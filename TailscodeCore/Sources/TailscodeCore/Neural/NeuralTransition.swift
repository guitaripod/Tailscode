import Foundation

/// The move between a collapsed turn and its open stage, and back: one choreography Core owns
/// down to every curve, driven by a progress `p` from nothing to one that the client reads off its
/// display clock. A client applies the numbers a frame carries and decides nothing.
///
/// Opening takes 320 ms, closing 220 ms, and a new turn arriving (the old one collapsing while the
/// new one opens) 280 ms for both halves. Reduced motion is a 120 ms crossfade with no travel, no
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
/// | 120 to 300 | nodes pop in step order across 150 ms (0.6 to 1.0 with a 6 percent overshoot) |
/// | 140 to 300 | wires draw along their length, just behind the nodes; ties 240 to 320 |
/// | 150 to 320 | the readout fades in and slides in |
/// | 240 to 320 | the footer fades in |
///
/// Closing is the reverse, faster and with no overshoot: footer and readout out by 100, nodes and
/// wires gone by 150, the head shrinks into the card's picture while the card fades back in.
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

        public init(
            picture: NeuralRect, rowHeight: Double, readout: NeuralRect = .zero,
            footer: NeuralRect = .zero, readoutTravel: NeuralPoint = NeuralPoint(0, 0)
        ) {
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

    public let direction: Direction
    public let from: Geometry
    public let to: Geometry
    /// How many nodes are drawn: the stagger is spread over them.
    public let nodeCount: Int
    public let reduceMotion: Bool
    public let level: ShedLevel

    private let table: Direction
    private let spanStart: Double
    private let spanEnd: Double

    /// Whether this window may not afford the sweep and the stagger.
    public var isStrained: Bool { level >= .strained }

    /// A move from `from` to `to`: for an opening the card to the stage, for a closing the stage
    /// to the card.
    public init(
        direction: Direction, from: Geometry, to: Geometry, nodeCount: Int = 0,
        reduceMotion: Bool = false, level: ShedLevel = .calm
    ) {
        self.direction = direction
        self.from = from
        self.to = to
        self.nodeCount = max(nodeCount, 0)
        self.reduceMotion = reduceMotion
        self.level = level
        table = direction
        spanStart = 0
        spanEnd = 1
    }

    private init(copying other: NeuralTransition, direction: Direction, spanStart: Double, spanEnd: Double) {
        self.direction = direction
        from = other.from
        to = other.to
        nodeCount = other.nodeCount
        reduceMotion = other.reduceMotion
        level = other.level
        table = other.table
        self.spanStart = spanStart
        self.spanEnd = spanEnd
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

    /// How long this move takes: the whole of it, or the share of it a reversal still has to run.
    public var duration: TimeInterval {
        let share = abs(spanEnd - spanStart)
        return share >= 1 ? fullDuration : max(fullDuration * share, Self.minimumDuration)
    }

    public static let minimumDuration: TimeInterval = 0.040

    /// The same move run back from `p`, so a press during it turns the head round where it is
    /// rather than restarting. The new move's frame at 0 is exactly this move's frame at `p`, its
    /// frame at 1 is this move's frame at 0, and it takes the time the new direction needs for
    /// the distance left.
    public func reversed(from p: Double) -> NeuralTransition {
        let at = spanStart + (spanEnd - spanStart) * Self.clamp(p)
        let target = spanEnd >= spanStart ? 0.0 : 1.0
        return NeuralTransition(
            copying: self, direction: direction.reversed, spanStart: at, spanEnd: target)
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

    /// Every element at progress `u` of this move, from nothing to one.
    public func frame(at u: Double) -> NeuralTransitionFrame {
        let progress = spanStart + (spanEnd - spanStart) * Self.clamp(u)
        return Timeline(self).frame(at: progress)
    }
}

extension NeuralTransition {
    /// The move for a row's metrics: an opening runs from the card to the stage, a closing from
    /// the stage to the card.
    public static func make(
        _ direction: Direction, metrics: NeuralStageMetrics, nodeCount: Int,
        reduceMotion: Bool = false, level: ShedLevel = .calm
    ) -> NeuralTransition {
        let card = metrics.cardGeometry
        let stage = metrics.stageGeometry
        return NeuralTransition(
            direction: direction, from: direction.isOpening ? card : stage,
            to: direction.isOpening ? stage : card, nodeCount: nodeCount, reduceMotion: reduceMotion,
            level: level)
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
        let curve = closing ? NeuralTransition.easeOutCubic(p) : NeuralTransition.easeOutBack(p)
        return start + (1 - start) * curve
    }

    /// The node's alpha: in a little before it has finished growing.
    public func alpha(_ index: Int) -> Double {
        NeuralTransition.clamp(progress(index) * 1.6)
    }
}

/// Every element of the row at one instant of a transition.
public struct NeuralTransitionFrame: Sendable, Equatable {
    /// The move's own progress, `0...1`, on the timeline of the move this frame was cut from.
    public var progress: Double
    /// The head: the one element that travels.
    public var traveller: NeuralRect
    /// The traveller's width over the stage's: about 0.23 at the card.
    public var travellerScale: Double
    public var travellerAlpha: Double
    /// The card's own picture; zero through a move, because the traveller is the picture. Only a
    /// crossfade fades it.
    public var cardPictureAlpha: Double
    /// The card's zone lights and rings. A closing keeps them off for the first 130 ms and brings
    /// them in with the card, because the ring scales up with the traveller and would be heavy
    /// mid-move; an opening draws them inside the traveller, so they are off.
    public var cardLightsAlpha: Double
    public var cardTextAlpha: Double
    public var cardTextOffsetX: Double
    public var cardSurfaceAlpha: Double
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
    /// How far the readout still has to slide, and how visible it is.
    public var readoutOffset: NeuralPoint
    public var readoutAlpha: Double
    public var footerAlpha: Double
}

extension NeuralTransition {
    /// The tables, evaluated.
    fileprivate struct Timeline {
        let move: NeuralTransition
        let opening: Bool
        let baseMs: Double

        init(_ move: NeuralTransition) {
            self.move = move
            opening = move.table.isOpening
            baseMs = opening ? 320 : 220
        }

        private func window(_ t: Double, _ start: Double, _ end: Double) -> Double {
            NeuralTransition.clamp((t - start) / (end - start))
        }

        private var stage: Geometry { opening ? move.to : move.from }

        func frame(at p: Double) -> NeuralTransitionFrame {
            move.reduceMotion ? crossfade(at: p) : travel(at: p)
        }

        private func height(at p: Double) -> Double {
            let eased = opening ? NeuralTransition.easeOutCubic(p) : NeuralTransition.easeInCubic(p)
            return move.from.rowHeight + (move.to.rowHeight - move.from.rowHeight) * eased
        }

        private func scale(of rect: NeuralRect) -> Double {
            let full = max(move.from.picture.width, move.to.picture.width)
            return full > 0 ? rect.width / full : 1
        }

        private func crossfade(at p: Double) -> NeuralTransitionFrame {
            let shown = opening ? p : 1 - p
            let card = 1 - shown
            let rect: NeuralRect
            if opening {
                rect = p <= 0 ? move.from.picture : move.to.picture
            } else {
                rect = p >= 1 ? move.to.picture : move.from.picture
            }
            return NeuralTransitionFrame(
                progress: p, traveller: rect, travellerScale: scale(of: rect), travellerAlpha: shown,
                cardPictureAlpha: card, cardLightsAlpha: card, cardTextAlpha: card, cardTextOffsetX: 0,
                cardSurfaceAlpha: card, rowHeight: height(at: p), sweepAmount: 0, sweepPhase: 0,
                zoneLift: shown,
                nodes: NeuralNodeReveal(
                    count: move.nodeCount, clock: 0, start: 0, stagger: 0, length: 1,
                    closing: !opening, uniform: shown),
                wireDraw: shown, tieDraw: shown, readoutOffset: NeuralPoint(0, 0),
                readoutAlpha: shown, footerAlpha: shown)
        }

        private func travel(at p: Double) -> NeuralTransitionFrame {
            let t = p * baseMs
            let eased = opening ? NeuralTransition.easeOutCubic(p) : NeuralTransition.easeInCubic(p)
            let rect = move.from.picture.interpolated(to: move.to.picture, eased)
            return opening ? openingFrame(t: t, p: p, rect: rect) : closingFrame(t: t, p: p, rect: rect)
        }

        private func openingFrame(t: Double, p: Double, rect: NeuralRect) -> NeuralTransitionFrame {
            let out = window(t, 0, 90)
            let sweepWindow = window(t, 40, 200)
            let sweeping = !move.isStrained
            let readoutWindow = NeuralTransition.easeOutCubic(window(t, 150, 320))
            let travel = stage.readoutTravel
            return NeuralTransitionFrame(
                progress: p, traveller: rect, travellerScale: scale(of: rect), travellerAlpha: 1,
                cardPictureAlpha: 0, cardLightsAlpha: 0, cardTextAlpha: 1 - out,
                cardTextOffsetX: -NeuralTransition.cardTextSlide * out, cardSurfaceAlpha: 1 - out,
                rowHeight: height(at: p),
                sweepAmount: sweeping && sweepWindow > 0 && sweepWindow < 1 ? sin(Double.pi * sweepWindow) : 0,
                sweepPhase: sweeping ? sweepWindow : 0,
                zoneLift: NeuralTransition.easeOutCubic(sweepWindow),
                nodes: NeuralNodeReveal(
                    count: move.nodeCount, clock: t, start: 120,
                    stagger: move.isStrained ? 0 : 150, length: move.isStrained ? 180 : 30,
                    closing: false, uniform: nil),
                wireDraw: NeuralTransition.easeOutCubic(window(t, 140, 300)),
                tieDraw: NeuralTransition.easeOutCubic(window(t, 240, 320)),
                readoutOffset: NeuralPoint(travel.x * (1 - readoutWindow), travel.y * (1 - readoutWindow)),
                readoutAlpha: readoutWindow,
                footerAlpha: NeuralTransition.easeOutCubic(window(t, 240, 320)))
        }

        private func closingFrame(t: Double, p: Double, rect: NeuralRect) -> NeuralTransitionFrame {
            let outWindow = window(t, 0, 100)
            let back = window(t, 120, 220)
            let travel = stage.readoutTravel
            let slide = NeuralTransition.easeInCubic(outWindow)
            return NeuralTransitionFrame(
                progress: p, traveller: rect, travellerScale: scale(of: rect), travellerAlpha: 1,
                cardPictureAlpha: 0, cardLightsAlpha: window(t, 130, 220), cardTextAlpha: back,
                cardTextOffsetX: -NeuralTransition.cardTextSlide * (1 - back), cardSurfaceAlpha: back,
                rowHeight: height(at: p), sweepAmount: 0, sweepPhase: 0,
                zoneLift: 1 - window(t, 0, 220),
                nodes: NeuralNodeReveal(
                    count: move.nodeCount, clock: t, start: 40,
                    stagger: move.isStrained ? 0 : 70, length: move.isStrained ? 110 : 40,
                    closing: true, uniform: nil),
                wireDraw: 1 - window(t, 20, 140), tieDraw: 1 - window(t, 0, 60),
                readoutOffset: NeuralPoint(travel.x * slide, travel.y * slide),
                readoutAlpha: 1 - outWindow, footerAlpha: 1 - outWindow)
        }
    }
}
