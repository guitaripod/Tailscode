import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension SelfTest {
    /// Every worker view is placed, shown and kept inside the cell of its own session; the text it
    /// sets may end in an ellipsis, which is how a small tile says there is more in the peek.
    static func squadProblems(_ window: AgentsWindow, scene: String) -> [String] {
        var problems: [String] = []
        let view = window.watchView
        let all = view.workers.merging(view.crowds) { first, _ in first }
        for (key, worker) in all {
            guard let box = Gtk.bounds(of: worker.widget, in: window.window) else {
                problems.append("\(scene) \(key) has no place")
                continue
            }
            let parts: [(String, WatchLabel)] = [
                ("title", worker.title), ("status", worker.status), ("words", worker.words),
                ("figure", worker.figure),
            ]
            for (name, label) in parts where !label.text.isEmpty {
                guard gtk_widget_get_mapped(label.widget) != 0,
                    let at = Gtk.bounds(of: label.widget, in: window.window)
                else {
                    if name == "title" || name == "status" || (name == "figure" && worker.isCount) {
                        problems.append("\(scene) \(worker.spoken(now: view.context.clock.now)) \(name) is not shown")
                    }
                    continue
                }
                if at.x < box.x - 1 || at.x + at.width > box.x + box.width + 1 || at.y + at.height > box.y + box.height + 1 {
                    problems.append("\(scene) \(worker.spoken(now: view.context.clock.now)) \(name) leaves its tile")
                }
            }
        }
        return problems
    }

    static func checkWatchSquad(_ check: WatchCheck) throws {
        let window = check.open(size: (1920, 1080))
        defer { check.close(window) }
        let view = window.watchView
        let now = view.context.clock.now

        view.startScene("squad")
        check.pump(0.3)
        let fixing = try view.wall.tiles.first { $0.title == "Fix reconnect test" }
            .unwrap("agents watch: the squad scene has the session with the crew")
        try check.expect(
            view.workers.count == 7 && view.crowds.isEmpty,
            "the squad scene gives each of its seven workers a tile of its own: \(view.workers.count)")
        try check.expect(
            view.top.watchLine.text.contains("sub-agents"),
            "the watch line counts the sub-agents: \(view.top.watchLine.text)")
        var said: [String] = []
        for worker in fixing.workers {
            guard let tile = view.workers[worker.id] else {
                throw SelfTestFailure("agents watch: \(worker.title) has no tile of its own")
            }
            tile.tick(now: now)
            let spoken = tile.spoken(now: now)
            said.append(spoken)
            try check.expect(
                spoken.contains(worker.title) && spoken.contains(worker.statusWord(at: now))
                    && tailscode_accessible_has_label(tile.widget, spoken) != 0,
                "\(worker.title) is named with its state word: \(spoken)")
        }
        try check.expect(
            said.contains { $0.contains("stuck") } && said.contains { $0.contains("quiet for") }
                && said.contains { $0.contains("Finished") },
            "stuck, quiet and finished workers say so: \(said)")
        let lint = try fixing.workers.first { $0.state.isFinished }
            .unwrap("agents watch: a cooling worker is on the wall")
        try check.expect(
            (view.workers[lint.id].map { gtk_widget_get_opacity($0.widget) } ?? 1) < 1,
            "a finished worker cools toward the ground")

        let opener = try view.workers[fixing.workers[0].id].unwrap("agents watch: the first worker has a tile")
        opener.open()
        check.pump(0.3)
        try check.expect(
            window.selectedKey == fixing.id,
            "a press on a worker opens the peek of its session: \(window.selectedKey ?? "none")")

        view.startScene("crowded")
        check.pump(0.3)
        let crowd = try view.crowds.values.first.unwrap("agents watch: the crowded scene counts what did not fit")
        try check.expect(
            view.crowds.count == 1 && view.workers.count == 2 && crowd.figure.text == "+3",
            "five sub-agents in a small cell are two tiles and a +3: \(view.workers.count) \(crowd.figure.text)")

        for size in [(Int32(1080), Int32(1920)), (960, 540)] {
            check.resize(window, size.0, size.1)
            view.startScene("squad")
            check.pump(0.3)
            view.tickSecond()
            let problems = squadProblems(window, scene: "squad \(size.0)x\(size.1)")
            try check.expect(problems.isEmpty, "no worker text leaves its tile: \(problems.prefix(4))")
            try check.expect(
                view.workers.count == view.wall.tiles.reduce(0) { $0 + ($1.squad?.slots.count ?? 0) },
                "a worker view for every slot at \(size.0)x\(size.1)")
        }
    }
}

extension Optional {
    fileprivate func unwrap(_ message: String) throws -> Wrapped {
        guard let value = self else { throw SelfTestFailure(message) }
        return value
    }
}
