import AppKit
import TailscodeCore
import UniformTypeIdentifiers

/// What both lanes do with the bytes the machine wrote: offer them to a save panel under a name,
/// and say where they went. The bytes are always the machine's own, never a re-encode of what a
/// stage drew.
@MainActor
enum StudioFiles {
    static func save(
        data: Data, name: String, window: NSWindow?, report: @escaping @MainActor (String) -> Void
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        if let type = UTType(filenameExtension: (name as NSString).pathExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.canCreateDirectories = true
        let write: (NSApplication.ModalResponse) -> Void = { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                if (try? data.write(to: url, options: .atomic)) != nil {
                    report(ImageGenWords.savedNotice(path: url.path))
                } else {
                    report(Localized.text("Could not write %@", url.path))
                }
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: write)
        } else {
            write(panel.runModal())
        }
    }

    /// Hands a file to the system's share picker, anchored near the foot of the view that holds what
    /// is being shared.
    static func share(_ url: URL, from anchor: NSView) {
        let picker = NSSharingServicePicker(items: [url])
        let rect = NSRect(x: anchor.bounds.midX - 1, y: anchor.bounds.maxY - 80, width: 2, height: 2)
        picker.show(relativeTo: rect, of: anchor, preferredEdge: .minY)
    }
}
