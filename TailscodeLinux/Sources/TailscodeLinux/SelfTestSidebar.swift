import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension SelfTest {
    /// What the chat list promises without a window: a burst of draws asked for in the same
    /// instant is the draw that went first and the one that closes it, the closing draw is the
    /// last request's, a flush spends the promise it overtakes, the interval stretches with the
    /// shed level, and the accent never reaches into a row widget that has no parent to belong to.
    static func checkSidebar() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("sidebar: \(label)") }
            checks += 1
        }

        var coalescer = RenderCoalescer()
        var draws = 0
        var promised: [(token: Int, delay: TimeInterval)] = []
        var now: TimeInterval = 1_000
        var lastAsked = 0
        for request in 0..<200 {
            lastAsked = request
            switch coalescer.request(at: now, interval: 0.1) {
            case .runNow: draws += 1
            case .wait(let delay, let token): promised.append((token, delay))
            case .covered: break
            }
            now += 0.0001
        }
        try expect(draws == 1, "a burst of 200 requests draws once at once (\(draws))")
        try expect(promised.count == 1, "and promises exactly one closing draw")
        now += promised[0].delay
        if coalescer.fire(token: promised[0].token, at: now) { draws += 1 }
        try expect(draws == 2, "the burst costs two draws (\(draws))")
        try expect(lastAsked == 199 && !coalescer.isWaiting, "nothing is left owed after the closing draw")

        let slow = coalescer.request(at: now + 0.01, interval: 1)
        guard case .wait(let delay, _) = slow else { throw SelfTestFailure("sidebar: a stretched interval waits") }
        try expect(delay > 0.9, "a critical window waits about a second (\(delay))")
        try expect(
            SidebarCadence.interval(at: .critical, visible: true)
                > SidebarCadence.interval(at: .calm, visible: true),
            "the interval grows with the shed level")

        guard gtk_init_check() != 0 else { return checks }
        let holder = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        let button = gtk_button_new()!
        gtk_widget_add_css_class(button, "session-row")
        gtk_box_append(ptr(holder), button)
        SidebarRow.setFocused(holder, true)
        try expect(
            gtk_widget_has_css_class(button, "row-focused") == 0,
            "a row holder with no parent is left alone")
        let list = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_box_append(ptr(list), holder)
        SidebarRow.setFocused(holder, true)
        try expect(gtk_widget_has_css_class(button, "row-focused") != 0, "a placed row takes the accent")
        SidebarRow.setFocused(holder, false)
        try expect(gtk_widget_has_css_class(button, "row-focused") == 0, "and gives it back")
        return checks
    }
}
