import CAdw
import CGtkShim
import Foundation

/// `agents-bench=<seconds>`: how the Agents window draws, as numbers. Every frame its clock paints
/// is stamped for that long, then one line says how many there were, how evenly they came against
/// the pace the wall asked for, what each paint cycle cost and how much of a core the main thread
/// spent, with the canvases' own cairo draws beside it.
enum AgentsBench {
    /// The once-a-second work of the window — the reread, the words, the clocks — kept apart from
    /// the frames, because it runs between them and a slow one is a late frame.
    nonisolated(unsafe) private(set) static var ticks: [Double] = []

    static func noteTick(microseconds: Int) {
        ticks.append(Double(microseconds) / 1000)
        if ticks.count > 600 { ticks.removeFirst(ticks.count - 600) }
    }

    static func run(seconds: Double) {
        guard let board = AgentsWindow.current, tailscode_frame_meter_start(board.window) != 0 else {
            FileHandle.standardOutput.write(Data("AGENTS bench no window\n".utf8))
            return
        }
        let draws = AgentsCanvas.drawsEverywhere
        let pixels = AgentsCanvas.pixelsEverywhere
        let snapshots = WallLayer.snapshotsEverywhere
        let paints = WallPicture.paintsEverywhere
        let allocations = board.watchView.stage.allocations
        ticks.removeAll()
        _ = tailscode_tile_canvas_take_worst_allocate_us()
        Gtk.after(UInt32(min(600, max(0.1, seconds)) * 1000)) {
            let capacity = 65536
            var gaps = [Double](repeating: 0, count: capacity)
            var cycles = [Double](repeating: 0, count: capacity)
            var layouts = [Double](repeating: 0, count: capacity)
            var cpu = 0.0
            var elapsed = 0.0
            var refresh = 0.0
            let count = Int(
                tailscode_frame_meter_stop(&gaps, &cycles, &layouts, Int32(capacity), &cpu, &elapsed, &refresh))
            var line = summary(
                gaps: Array(gaps.prefix(count)), cycles: Array(cycles.prefix(count)), cpu: cpu,
                seconds: elapsed, refresh: refresh, target: board.watchView.frameTarget * 1000,
                draws: AgentsCanvas.drawsEverywhere - draws,
                megapixels: (AgentsCanvas.pixelsEverywhere - pixels) / 1e6, lens: board.mode)
            let span = max(elapsed, 0.001)
            let laid = Array(layouts.prefix(count))
            let worst = cycles.prefix(count).enumerated().max { $0.element < $1.element }
            line += String(
                format: " layout max=%.2f over4ms=%d worst-frame layout=%.2f of %.2f worst-allocate=%.2f",
                laid.max() ?? 0, laid.filter { $0 > 4 }.count, worst.map { laid[$0.offset] } ?? 0,
                worst?.element ?? 0, Double(tailscode_tile_canvas_take_worst_allocate_us()) / 1000)
            line += String(
                format: " snapshots=%.0f/s pictures=%.1f/s stage-layouts=%.1f/s tick mean=%.2f max=%.2f",
                Double(WallLayer.snapshotsEverywhere - snapshots) / span,
                Double(WallPicture.paintsEverywhere - paints) / span,
                Double(board.watchView.stage.allocations - allocations) / span,
                ticks.isEmpty ? 0 : ticks.reduce(0, +) / Double(ticks.count), ticks.max() ?? 0)
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
            AppLog.write(.ui, line)
        }
    }

    static func summary(
        gaps: [Double], cycles: [Double], cpu: Double, seconds: Double, refresh: Double,
        target: Double, draws: Int, megapixels: Double, lens: AgentsWindow.Mode
    ) -> String {
        let sorted = gaps.sorted()
        let costs = cycles.sorted()
        func at(_ values: [Double], _ fraction: Double) -> Double {
            values.isEmpty ? 0 : values[min(values.count - 1, Int(Double(values.count) * fraction))]
        }
        let late = gaps.filter { $0 > target * 1.5 }.count
        let mean = costs.isEmpty ? 0 : costs.reduce(0, +) / Double(costs.count)
        let seconds = max(seconds, 0.001)
        return String(
            format:
                "AGENTS bench lens=%@ frames=%d fps=%.1f target=%.2fms refresh=%.2fms gap median=%.2f p95=%.2f p99=%.2f max=%.2f late=%d cycle mean=%.2f p99=%.2f max=%.2f cpu=%.0fms/s (%.1f%%) draws=%.0f/s %.1fMpx/s",
            "\(lens)", gaps.count + 1, Double(gaps.count) / seconds, target, refresh,
            at(sorted, 0.5), at(sorted, 0.95), at(sorted, 0.99), sorted.last ?? 0, late, mean,
            at(costs, 0.99), costs.last ?? 0, cpu / seconds, cpu / seconds / 10,
            Double(draws) / seconds, megapixels / seconds)
    }
}
