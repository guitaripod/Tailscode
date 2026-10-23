import AppKit
import TailscodeCore

extension SplitPaneHost {
    func snapshot() -> SplitSnapshot {
        var sessions: [String: SplitPaneSession] = [:]
        var videos: [String: String] = [:]
        var pages: [String: String] = [:]
        var draws: [String: String] = [:]
        let held = heldSessions?() ?? [:]
        for (id, pane) in panes {
            if let endpoint = pane.drawEndpoint {
                draws[id.raw] = endpoint.address
                continue
            }
            if let target = pane.webTarget {
                pages[id.raw] = target.address
                continue
            }
            #if !TAILSCODE_MAS
                if let target = pane.videoTarget {
                    videos[id.raw] = target.address
                    continue
                }
            #endif
            guard let entry = pane.currentEntry else {
                if let session = held[id] { sessions[id.raw] = session }
                continue
            }
            sessions[id.raw] = SplitPaneSession(
                profileID: entry.profileID, sessionID: entry.session.id)
        }
        return SplitSnapshot(
            layout: layout, sessions: sessions, videos: videos, pages: pages, draws: draws)
    }

    /// The same key and shape the Linux desktop persists, so both restore the same arrangement.
    /// A lone pane clears the record: the plain window needs no layout file.
    func persist() {
        schedulePersist()
        onLayoutChanged?()
    }

    func schedulePersist() {
        persistRequests += 1
        let current = snapshot()
        if paneCount > 1 || !current.videos.isEmpty || !current.pages.isEmpty
            || !current.draws.isEmpty,
            let encoded = current.encoded
        {
            writer.schedule(encoded)
        } else {
            writer.schedule(nil)
        }
    }

    /// Writes the waiting layout now; every exit path calls it.
    func flushPersistence() {
        writer.flush()
    }
}
