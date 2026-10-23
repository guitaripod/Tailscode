import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

extension SidebarViewController {
    /// What a person decided about a chat reaches this list from more than its own presses — a
    /// server's listing adopting a pin made on the phone, a chat read on another desk, a notice
    /// answered from a banner — and none of those is a listing this table would otherwise redraw
    /// for. A write that changed nothing is not posted and a redraw that changes nothing touches no
    /// row, so listening to every store the rows are drawn from costs nothing at rest.
    func observeDecisions() {
        let names = [
            SessionPinStore.didChange, SessionSeenStore.didSync, SavedChatStore.didChange,
            ArchivedChatStore.didChange, ActivityInbox.didChange, ModelCatalogStore.didChange,
        ]
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                MainThread.call { self?.render() }
            }
        }
    }

    @objc func orbSettingChanged() {
        orb.setEnabled(PresenceOrbSetting.isEnabled)
        refreshOrb()
    }

    /// One cheap re-read of the last aggregate, for the fact that changes without a listing —
    /// the ultracode aura lighting or dying under a draft. The full render feeds `known`; this
    /// keeps the rainbow honest between renders.
    func refreshOrb() {
        orb.update(
            signal: PresenceSignal.aggregate(
                known.map { $0.state.activity }, ultracode: ultracodeSource?() ?? false))
    }

    /// A touch on the orb goes to the conversation that most needs the person: a turn stopped to
    /// ask first, then whatever is running.
    func openOrbTarget() {
        guard
            let target = known.first(where: { $0.state == .awaitingApproval })
                ?? known.first(where: { $0.state == .live })
        else { return }
        open(target.entry)
    }

    @objc func rowClicked() {
        let index = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard index >= 0, index < rows.count else { return }
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        if index < visible.count, modifiers.contains(.shift), rows[index].isChat {
            selection.rangeSelect(visible[index], in: visible)
            lastSidebar = nil
            render()
            return
        }
        if index < visible.count, modifiers.contains(.command), rows[index].isChat {
            toggleMark(visible[index])
            lastSidebar = nil
            render()
            return
        }
        switch rows[index] {
        case .session(let model, _, _):
            open(model.entry)
        case .tab(let model, _):
            onOpenSplitTab?(model.tab)
        case .more:
            sidebarLimit += 200
            lastSidebar = nil
            render()
        case .archived:
            setArchiveShown(true)
        case .backLink:
            setArchiveShown(false)
        case .scopeLink:
            setProjectScope(nil)
        case .scopeNew:
            guard let scope = projectScope else { break }
            onNewChatInScope?(scope)
        case .addMachine:
            onAddMachine?()
        case .missed(let item):
            openMissed(sessionID: item.sessionID)
        case .searchResult(let result):
            openSearchResult(profileID: result.profileID, sessionID: result.sessionID)
        case .searchHeader:
            leaveTranscriptSearch()
        case .banner, .header, .empty, .missedHeader:
            break
        }
    }

    /// A missed notice is a place to go back to. The chat may have been deleted or its server
    /// removed since, in which case the notice is stale and goes rather than sitting there
    /// failing to open.
    private func openMissed(sessionID: String) {
        guard let entry = entries.first(where: { $0.session.id == sessionID }) else {
            ActivityInbox.clear(sessionID: sessionID)
            lastSidebar = nil
            render()
            return
        }
        open(entry)
        lastSidebar = nil
        render()
    }

    func clearMissed() {
        ActivityInbox.clearAll()
        lastSidebar = nil
        render()
    }
}
