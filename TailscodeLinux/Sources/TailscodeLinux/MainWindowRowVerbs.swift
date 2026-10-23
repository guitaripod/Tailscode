import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension MainWindow {
    /// Watches the chat list for a pointer resting on a row, through one motion controller on the
    /// overlay the list scrolls in — never one per row — and floats the row's verbs there.
    func installRowVerbs(on overlay: UnsafeMutablePointer<GtkWidget>) {
        sidebarOverlay = overlay
        gtk_overlay_add_overlay(op(overlay), rowVerbs.widget)
        rowVerbs.press = { [weak self] verb, button in self?.performRowVerb(verb, from: button) }
        Gtk.onPointer(
            overlay,
            move: { [weak self] x, y in
                guard let self else { return }
                self.sidebarPointer = (x, y)
                self.evaluateRowVerbs()
                self.noteWarmIntent()
            },
            leave: { [weak self] in
                self?.sidebarPointer = nil
                self?.rowVerbs.dismiss()
                self?.cancelWarmIntent()
            })
    }

    /// How long a pointer rests on a chat before the chat is started: long enough that a pointer
    /// crossing the list starts nothing, short enough to be well ahead of the click.
    static let warmIntent: UInt32 = 90

    /// The chat the pointer is on, if it is on one the list draws as a single chat.
    func chatEntryUnderPointer() -> SessionEntry? {
        guard let point = sidebarPointer, let overlay = sidebarOverlay, !sidebarScrolling,
            sidebarRows.count <= visible.count
        else { return nil }
        let index = PointerRows.row(
            atY: point.y, count: sidebarRows.count,
            span: { [sidebarRows] index in
                guard let widget = sidebarRows[index].widget,
                    let box = Gtk.bounds(of: widget, in: overlay)
                else { return nil }
                return box.y...(box.y + box.height)
            })
        guard let index, case .chat(let row) = visible[index],
            sidebarRows[index].key == visible[index].key
        else { return nil }
        return row.entry
    }

    /// A pointer that has stayed on a chat starts it, once, unless a pane already shows it.
    func noteWarmIntent() {
        guard let entry = chatEntryUnderPointer() else {
            cancelWarmIntent()
            return
        }
        let key = LiveKey(entry)
        guard key != warmIntentKey else { return }
        warmIntentKey = key
        warmIntentToken &+= 1
        let token = warmIntentToken
        Gtk.after(Self.warmIntent) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.warmIntentToken == token else { return }
                self.warmUnlessShown(entry)
            }
        }
    }

    func cancelWarmIntent() {
        guard warmIntentKey != nil else { return }
        warmIntentKey = nil
        warmIntentToken &+= 1
    }

    /// A button going down on a chat is a click that has not finished: it starts then, not when
    /// the button comes up.
    func warmChatPressed() {
        guard let entry = chatEntryUnderPointer() else { return }
        warmUnlessShown(entry)
    }

    func warmUnlessShown(_ entry: SessionEntry) {
        guard splitHost.pane(showing: entry.session.id) == nil else { return }
        live.warmer.warm(entry)
    }

    /// The list is moving under the pointer: the verbs come down for as long as it does, and go to
    /// whatever row is then under the pointer once it has been still for a moment.
    func rowVerbsScrolled() {
        guard sidebarPointer != nil else { return }
        rowVerbs.dismiss()
        sidebarScrolling = true
        sidebarScrollToken &+= 1
        let token = sidebarScrollToken
        Gtk.after(120) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.sidebarScrollToken == token else { return }
                self.sidebarScrolling = false
                self.evaluateRowVerbs()
            }
        }
    }

    /// The list was redrawn, perhaps with a different chat under a pointer standing still. Looked
    /// at once the allocations have settled, and no more than once for a burst of redraws.
    func scheduleRowVerbsRefresh() {
        guard sidebarPointer != nil, !sidebarVerbRefreshQueued else { return }
        sidebarVerbRefreshQueued = true
        Gtk.after(60) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.sidebarVerbRefreshQueued = false
                self.evaluateRowVerbs()
            }
        }
    }

    /// Which way each of a chat's verbs would go, read from the stores at the moment the pointer
    /// arrives, because they can change under a row that is not being redrawn.
    func rowVerbState(for entry: SessionEntry) -> ChatRowVerbState {
        ChatRowVerbState(
            pinned: SessionPinStore.contains(
                profileID: entry.profileID, sessionID: entry.session.id),
            saved: SavedChatStore.contains(entry),
            archived: ArchivedChatStore.contains(
                profileID: entry.profileID, sessionID: entry.session.id))
    }

    func evaluateRowVerbs() {
        guard let point = sidebarPointer, let overlay = sidebarOverlay, !sidebarScrolling else {
            return
        }
        let bounds: (Int) -> (y: Double, height: Double, right: Double)? = { [sidebarRows] index in
            guard let widget = sidebarRows[index].widget,
                let box = Gtk.bounds(of: widget, in: overlay)
            else {
                return nil
            }
            return (box.y, box.height, box.x + box.width)
        }
        let index =
            sidebarRows.count <= visible.count
            ? PointerRows.row(
                atY: point.y, count: sidebarRows.count,
                span: { index in bounds(index).map { $0.y...($0.y + $0.height) } })
            : nil
        guard let index, case .chat(let row) = visible[index],
            sidebarRows[index].key == visible[index].key, let box = bounds(index)
        else {
            rowVerbs.dismiss()
            return
        }
        let key = visible[index].key
        if key == rowVerbs.shownKey, rowVerbs.contains(x: point.x, y: point.y, in: overlay) {
            return
        }
        rowVerbs.present(
            key: key, state: rowVerbState(for: row.entry), right: box.right - 2,
            bottom: box.y + box.height - 3)
    }

    /// A verb pressed on a row: the same stores the context menu writes, and for the ellipsis the
    /// context menu itself, opened under the button that asked for it.
    func performRowVerb(
        _ verb: ChatRowVerb, from button: UnsafeMutablePointer<GtkWidget>
    ) {
        guard let key = rowVerbs.shownKey,
            let index = visible.firstIndex(where: { $0.key == key }),
            case .chat(let row) = visible[index]
        else { return }
        let entry = row.entry
        switch verb {
        case .pin: togglePinned(entry)
        case .save: toggleSaved(entry)
        case .archive: _ = toggleArchived(entry)
        case .more:
            presentRowVerbMenu(row, key: key, from: button)
            return
        }
        refreshRowVerbState(for: entry, key: key)
        scheduleRowVerbsRefresh()
    }

    /// The strip answers a press at once, from the stores, rather than waiting for the list to be
    /// redrawn under it: a pinned chat's pin lights the moment it is pressed.
    func refreshRowVerbState(for entry: SessionEntry, key: String) {
        guard let overlay = sidebarOverlay, let box = Gtk.bounds(of: rowVerbs.widget, in: overlay)
        else { return }
        rowVerbs.present(
            key: key, state: rowVerbState(for: entry), right: box.x + box.width,
            bottom: box.y + box.height)
    }

    func presentRowVerbMenu(
        _ row: SessionRowModel, key: String, from button: UnsafeMutablePointer<GtkWidget>
    ) {
        guard let overlay = sidebarOverlay,
            let holder = sidebarRows.first(where: { $0.key == key })?.widget,
            let rowBox = Gtk.bounds(of: holder, in: overlay),
            let buttonBox = Gtk.bounds(of: button, in: overlay)
        else { return }
        presentRowMenu(
            row, rowBits: UInt(bitPattern: holder), x: buttonBox.x - rowBox.x,
            y: buttonBox.y + buttonBox.height - rowBox.y)
    }
}
