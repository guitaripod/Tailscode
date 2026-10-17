import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension SelfTest {
    /// What closing the window promises: work posted to the main loop never reaches Swift once the
    /// process is quitting, a held widget reads nil once the toolkit has disposed it, the first-fill
    /// backfill gives a closing pane's hops back and waits at critical without losing the hops a
    /// person asked for, and stopping the governor's tick twice is the same as once.
    static func checkShutdown() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("shutdown: \(label)") }
            checks += 1
        }
        guard gtk_init_check() != 0 else { return checks }
        defer { Gtk.markNotQuitting() }

        try checkWeakWidget(expect)
        try checkQuittingGate(expect)
        try checkFillPolicy(expect)
        try checkTeardownRepeats(expect)
        return checks
    }

    private static func pumpMainLoop(_ seconds: Double) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            while g_main_context_iteration(nil, 0) != 0 {}
            usleep(4000)
        }
    }

    private static func checkWeakWidget(_ expect: (Bool, String) throws -> Void) throws {
        let label = gtk_label_new("held")!
        g_object_ref_sink(UnsafeMutableRawPointer(label))
        let hold = Gtk.WeakWidget(label)
        try expect(hold.widget == label, "a held widget reads back while it lives")
        g_object_unref(UnsafeMutableRawPointer(label))
        try expect(hold.widget == nil, "a held widget reads nil once it is disposed")

        let other = gtk_label_new("outlived")!
        g_object_ref_sink(UnsafeMutableRawPointer(other))
        var scoped: Gtk.WeakWidget? = Gtk.WeakWidget(other)
        try expect(scoped?.widget == other, "a second hold reads back")
        scoped = nil
        g_object_unref(UnsafeMutableRawPointer(other))
        try expect(scoped == nil, "a hold let go before its widget leaves nothing to fire")
    }

    private static func checkQuittingGate(_ expect: (Bool, String) throws -> Void) throws {
        final class Ran: @unchecked Sendable {
            var posted = 0
            var timed = 0
            var framed = 0
        }
        let ran = Ran()
        Gtk.markQuitting()
        try expect(Gtk.isQuitting, "marking the process as quitting is readable")
        Gtk.onMain { ran.posted += 1 }
        Gtk.after(5) { ran.timed += 1 }
        Gtk.betweenFrames(of: nil) { ran.framed += 1 }
        pumpMainLoop(0.15)
        try expect(ran.posted == 0, "posted work does not run after the process is quitting")
        try expect(ran.timed == 0, "timed work does not run after the process is quitting")
        try expect(ran.framed == 0, "between-frames work does not run after the process is quitting")

        Gtk.markNotQuitting()
        try expect(!Gtk.isQuitting, "the gate can be lifted for a test")
        Gtk.onMain { ran.posted += 1 }
        Gtk.after(5) { ran.timed += 1 }
        pumpMainLoop(0.15)
        try expect(ran.posted == 1 && ran.timed == 1, "work posted with the gate down still runs")
    }

    private static func checkFillPolicy(_ expect: (Bool, String) throws -> Void) throws {
        let calm = FillTurns.rest(wall: 1.0, cpu: 0.2, since: (wall: 1.0, cpu: 0.0), level: .calm)
        let loaded = FillTurns.rest(wall: 1.0, cpu: 0.2, since: (wall: 1.0, cpu: 0.0), level: .loaded)
        try expect(loaded > calm, "a backfill rests longer once the loop is loaded")
        try expect(loaded <= FillTurns.strainedLongestRest, "the longer rest is still bounded")
        try expect(FillTurns.chunk(level: .loaded) < FillTurns.chunk(level: .calm), "a loaded loop gets smaller hops")
        try expect(FillTurns.pausesIdleWork(at: .critical), "the top-up waits at critical")
        try expect(!FillTurns.pausesIdleWork(at: .loaded), "the top-up only stretches at loaded")

        final class Owner {}
        let owner = Owner()
        let kept = Owner()
        let widget = gtk_label_new("anchor")!
        g_object_ref_sink(UnsafeMutableRawPointer(widget))
        FillTurns.cancelAll()
        FillTurns.take(on: widget, owner: owner) {}
        FillTurns.take(on: widget, owner: kept) {}
        FillTurns.cancel(owner: owner)
        try expect(FillTurns.pending == 1, "a closing pane takes back only its own hops")
        g_object_unref(UnsafeMutableRawPointer(widget))
        FillTurns.cancelAll()
        try expect(FillTurns.pending == 0, "a closing window takes back every hop")
        FillTurns.cancelAll()
    }

    private static func checkTeardownRepeats(_ expect: (Bool, String) throws -> Void) throws {
        let belts = Seatbelts()
        belts.stop()
        belts.stop()
        try expect(belts.isStopped, "the governor's tick stays stopped when stopped twice")
        UpdateWatch.stop()
        UpdateWatch.stop()
        FillTurns.cancelAll()
        FillTurns.cancelAll()
        try expect(FillTurns.pending == 0, "taking everything back twice is taking it back once")
    }
}
