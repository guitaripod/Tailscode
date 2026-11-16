import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// What can be done with a picture's own bytes on this desk, in one place: the viewer and a tile's
/// menu hand a picture to the clipboard and to Downloads the same way and say the same words.
enum PictureDesk {
    /// Puts the picture on the clipboard as a picture and returns the words that say so.
    static func copy(_ data: Data) -> String {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            tailscode_clipboard_set_image_png(base, gsize(data.count))
        }
        return ImageGenWords.copiedNotice
    }

    /// Writes the picture into Downloads under its own name and returns the words that say where
    /// it went, or that it could not be written.
    static func save(_ data: Data, named name: String) -> String {
        let target = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(ImageBytes.exportFilename(name, data: data))
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let wrote = (try? data.write(to: target)) != nil
        return wrote
            ? Localized.text("Saved %@", target.path)
            : Localized.text("Could not write %@", target.path)
    }

    /// What is said when a picture's bytes are not on this device yet.
    static var stillLoading: String { Localized.text("Still loading — try again in a moment.") }
}
