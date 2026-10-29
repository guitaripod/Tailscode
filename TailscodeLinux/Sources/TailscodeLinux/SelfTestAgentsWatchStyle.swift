import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension SelfTest {
    private static func children(of strip: UnsafeMutablePointer<GtkWidget>?) -> [UnsafeMutablePointer<GtkWidget>] {
        var out: [UnsafeMutablePointer<GtkWidget>] = []
        var child = strip.flatMap { gtk_widget_get_first_child($0) }
        while let button = child {
            out.append(button)
            child = gtk_widget_get_next_sibling(button)
        }
        return out
    }

    private static func chosen(_ strip: UnsafeMutablePointer<GtkWidget>?) -> Int? {
        children(of: strip).firstIndex { gtk_toggle_button_get_active(ptr($0)) != 0 }
    }

    /// The wall's style: it survives the settings file, reaches an open wall, and each switch does
    /// what its row says; the Settings rows write it, show a hand-made style as Custom and put a
    /// preset on every row.
    static func checkWatchStyle(_ check: WatchCheck) throws {
        tailscode_set_animations_enabled(1)
        let window = check.open(size: (1920, 1080))
        defer {
            Preferences.setAgentsWatchStyle(nil)
            check.close(window)
        }
        let view = window.watchView
        let controls: WatchControls = window.controls
        let clock = view.context.clock
        setWatchStyle(window, .studio)

        var custom = WallStyle.showcase.with {
            $0.field = .currents
            $0.dimAfter = 1800
            $0.moves.steps = false
            $0.showsRails = false
        }
        custom.night = .always
        Preferences.setAgentsWatchStyle(custom)
        let stored = SettingsFile.stored(forKey: "agentsWatchStyle") as? String
        try check.expect(
            stored == custom.encoded() && WallStyle.decoded(stored) == custom && Preferences.agentsWatchStyle == custom
                && custom.preset == .custom,
            "a style survives the settings file as its own JSON text and comes back whole")
        Preferences.setAgentsWatchStyle(nil)
        try check.expect(Preferences.agentsWatchStyle == .studio, "and nothing stored is the Studio style")
        window.styleChanged()
        try check.expect(
            view.context.style == .studio && view.dim.calmFor == 600 && !view.context.isNight,
            "the wall follows the settings")

        let day = view.context.dayPalette
        let core = WallPalette(palette: day.source).night()
        let mine = day.night()
        let pairs: [(PartyInk, WallInk)] = [
            (mine.ground, core.ground), (mine.groundDeep, core.deep), (mine.text, core.text),
            (mine.dim, core.dim), (mine.rule, core.rule), (mine.working, core.working),
            (mine.thinking, core.thinking), (mine.needs, core.needs), (mine.overdue, core.overdue),
            (mine.quiet, core.quiet), (mine.finished, core.finished), (mine.failed, core.failed),
        ]
        try check.expect(
            pairs.allSatisfy { abs($0.red - $1.red) + abs($0.green - $1.green) + abs($0.blue - $1.blue) < 1e-9 },
            "the Linux night palette is Core's, ink for ink")
        var night = WallStyle.studio
        night.night = .always
        setWatchStyle(window, night)
        try check.expect(
            view.context.isNight && view.context.palette == mine && view.context.palette != day,
            "Night puts the wall in the warmer, dimmer palette")
        setWatchStyle(window, .studio)
        try check.expect(!view.context.isNight && view.context.palette == day, "and takes it off again")

        let frameWidth = Int32(gtk_widget_get_width(view.stage.widget))
        let frameHeight = Int32(gtk_widget_get_height(view.stage.widget))
        view.startScene("busy")
        check.pump(0.3)
        for _ in 0..<12 {
            view.moteField.step(dt: 1.0 / 15, mood: .busy, target: nil, slow: 1, aspect: 16 / 9)
        }
        func motes(_ field: WallStyle.Field) -> [UInt8] {
            var style = WallStyle.studio
            style.field = field
            setWatchStyle(window, style)
            return renderLayer(frameWidth, frameHeight) { cr, w, h in view.motes.paint?(cr, w, h) }
        }
        let plain = motes(.motes)
        let none = motes(.none)
        let currents = motes(.currents)
        let ink: ([UInt8]) -> Int = { bytes in stride(from: 3, to: bytes.count, by: 4).reduce(0) { $0 + Int(bytes[$1]) } }
        try check.expect(ink(plain) > 0, "the motes are there by default")
        try check.expect(ink(none) == 0, "no field paints no motes at all")
        try check.expect(ink(currents) > ink(plain), "Currents adds a trail behind each: \(ink(currents)) over \(ink(plain))")
        var aurora = WallStyle.studio
        aurora.field = .aurora
        aurora.light = false
        setWatchStyle(window, aurora)
        let withAurora = renderLayer(frameWidth, frameHeight) { cr, w, h in view.paintGround(cr, w, h) }
        aurora.field = .none
        aurora.light = false
        setWatchStyle(window, aurora)
        let withoutAurora = renderLayer(frameWidth, frameHeight) { cr, w, h in view.paintGround(cr, w, h) }
        try check.expect(withAurora != withoutAurora, "Aurora lights the ground")
        var bright = 0
        for index in stride(from: 0, to: withAurora.count, by: 4) {
            let delta = abs(Int(withAurora[index + 1]) - Int(withoutAurora[index + 1]))
            bright = max(bright, delta)
        }
        try check.expect(bright <= 26, "and each bloom stays under four in a hundred, a tenth where all three meet: \(bright) of 255")
        var lit = WallStyle.studio
        lit.light = true
        setWatchStyle(window, lit)
        let lights = renderLayer(frameWidth, frameHeight) { cr, w, h in view.paintGround(cr, w, h) }
        try check.expect(lights != withoutAurora, "tiles spill light on the ground")
        lit.light = false
        setWatchStyle(window, lit)
        let dark = renderLayer(frameWidth, frameHeight) { cr, w, h in view.paintGround(cr, w, h) }
        try check.expect(dark == withoutAurora, "and stop when the light is off")

        var dims = WallStyle.studio
        dims.dimAfter = 300
        setWatchStyle(window, dims)
        view.startScene("calm")
        check.pump(0.3)
        clock.advance(by: 250)
        window.secondPassed()
        try check.expect(!view.dim.isDimmed(at: clock.now), "five minutes of calm are not yet five minutes")
        clock.advance(by: 60)
        window.secondPassed()
        try check.expect(view.dim.isDimmed(at: clock.now), "a style that dims after five minutes dims after five")
        dims.dimAfter = nil
        setWatchStyle(window, dims)
        view.startScene("calm")
        check.pump(0.3)
        clock.advance(by: 20_000)
        window.secondPassed()
        try check.expect(!view.dim.isDimmed(at: clock.now), "and one that never dims does not dim by itself")
        view.toggleDim()
        try check.expect(view.dim.isDimmed(at: clock.now), "though a hand still can")
        view.toggleDim()

        let fake = FakeInhibitor()
        controls.inhibitor = fake
        var awake = WallStyle.studio
        awake.keepAwake = .never
        setWatchStyle(window, awake)
        controls.setFullscreen(true)
        try check.expect(fake.held.isEmpty, "Never keeps no inhibit, even in fullscreen")
        controls.toggleKeepAwake()
        try check.expect(fake.held.count == 1, "yet the toggle is the person's own say")
        controls.setFullscreen(false)
        try check.expect(fake.held.isEmpty, "which ends with the screen")
        awake.keepAwake = .whileCharging
        controls.power = WatchPower(now: clock.now, reading: { false })
        setWatchStyle(window, awake)
        controls.setFullscreen(true)
        try check.expect(fake.held.isEmpty, "While charging holds nothing on the battery")
        controls.power = WatchPower(now: clock.now, reading: { true })
        clock.advance(by: 61)
        controls.refreshPower()
        try check.expect(fake.held.count == 1, "and holds it once the machine is plugged in, as the minute's reading says")
        controls.power = WatchPower(now: clock.now, reading: { false })
        awake.keepAwake = .always
        setWatchStyle(window, awake)
        try check.expect(fake.held.count == 1, "Always holds it on the battery too")
        controls.setFullscreen(false)
        setWatchStyle(window, .studio)
        controls.power = WatchPower(reading: { true })
        try check.expect(
            WatchPower(reading: { true }).isOnMains(at: Date()) && !WatchPower(reading: { false }).isOnMains(at: Date()),
            "the power reading is a seam a check can fill")

        view.startScene("squad")
        check.pump(0.3)
        try check.expect(view.workers.count == 7, "the squad scene has its seven small tiles")
        var bare = WallStyle.studio
        bare.showsSquads = false
        bare.showsClock = false
        bare.showsHour = false
        bare.showsRails = false
        let roomy = view.geometry.grid.height
        setWatchStyle(window, bare)
        check.pump(0.3)
        let session = try view.wall.tiles.first { !$0.workers.isEmpty }.unwrapEffect("a session with a crew")
        try check.expect(
            view.workers.isEmpty && view.crowds.isEmpty
                && (view.tileView(session.id)?.meta.text.contains(Localized.text("%d sub-agents", 4)) == true
                    || view.tileView(session.id)?.meta.text.contains("sub-agent") == true),
            "without sub-agent tiles a session is one tile with a count: \(view.tileView(session.id)?.meta.text ?? "-")")
        try check.expect(
            gtk_widget_get_mapped(view.top.clock.widget) == 0 && gtk_widget_get_mapped(view.top.date.widget) == 0
                && gtk_widget_get_mapped(view.ribbon.canvas.widget) == 0
                && view.rails.widgets.allSatisfy { gtk_widget_get_mapped($0) == 0 },
            "the clock, the last hour and the rails are gone")
        try check.expect(
            view.geometry.grid.height > roomy + 10 * view.geometry.unit,
            "and their room goes to the grid: \(roomy) to \(view.geometry.grid.height)")
        setWatchStyle(window, .studio)
        check.pump(0.3)
        try check.expect(
            view.workers.count == 7 && gtk_widget_get_mapped(view.top.clock.widget) != 0
                && gtk_widget_get_mapped(view.ribbon.canvas.widget) != 0,
            "all of it comes back")

        view.startScene("attention")
        check.pump(0.3)
        let asking = try view.wall.tiles.first { $0.ask?.isApproval == true }.unwrapEffect("an approval on the wall")
        let tile = try view.tileView(asking.id).unwrapEffect("its tile")
        try check.expect(
            gtk_widget_get_mapped(tile.approve) != 0 && gtk_widget_get_mapped(tile.chat) == 0,
            "an approval is held to approve by default")
        var chat = WallStyle.studio
        chat.approvals = .openChat
        setWatchStyle(window, chat)
        check.pump(0.3)
        try check.expect(
            gtk_widget_get_mapped(tile.approve) == 0 && gtk_widget_get_mapped(tile.chat) != 0,
            "and opens the chat when the style says so")
        let opened = check.log.opened.count
        tile.approveDown()
        try check.expect(!tile.gauge.isHolding, "with nothing to hold")
        tile.chatTapped()
        try check.expect(check.log.opened.count == opened + 1, "while the chat button opens the chat")
        setWatchStyle(window, .studio)

        try check.expect(gtk_widget_get_visible(window.styleButton) != 0, "the wall's header has a Style button")
        let pressed = check.log.styleOpened
        _ = gtk_widget_activate(window.styleButton)
        check.pump(0.6)
        try check.expect(check.log.styleOpened == pressed + 1, "which asks for Preferences on the Watch group")
        window.show(.now)
        try check.expect(gtk_widget_get_visible(window.styleButton) == 0, "and is not offered on the other lenses")
        window.show(.watch)

        let page = adw_preferences_page_new()!
        g_object_ref_sink(UnsafeMutableRawPointer(page))
        let rows = SettingsWatchStyle.add(to: page)
        let preset = try rows.presetRow.unwrapEffect("a preset row")
        try check.expect(
            adw_combo_row_get_selected(ptr(preset)) == 0 && chosen(rows.effectsStrip) == 1 && chosen(rows.fieldStrip) == 0,
            "the rows open on the Studio style")
        adw_combo_row_set_selected(ptr(preset), 1)
        try check.expect(
            Preferences.agentsWatchStyle == .nightDesk && view.context.style == .nightDesk
                && chosen(rows.fieldStrip) == 3 && chosen(rows.dimStrip) == 0
                && adw_switch_row_get_active(OpaquePointer(rows.lightRow!)) == 0
                && !view.context.style.showsSquads,
            "Night desk sets every row and reaches the open wall at once")
        let lively = children(of: rows.effectsStrip)[2]
        gtk_toggle_button_set_active(ptr(lively), 1)
        try check.expect(
            view.context.style.effects == .lively && Preferences.agentsWatchStyle.preset == .custom
                && adw_combo_row_get_selected(ptr(preset)) == 3,
            "changing one row by hand shows the preset as Custom")
        adw_combo_row_set_selected(ptr(preset), 2)
        try check.expect(
            Preferences.agentsWatchStyle == .showcase && chosen(rows.fieldStrip) == 2
                && chosen(rows.effectsStrip) == 2 && WallStyle.showcase.dimAfter == nil
                && chosen(rows.dimStrip) == 3,
            "Showcase puts Aurora, Lively and never-dim on their rows")
        adw_switch_row_set_active(OpaquePointer(rows.eventRows[0]), 0)
        try check.expect(
            !view.context.style.moves.steps && view.context.style.moves.failures && rows.eventRows.count == 8
                && rows.wallRows.count == 4,
            "the eight events and the four wall switches each have a row")
        adw_combo_row_set_selected(ptr(preset), 0)
        try check.expect(Preferences.agentsWatchStyle == .studio && view.context.style == .studio, "and Studio is back")
        g_object_unref(UnsafeMutableRawPointer(page))
    }
}

extension Optional {
    fileprivate func unwrapEffect(_ message: String) throws -> Wrapped {
        guard let value = self else { throw SelfTestFailure("agents watch: \(message)") }
        return value
    }
}
