import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension SelfTest {
    static func setWatchStyle(_ window: AgentsWindow, _ style: WallStyle) {
        Preferences.setAgentsWatchStyle(style)
        window.styleChanged()
    }

    static func renderLayer(
        _ width: Int32, _ height: Int32, _ paint: (OpaquePointer, Double, Double) -> Void
    ) -> [UInt8] {
        let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height)!
        let cr = cairo_create(surface)!
        paint(cr, Double(width), Double(height))
        cairo_surface_flush(surface)
        let data = cairo_image_surface_get_data(surface)!
        let bytes = Array(UnsafeBufferPointer(start: data, count: Int(width) * Int(height) * 4))
        cairo_destroy(cr)
        cairo_surface_destroy(surface)
        return bytes
    }

    /// The light in a rectangle of a rendered layer: the sum of its alpha.
    static func light(
        _ bytes: [UInt8], width: Int, in box: (x: Int, y: Int, width: Int, height: Int)
    ) -> Int {
        var total = 0
        for y in max(0, box.y)..<(box.y + box.height) {
            for x in max(0, box.x)..<(box.x + box.width) where (y * width + x) * 4 + 3 < bytes.count {
                total += Int(bytes[(y * width + x) * 4 + 3])
            }
        }
        return total
    }

    /// The wall's effects and style: each kind of event plays on the tile it belongs to, Still turns
    /// the gestures into crossfades, Off plays none and still steps the context ring down, the frame
    /// rate is Core's, the style survives the settings file and reaches the wall, and every switch
    /// of it does what its row says.
    static func checkWatchEffects(_ check: WatchCheck) throws {
        tailscode_set_animations_enabled(1)
        let window = check.open(size: (1920, 1080))
        defer {
            Preferences.setAgentsWatchStyle(nil)
            check.close(window)
        }
        let view = window.watchView
        let clock = view.context.clock
        setWatchStyle(window, .studio)

        let producing: [(WallEvent.Kind, String)] = [
            (.step, "busy"), (.joined, "busy"), (.left, "busy"), (.asked, "attention"),
            (.answered, "attention"), (.finished, "busy"), (.failed, "busy"), (.stopped, "busy"),
            (.retried, "busy"), (.resumed, "busy"), (.back, "busy"), (.compacted, "busy"),
            (.workerStarted, "squad"), (.workerEnded, "squad"),
        ]
        for (kind, scene) in producing {
            view.startScene(scene)
            check.pump(0.25)
            view.effects.clear()
            guard let event = view.fire(kind) else {
                throw SelfTestFailure("agents watch: no tile in \(scene) suits \(kind)")
            }
            let live = view.effects.live
            try check.expect(
                !live.isEmpty && live.allSatisfy { $0.tile == event.tile && $0.worker == event.worker },
                "\(kind) plays on its own tile (\(event.worker == nil ? "the tile" : "the worker")): \(live.map(\.kind))")
        }
        for (kind, scene) in [(WallEvent.Kind.quiet, "busy"), (.away, "busy"), (.workerQuiet, "squad"), (.workerStuck, "squad")] {
            view.startScene(scene)
            check.pump(0.2)
            view.effects.clear()
            view.fire(kind)
            try check.expect(view.effects.live.isEmpty, "\(kind) is a change of state and makes no gesture")
        }

        view.startScene("attention")
        check.pump(0.25)
        view.effects.clear()
        let asker = try view.wall.tiles.first { $0.state.isNeedsYou }
            .unwrapEffect("the attention scene has an ask")
        view.fire(.asked)
        try check.expect(
            view.effects.live.map(\.kind) == [.knock, .knock]
                && abs(view.effects.live[1].start - view.effects.live[0].start - 0.34) < 0.001,
            "an ask knocks twice, 0.34 s apart")
        check.pump(0.45)
        try check.expect(view.effects.hasRipples, "the knock spreads a band under the tile on the ground")
        let width = Int(gtk_widget_get_width(view.stage.widget))
        let height = Int(gtk_widget_get_height(view.stage.widget))
        let ground = renderLayer(Int32(width), Int32(height)) { cr, w, h in view.paintGround(cr, w, h) }
        view.effects.clear()
        view.tickEffects(at: context(view))
        let bare = renderLayer(Int32(width), Int32(height)) { cr, w, h in view.paintGround(cr, w, h) }
        try check.expect(ground != bare, "and the ground is lit by it")

        view.startScene("busy")
        check.pump(0.25)
        view.effects.clear()
        view.fire(.finished)
        check.pump(0.35)
        let finished = try view.wall.tiles.first.unwrapEffect("a tile")
        let index = 0
        let anchor = try view.tileAnchor(index, worker: nil).unwrapEffect("an anchor for the first tile")
        try check.expect(
            !view.effects.pieces.isEmpty && view.effects.hasRipples,
            "finishing exhales a ring and ripples the ground: \(view.effects.pieces.count) pieces")
        let painted = renderLayer(Int32(width), Int32(height)) { cr, w, h in view.effects.paint(cr, w, h) }
        let near = light(
            painted, width: width,
            in: (Int(anchor.tile.x), Int(anchor.tile.y), Int(anchor.tile.width), Int(anchor.tile.height)))
        let all = light(painted, width: width, in: (0, 0, width, height))
        try check.expect(
            near > 0 && near * 10 > all * 6,
            "the ring is painted on that tile and nowhere else much: \(near) of \(all) (\(finished.title))")
        let bareCanvas = renderLayer(Int32(width), Int32(height)) { _, _, _ in }
        try check.expect(painted != bareCanvas, "the effects layer draws something")

        var still = WallStyle.studio
        still.still = true
        setWatchStyle(window, still)
        view.effects.clear()
        view.fire(.step)
        try check.expect(view.effects.live.isEmpty, "Still drops the gestures that only move")
        for kind in [WallEvent.Kind.finished, .failed, .asked] {
            view.effects.clear()
            view.fire(kind)
            try check.expect(
                !view.effects.live.isEmpty && view.effects.live.allSatisfy { $0.kind == .fade },
                "and turns \(kind) into a crossfade: \(view.effects.live.map(\.kind))")
        }
        try check.expect(!view.context.animated, "Still turns the wall's own breathing off too")

        var off = WallStyle.studio
        off.effects = .off
        setWatchStyle(window, off)
        for kind in [WallEvent.Kind.finished, .failed, .step, .asked] {
            view.effects.clear()
            view.fire(kind)
            try check.expect(view.effects.live.isEmpty, "Off plays no gesture for \(kind)")
        }
        view.startScene("busy")
        check.pump(0.25)
        view.effects.clear()
        let event = try view.fire(.compacted).unwrapEffect("a tile with a context ring")
        let drain = try view.effects.live.first.unwrapEffect("a drain")
        try check.expect(
            view.effects.live.count == 1 && drain.kind == .drain && drain.amplitude == 0,
            "Off still queues the ring's drain: \(view.effects.live.map(\.kind))")
        check.pump(0.6)
        let share = view.tileView(event.tile)?.drainShare
        try check.expect(
            share != nil && share! < (drain.from ?? 0) && share! > (drain.to ?? 1) - 0.0001
                && view.effects.pieces.isEmpty,
            "the context ring steps down while nothing is drawn: \(share ?? -1) from \(drain.from ?? -1)")
        view.effects.clear()
        view.tickEffects(at: context(view))
        try check.expect(view.tileView(event.tile)?.drainShare == nil, "and lets go of the ring when it ends")

        setWatchStyle(window, .studio)
        view.startScene("busy")
        check.pump(0.25)
        view.effects.clear()
        view.fire(.finished)
        try check.expect(view.cadenceCap() == 30, "while an effect plays the wall may draw at thirty: \(view.cadenceCap())")
        try check.expect(view.isTurning, "and its frame clock runs")
        view.effects.clear()
        view.startScene("calm")
        check.pump(0.2)
        clock.advance(by: 700)
        window.secondPassed()
        view.settleDim()
        view.updateClock()
        try check.expect(view.cadenceCap() == 1 && !view.isTurning, "a dimmed calm wall draws once a second: \(view.cadenceCap())")
        view.effects.add([WallEvent(kind: .finished, tile: "nowhere")], at: view.context.seconds, style: .studio, contexts: [:])
        try check.expect(view.cadenceCap() == 30, "an effect wakes the rate for as long as it lasts")
        view.effects.clear()
        view.setVisible(false)
        try check.expect(view.cadenceCap() == 0, "and a hidden wall draws nothing")
        view.setVisible(true)
        view.userTouched()

        let burst = (0..<30).map { WallEvent(kind: .retried, tile: "t\($0 % 6)") }
        view.effects.clear()
        view.effects.add(burst, at: view.context.seconds, style: .studio, contexts: [:])
        let perTile = Dictionary(grouping: view.effects.live, by: \.tile).values.map(\.count).max() ?? 0
        try check.expect(
            view.effects.live.count <= WallEffectQueue.maxLive && perTile <= WallEffectQueue.maxPerTile,
            "a storm stays within forty effects and three to a tile: \(view.effects.live.count), \(perTile)")
        view.effects.clear()
        let failures = (0..<12).map { WallEvent(kind: .failed, tile: "t\($0 % 2)") }
        view.effects.add(failures, at: view.context.seconds, style: .studio, contexts: [:])
        try check.expect(
            view.effects.live.filter { $0.kind == .fracture }.count == 12,
            "but a failure is never the one dropped")
        view.effects.clear()
    }

    static func context(_ view: AgentsWatchView) -> Double { view.context.seconds }
}

extension Optional {
    fileprivate func unwrapEffect(_ message: String) throws -> Wrapped {
        guard let value = self else { throw SelfTestFailure("agents watch: \(message)") }
        return value
    }
}
