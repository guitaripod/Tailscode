import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension ChatPane {
    /// Watches the transcript for a pointer resting on a message, through one motion controller on
    /// the overlay the scroller sits in — never one per row — and floats `messageBar` there.
    func installMessageHover(on overlay: UnsafeMutablePointer<GtkWidget>) {
        hoverOverlay = overlay
        gtk_overlay_add_overlay(op(overlay), messageBar.widget)
        messageBar.copy = { [weak self] id in self?.copyMessage(id) }
        messageBar.undo = { [weak self] id in self?.confirmUndo(messageID: id) }
        Gtk.onPointer(
            overlay,
            move: { [weak self] x, y in
                guard let self else { return }
                self.hoverPointer = (x, y)
                self.evaluateHover()
            },
            leave: { [weak self] in
                guard let self else { return }
                self.hoverPointer = nil
                self.messageBar.scheduleHide()
            })
    }

    /// A press on the transcript is a click or the start of a selection, and the plate has no
    /// business over either.
    func messageHoverPressed() {
        messageBar.dismiss()
    }

    /// A reader scrolling takes the plate down for as long as the wheel turns, and it comes back
    /// on whatever is then under the pointer once the page has been still for a moment.
    func messageHoverScrolled() {
        guard hoverPointer != nil else { return }
        messageBar.dismiss()
        hoverHeldOff = true
        hoverQuietToken &+= 1
        let token = hoverQuietToken
        Gtk.after(Self.hoverQuiet) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.hoverQuietToken == token else { return }
                self.hoverHeldOff = false
                self.hoverDirty = true
                self.evaluateHover()
            }
        }
    }

    /// Rows arrived or moved under a pointer that may be standing still: look again, at most
    /// every `hoverRefreshEvery`, so a turn writing forty tokens a second costs one lookup an
    /// interval and nothing at all while the pointer is elsewhere.
    func scheduleHoverRefresh() {
        hoverDirty = true
        guard hoverPointer != nil, messageBar.shownID != nil, !hoverRefreshQueued else { return }
        hoverRefreshQueued = true
        Gtk.after(Self.hoverRefreshEvery) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.hoverRefreshQueued = false
                self.evaluateHover()
            }
        }
    }

    private static let hoverQuiet: UInt32 = 160
    private static let hoverRefreshEvery: UInt32 = 80

    private func evaluateHover() {
        guard let point = hoverPointer, let overlay = hoverOverlay, !hoverHeldOff else { return }
        guard !pointerHeld else { return }
        if messageBar.contains(x: point.x, y: point.y, in: overlay) {
            messageBar.cancelHide()
            return
        }
        guard let hit = messageHit(atOverlayX: point.x, y: point.y, in: overlay) else {
            messageBar.scheduleHide()
            return
        }
        let verbs: MessageHover.Verbs
        if let held = hoverVerbs, held.id == hit.owner, !hoverDirty {
            verbs = held.verbs
        } else {
            guard let message = lastState?.messages.last(where: { $0.id == hit.owner }) else {
                messageBar.scheduleHide()
                return
            }
            verbs = MessageHover.verbs(
                for: message, isPrompt: message.role == .user, capabilities: backend?.capabilities)
            hoverVerbs = (hit.owner, verbs)
            hoverDirty = false
        }
        messageBar.present(
            messageID: hit.owner, verbs: verbs, right: hit.right, top: hit.top, ceiling: 2)
    }

    /// The message under a point on the overlay, with the corner its plate hangs from. Nothing
    /// when the pointer is over a button of the row's own (a code block's copy), in the room
    /// between messages, or over a row that is the agent working rather than a message.
    private func messageHit(
        atOverlayX x: Double, y: Double, in overlay: UnsafeMutablePointer<GtkWidget>
    ) -> (owner: String, right: Double, top: Double)? {
        guard !placeholderShown, !renderedRows.isEmpty, renderedRows.count == rowWidgets.count
        else { return nil }
        let bounds: (Int) -> (y: Double, height: Double, right: Double)? = { [rowWidgets] index in
            guard let raw = UnsafeMutableRawPointer(bitPattern: rowWidgets[index]),
                let box = Gtk.bounds(of: ptr(raw), in: overlay)
            else { return nil }
            return (box.y, box.height, box.x + box.width)
        }
        let rows = renderedRows
        let hit = PointerRows.message(
            atY: y, count: rows.count,
            span: { index in bounds(index).map { $0.y...($0.y + $0.height) } },
            owner: { hoverOwner(of: rows[$0]) })
        guard let hit, let first = bounds(hit.rows.lowerBound),
            !pointerIsOverButton(x: x, y: y, in: overlay)
        else { return nil }
        return (hit.owner, first.right - 6, first.y)
    }

    /// Which message a row draws the words of. An answer's rows are keyed by the message and the
    /// part they came from, so the message is the one whose id leads the key; the lookup is
    /// remembered by key because the same few rows are asked about on every move.
    private func hoverOwner(of row: TranscriptRow) -> String? {
        switch row.kind {
        case .userText(_, let messageID): return messageID
        case .file(_, let mine): return mine ? messageID(leading: row.key) : nil
        case .agentProse, .codeBlock, .table, .tableDraft: return messageID(leading: row.key)
        default: return nil
        }
    }

    private func messageID(leading key: String) -> String? {
        if let known = hoverOwners[key] { return known }
        guard let id = lastState?.messages.last(where: { key.hasPrefix($0.id + ":") })?.id
        else { return nil }
        if hoverOwners.count > 512 { hoverOwners.removeAll(keepingCapacity: true) }
        hoverOwners[key] = id
        return id
    }

    /// A button inside a row — a code block's copy, a table's — keeps the pointer to itself.
    private func pointerIsOverButton(
        x: Double, y: Double, in overlay: UnsafeMutablePointer<GtkWidget>
    ) -> Bool {
        var current = gtk_widget_pick(overlay, x, y, GTK_PICK_DEFAULT)
        while let widget = current, widget != overlay {
            let instance = UnsafeMutableRawPointer(widget).assumingMemoryBound(
                to: GTypeInstance.self)
            if g_type_check_instance_is_a(instance, gtk_button_get_type()) != 0 { return true }
            current = gtk_widget_get_parent(widget)
        }
        return false
    }

    private func copyMessage(_ id: String) {
        guard let message = lastState?.messages.first(where: { $0.id == id }) else { return }
        Gtk.copyToClipboard(MessageHover.words(of: message))
        host?.toast(Localized.text("Copied"))
    }
}
