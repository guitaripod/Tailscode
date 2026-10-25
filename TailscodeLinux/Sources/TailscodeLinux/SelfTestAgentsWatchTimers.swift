import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension SelfTest {
    /// Everything the wall waits on, moved by the wall's own clock instead of slept through: the
    /// peek's twenty seconds, the ten minutes of calm before the dim and the event that undoes it,
    /// the cycle of scenes, and how often the wall is read.
    static func checkWatchTimers(_ check: WatchCheck) throws {
        let window = check.open(size: (1920, 1080))
        defer { check.close(window) }
        let view = window.watchView
        let clock = view.context.clock
        let key = AgentDemo.studio + "/w"

        let reads = view.rereads
        check.pump(1.3)
        try check.expect(
            view.rereads - reads <= 2,
            "the wall is read once a second at most while nothing changes: \(view.rereads - reads) in 1.3 s")

        window.select(key: key)
        check.pump(0.4)
        try check.expect(
            view.peekLayer.isShown && window.overlayPeek.key == key && window.peekRevealed,
            "a tile opens the peek over the wall")
        clock.advance(by: 15)
        window.secondPassed()
        try check.expect(view.peekLayer.isShown, "it stays while it has been used within twenty seconds")
        view.peekLayer.touch()
        clock.advance(by: 19)
        window.secondPassed()
        try check.expect(view.peekLayer.isShown, "and touching it starts the twenty seconds again")
        clock.advance(by: 2)
        window.secondPassed()
        check.pump(0.3)
        try check.expect(
            !view.peekLayer.isShown && window.selectedKey == nil && gtk_widget_get_mapped(view.peekLayer.sheet) == 0,
            "after twenty seconds without input it goes back to the wall by itself")

        view.startScene("calm")
        check.pump(0.3)
        try check.expect(view.wall.mood == .calm && !view.dim.isDimmed(at: clock.now), "a calm wall starts bright")
        clock.advance(by: 540)
        window.secondPassed()
        try check.expect(!view.dim.isDimmed(at: clock.now), "nine minutes of calm do not dim it")
        clock.advance(by: 70)
        window.secondPassed()
        view.settleDim()
        try check.expect(
            view.dim.isDimmed(at: clock.now) && abs(gtk_widget_get_opacity(view.scrim) - 0.6) < 0.01,
            "ten minutes of calm dim it to forty percent: \(gtk_widget_get_opacity(view.scrim))")
        view.userTouched()
        view.settleDim()
        try check.expect(
            !view.dim.isDimmed(at: clock.now) && gtk_widget_get_opacity(view.scrim) < 0.01,
            "any touch brings it back")
        clock.advance(by: 700)
        window.secondPassed()
        view.settleDim()
        try check.expect(view.dim.isDimmed(at: clock.now), "and it dims again after another ten calm minutes")
        view.startScene("busy")
        check.pump(0.3)
        view.settleDim()
        try check.expect(
            !view.dim.isDimmed(at: clock.now) && gtk_widget_get_opacity(view.scrim) < 0.01,
            "an event on the wall wakes it")
        view.toggleDim()
        try check.expect(
            !view.dim.isDimmed(at: clock.now), "the d key cannot dim a wall with something running")
        view.startScene("calm")
        check.pump(0.2)
        view.toggleDim()
        view.settleDim()
        try check.expect(
            view.dim.isDimmed(at: clock.now) && gtk_widget_get_opacity(view.scrim) > 0.59,
            "the d key dims a calm wall at once")
        view.toggleDim()
        view.settleDim()
        try check.expect(!view.dim.isDimmed(at: clock.now), "and undims it")

        view.startCycle()
        for _ in 0..<7 {
            clock.advance(by: AgentsWatchView.cycleEvery)
            window.secondPassed()
        }
        try check.expect(
            Set(view.cycleVisited) == Set(AgentsWatchView.sceneNames),
            "the cycle visits all six scenes: \(view.cycleVisited)")
        view.leaveScene()
        check.pump(0.3)
        try check.expect(view.scene == nil && view.cycleStarted == nil, "and ends when asked to")
    }
}
