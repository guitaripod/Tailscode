import Foundation

/// Which scroller a wheel or trackpad event belongs to when a scroller sits inside another: the
/// view under the pointer (the inner) or the one around it (the outer). A person who rests the
/// pointer over a step list or an account while reading the page must be able to keep scrolling
/// the page, so the inner view keeps an event only while it can use it.
///
/// A gesture is one decision. The first event with a direction chooses, from where the inner view
/// stands and which way the fingers move, and the choice stands for the rest of the gesture and
/// for the momentum that follows it: a gesture that began at the edge it is moving past belongs to
/// the outer scroller from start to finish, and one the inner view started consuming stays its
/// own to the end even when it reaches the edge, so a list never hands the page a scroll that
/// the person began inside it. A wheel without phases decides every event on its own.
///
/// Positions and deltas are along one axis, the one the gesture moves on. A positive delta moves
/// the content toward its start (down on screen for a vertical scroller, which is what the system
/// reports for fingers moving down under natural scrolling or a wheel turned up without it), so
/// the offset falls; the offset is the distance of the viewport from the start of the content.
public struct ScrollHandoff: Sendable, Equatable {
    public enum Owner: Sendable, Equatable {
        case inner
        case outer
    }

    /// The phase of a gesture or of its momentum, as the system names them. `none` is the absence
    /// of one: a wheel with notches has no phase at all, and the events of momentum carry theirs
    /// in `momentum` while `phase` is `none`.
    public enum Phase: Sendable, Equatable {
        case none
        case mayBegin
        case began
        case stationary
        case changed
        case ended
        case cancelled
    }

    public struct Event: Sendable, Equatable {
        public var delta: Double
        public var phase: Phase
        public var momentum: Phase

        public init(delta: Double, phase: Phase = .none, momentum: Phase = .none) {
            self.delta = delta
            self.phase = phase
            self.momentum = momentum
        }

        /// A wheel with notches, whose events are each their own gesture.
        public var isDiscrete: Bool { phase == .none && momentum == .none }

        /// An event of the momentum a lifted gesture left behind.
        public var isMomentum: Bool { phase == .none && momentum != .none }
    }

    /// Where the inner scroller stands along the axis of the gesture.
    public struct Metrics: Sendable, Equatable {
        public var offset: Double
        public var content: Double
        public var viewport: Double

        public init(offset: Double, content: Double, viewport: Double) {
            self.offset = offset
            self.content = content
            self.viewport = viewport
        }

        /// How far the content reaches past the viewport.
        public var overflow: Double { max(content - viewport, 0) }

        /// Whether the inner view has anything to scroll: an overflow of a point or less is
        /// rounding in a layout, not content, and the view would only rubber-band.
        public var scrolls: Bool { overflow > ScrollHandoff.negligibleOverflow }

        /// Whether a delta of this sign still moves the inner view. It stops at the edge the
        /// delta moves it toward, within the width of a device pixel.
        public func canMove(_ delta: Double) -> Bool {
            guard scrolls else { return false }
            if delta > 0 { return offset > ScrollHandoff.edgeTolerance }
            if delta < 0 { return offset < overflow - ScrollHandoff.edgeTolerance }
            return true
        }
    }

    /// An overflow up to this many points is not scrolled.
    public static let negligibleOverflow = 1.0
    /// How near an edge the offset counts as standing on it.
    public static let edgeTolerance = 0.5

    private var latch: Owner?

    public init() {}

    /// Which scroller takes `event`, with the inner view standing at `metrics` as the event
    /// arrives. The call also keeps the gesture's decision for the events that follow.
    public mutating func route(_ event: Event, in metrics: Metrics) -> Owner {
        guard metrics.scrolls else {
            latch = event.isDiscrete || closes(event) ? nil : .outer
            return .outer
        }
        if event.isDiscrete {
            latch = nil
            return metrics.canMove(event.delta) ? .inner : .outer
        }
        if event.phase == .mayBegin {
            latch = nil
            return .inner
        }
        if event.phase == .began { latch = nil }
        if latch == nil { latch = choice(for: event, in: metrics) }
        let owner = latch ?? .inner
        if closes(event) { latch = nil }
        return owner
    }

    /// Who takes one notch of a wheel, for a client whose toolkit reports notches and no gestures.
    public static func notch(_ delta: Double, in metrics: Metrics) -> Owner {
        metrics.canMove(delta) ? .inner : .outer
    }

    /// Forgets the gesture in progress, for a view that was moved or rebuilt under the pointer.
    public mutating func reset() { latch = nil }

    /// Whether this event is the last of its gesture and of the momentum after it. A gesture that
    /// lifts keeps its owner through the momentum that follows, so the lift alone closes nothing.
    private func closes(_ event: Event) -> Bool {
        event.phase == .cancelled || event.momentum == .ended || event.momentum == .cancelled
    }

    /// The owner an event with a direction chooses, nil while the gesture has not moved yet.
    private func choice(for event: Event, in metrics: Metrics) -> Owner? {
        guard event.delta != 0 else { return nil }
        return metrics.canMove(event.delta) ? .inner : .outer
    }
}
