import CodingAgentKit
import Foundation
import TailscodeCore

extension ChatPane {
    /// A press on a named video's tile or a song's button, or a hand on a song's bar: the video
    /// opens on the clip sheet, the song plays, pauses or moves where it is. A file not yet read,
    /// or read and failed, is read again.
    func playMedia(_ reference: FileReference, key: String, at fraction: Double? = nil) {
        let deck = MediaDeck.shared
        guard let kind = MediaKind.of(reference), kind != .picture else { return }
        guard case .ready(let ready)? = deck.state(key, url: reference.url) else {
            deck.read(reference, key: key, backend: backend, force: true)
            return
        }
        let name = MediaTileReading.name(of: reference)
        switch kind {
        case .video:
            ClipSheet.present(
                name: name, source: ready.source, duration: ready.duration,
                playhead: reference.url ?? key,
                failed: { Gtk.onMain { MediaDeck.shared.forget(key) } },
                notice: { [weak self] text in Gtk.onMain { [weak self] in self?.setNotice(text) } })
        case .audio:
            deck.toggleAudio(key, name: name, owner: ObjectIdentifier(self), at: fraction)
        case .picture:
            break
        }
    }

    /// A picture a reply named turned out not to be there: the rows are built again, and it stands
    /// as one quiet line where its tile was.
    func mediaMissed() {
        guard let state = lastState else { return }
        if lease != nil {
            feed.rebuild(state)
        } else if !isParked {
            apply(state: state, rows: paneRows(for: state))
        }
    }
}
