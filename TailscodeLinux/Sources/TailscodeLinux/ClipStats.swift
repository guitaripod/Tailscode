import CGtkShim
import Foundation

/// The clip sheet's own measurement: a 10 ms timer on the main loop whose lateness is how long
/// the loop was held, and once a second the sheet's line about painting and mpv's timing, written
/// to standard output so a run can be read without a screen.
final class ClipStats: @unchecked Sendable {
    private weak var sheet: ClipSheet?
    private var expected: Double = 0
    private var lags: [Double] = []
    private var lastLine: Double = 0

    init(sheet: ClipSheet) {
        self.sheet = sheet
    }

    private var phaseStart: Double = 0
    private var paintStart: Double = 0
    private var frames: [Double] = []
    private var paints: [Double] = []

    func run() {
        lastLine = Self.now()
        arm()
        guard let clock = sheet?.frameClock else { return }
        let raw = UnsafeMutableRawPointer(clock)
        Gtk.connect(raw, "before-paint") { [self] in self.phaseStart = Self.now() }
        Gtk.connect(raw, "paint") { [self] in self.paintStart = Self.now() }
        Gtk.connect(raw, "after-paint") { [self] in
            let now = Self.now()
            if self.phaseStart > 0 { self.frames.append((now - self.phaseStart) * 1000) }
            if self.paintStart > 0 { self.paints.append((now - self.paintStart) * 1000) }
        }
    }

    private func spread(_ values: inout [Double]) -> String {
        defer { values.removeAll(keepingCapacity: true) }
        guard !values.isEmpty else { return "0/0" }
        return String(format: "%.2f/%.1f", values.reduce(0, +) / Double(values.count), values.max() ?? 0)
    }

    private func arm() {
        expected = Self.now() + 0.010
        Gtk.after(10) { [self] in
            Gtk.onMain { [self] in self.fired() }
        }
    }

    private func fired() {
        guard let sheet, !sheet.isClosed else { return }
        let now = Self.now()
        lags.append(max(0, now - expected) * 1000)
        if now - lastLine >= 1 {
            lastLine = now
            let worst = lags.max() ?? 0
            let average = lags.isEmpty ? 0 : lags.reduce(0, +) / Double(lags.count)
            lags.removeAll(keepingCapacity: true)
            if let line = sheet.statsLine(lagMax: worst, lagAverage: average) {
                let phases = " frame=" + spread(&frames) + " paint=" + spread(&paints)
                FileHandle.standardOutput.write(Data((line + phases + "\n").utf8))
            }
        }
        arm()
    }

    private static func now() -> Double {
        Double(g_get_monotonic_time()) / 1_000_000
    }
}
