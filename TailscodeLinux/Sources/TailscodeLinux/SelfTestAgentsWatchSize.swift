import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension SelfTest {
    /// The window that used to grow past the one it came from: sized from its parent and the
    /// monitor, held there by a board built to be worse than any real one, in every lens and with
    /// the peek open, and remembered once the person has moved it.
    static func checkWatchSize(_ check: WatchCheck) throws {
        let parent = gtk_window_new()!
        gtk_window_set_default_size(ptr(parent), 1000, 600)
        gtk_window_present(ptr(parent))
        check.pump(0.5)
        defer {
            gtk_window_destroy(ptr(parent))
            check.pump(0.2)
        }
        let ceiling = AgentsWindowSize.ceiling(near: parent)
        let window = check.open(parent: parent)
        defer { check.close(window) }
        let reference = max(gtk_widget_get_height(parent), AgentsWindowSize.floor.height)
        func height() -> Int32 { gtk_widget_get_height(window.window) }
        try check.expect(
            height() <= reference && height() <= ceiling && gtk_widget_get_width(window.window) <= gtk_widget_get_width(parent),
            "the window opens at its parent's size: \(window.windowSize) in a parent of \(gtk_widget_get_width(parent))x\(gtk_widget_get_height(parent)), the monitor's room \(ceiling)")
        let now = Date()
        for parts in [40, 14] {
            window.apply(board: AgentsStress.board(now: now, askCommand: AgentsStress.command(parts: parts)))
            for lens in [AgentsWindow.Mode.watch, .now, .hour] {
                window.show(lens)
                check.pump(0.3)
                try check.expect(
                    height() <= reference && height() <= ceiling,
                    "a \(parts)-part command in \(lens) leaves the window at \(window.windowSize), no taller than its parent's \(reference) or the monitor's \(ceiling)")
            }
        }
        report("agents watch window: parent \(gtk_widget_get_width(parent))x\(gtk_widget_get_height(parent)), window \(window.windowSize) after a 40-part command in Watch, Now and Hour, the monitor's room \(ceiling) high")
        window.show(.now)
        window.select(key: AgentDemo.homelab + "/ask")
        check.pump(0.6)
        try check.expect(
            height() <= reference && window.peekRevealed,
            "an open inspector over the tall board does not grow it either: \(window.windowSize)")
        window.deselect()
        window.show(.watch)
        window.select(key: AgentDemo.homelab + "/ask")
        check.pump(0.6)
        try check.expect(
            height() <= reference && window.watchView.peekLayer.isShown,
            "nor does the peek over the wall: \(window.windowSize)")
        window.deselect()

        check.resize(window, 900, 500)
        window.rememberSize()
        try check.expect(
            Preferences.agentsWindowSize.map { $0 == (900, 500) || ($0.0 >= 880 && $0.1 >= 480) } ?? false,
            "a size the person chose is remembered: \(String(describing: Preferences.agentsWindowSize))")
        check.close(window)
        let again = check.open(parent: parent)
        try check.expect(
            abs(gtk_widget_get_width(again.window) - 900) <= 20 && gtk_widget_get_height(again.window) <= ceiling,
            "and used the next time, within the monitor: \(again.windowSize)")
        check.close(again)
        Preferences.forgetAgentsWindowSize()
        let clamp = AgentsWindowSize.clamp((9000, 9000), near: parent)
        try check.expect(
            clamp.height <= ceiling && clamp.width <= AgentsWindowSize.workArea(near: parent).width,
            "a remembered size from a bigger monitor is held to this one: \(clamp)")
        let small = AgentsWindowSize.initial(parent: nil)
        try check.expect(
            small.width >= AgentsWindowSize.floor.width && small.height >= AgentsWindowSize.floor.height,
            "and never below the floor: \(small)")
    }
}
