import AppKit
import CodingAgentKit
import TailscodeCore

extension TileHost {
    func restore(_ snapshot: SplitSnapshot) -> [PaneID: SplitPaneSession] {
        guard snapshot.layout.isValid else { return [:] }
        for id in Array(panes.keys) { retire(id) }
        layout = snapshot.layout
        pinned = Set(snapshot.layout.paneIDs.filter { snapshot.isPinned($0) })
        var bindings: [PaneID: SplitPaneSession] = [:]
        for id in layout.paneIDs {
            let pane = buildPane()
            adopt(pane, as: id)
            switch snapshot.content(for: id) {
            case .chat(let session):
                bindings[id] = session
            case .web(let address):
                #if TAILSCODE_MAS
                    recordDropped("web")
                #else
                    if let target = WebTarget.classify(address) { pane.showWeb(target) }
                #endif
            case .video(let address):
                #if TAILSCODE_MAS
                    recordDropped("video")
                #else
                    if let target = VideoTarget.classify(address) { pane.showVideo(target) }
                #endif
            case .draw:
                recordDropped("draw")
            case .preview:
                if let target = snapshot.preview(for: id) { pane.showPreview(target) }
            case .empty:
                break
            }
        }
        relayout()
        return bindings
    }

    /// A restored pane this copy cannot show comes back empty, and the recorder says which kind —
    /// never what it held.
    private func recordDropped(_ kind: String) {
        Seatbelts.shared.writer?.write(
            FlightRecord(t: FlightRecord.epochMilliseconds(), ev: "restore \(kind)->empty"))
        AppLogger.lifecycle.info("restore: a \(kind) pane this copy cannot show came back empty")
    }

    func snapshot() -> SplitSnapshot {
        var contents: [String: PaneContent] = [:]
        let waiting = heldSessions?() ?? [:]
        for (id, pane) in panes {
            if let target = pane.webTarget {
                contents[id.raw] = .web(target.address)
                continue
            }
            if let target = pane.previewTarget {
                contents[id.raw] = .preview(target.address)
                continue
            }
            #if !TAILSCODE_MAS
                if let target = pane.videoTarget {
                    contents[id.raw] = .video(target.address)
                    continue
                }
            #endif
            if let entry = pane.currentEntry {
                contents[id.raw] = .chat(
                    SplitPaneSession(profileID: entry.profileID, sessionID: entry.session.id))
            } else if let session = waiting[id] ?? held[id] {
                contents[id.raw] = .chat(session)
            }
        }
        return SplitSnapshot(
            layout: layout, contents: contents,
            pinned: layout.paneIDs.filter { pinned.contains($0) }.map(\.raw))
    }

    func persist() {
        schedulePersist()
        onLayoutChanged?()
        if currentKinds() != reconciledKinds {
            reconcile()
            applyFocusStyling()
        }
    }

    func schedulePersist() {
        persistRequests += 1
        let current = snapshot()
        let slots = current.contents.values.contains { $0.kind != .chat }
        if paneCount > 1 || slots, let encoded = current.encoded {
            writer.schedule(encoded)
        } else {
            writer.schedule(nil)
        }
    }

    func flushPersistence() {
        writer.flush()
    }
}
