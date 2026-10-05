import CGtkShim
import Foundation
import TailscodeCore

/// How busy the GTK main loop is, measured where the loop itself waits.
///
/// The shim wraps the default context's poll function, so busy is wall time minus time inside
/// `g_poll`, and the worst slice is the longest stretch between leaving one poll and entering the
/// next. This reads that ledger once a second into Core's `LoopLoad`, which keeps the one- and
/// two-second windows the governor reads. Main context only: the poll function runs there and so
/// does every read, so nothing here needs a lock.
final class LoopMeter {
    struct Reading {
        let loop: LoopReading
        /// The longest busy slice since the previous read, a slice still running included.
        let worstSinceLast: TimeInterval
        /// The meter's own clock at the read, in monotonic seconds.
        let now: TimeInterval
    }

    private var load = LoopLoad()
    private(set) var installed = false

    func install() {
        guard !installed else { return }
        tailscode_loop_meter_install()
        installed = true
    }

    func take() -> Reading {
        var sample = TailscodeLoopSample()
        tailscode_loop_meter_take(&sample)
        let now = Double(sample.now_us) / 1_000_000
        let busy = Double(sample.busy_us) / 1_000_000
        let idle = Double(sample.idle_us) / 1_000_000
        let worst = Double(sample.worst_us) / 1_000_000
        if busy + idle > 0 {
            load.record(spanFrom: now - busy - idle, to: now, busy: busy, worst: worst)
        }
        return Reading(loop: load.reading(now: now), worstSinceLast: worst, now: now)
    }
}
