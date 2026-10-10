import CAdw
import CodingAgentKit
import Foundation
import TailscodeCore

/// The conversation's pictures as the viewer's pages: every image of the transcript, in reading
/// order, each painted from the transcript's own cache and fetched when it is not there yet. The
/// window this used to be is gone; the pages are shown by ``MediaViewer``, as a sheet over the
/// conversation.
enum ImageGallery {
    struct Item {
        let key: String
        let name: String
        let reference: FileReference
    }

    /// Opens the viewer over `items`, landed on `startKey`. The window every viewer belongs to is
    /// the one main window, so `parent` only says which conversation the pictures came from.
    static func present(
        items: [Item], startKey: String, parent: UnsafeMutablePointer<GtkWidget>?,
        context: TranscriptContext,
        fetch: @escaping @Sendable (FileReference, String) -> Void,
        notice: @escaping @Sendable (String) -> Void
    ) {
        let pages = items.map { item in
            MediaViewer.Item(
                key: item.key, name: item.name, facts: nil, tooltip: nil,
                texture: { context.textures[item.key] ?? 0 },
                dimensions: { context.imageDimensions[item.key] },
                original: { context.imageData[item.key] },
                fetch: { fetch(item.reference, item.key) },
                release: {}, actions: [])
        }
        MediaViewer.present(
            items: pages, startKey: startKey,
            landing: { handler in
                let previous = context.onImageStored
                context.onImageStored = { key in
                    previous?(key)
                    handler(key)
                }
                return { context.onImageStored = previous }
            }, notice: notice)
    }
}
