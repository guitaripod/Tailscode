import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

extension SidebarViewController {
    /// Reads which row the pointer is over and puts the ground and the verbs there — after a
    /// move, a scroll, or a redraw that put a different chat under a pointer standing still.
    func refreshHover() {
        let row = hoverWatch.row(in: tableView)
        let pressable = row >= 0 && row < rows.count && rows[row].isPressable
        setHoveredRow(pressable ? row : -1, force: row == hoveredRow)
    }

    private func setHoveredRow(_ row: Int, force: Bool = false) {
        guard row != hoveredRow || force else { return }
        if hoveredRow >= 0, hoveredRow < tableView.numberOfRows, hoveredRow != row {
            (tableView.rowView(atRow: hoveredRow, makeIfNecessary: false) as? SidebarRowView)?
                .isHovered = false
            (tableView.view(atColumn: 0, row: hoveredRow, makeIfNecessary: false)
                as? SidebarSessionCell)?.setHovered(nil)
        }
        hoveredRow = row
        warmWork?.cancel()
        warmWork = nil
        guard row >= 0, row < tableView.numberOfRows else { return }
        (tableView.rowView(atRow: row, makeIfNecessary: false) as? SidebarRowView)?.isHovered = true
        (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarSessionCell)?
            .setHovered(quickState(for: row))
        let work = DispatchWorkItem { [weak self] in self?.warm(row: row) }
        warmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverIntent, execute: work)
    }

    /// Starts the conversation a row stands for, unless it is the one already open.
    private func warm(row: Int) {
        guard row >= 0, row < rows.count, case .session(let model, _, _) = rows[row] else { return }
        let entry = model.entry
        let showing =
            focusedSessionID.map { $0() == entry.session.id } ?? (selectedID == entry.session.id)
        guard !showing,
            let profile = ServerDirectory.shared.profiles.first(where: { $0.id == entry.profileID }),
            let backend = ServerDirectory.shared.backend(for: profile)
        else { return }
        ConversationWarmer.shared.warm(entry, backend: backend)
    }

    /// A button going down on a chat row is a click that has not finished: the conversation starts
    /// then rather than a tenth of a second later, when the button comes up.
    func watchPresses() {
        guard pressWatch == nil else { return }
        let sidebar = WeakBox(self)
        pressWatch = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { @Sendable event in
            nonisolated(unsafe) let pressed = event
            DispatchQueue.main.async { MainThread.call { sidebar.value?.pressed(pressed) } }
            return event
        }
    }

    private func pressed(_ event: NSEvent) {
        guard event.window === tableView.window, event.window != nil else { return }
        let point = tableView.convert(event.locationInWindow, from: nil)
        guard tableView.visibleRect.contains(point) else { return }
        warm(row: tableView.row(at: point))
    }

    /// Which way each of a chat row's verbs would go, read from the stores at the moment the
    /// pointer arrives. Nil for anything that is not a single chat.
    func quickState(for row: Int) -> SidebarQuickState? {
        guard row >= 0, row < rows.count, case .session(let model, _, _) = rows[row] else {
            return nil
        }
        let entry = model.entry
        return SidebarQuickState(
            pinned: SessionPinStore.contains(profileID: entry.profileID, sessionID: entry.session.id),
            saved: SavedChatStore.contains(entry),
            archived: ArchivedChatStore.contains(
                profileID: entry.profileID, sessionID: entry.session.id))
    }

    /// A verb pressed on a row: the same stores the context menu writes, and for the ellipsis the
    /// context menu itself, opened under the button that asked for it.
    func performQuickAction(_ action: SidebarQuickAction, on entry: SessionEntry, from view: NSView) {
        switch action {
        case .pin: togglePinned(entry)
        case .save: toggleSaved(entry)
        case .archive: toggleArchived(entry)
        case .more:
            guard let row = rowIndex(of: entry.session.id) else { return }
            let menu = NSMenu()
            fillRowMenu(menu, row: row)
            guard !menu.items.isEmpty else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
        }
    }
}
