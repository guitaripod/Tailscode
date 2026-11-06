import CodingAgentKit
import Foundation

/// When a piece of work is over, as opposed to when a turn is.
///
/// A turn ending says only that the prompt is free. The agent may still be carrying a command, an
/// agent or a workflow it backgrounded; a queued message may be about to start the next turn; the
/// machine may be about to start one itself because that background work just finished. Work is
/// over when none of that is true and it has stayed that way for `grace` — long enough for a CLI
/// that speaks again on its own, or a queue that drains, to have started. A span runs from the
/// first sign of work to that moment, so its length is how long the person was waited on, not how
/// long the last of several turns took.
///
/// A mutating value type on an injected clock, like `ActivityWatch` and `StreamCadence`: the host
/// feeds it readings and asks it what is due. claude-bridge's `WorkSettle` mirrors these rules for
/// the pushes it sends, so a phone and its server agree about when work ended.
public struct WorkSettle: Sendable {
    public static let grace: TimeInterval = 10

    /// Everything a witness can say about whether work goes on.
    public struct Reading: Sendable, Equatable {
        /// A turn is open.
        public var running: Bool
        /// Background tasks and working agents the conversation's process still holds.
        public var carried: Int
        /// Prompts that will start a turn on their own, behind the one running.
        public var queued: Int
        /// An approval or a question stands. Not over: the person has something to answer.
        public var waiting: Bool
        /// The last turn ended in a failure.
        public var failed: Bool

        public init(
            running: Bool, carried: Int = 0, queued: Int = 0, waiting: Bool = false,
            failed: Bool = false
        ) {
            self.running = running
            self.carried = carried
            self.queued = queued
            self.waiting = waiting
            self.failed = failed
        }

        public var isBusy: Bool { running || carried > 0 || queued > 0 || waiting }

        /// What a streamed conversation says: the turn, what its process carries, the server's
        /// queue unless a Stop paused it, the messages this device holds unless a failure is
        /// holding them back for the person, and anything it is asking.
        public init(_ state: ConversationState, heldQueue: Int = 0) {
            self.init(
                running: state.status == .running || state.compaction?.isRunning == true,
                carried: state.backgroundWork?.tasks ?? 0,
                queued: (state.queuePaused ? 0 : state.queue.count)
                    + (state.lastFailure == nil ? heldQueue : 0),
                waiting: !state.pendingPermissions.isEmpty || !state.pendingQuestions.isEmpty,
                failed: state.lastFailure != nil)
        }
    }

    /// A stretch of work that came to an end.
    public struct Ending: Sendable, Equatable {
        public let key: String
        public let began: Date
        public let ended: Date
        public internal(set) var failed: Bool

        public var length: TimeInterval { max(0, ended.timeIntervalSince(began)) }
    }

    /// What one reading changed.
    public struct Change: Sendable, Equatable {
        /// A turn closed, whatever else is still going on: what a person who wants every turn hears.
        public var turnEnded: Ending?
        /// The work just stopped. It is over at `ended + grace` unless something starts first.
        public var settling: Ending?
        /// Work started again inside the grace, taking back the ending that was settling.
        public var resumed = false

        public static let none = Change()
    }

    private struct Track: Sendable {
        var busy: Bool
        var running: Bool
        var turnBegan: Date?
        var spanBegan: Date?
        var settling: Ending?
    }

    private var tracks: [String: Track] = [:]
    /// Endings whose grace ran out between two calls to `due`, kept so a reading that arrives
    /// before the host's timer cannot swallow them: the next span starts, and this one is still owed.
    private var matured: [Ending] = []

    public init() {}

    /// Folds one reading into the key's track. The first reading of a key primes it: work already
    /// under way is a span from now, and a key first seen at rest says nothing.
    public mutating func observe(_ key: String, _ reading: Reading, at now: Date) -> Change {
        guard var track = tracks[key] else {
            tracks[key] = Track(
                busy: reading.isBusy, running: reading.running,
                turnBegan: reading.running ? now : nil, spanBegan: reading.isBusy ? now : nil)
            return .none
        }
        var change = Change()
        if let settling = track.settling, Self.isOver(settling, at: now) {
            matured.append(settling)
            track.settling = nil
            track.spanBegan = nil
        }
        if track.running, !reading.running, let began = track.turnBegan {
            change.turnEnded = Ending(key: key, began: began, ended: now, failed: reading.failed)
        }
        if reading.running, !track.running { track.turnBegan = now }
        if reading.isBusy {
            if track.settling != nil {
                track.settling = nil
                change.resumed = true
            }
            if track.spanBegan == nil { track.spanBegan = now }
        } else if var settling = track.settling {
            if reading.failed, !settling.failed {
                settling.failed = true
                track.settling = settling
                change.settling = settling
            }
        } else if track.busy, let began = track.spanBegan {
            let settling = Ending(key: key, began: began, ended: now, failed: reading.failed)
            track.settling = settling
            change.settling = settling
        }
        track.busy = reading.isBusy
        track.running = reading.running
        tracks[key] = track
        return change
    }

    /// Spans whose grace has run out with nothing starting, each handed over once.
    public mutating func due(at now: Date) -> [Ending] {
        var endings = matured
        matured.removeAll()
        for (key, track) in tracks {
            guard let settling = track.settling, Self.isOver(settling, at: now) else { continue }
            endings.append(settling)
            tracks[key]?.settling = nil
            tracks[key]?.spanBegan = nil
        }
        return endings.sorted { $0.ended < $1.ended }
    }

    /// When the next span falls due, for a host that sleeps until then rather than polling.
    public var nextDue: Date? {
        let pending = tracks.values.compactMap { $0.settling?.ended.addingTimeInterval(Self.grace) }
        let owed = matured.map(\.ended)
        return (pending + owed).min()
    }

    private static func isOver(_ ending: Ending, at now: Date) -> Bool {
        now >= ending.ended.addingTimeInterval(grace)
    }

    /// The ending a key is settling on right now, if any.
    public func settling(_ key: String) -> Ending? { tracks[key]?.settling }

    /// Whether the key is mid-work as far as the last reading went.
    public func isBusy(_ key: String) -> Bool { tracks[key]?.busy ?? false }

    public mutating func forget(_ key: String) {
        tracks[key] = nil
        matured.removeAll { $0.key == key }
    }
}
