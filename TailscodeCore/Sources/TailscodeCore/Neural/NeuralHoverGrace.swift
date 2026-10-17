import Foundation

/// When the readout believes the pointer: a node is entered after it has rested for 40 ms, or at
/// once when the pointer arrives from another node, and leaving a node starts a grace so a drift
/// across a wire does not flash the digest. Everything is a pure function of the timestamps the
/// client passes, in the seconds of whatever monotonic clock it already draws from; nothing here
/// reads a clock or starts a timer.
public struct NeuralHoverGrace: Sendable, Equatable {
    /// How long the pointer rests on a node before the readout follows it.
    public static let intentDelay: TimeInterval = 0.040
    /// How long the readout keeps a node after the pointer left it, before it returns to the
    /// digest.
    public static let leaveGrace: TimeInterval = 0.400
    /// The same, for a turn that is running, where the readout returns to Now.
    public static let liveLeaveGrace: TimeInterval = 1.5
    /// What a clock's rounding may be off by when two timestamps are compared against a delay.
    private static let slack: TimeInterval = 1e-9

    /// Whether the client has ever told this state where the pointer is. Until it has, the
    /// model's own `hovered` node is taken as entered at once.
    public private(set) var isDriven = false

    private var resting: String?
    private var restingSince: Double = 0
    private var entered: String?
    private var leftAt: Double?
    private var holding = false

    public init() {}

    /// The pointer is over `id`, or over no node for nil, at `clock`.
    public mutating func pointer(over id: String?, at clock: Double) {
        isDriven = true
        if let pending = resting, clock - restingSince >= Self.intentDelay - Self.slack {
            entered = pending
            leftAt = nil
        }
        guard let id else {
            resting = nil
            if entered != nil, leftAt == nil, !holding { leftAt = clock }
            return
        }
        if id == entered {
            resting = nil
            leftAt = nil
        } else if id == resting {
            return
        } else if arrivesFromNode(at: clock) {
            entered = id
            resting = nil
            leftAt = nil
        } else {
            resting = id
            restingSince = clock
        }
    }

    /// The pointer moved into the readout, which keeps what it shows, or out of it.
    public mutating func readoutPointer(inside: Bool, at clock: Double) {
        isDriven = true
        if inside {
            holding = true
            leftAt = nil
        } else if holding {
            holding = false
            if entered != nil { leftAt = clock }
        }
    }

    /// The node the readout follows at `clock`: the one resting under the pointer once it has
    /// rested long enough, or the one entered while the pointer is on it, is in the readout or
    /// left it less than `grace` ago; nil otherwise.
    public func resolved(at clock: Double, grace: TimeInterval = leaveGrace) -> String? {
        if let pending = resting, clock - restingSince >= Self.intentDelay - Self.slack { return pending }
        guard let node = entered else { return nil }
        if holding { return node }
        guard let left = leftAt else { return resting == nil ? node : nil }
        return clock - left < grace - Self.slack ? node : nil
    }

    /// The next moment `resolved` changes by itself, after `clock`; nil when nothing is pending.
    /// A client wakes at it rather than ticking.
    public func nextChange(after clock: Double, grace: TimeInterval = leaveGrace) -> Double? {
        var times: [Double] = []
        if resting != nil, restingSince + Self.intentDelay > clock {
            times.append(restingSince + Self.intentDelay)
        }
        if !holding, let left = leftAt, left + grace > clock { times.append(left + grace) }
        return times.min()
    }

    /// Forgets the pointer: nothing is resting, entered or held.
    public mutating func reset() {
        resting = nil
        entered = nil
        leftAt = nil
        holding = false
    }

    private func arrivesFromNode(at clock: Double) -> Bool {
        if resting != nil { return true }
        guard entered != nil else { return false }
        guard let left = leftAt else { return true }
        return clock - left < Self.leaveGrace - Self.slack
    }
}

extension NeuralBrainModel {
    /// The pointer is over `id`, or over no node for nil, at `clock`. The readout follows this
    /// through `readoutSubject`; the lit wires still follow `setHover`.
    public mutating func pointer(over id: String?, at clock: Double) {
        hoverGrace.pointer(over: id.flatMap { indexByID[$0] == nil ? nil : layout.representative(of: $0) }, at: clock)
    }

    /// The pointer moved into the readout, which holds what it shows, or out of it.
    public mutating func readoutPointer(inside: Bool, at clock: Double) {
        hoverGrace.readoutPointer(inside: inside, at: clock)
    }

    /// The grace this turn gives a node the pointer left: longer while the turn runs, because the
    /// panel then returns to Now rather than to a digest.
    public var leaveGrace: TimeInterval {
        turn.outcome == .running ? NeuralHoverGrace.liveLeaveGrace : NeuralHoverGrace.leaveGrace
    }

    /// The node the pointer counts as having entered at `clock`, after the 40 ms of rest and
    /// within the grace of leaving; nil when the readout should not follow one.
    public func hoverIntent(at clock: Double) -> String? {
        hoverGrace.resolved(at: clock, grace: leaveGrace)
    }

    /// What the readout is about at `clock`.
    public func readoutSubject(now clock: Double) -> NeuralReadout.Mode {
        NeuralReadout.mode(for: self, hover: hoverIntent(at: clock))
    }

    /// When the readout's subject next changes without the pointer moving.
    public func nextReadoutChange(after clock: Double) -> Double? {
        hoverGrace.nextChange(after: clock, grace: leaveGrace)
    }

    /// Dives into a zone, which the readout lists, or surfaces for nil.
    public mutating func setDive(zone: NeuralZone?) {
        divedZone = zone
    }

    /// The readout at this moment. `clock` is the client's monotonic seconds, which the hover
    /// grace and a replay's playhead are read against; `now` is the wall clock a running turn's
    /// elapsed time is read from; `answer` is the final message's text, which the model does not
    /// hold; `outputLines` is how many lines of output to show, `NeuralStageMetrics.outputLinesShown`.
    public func readout(
        now: Date = Date(), tz: TimeZone = .current, clock: Double = 0, answer: String? = nil,
        outputLines: Int = NeuralReadout.outputShown
    ) -> NeuralReadout {
        NeuralReadout.make(
            model: self, subject: readoutSubject(now: clock), now: now, tz: tz, clock: clock,
            answer: answer, outputLines: outputLines)
    }
}
