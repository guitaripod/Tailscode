import CodingAgentKit
import Foundation
import TailscodeCore

extension ChatPane {
    /// A press on a named video's tile or a song's button: the video opens on the clip sheet, the
    /// song plays or pauses where it is. A file not yet read, or read and failed, is read again.
    func playMedia(_ reference: FileReference, key: String) {
        let deck = MediaDeck.shared
        guard let kind = MediaKind.of(reference), kind != .picture else { return }
        guard case .ready(let ready)? = deck.state(key, url: reference.url) else {
            deck.read(reference, key: key, backend: backend, force: true)
            return
        }
        switch kind {
        case .video:
            let name = MediaTileReading.name(of: reference)
            ClipSheet.present(
                name: name, source: ready.source,
                failed: { Gtk.onMain { MediaDeck.shared.forget(key) } },
                notice: { [weak self] text in Gtk.onMain { [weak self] in self?.setNotice(text) } })
        case .audio:
            deck.toggleAudio(key, owner: ObjectIdentifier(self))
        case .picture:
            break
        }
    }
}
