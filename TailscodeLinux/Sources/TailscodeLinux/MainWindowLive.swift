import CAdw
import CodingAgentKit
import Foundation
import TailscodeCore

extension MainWindow {
    /// Watches a conversation whose pane moved on, so a turn still in flight keeps its LIVE NOW seat
    /// until it settles. A listing — opencode's especially — cannot say a turn is running, so the
    /// hub keeps the one subscription alive under a `watching` lease and the edge services feed the
    /// sidebar what they read. The lease shares the conversation a pane may still hold, so handing
    /// a chat from a pane to the watch never dials a second stream.
    func keepWatching(_ entry: SessionEntry) {
        let key = LiveKey(entry)
        live.edges.note(entry)
        guard watchLeases[key.pinKey] == nil else { return }
        live.edges.setWatched(key, true)
        watchLeases[key.pinKey] = live.hub.lease(key, interest: .watching) {}
        live.hub.reevaluate(key)
    }

    func stopWatching(_ key: String) {
        guard let lease = watchLeases.removeValue(forKey: key) else {
            backgroundPresence[key] = nil
            return
        }
        live.edges.setWatched(lease.key, false)
        lease.cancel()
        backgroundPresence[key] = nil
    }

    /// The edge services read a watched conversation differently: the sidebar follows, and a turn
    /// that settled with nothing held for it ends the watch.
    func watchedPresenceChanged(_ key: LiveKey, _ reading: SessionPresence) {
        guard watchLeases[key.pinKey] != nil else { return }
        backgroundPresence[key.pinKey] = reading
        renderSidebar()
        let held = !SendQueueStore.queue(profileID: key.profileID, sessionID: key.sessionID).isEmpty
        if reading == .unobserved, !held { stopWatching(key.pinKey) }
    }

    /// A conversation's queue may drain now. The pane showing it drains it, so the message gets
    /// the echo, the rise and the failure card a send from that pane would; with no pane showing it
    /// the edges send it themselves. Exactly one surface is asked.
    func drainLive(_ key: LiveKey, _ state: ConversationState) {
        defer { live.edges.drainHandled(key) }
        let showing = panes(showing: key)
        guard let drainer = showing.first(where: { $0 === activePane }) ?? showing.first else {
            live.edges.drainInBackground(key, after: state)
            return
        }
        drainer.drainHeldQueue(state)
        for other in showing where other !== drainer { other.reloadQueue() }
    }

    /// Something took from or put back into a conversation's queue behind the panes' backs.
    func liveQueueChanged(_ key: LiveKey) {
        for pane in panes(showing: key) { pane.reloadQueue() }
    }

    /// Every pane that shows a conversation, active first.
    func panes(showing key: LiveKey) -> [ChatPane] {
        var found: [ChatPane] = []
        splitHost.eachPane { pane in
            guard pane.sessionID == key.sessionID, pane.entry?.profileID == key.profileID else {
                return
            }
            found.append(pane)
        }
        let active = activePane
        return found.filter { $0 === active } + found.filter { $0 !== active }
    }

    /// Every conversation the store is holding a message for gets a watch, so a queue written
    /// before the app quit goes when its turn yields rather than when somebody opens the chat. A
    /// chat a pane is showing drains through that pane; a held chat the listing no longer has
    /// waits for a listing that does.
    func wakeHeldQueues() {
        for record in SendQueueStore.all() {
            guard
                let entry = entries.first(where: {
                    $0.session.id == record.sessionID && $0.profileID == record.profileID
                })
            else { continue }
            let key = LiveKey(entry)
            guard watchLeases[key.pinKey] == nil, panes(showing: key).isEmpty else { continue }
            keepWatching(entry)
        }
    }
}

extension MainWindow {
    /// The drive verbs that read and prove the live runtime: `live` prints what every pane owns
    /// (lease, drain slot, clocks, parked), `lifetime` closes a pane mid-rise mid-stream and checks
    /// that the pane object is actually freed, and `slotswap` turns a chat pane into a slot and back
    /// and checks that each mode let go of the other's resources.
    func driveLive(_ verb: String, _ argument: String) {
        switch verb {
        case "live":
            reportLive()
        case "lifetime":
            proveLifetime()
        case "slotswap":
            proveSlotSwap()
        default:
            break
        }
    }

    private func say(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    private func reportLive() {
        for (index, pane) in splitHost.orderedPanes.enumerated() {
            say("LIVE \(index) \(pane.liveReading)")
        }
        let keys = live.hub.keys
        let streaming = keys.filter { live.hub.isStreaming($0) }.count
        let leases = keys.map { live.hub.leaseCount($0) }.reduce(0, +)
        say(
            "LIVEHUB keys=\(keys.count) streaming=\(streaming) leases=\(leases) "
                + "watches=\(watchLeases.count) slots=\(live.drain.count)")
    }

    private func proveLifetime() {
        guard let entry = entries.first else {
            say("LIFETIME fail no entries")
            return
        }
        _ = perform(.splitPane(.horizontal))
        let pane = activePane
        let watch = WeakPane(pane)
        pane.open(entry)
        Gtk.after(1500) { [weak self] in
            guard let self, let pane = watch.pane else {
                FileHandle.standardOutput.write(Data("LIFETIME fail pane gone before send\n".utf8))
                return
            }
            pane.sendComposed("Lifetime check: a long answer, please.")
            Gtk.after(150) { [weak self] in
                guard let self, let pane = watch.pane else { return }
                let before = pane.liveReading
                _ = self.perform(.closeSplit)
                let after = watch.pane.map { "chat=\($0.chatLife.count) stream=\($0.streamLife.count) \($0.liveReading)" } ?? "freed"
                self.say("LIFETIME closed before=[\(before)] after=[\(after)]")
                Gtk.after(1500) { [weak self] in
                    guard let self else { return }
                    self.say(watch.pane == nil ? "LIFETIME ok weak=nil" : "LIFETIME fail pane still alive")
                    self.reportLive()
                }
            }
        }
    }

    private func proveSlotSwap() {
        guard let entry = entries.first else {
            say("SLOTSWAP fail no entries")
            return
        }
        let pane = activePane
        pane.open(entry)
        Gtk.after(1200) { [weak self] in
            guard let self else { return }
            let asChat = pane.lease != nil && pane.sessionID != nil
            pane.showVideo(nil)
            let asSlot = pane.lease == nil && pane.sessionID == nil && pane.isWatching
                && gtk_widget_is_visible(pane.composerScroller) == 0
            pane.open(entry)
            Gtk.after(800) { [weak self] in
                guard let self else { return }
                let back = pane.lease != nil && !pane.isSlot
                    && gtk_widget_is_visible(pane.composerScroller) != 0
                self.say(
                    (asChat && asSlot && back ? "SLOTSWAP ok" : "SLOTSWAP fail")
                        + " chat=\(asChat) slot=\(asSlot) back=\(back)")
            }
        }
    }
}

/// A weak hold on a pane that a timer can carry, for the deallocation check.
private final class WeakPane: @unchecked Sendable {
    weak var pane: ChatPane?
    init(_ pane: ChatPane) { self.pane = pane }
}

extension MainWindow {
    /// Opens several chats into their panes one per frame rather than all in one slice: each open
    /// builds its pane's first screenful of rows, and five of them in one frame was one stall the
    /// size of all five. The first opens at once; the rest follow, each after the previous one has
    /// been laid out and painted.
    func openInTurns(_ pairs: [(PaneID, SessionEntry)]) {
        guard let (first, entry) = pairs.first else { return }
        splitHost.panes[first]?.open(entry)
        let rest = Array(pairs.dropFirst())
        guard !rest.isEmpty, let root = splitHost.panes[first]?.frame else { return }
        FillTurns.take(on: root) { [weak self] in self?.openInTurns(rest) }
    }
}
