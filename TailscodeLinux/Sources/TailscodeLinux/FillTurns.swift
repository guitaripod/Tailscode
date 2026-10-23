import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// One first-fill hop at a time, across every pane in the window, spending a bounded share of the
/// main thread.
///
/// A pane fills an opened transcript from its tail a chunk of rows at a time, and every chunk has
/// to be laid out before the next is added or the chunking buys nothing. Five panes opened at once
/// were five chunks laid out in the same frame, each frame the size of all of them; here the panes
/// take turns, one chunk after each frame, so no frame lays out more than one pane's chunk.
///
/// Hop after hop, one frame apiece, is still a loop that never rests: a chunk and the layout it
/// causes cost a frame cycle each, and a window of panes opened together kept the main thread
/// near fully busy for as long as it took to put every row back, which the governor reads as load
/// and answers by shedding before anything has streamed. So each hop measures what the main
/// thread spent between its start and the end of the frame that drew it, and the next one waits
/// until that work is no more than `duty` of the time since — the backfill is background work and
/// leaves the rest of the loop to whatever else is happening, which is also why it slows down
/// by itself while a turn streams.
enum FillTurns {
    private struct Entry {
        let owner: ObjectIdentifier?
        let essential: Bool
        let urgent: (@Sendable () -> Bool)?
        let widget: Gtk.WeakWidget
        let hop: @Sendable () -> Void

        var isUrgent: Bool { urgent?() ?? false }
    }

    nonisolated(unsafe) private static var waiting: [Entry] = []
    nonisolated(unsafe) private static var scheduled = false
    nonisolated(unsafe) private static var lastHop: (wall: Double, cpu: Double)?
    nonisolated(unsafe) private static var generation = 0

    /// The share of the main thread a backfill may take over the time since its last hop.
    static let duty = 0.4
    /// The longest a hop is held back, so a very busy loop still makes progress.
    static let longestRest = 0.4
    /// The same two at `loaded` and above, where the loop is already behind and a backfill is the
    /// first thing that can wait.
    static let strainedDuty = 0.15
    static let strainedLongestRest = 1.0
    /// How often a paused backfill looks at the governor again.
    static let pausedLook = 1.0
    /// Rows put back above the tail per hop of a first fill. Each hop is laid out in a frame of its
    /// own, and a row of markdown, a table or a code block costs one to two milliseconds to lay out
    /// on a software renderer, so twenty keeps a hop's frame well inside the stall budget.
    static let calmChunk = 20
    static let strainedChunk = 8

    /// A hop that fills history from the top-up of an opened chat is `idle` work: it stretches at
    /// `loaded` and waits at `critical`. A hop that carries out something the person asked for
    /// (the rest of a set of chats opening) is `essential` and only ever stretches.
    ///
    /// `owner` lets a closing pane take its own entries back; the widget is held weakly, because
    /// the pane that supplied it can be gone before the hop's turn.
    ///
    /// `urgent` is asked each time the hop's turn comes round, after the frame that drew the last
    /// one: a page that is not yet full, or a reader who has scrolled to the edge of what exists,
    /// is waiting for this hop, and it takes its turn on the next frame without resting and at any
    /// level. Everything else about the backfill stays the background work it was.
    static func take(
        on widget: UnsafeMutablePointer<GtkWidget>, owner: AnyObject? = nil, essential: Bool = false,
        urgent: (@Sendable () -> Bool)? = nil, _ hop: @escaping @Sendable () -> Void
    ) {
        waiting.append(
            Entry(
                owner: owner.map(ObjectIdentifier.init), essential: essential, urgent: urgent,
                widget: Gtk.WeakWidget(widget), hop: hop))
        schedule()
    }

    /// Looks at the queue again at once instead of at the end of the rest it was waiting out, for
    /// a reader who has just scrolled to where the rows run out.
    static func rush() {
        guard scheduled, !waiting.isEmpty else { return }
        generation += 1
        scheduled = false
        schedule()
    }

    /// Takes back every hop a closing pane queued, so none of them runs for a pane that is gone.
    static func cancel(owner: AnyObject) {
        let identity = ObjectIdentifier(owner)
        waiting.removeAll { $0.owner == identity }
    }

    /// Drops everything, for a window that is closing.
    static func cancelAll() {
        waiting.removeAll()
        generation += 1
        scheduled = false
        lastHop = nil
    }

    static var pending: Int { waiting.count }

    /// Seconds to wait before the next hop so that the work since the last one stays within the
    /// duty.
    static func rest(
        wall: Double, cpu: Double, since last: (wall: Double, cpu: Double)?,
        level: ShedLevel = .calm
    ) -> Double {
        guard let last else { return 0 }
        let share = level >= .loaded ? strainedDuty : duty
        let ceiling = level >= .loaded ? strainedLongestRest : longestRest
        let spent = cpu - last.cpu
        let needed = spent / share - (wall - last.wall)
        return min(ceiling, max(0, needed))
    }

    /// Rows added by one top-up hop: fewer while the loop is behind.
    static func chunk(level: ShedLevel) -> Int {
        level >= .loaded ? strainedChunk : calmChunk
    }

    /// Whether a top-up waits for the level to relax rather than taking its turn.
    static func pausesIdleWork(at level: ShedLevel) -> Bool { level >= .critical }

    private static func nextIndex(level: ShedLevel) -> Int? {
        guard !waiting.isEmpty else { return nil }
        if let index = waiting.firstIndex(where: { $0.isUrgent }) { return index }
        guard pausesIdleWork(at: level) else { return 0 }
        return waiting.firstIndex { $0.essential }
    }

    private static func schedule() {
        guard !scheduled, !waiting.isEmpty else { return }
        scheduled = true
        let epoch = generation
        let anchor = waiting.lazy.compactMap { $0.widget.widget }.first
        Gtk.betweenFrames(of: anchor) {
            guard epoch == generation else { return }
            let level = CascadeBudget.level
            guard !waiting.isEmpty else {
                scheduled = false
                lastHop = nil
                return
            }
            guard let next = nextIndex(level: level) else {
                pause(epoch: epoch)
                return
            }
            let wait =
                waiting[next].isUrgent
                ? 0 : rest(wall: wallClock(), cpu: mainThreadCPU(), since: lastHop, level: level)
            if wait > 0 {
                Gtk.after(UInt32((wait * 1000).rounded(.up))) {
                    guard epoch == generation else { return }
                    run()
                }
            } else {
                run()
            }
        }
    }

    private static func pause(epoch: Int) {
        Gtk.after(UInt32(pausedLook * 1000)) {
            guard epoch == generation else { return }
            scheduled = false
            schedule()
        }
    }

    private static func run() {
        scheduled = false
        guard let index = nextIndex(level: CascadeBudget.level) else {
            if waiting.isEmpty { lastHop = nil }
            schedule()
            return
        }
        let entry = waiting.remove(at: index)
        lastHop = (wallClock(), mainThreadCPU())
        entry.hop()
        schedule()
    }

    private static func wallClock() -> Double { seconds(CLOCK_MONOTONIC) }

    private static func mainThreadCPU() -> Double { seconds(CLOCK_THREAD_CPUTIME_ID) }

    private static func seconds(_ clock: clockid_t) -> Double {
        var now = timespec()
        clock_gettime(clock, &now)
        return Double(now.tv_sec) + Double(now.tv_nsec) / 1e9
    }
}
