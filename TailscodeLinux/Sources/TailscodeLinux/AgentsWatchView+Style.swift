import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension AgentsWatchView {
    /// Puts a style on the wall at once: how long calm waits before the dim, whether the wall
    /// breathes, which field drifts, what stands on it, and whether its colours are the night's.
    func apply(style next: WallStyle) {
        context.style = next
        dim.calmFor = next.dimAfter
        context.animated = RepeatingMotion.allowed && !next.still
        syncWorkers(wall, now: context.clock.now)
        refreshNight(now: context.clock.now, force: true)
        top.apply(wall, now: context.clock.now)
        stage.invalidate()
        redrawEverything()
        updateClock()
    }

    /// The night's palette while the style says it is night, the day's otherwise. The colours reach
    /// the stylesheet, every label and every drawing, so a change lays the wall out again.
    func refreshNight(now: Date, force: Bool = false) {
        let night = context.style.isNight(at: now)
        guard force || night != context.isNight else { return }
        let changed = night != context.isNight
        context.isNight = night
        guard changed || force else { return }
        context.palette = night ? context.dayPalette.night() : context.dayPalette
        WatchStyle.install(context.palette)
        restyle()
        for view in tiles.values { view.styleChanged(now: now) }
        for view in workers.values { view.paletteChanged() }
        for view in crowds.values { view.paletteChanged() }
        stage.invalidate()
        redrawEverything()
    }
}
