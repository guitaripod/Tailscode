import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension SelfTest {
    /// What the wall costs: one frame clock under thirty a second while anything moves, none when
    /// the desk asks for stillness or nobody can see the window, still frames that do not change
    /// with time, and an edge that breathes only while something has waited too long.
    static func checkWatchMotion(_ check: WatchCheck) throws {
        tailscode_set_animations_enabled(1)
        defer { tailscode_set_animations_enabled(1) }
        let palette = WatchPalette.current()
        let states: [WallState] = [
            .working, .thinking, .needsYou(.fresh), .needsYou(.overdue), .retrying(attempt: 2),
            .quiet(since: Date()), .background(stuck: false), .background(stuck: true),
            .finished(.done), .finished(.failed), .finished(.stopped), .away(lastSeen: Date()),
        ]
        func glyph(_ state: WallState, _ t: Double, _ animated: Bool) -> [UInt8] {
            pixels(80) { cr in
                WatchGlyph.paint(cr, size: 80, state: state, share: 0.6, fade: 0.2, palette: palette, t: t, animated: animated)
            }
        }
        for state in states {
            try check.expect(
                glyph(state, 0, false) == glyph(state, 37.3, false),
                "\(state) is one still picture when the desk asks for less movement")
        }
        let moving = states.filter { state in
            switch state {
            case .finished, .away, .background(true): return false
            default: return true
            }
        }
        for state in moving {
            try check.expect(
                (0..<8).contains { glyph(state, 0.5 * Double($0), true) != glyph(state, 0, true) },
                "\(state) moves when the desk allows it")
        }
        func card(_ state: WallState, _ t: Double, _ animated: Bool) -> [UInt8] {
            pixels(120) { cr in
                WatchTilePaint.card(
                    cr, width: 120, height: 120, unit: 8, face: .init(state: state, focused: false),
                    palette: palette, t: t, animated: animated)
            }
        }
        for state in [WallState.working, .needsYou(.overdue)] {
            try check.expect(card(state, 0, false) == card(state, 19.7, false), "\(state)'s glass is still too")
            try check.expect((0..<8).contains { card(state, 0.6 * Double($0), true) != card(state, 0, true) }, "and breathes otherwise")
        }
        let motes = WatchMotes()
        func field(_ t: Double, _ animated: Bool) -> [UInt8] {
            pixels(160) { cr in motes.paint(cr, width: 160, height: 160, unit: 6, ink: palette.working, t: t, animated: animated, brightness: 1) }
        }
        try check.expect(field(0, false) == field(55, false), "the motes hold still with it")
        let before = motes.positionSum
        motes.step(dt: 5, mood: .calm, target: nil, slow: 1)
        let calmMove = abs(motes.positionSum - before)
        let busyStart = motes.positionSum
        motes.step(dt: 5, mood: .busy, target: nil, slow: 1)
        try check.expect(
            calmMove < abs(motes.positionSum - busyStart) / 3,
            "calm motes are almost still where busy ones drift: \(calmMove) against \(abs(motes.positionSum - busyStart))")
        let vignette = pixels(100) { cr in WatchAmbient.vignette(cr, width: 100, height: 100, unit: 4, ink: palette.overdue, intensity: 0.2) }
        try check.expect(vignette.contains { $0 != 0 } && vignette[(50 * 100 + 50) * 4 + 3] == 0, "the edge is lit and the middle is not")

        let window = check.open(size: (1280, 720))
        let view = window.watchView
        view.startScene("busy")
        check.pump(0.4)
        try check.expect(view.isTurning, "a wall with things moving runs its frame clock")
        let frames = view.frames
        check.pump(0.7)
        let made = view.frames - frames
        try check.expect(made >= 6 && made <= 23, "and draws at thirty a second at the most: \(made) in 0.7 s")
        view.setVisible(false)
        try check.expect(!view.isTurning, "a hidden window runs no clock")
        let still = view.frames
        check.pump(0.5)
        try check.expect(view.frames == still, "and draws nothing")
        view.setVisible(true)
        try check.expect(view.isTurning, "which comes back with the window")
        tailscode_set_animations_enabled(0)
        view.updateClock()
        try check.expect(!view.isTurning && !view.context.animated, "a desk that asks for stillness stops it")
        let beat = view.tiles.values.first { !$0.beatValues.isEmpty }
        try check.expect(beat != nil, "while the heartbeat still has its strip")
        view.startScene("alarm")
        check.pump(0.3)
        try check.expect(
            view.wall.hasOverdue && !view.isTurning,
            "an overdue ask draws its edge without a clock")
        tailscode_set_animations_enabled(1)
        view.updateClock()
        view.startScene("calm")
        check.pump(0.2)
        view.context.clock.advance(by: 700)
        window.secondPassed()
        view.settleDim()
        view.updateClock()
        try check.expect(!view.isTurning, "a calm wall that has dimmed stops the frame clock and draws once a second")
        view.userTouched()
        view.updateClock()
        try check.expect(view.isTurning, "and any touch starts it again")
        check.close(window)
    }
}
