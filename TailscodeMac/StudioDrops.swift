import AppKit
import ImageIO
import TailscodeCore
import UniformTypeIdentifiers

/// What a drag carried that the Studio can start a picture from. A tile dragged from the shelf names
/// itself, so the reference is the machine's own file and nothing travels; a file is read where it
/// lies; pixels with no file behind them — a picture copied out of a browser — are written to one,
/// because the machine is handed a file wherever the picture came from.
enum StudioDrop {
    case tile(String)
    case file(URL)
    case pixels(Data)
    case promised(NSFilePromiseReceiver)

    /// The private type a shelf tile adds beside its file promise, so a drag that never leaves the
    /// window is read as the tile it is rather than as a file that has to be written out first.
    static let tileType = NSPasteboard.PasteboardType("com.guitaripod.tailscode.studio.tile")

    static var registered: [NSPasteboard.PasteboardType] {
        [tileType, .fileURL, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map {
            NSPasteboard.PasteboardType($0)
        }
    }

    /// The first picture a pasteboard holds, in the order a hand means them.
    static func read(_ pasteboard: NSPasteboard) -> StudioDrop? {
        if let id = pasteboard.string(forType: tileType) { return .tile(id) }
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: [UTType.image.identifier]]
        ) as? [URL], let first = urls.first {
            return .file(first)
        }
        if let receivers = pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
            let first = receivers.first
        {
            return .promised(first)
        }
        if let png = pasteboard.data(forType: .png) { return .pixels(png) }
        if let tiff = pasteboard.data(forType: .tiff), let png = Self.png(fromTIFF: tiff) {
            return .pixels(png)
        }
        return nil
    }

    /// Whether a drag is worth lighting the drop target for.
    static func accepts(_ pasteboard: NSPasteboard) -> Bool { read(pasteboard) != nil }

    static func png(fromTIFF data: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// The largest picture a reference may be, so a drop of a raw photograph cannot stall the
    /// machine's upload — the same ceiling an attachment to a chat has.
    static let ceiling = 24 * 1024 * 1024

    /// Puts what was dropped where the next render will start from.
    @MainActor
    static func hold(_ drop: StudioDrop, in studio: MacImageStudio, then done: @escaping @MainActor (Bool) -> Void) {
        switch drop {
        case .tile(let id):
            done(holdTile(id, in: studio))
        case .file(let url):
            guard isUsable(url) else { return done(false) }
            studio.hold(ImageGenReference(path: url.path))
            done(true)
        case .pixels(let data):
            guard data.count <= ceiling else { return done(false) }
            studio.hold(data: data, named: "dropped.png")
            done(true)
        case .promised(let receiver):
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("tailscode-drops", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            receiver.receivePromisedFiles(
                atDestination: folder, options: [:], operationQueue: .main
            ) { url, error in
                MainActor.assumeIsolated {
                    guard error == nil, isUsable(url) else { return done(false) }
                    studio.hold(ImageGenReference(path: url.path))
                    done(true)
                }
            }
        }
    }

    @MainActor
    private static func holdTile(_ id: String, in studio: MacImageStudio) -> Bool {
        if let made = studio.slot.pictures.first(where: { ($0.remoteName ?? $0.path) == id }) {
            studio.hold(ImageGenReference(path: made.path, kept: made.kept))
            return true
        }
        if let item = studio.library.item(named: id) {
            studio.hold(kept: item)
            return true
        }
        return false
    }

    private static func isUsable(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image)
        else { return false }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return size > 0 && size <= ceiling
    }

    /// The shape of a picture on disk, read from its header — which is all the stage needs to size
    /// the rectangle an edit will land in before anything is decoded.
    static func aspect(ofFileAt path: String) -> Double? {
        guard !path.isEmpty, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Double,
            let height = properties[kCGImagePropertyPixelHeight] as? Double,
            width > 0, height > 0
        else { return nil }
        return width / height
    }
}
