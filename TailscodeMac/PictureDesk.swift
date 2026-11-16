import AppKit
import CodingAgentKit
import TailscodeCore
import UniformTypeIdentifiers

/// What can be done with a picture's own bytes on this Mac, in one place: the viewer and a tile's
/// menu hand a picture to the pasteboard and to Downloads the same way and say the same words.
@MainActor
enum PictureDesk {
    /// What is said when a picture's bytes are not on this Mac yet.
    static var stillLoading: String { Localized.text("Still loading — try again in a moment.") }

    /// Puts the picture `key` on the pasteboard, as the server's own bytes when it has them, and
    /// returns the words that say what happened.
    static func copy(key: String) -> String {
        guard let entry = ImageStore.shared.entry(forKey: key) else { return stillLoading }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !entry.data.isEmpty, let ext = ImageBytes.sniffedExtension(entry.data),
            let type = UTType(filenameExtension: ext)
        {
            pasteboard.setData(entry.data, forType: NSPasteboard.PasteboardType(type.identifier))
        } else {
            pasteboard.writeObjects([entry.image])
        }
        return ImageGenWords.copiedNotice
    }

    /// Writes the picture `key` into the person's Downloads under `name` and returns the words
    /// that say where it went. The folder is asked of the file manager rather than built out of a
    /// home path: inside a container the home directory is the container, and a hand-built path
    /// writes the picture where nobody will look for it under a notice naming a folder it is not in.
    static func save(key: String, named name: String) -> String {
        guard let entry = ImageStore.shared.entry(forKey: key) else { return stillLoading }
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        else { return Localized.text("This Mac has no Downloads folder to write to.") }
        let target = downloads.appendingPathComponent(ImageBytes.exportFilename(name, data: entry.data))
        let wrote = (try? entry.data.write(to: target)) != nil
        return wrote ? Localized.text("Saved %@", target.path) : Localized.text("Could not write %@", target.path)
    }

    /// The menu a picture answers a right click with where it stands (`PictureVerbs`). `open`
    /// opens it in the viewer and `say` is where the words of a copy or a save go.
    static func menu(
        key: String, name: String, reference: FileReference, open: @escaping () -> Void,
        say: @escaping (String) -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        for verb in PictureVerbs.pointer(hasPath: reference.path != nil) {
            let item = ClosureMenuItem(title: verb.title) {
                switch verb {
                case .open: open()
                case .copy: say(copy(key: key))
                case .saveToDownloads: say(save(key: key, named: name))
                case .copyPath:
                    guard let path = reference.path else { return }
                    RowKit.copyToClipboard(path)
                    say(Localized.text("Copied"))
                case .saveToPhotos, .saveToFiles, .share: break
                }
            }
            menu.addItem(item)
        }
        return menu
    }
}
