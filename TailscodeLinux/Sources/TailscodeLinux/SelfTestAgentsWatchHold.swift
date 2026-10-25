import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension SelfTest {
    /// Approving on a wall that may be left on a shared monitor: a tap asks to be held and sends
    /// nothing, an early release cancels, the full hold sends once however long it is kept, and
    /// Deny is one tap.
    static func checkWatchHold(_ check: WatchCheck) throws {
        let window = check.open(size: (1920, 1080))
        defer { check.close(window) }
        let view = window.watchView
        let key = AgentDemo.homelab + "/ask"
        guard let tile = view.tileView(key), let wall = tile.tile else {
            throw SelfTestFailure("agents watch: the board's ask has no tile: \(view.tiles.keys.sorted()) \(String(describing: view.scene?.name))")
        }
        let clock = view.context.clock
        try check.expect(
            wall.state.isNeedsYou && gtk_widget_get_mapped(tile.approve) != 0 && gtk_widget_get_mapped(tile.deny) != 0
                && tailscode_accessible_has_label(tile.deny, Localized.text("Deny")) != 0,
            "the ask's tile carries Approve and Deny")

        tile.approveDown()
        clock.advance(by: 0.1)
        tile.approveUp()
        check.pump(0.2)
        try check.expect(
            check.source.approves.isEmpty && tile.hintUntil != nil
                && tile.approveLabel.text == Localized.text("Hold to approve"),
            "a tap sends nothing and says to hold: \(tile.approveLabel.text)")

        tile.approveDown()
        clock.advance(by: 0.5)
        tile.evaluateHold()
        try check.expect(
            check.source.approves.isEmpty && tile.gauge.progress(at: clock.now) > 0.5,
            "half a hold fills half the ring and sends nothing: \(tile.gauge.progress(at: clock.now))")
        tile.approveUp()
        clock.advance(by: 2)
        tile.evaluateHold()
        check.pump(0.3)
        try check.expect(
            check.source.approves.isEmpty && !tile.gauge.isHolding && tile.gauge.progress(at: clock.now) == 0,
            "releasing early cancels the hold for good")

        tile.approveDown()
        clock.advance(by: 0.9)
        tile.evaluateHold()
        tile.evaluateHold()
        check.pump(0.4)
        try check.expect(
            check.source.approves.count == 1 && check.source.approves[0].0 == key && check.source.approves[0].1,
            "a hold of 0.8 seconds approves exactly once: \(check.source.approves.count)")
        tile.approveUp()
        tile.approveDown()
        clock.advance(by: 2)
        tile.evaluateHold()
        check.pump(0.3)
        tile.approveUp()
        try check.expect(
            check.source.approves.count == 1, "and a second hold while it is sent adds nothing: \(check.source.approves.count)")
        try check.expect(
            tile.approveLabel.text == Localized.text("Sent"), "the button says it was sent")

        window.actions.reconcile(live: [key], now: Date().addingTimeInterval(30))
        tile.refreshControls()
        tailscode_emit_clicked(tile.deny)
        check.pump(0.3)
        try check.expect(
            check.source.approves.count == 2 && !check.source.approves[1].1,
            "Deny is one tap and sends once: \(check.source.approves.map(\.1))")
        tailscode_emit_clicked(tile.deny)
        check.pump(0.3)
        try check.expect(check.source.approves.count == 2, "a second tap while it is sent is the same send")

        let ring = pixels(36) { cr in tile.paintRing(cr, 36) }
        try check.expect(ring.contains { $0 != 0 }, "the ring draws")
        view.startScene("attention")
        check.pump(0.4)
        try check.expect(
            check.log.opened.isEmpty && !window.watchView.peekLayer.isShown,
            "nothing on the wall opened a chat or a peek by itself")
    }

    static func pixels(_ side: Int32, _ paint: (OpaquePointer) -> Void) -> [UInt8] {
        let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, side, side)!
        let cr = cairo_create(surface)!
        paint(cr)
        cairo_surface_flush(surface)
        let data = cairo_image_surface_get_data(surface)!
        let bytes = Array(UnsafeBufferPointer(start: data, count: Int(side) * Int(side) * 4))
        cairo_destroy(cr)
        cairo_surface_destroy(surface)
        return bytes
    }
}
