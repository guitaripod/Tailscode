import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension WatchTileView {
    static let hintLasts: TimeInterval = 2.6

    func wireButtons() {
        denyLabel.set(text: Localized.text("Deny"))
        approveLabel.set(text: Localized.text("Approve"))
        chatLabel.set(text: Localized.text("Open chat"))
        tailscode_set_accessible_label(deny, Localized.text("Deny"))
        tailscode_set_accessible_label(approve, Localized.text("Hold to approve"))
        tailscode_set_accessible_label(chat, Localized.text("Open chat"))
        Gtk.connect(UnsafeMutableRawPointer(deny), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.denyTapped() }
        }
        Gtk.connect(UnsafeMutableRawPointer(chat), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.chatTapped() }
        }
        Gtk.onPressHold(
            approve,
            down: { [weak self] in Gtk.onMain { [weak self] in self?.approveDown() } },
            up: { [weak self] in Gtk.onMain { [weak self] in self?.approveUp() } })
    }

    func denyTapped() {
        guard let tile, !tile.isAwayState else { return }
        context.touched()
        context.actions.perform(.deny, key: tile.id, title: tile.title)
    }

    func chatTapped() {
        guard let tile else { return }
        context.touched()
        context.actions.openChat(tile.id)
    }

    func approveDown() {
        guard let tile, !tile.isAwayState, context.style.approvals == .hold,
            !context.actions.state(tile.id).blocks(.approve)
        else { return }
        context.touched()
        clearHint()
        gauge.begin(at: context.clock.now)
        ring.redraw()
        pumpHold()
    }

    func approveUp() {
        switch gauge.release(at: context.clock.now) {
        case .tap: showHint()
        case .cancelled, .after, .none: break
        }
        ring.redraw()
        card.redraw()
    }

    /// The hold is read from the clock, never counted in frames, so a slow frame cannot make an
    /// approval harder or easier to give; the pump only wakes often enough to draw the ring.
    func pumpHold() {
        guard !holdPumping else { return }
        holdPumping = true
        Gtk.after(33) { [weak self] in self?.holdStep() }
    }

    func holdStep() {
        holdPumping = false
        guard gauge.isHolding else { return }
        if gauge.advance(to: context.clock.now) { approveHeld() }
        ring.redraw()
        card.redraw()
        if gauge.isHolding && !gauge.fired { pumpHold() }
    }

    func evaluateHold() {
        guard gauge.isHolding else { return }
        if gauge.advance(to: context.clock.now) { approveHeld() }
        ring.redraw()
    }

    private func approveHeld() {
        guard let tile else { return }
        context.actions.perform(.approve, key: tile.id, title: tile.title)
        refreshControls()
    }

    func showHint() {
        hintUntil = context.clock.now.addingTimeInterval(Self.hintLasts)
        refreshControls()
    }

    func clearHint() {
        guard hintUntil != nil else { return }
        hintUntil = nil
        refreshControls()
    }

    /// The buttons say where a press has got to, are dead while it travels or while the machine
    /// is not answering, and a failure says why next to them and leaves them live.
    func refreshControls() {
        guard let tile else { return }
        let state = context.actions.state(tile.id)
        let busy = state.blocks(.approve) || tile.isAwayState
        gtk_widget_set_sensitive(deny, busy ? 0 : 1)
        gtk_widget_set_sensitive(approve, busy ? 0 : 1)
        var approveWords = Localized.text("Approve")
        var denyWords = Localized.text("Deny")
        var failure: String?
        switch state {
        case .inFlight(.approve): approveWords = Localized.text("Approving…")
        case .sent(.approve, _): approveWords = Localized.text("Sent")
        case .inFlight(.deny): denyWords = Localized.text("Sending…")
        case .sent(.deny, _): denyWords = Localized.text("Sent")
        case .failed(_, let why): failure = Localized.text("Could not send: %@", why)
        default: break
        }
        if hintUntil != nil { approveWords = Localized.text("Hold to approve") }
        approveLabel.set(text: approveWords)
        denyLabel.set(text: denyWords)
        hint.set(text: failure ?? (truncated ? Localized.text("Tap to read it all") : ""))
        hint.set(style: context.label(1.9, ink: failure == nil ? context.palette.dim : context.palette.failed.lifted(0.2)))
        tailscode_set_accessible_label(approve, approveWords)
        tailscode_set_accessible_label(deny, denyWords)
    }

    func paintRing(_ cr: OpaquePointer, _ size: Double) {
        let palette = context.palette
        let centre = size / 2
        let width = max(2, size * 0.16)
        let radius = size / 2 - width
        let progress = gauge.progress(at: context.clock.now)
        cairo_set_line_width(cr, width)
        cairo_new_path(cr)
        cairo_arc(cr, centre, centre, radius, 0, 2 * .pi)
        palette.text.set(cr, alpha: gauge.isHolding ? 0.28 : 0.5)
        cairo_stroke(cr)
        if progress > 0 {
            cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
            cairo_new_path(cr)
            cairo_arc(cr, centre, centre, radius, -.pi / 2, -.pi / 2 + 2 * .pi * progress)
            (progress >= 1 ? palette.working.lifted(0.3) : palette.working).set(cr)
            cairo_stroke(cr)
            cairo_set_line_cap(cr, CAIRO_LINE_CAP_BUTT)
        }
        cairo_new_path(cr)
        cairo_arc(cr, centre, centre, size * 0.1, 0, 2 * .pi)
        palette.text.set(cr, alpha: progress > 0 ? 0.95 : 0.6)
        cairo_fill(cr)
    }
}
