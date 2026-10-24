import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension AgentsWindow {
    func toggleSelection(_ key: String) {
        if selectedKey == key, selectedLane == nil { deselect() } else { select(key: key) }
    }

    func select(key: String, lane: String? = nil) {
        let changed = selectedKey != key
        selectedKey = key
        selectedLane = lane
        if changed { selectionSeen = false }
        boardView.applySelection(key)
        hourView.select(id: lane)
        if changed {
            facts = nil
            watchFacts(key)
        }
        refreshPeek(now: Date())
    }

    func select(lane: AgentHourLane) {
        select(key: lane.profileID + "/" + lane.sessionID, lane: lane.id)
    }

    func deselect() {
        selectedKey = nil
        selectedLane = nil
        facts = nil
        factsTask?.cancel()
        factsTask = nil
        pendingFacts = nil
        boardView.applySelection(nil)
        hourView.select(id: nil)
        gtk_revealer_set_reveal_child(op(revealer), 0)
    }

    func watchFacts(_ key: String) {
        factsTask?.cancel()
        guard isLive else { return }
        let source = source
        factsTask = Task { [weak self] in
            let stream = await source.facts(for: key)
            for await next in stream {
                if Task.isCancelled { break }
                Gtk.onMain { [weak self] in self?.heard(key, next) }
            }
        }
    }

    /// What the tower says of the agent a peek shows, at most four times a second: a conversation
    /// that streams changes its facts far faster than a person reads them.
    func heard(_ key: String, _ next: AgentFacts?) {
        guard key == selectedKey, isLive else { return }
        pendingFacts = (key, next)
        guard !factsFlush else { return }
        factsFlush = true
        Gtk.after(250) { [weak self] in self?.flushFacts() }
    }

    func flushFacts() {
        factsFlush = false
        guard isLive, let pending = pendingFacts, pending.key == selectedKey else { return }
        pendingFacts = nil
        facts = pending.facts
        refreshPeek(now: Date())
    }

    func applyFactsNow(_ next: AgentFacts?) {
        facts = next
        refreshPeek(now: Date())
    }

    func subject(for key: String) -> AgentPeekSubject? {
        if let found = AgentPeekSubject.find(key, in: board) { return found }
        guard let laneID = selectedLane, let lane = hourView.lane(for: laneID) else { return nil }
        let top = lane.parentID.flatMap { hourView.lane(for: $0) } ?? lane
        return AgentPeekSubject.lane(top)
    }

    func refreshPeek(now: Date) {
        guard let key = selectedKey, let subject = subject(for: key) else { return }
        peek.show(subject, facts: facts, now: now)
        gtk_revealer_set_reveal_child(op(revealer), 1)
    }

    /// The nth thing on the board, top to bottom in Now and the nth lane in Hour: what a drive verb
    /// and the harness mean by "the first one".
    func peek(at index: Int) {
        if mode == .hour {
            hourView.chooseLane(at: index)
            return
        }
        let keys = boardView.orderedKeys
        guard keys.indices.contains(index) else {
            wantedIndex = index
            return
        }
        select(key: keys[index])
    }

    var stateLine: String {
        let counts = boardView.counts()
        let kinds = AgentsBoardView.Kind.allCases.map { "\($0.title)=\(counts[$0] ?? 0)" }
        return "mode=\(mode) live=\(isLive) \(kinds.joined(separator: " ")) lanes=\(hourView.laneCount) selected=\(selectedKey ?? "-") peek=\(peekRevealed) boards=\(boardsApplied)"
    }

    func actionChanged(_ key: String) {
        boardView.refresh(key: key, now: Date())
        if peek.key == key { peek.refreshControls() }
    }

    func toast(_ text: String) {
        guard let toast = adw_toast_new(text) else { return }
        adw_toast_overlay_add_toast(op(UnsafeMutableRawPointer(toasts)), toast)
    }

    var peekRevealed: Bool { gtk_revealer_get_reveal_child(op(revealer)) != 0 }
    var inspectorWidth: Int32 { gtk_widget_get_width(peek.widget) }
}
