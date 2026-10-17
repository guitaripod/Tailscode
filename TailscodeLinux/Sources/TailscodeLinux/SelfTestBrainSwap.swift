import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension SelfTest {
    /// What the readout promises while its cross-fade runs: a subject that arrives meanwhile
    /// builds nothing and leaves the fading page's widgets alone (a hover is delivered from them),
    /// the fade's end shows what the model says by then, a subject that comes back to the one on
    /// screen costs nothing, and a long sweep over the timeline strip is bounded by the fades.
    static func checkBrainSwap() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("readout swap: \(label)") }
            checks += 1
        }
        guard gtk_init_check() != 0, NeuralAssetFiles.isAvailable else { return checks }
        Gtk.installStyle()
        tailscode_set_animations_enabled(1)
        tailscode_notify_animations()

        let (brains, builder) = try brainRows()
        var open = brains[1]
        open.open = true
        let policy: () -> NeuralOpenPolicy? = { builder.brainPolicy }
        let bed = try BrainBed(row: open, width: 1100, key: "st-swap", policy: policy)
        defer { bed.close() }
        _ = brainPump(10) { bed.view.stage?.hasPicture == true }
        _ = brainPump(0.5)
        let view = bed.view
        guard let readout = view.readout else { throw SelfTestFailure("readout swap: no readout") }
        try expect(readout.reading.hasPrefix("digest"), "a settled turn's readout opens on its digest")

        let steps = view.model.steps
            .filter { view.model.layout.representative(of: $0.id) == $0.id }
            .map(\.id)
        guard steps.count >= 4 else { throw SelfTestFailure("readout swap: the demo has \(steps.count) steps") }

        let before = readout.pageSwaps
        view.stripHover(steps[0])
        try expect(readout.reading.hasPrefix("step") && readout.pageSwaps == before + 1, "a hover reads its step out")
        try expect(readout.isFading, "by a cross-fade")
        view.stripHover(steps[1])
        view.stripHover(steps[2])
        try expect(readout.pageSwaps == before + 1, "a hover that arrives during the fade builds nothing yet")
        try expect(readout.idlePageIsBuilt, "and leaves the page that is fading out whole")
        _ = brainPump(0.5)
        try expect(!readout.isFading, "the fade ends")
        try expect(
            readout.shown?.step?.stepID == steps[2] && readout.pageSwaps == before + 2,
            "and the panel then reads what the pointer is on by then, built once (\(readout.reading), \(readout.pageSwaps - before))")

        let base = readout.pageSwaps
        view.stripHover(steps[3])
        view.stripHover(steps[0])
        view.stripHover(steps[3])
        _ = brainPump(0.5)
        try expect(
            readout.shown?.step?.stepID == steps[3] && readout.pageSwaps == base + 1,
            "a pointer that goes away during a fade and comes back to what is shown builds nothing more (\(readout.pageSwaps - base))")

        let sweepStart = readout.pageSwaps
        let sweep = 120
        for index in 0..<sweep {
            view.stripHover(steps[index % steps.count])
            _ = brainPump(0.012)
        }
        let last = steps[(sweep - 1) % steps.count]
        _ = brainPump(0.6)
        try expect(
            readout.shown?.step?.stepID == last,
            "after a sweep of \(sweep) hovers the panel reads the last one (\(readout.reading))")
        try expect(
            readout.pageSwaps - sweepStart < sweep / 2,
            "and the sweep built a page per fade, not per hover (\(readout.pageSwaps - sweepStart) builds)")
        try expect(!readout.isFading && readout.pageSwaps >= sweepStart, "and nothing is left fading")
        return checks
    }
}
