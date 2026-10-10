import AppKit
import CodingAgentKit
import TailscodeCore

/// Every state the viewer has, put in front of a window with no conversation behind it that holds a
/// picture: `--open viewer[:pictures|loading|clip]`. The pictures are drawn here, as the Studio's demo
/// draws them, so nothing crosses a network and nothing a person made is touched; a debug build can point
/// `TAILSCODE_VIEWER_ART` at a folder of PNGs to look at real ones.
@MainActor
enum MediaViewerDemo {
    private static let drawnCount = 7

    static func open(_ state: String, in window: NSWindow?) {
        switch state {
        case "loading": loading(in: window)
        case "clip": clip(in: window)
        default: pictures(in: window)
        }
    }

    private static func pictures(in window: NSWindow?) {
        let items = made()
        guard let first = items.first else { return }
        MediaViewer.shared.showPictures(
            items: items, startKey: first.key, host: window, fetch: { _, _ in }, toast: nil)
    }

    private static func loading(in window: NSWindow?) {
        let item = ImageViewer.Item(
            key: "demo-viewer:loading", name: "tailscode_00071_.png",
            reference: FileReference(path: "/nonexistent/demo-viewer-loading"))
        MediaViewer.shared.showPictures(
            items: [item], startKey: item.key, host: window, fetch: { _, _ in }, toast: nil)
    }

    private static func clip(in window: NSWindow?) {
        guard let url = StudioVideoDemo.clipFile() else { return }
        MediaViewer.shared.play(
            clip: url, title: url.lastPathComponent, host: window, save: { _ in }, share: { _ in })
    }

    private static func made() -> [ImageViewer.Item] {
        if let folder = artFolder() {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder))?
                .filter { $0.hasSuffix(".png") }.sorted() ?? []
            let items = files.prefix(8).compactMap { name -> ImageViewer.Item? in
                let path = (folder as NSString).appendingPathComponent(name)
                guard let data = FileManager.default.contents(atPath: path), let entry = ImageStore.decode(data)
                else { return nil }
                let key = "demo-viewer:\(name)"
                ImageStore.shared.store(entry, forKey: key)
                return ImageViewer.Item(key: key, name: name, reference: FileReference(path: path))
            }
            if !items.isEmpty { return Array(items) }
        }
        return (0..<drawnCount).compactMap { index -> ImageViewer.Item? in
            guard let data = StudioDemo.png(StudioDemo.bokeh(seed: index, width: 1600, height: 1000)),
                let entry = ImageStore.decode(data)
            else { return nil }
            let key = "demo-viewer:\(index)"
            ImageStore.shared.store(entry, forKey: key)
            let name = String(format: "tailscode_%05d_.png", 71 - index)
            return ImageViewer.Item(key: key, name: name, reference: FileReference(path: "/nonexistent/\(key)"))
        }
    }

    private static func artFolder() -> String? {
        #if DEBUG
            return ProcessInfo.processInfo.environment["TAILSCODE_VIEWER_ART"].flatMap { $0.isEmpty ? nil : $0 }
        #else
            return nil
        #endif
    }
}
