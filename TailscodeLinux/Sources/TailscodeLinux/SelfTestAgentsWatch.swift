import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// What the wall's checks share: a counted claim, a pump of the main loop, and a window made over
/// a scripted source so every press and every second can be counted and moved.
final class WatchCheck {
    var claims = 0
    let source: ScriptedAgentsSource
    let log = AgentsHookLog()

    init(now: Date = Date()) {
        source = ScriptedAgentsSource(now: now)
    }

    func expect(_ condition: Bool, _ label: String) throws {
        guard condition else { throw SelfTestFailure("agents watch: \(label)") }
        claims += 1
    }

    func pump(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            while g_main_context_iteration(nil, 0) != 0 {}
            usleep(4000)
        }
    }

    func open(parent: UnsafeMutablePointer<GtkWidget>? = nil, size: (Int32, Int32)? = nil) -> AgentsWindow {
        let window = AgentsWindow.present(parent: parent, source: source, hooks: log.hooks, mode: .watch)
        window.controls.power = WatchPower(reading: { true })
        if let size { resize(window, size.0, size.1) }
        var waited = 0.0
        while window.boardsApplied == 0 && waited < 4 {
            pump(0.1)
            waited += 0.1
        }
        pump(0.2)
        return window
    }

    func resize(_ window: AgentsWindow, _ width: Int32, _ height: Int32) {
        gtk_window_set_default_size(ptr(window.window), width, height)
        pump(0.35)
    }

    func close(_ window: AgentsWindow) {
        window.close()
        pump(0.3)
    }
}

extension SelfTest {
    /// The wall in a real window: every demo scene at a monitor, a portrait monitor and a small
    /// window, with its tiles and state words named for assistive technology and none of its text
    /// clipped; then the window that must never outgrow its parent or its monitor, the hold that
    /// approves, the peek that goes back by itself, the dim, the keep-awake, the fullscreen, the
    /// still frames of reduced motion and the clock that stops when nobody can see it.
    static func checkAgentsWatch() throws -> Int {
        guard gtk_init_check() != 0 else { return 0 }
        MatrixTheme.install()
        let check = WatchCheck()
        Preferences.forgetAgentsWindowSize()
        Preferences.setAgentsWatchStyle(nil)
        defer {
            Preferences.forgetAgentsWindowSize()
            Preferences.setAgentsWatchStyle(nil)
        }
        try checkWatchSize(check)
        try checkWatchScenes(check)
        try checkWatchSquad(check)
        try checkWatchPlain(check)
        try checkWatchHold(check)
        try checkWatchTimers(check)
        try checkWatchControls(check)
        try checkWatchMotion(check)
        try checkWatchEffects(check)
        try checkWatchStyle(check)
        return check.claims
    }

    static func watchProblems(_ window: AgentsWindow, scene: String) -> [String] {
        var problems: [String] = []
        for (key, view) in window.watchView.tiles {
            guard let tile = view.tile, let box = Gtk.bounds(of: view.widget, in: window.window) else {
                problems.append("\(scene) \(key) has no place")
                continue
            }
            let parts: [(String, WatchLabel)] = [
                ("title", view.title), ("status", view.status), ("meta", view.meta), ("words", view.words),
                ("detail", view.detail),
            ]
            for (name, label) in parts where !label.text.isEmpty {
                guard gtk_widget_get_mapped(label.widget) != 0,
                    let at = Gtk.bounds(of: label.widget, in: window.window)
                else {
                    problems.append("\(scene) \(tile.title) \(name) is not shown")
                    continue
                }
                let natural = label.height(forWidth: at.width)
                if at.height < natural - 1 {
                    problems.append("\(scene) \(tile.title) \(name) clipped: \(at.height) of \(natural)")
                }
                if label.isEllipsized { problems.append("\(scene) \(tile.title) \(name) ends in an ellipsis") }
                if at.x < box.x - 1 || at.x + at.width > box.x + box.width + 1 || at.y + at.height > box.y + box.height + 1 {
                    problems.append("\(scene) \(tile.title) \(name) leaves its tile")
                }
            }
            if view.truncated { problems.append("\(scene) \(tile.title) cut its command") }
        }
        problems += squadProblems(window, scene: scene)
        let squad = window.watchView.workers.values.map(\.widget) + window.watchView.crowds.values.map(\.widget)
        let boxes = (window.watchView.tiles.values.map(\.widget) + squad)
            .compactMap { Gtk.bounds(of: $0, in: window.window) }
        for (index, one) in boxes.enumerated() {
            for other in boxes.dropFirst(index + 1)
            where one.x < other.x + other.width - 1 && other.x < one.x + one.width - 1
                && one.y < other.y + other.height - 1 && other.y < one.y + one.height - 1
            {
                problems.append("\(scene) two tiles overlap")
            }
        }
        return problems
    }

    private static func checkWatchScenes(_ check: WatchCheck) throws {
        let window = check.open()
        defer { check.close(window) }
        let view = window.watchView
        try check.expect(
            window.mode == .watch && view.context.palette.source.isDark,
            "the wall opens as the default lens and is drawn in the theme's dark palette")
        var seen = 0
        for size in [(Int32(1920), Int32(1080)), (1080, 1920), (960, 540)] {
            check.resize(window, size.0, size.1)
            for name in AgentsWatchView.sceneNames {
                view.startScene(name)
                check.pump(0.25)
                view.tickSecond()
                let wall = view.wall
                try check.expect(
                    view.tiles.count == wall.tiles.count && view.scene?.name == name,
                    "\(name) at \(size.0)x\(size.1) has a view for each of its \(wall.tiles.count) tiles")
                let now = view.context.clock.now
                for tile in wall.tiles {
                    guard let tileView = view.tileView(tile.id) else {
                        throw SelfTestFailure("agents watch: \(name) lost the tile \(tile.title)")
                    }
                    tileView.tick(now: now)
                    let spoken = tileView.spoken(now: now)
                    try check.expect(
                        spoken.contains(tile.statusWord(at: now)) && spoken.contains(tile.title)
                            && tailscode_accessible_has_label(tileView.widget, spoken) != 0,
                        "\(name): \(tile.title) is named with its state word: \(spoken)")
                    seen += 1
                }
                let problems = watchProblems(window, scene: "\(name) \(size.0)x\(size.1)")
                try check.expect(problems.isEmpty, "no tile text is clipped: \(problems.prefix(4))")
                try check.expect(
                    wall.tiles.count <= AgentWall.maxTiles && view.geometry.tiles.count == wall.tiles.count
                        && view.geometry.unit == WatchGeometry.unit(width: Double(gtk_widget_get_width(view.widget)), height: Double(gtk_widget_get_height(view.widget))),
                    "\(name): the grid holds the tiles at one unit")
            }
        }
        try check.expect(seen > 40, "every scene's tiles were named: \(seen)")
        check.resize(window, 1920, 1080)
        view.startScene("alarm")
        check.pump(0.3)
        try check.expect(
            view.wall.hasOverdue && view.wall.mood == .alarm
                && view.tiles.values.contains { $0.tile.map { if case .away = $0.state { return true } else { return false } } ?? false },
            "the alarm scene holds an overdue ask and an away machine")
    }
}
