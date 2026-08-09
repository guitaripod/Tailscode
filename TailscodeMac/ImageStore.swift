import AppKit
import CodingAgentKit
import TailscodeCore

/// A decoded picture crossing back from the decode task to the main actor, exactly once.
struct DecodedImage: @unchecked Sendable {
    let image: NSImage
    let data: Data
    let pixelWidth: Int
    let pixelHeight: Int
}

/// The pictures the transcript has shown: decoded ones in memory keyed by row so a repaint is a
/// lookup, and every byte ever fetched on disk keyed by the server path — a conversation reopened
/// shows its pictures from the first frame, and a bridge that takes thirty seconds to answer
/// costs each picture exactly once.
@MainActor
final class ImageStore {
    static let shared = ImageStore()

    private var entries: [String: DecodedImage] = [:]
    private var order: [String] = []
    /// The gallery's ear while it is open: a page whose bytes were still being fetched repaints
    /// the moment they land.
    var onStored: ((String) -> Void)?

    private init() {}

    func entry(forKey key: String) -> DecodedImage? {
        entries[key]
    }

    /// Decoded pictures are kept across chat switches, bounded: past the cap the least recently
    /// decoded is released — its bytes are still on disk, one frame away.
    func store(_ entry: DecodedImage, forKey key: String) {
        entries[key] = entry
        onStored?(key)
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > 48 {
            entries[order.removeFirst()] = nil
        }
    }

    /// The decode, off the main actor: a large PNG decoded on the UI loop is a visible freeze.
    nonisolated static func decode(_ data: Data) -> DecodedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let image = NSImage(cgImage: cgImage, size: .zero)
        return DecodedImage(
            image: image, data: data, pixelWidth: cgImage.width, pixelHeight: cgImage.height)
    }
}

/// The bytes of every picture on disk, mirroring the Linux cache's shape under this platform's
/// cache root. Keyed by the server path of the file — the same screenshot re-read in a later
/// turn is the same bytes.
enum ImageDisk {
    private static let maxFiles = 256

    private static var directory: URL {
        let base =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Caches")
        return base.appendingPathComponent("tailscode/images", isDirectory: true)
    }

    static func identity(for reference: FileReference) -> String? {
        guard let ident = reference.path ?? reference.url ?? reference.filename else { return nil }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in ident.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    static func load(_ reference: FileReference) -> Data? {
        guard let identity = identity(for: reference) else { return nil }
        let file = directory.appendingPathComponent(identity)
        guard let data = try? Data(contentsOf: file) else { return nil }
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: file.path)
        return data
    }

    static func save(_ data: Data, for reference: FileReference) {
        guard let identity = identity(for: reference) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(identity), options: .atomic)
        prune()
    }

    /// Oldest-untouched pictures fall out first; `load` refreshes what is still being looked at.
    private static func prune() {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles), files.count > maxFiles
        else { return }
        let dated = files.map { file in
            (
                file,
                (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
            )
        }.sorted { $0.1 < $1.1 }
        for (file, _) in dated.prefix(files.count - maxFiles) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// A picture in the flow is a thumbnail, not a poster: the transcript is for reading, and a
/// picture in it is a reference — small, scaled to fit, one click from the full-window viewer.
@MainActor
enum ImageRowView {
    static func make(
        _ reference: FileReference, mine: Bool, key: String, context: TranscriptContext
    ) -> NSView {
        let thumbWidth = CGFloat(ImagePreview.deskBound(ImagePreview.deskWidth, mine: mine))
        let thumbHeight = CGFloat(ImagePreview.deskBound(ImagePreview.deskHeight, mine: mine))
        let name =
            reference.filename
            ?? reference.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "file"
        let isImage = (reference.mime ?? "").hasPrefix("image/")
        guard isImage else {
            return RowKit.label(
                "📎 \(name)", font: MacTheme.Font.caption(), color: MacTheme.Color.secondaryLabel)
        }
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        column.translatesAutoresizingMaskIntoConstraints = false

        if let entry = ImageStore.shared.entry(forKey: key) {
            let scale = min(
                thumbWidth / CGFloat(max(1, entry.pixelWidth)),
                thumbHeight / CGFloat(max(1, entry.pixelHeight)), 1)
            let imageView = NSImageView(image: entry.image)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = 6
            imageView.layer?.masksToBounds = true
            imageView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(
                    equalToConstant: CGFloat(entry.pixelWidth) * scale),
                imageView.heightAnchor.constraint(
                    equalToConstant: CGFloat(entry.pixelHeight) * scale),
            ])
            let open = context.openImage
            imageView.addGestureRecognizer(
                ClickRelay { open?(key, name) })
            column.addArrangedSubview(imageView)
            column.addArrangedSubview(
                RowKit.label(
                    "\(name) · \(entry.pixelWidth)×\(entry.pixelHeight)",
                    font: MacTheme.Font.caption(), color: MacTheme.Color.secondaryLabel))
        } else {
            let frame = NSView()
            frame.wantsLayer = true
            frame.layer?.backgroundColor = MacTheme.Color.canvasRaised.cgColor
            frame.layer?.cornerRadius = 6
            frame.translatesAutoresizingMaskIntoConstraints = false
            let label = RowKit.label(
                Localized.text("🖼 %@ — loading…", name), font: MacTheme.Font.caption(),
                color: MacTheme.Color.tertiaryLabel)
            frame.addSubview(label)
            NSLayoutConstraint.activate([
                frame.widthAnchor.constraint(equalToConstant: thumbWidth),
                frame.heightAnchor.constraint(equalToConstant: thumbHeight),
                label.centerXAnchor.constraint(equalTo: frame.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: frame.centerYAnchor),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: frame.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(lessThanOrEqualTo: frame.trailingAnchor, constant: -6),
            ])
            column.addArrangedSubview(frame)
            context.requestImage?(reference, key)
        }
        return column
    }

    /// A click gesture that carries its closure, for image views built in static functions.
    private final class ClickRelay: NSClickGestureRecognizer {
        private let handler: () -> Void

        init(handler: @escaping () -> Void) {
            self.handler = handler
            super.init(target: nil, action: nil)
            target = self
            action = #selector(fire)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        @objc private func fire() {
            handler()
        }
    }
}

/// A gallery over every picture in the conversation rather than a single-image window: paged
/// with ‹ › or the arrow keys, magnifiable between fit and true 1:1 screen pixels with a
/// double-click or `z`, and a save that hands over the exact bytes the server sent under their
/// sniffed extension. Pages whose bytes are still being fetched paint the moment they land.
@MainActor
final class ImageViewer: NSObject {
    struct Item {
        let key: String
        let name: String
        let reference: FileReference
    }

    private let items: [Item]
    private var index: Int
    private let fetch: (FileReference, String) -> Void
    private let toast: ((String) -> Void)?
    private let previousEar: ((String) -> Void)?

    private var window: FloatingWindow?
    private let scrollView = NSScrollView()
    private let imageView = NSImageView()
    private let counterLabel = RowKit.label(
        "", font: MacTheme.Font.caption(), color: MacTheme.Color.secondaryLabel)
    private let zoomButton = NSButton(title: "", target: nil, action: nil)
    private var oneToOne = false
    private static var open: ImageViewer?

    static func present(
        items: [Item], startKey: String, host: NSWindow?,
        fetch: @escaping (FileReference, String) -> Void, toast: ((String) -> Void)?
    ) {
        guard !items.isEmpty else { return }
        let viewer = ImageViewer(items: items, startKey: startKey, fetch: fetch, toast: toast)
        open = viewer
        viewer.presentWindow(host: host)
    }

    private init(
        items: [Item], startKey: String, fetch: @escaping (FileReference, String) -> Void,
        toast: ((String) -> Void)?
    ) {
        self.items = items
        self.index = items.firstIndex { $0.key == startKey } ?? 0
        self.fetch = fetch
        self.toast = toast
        self.previousEar = ImageStore.shared.onStored
        super.init()
    }

    private func presentWindow(host: NSWindow?) {
        let hostFrame = host?.frame ?? NSRect(x: 0, y: 0, width: 1080, height: 800)
        let width = max(960, hostFrame.width - 120)
        let height = max(700, hostFrame.height - 100)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        scrollView.documentView = imageView
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.02
        scrollView.maxMagnification = 12
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        var barViews: [NSView] = []
        if items.count > 1 {
            barViews.append(
                RowKit.ActionButton(title: "‹") { [weak self] in self?.step(-1) })
            barViews.append(
                RowKit.ActionButton(title: "›") { [weak self] in self?.step(1) })
        }
        zoomButton.target = self
        zoomButton.action = #selector(toggleZoom)
        zoomButton.bezelStyle = .rounded
        barViews.append(zoomButton)
        barViews.append(counterLabel)
        barViews.append(RowKit.spacer())
        let save = RowKit.ActionButton(title: Localized.text("Save to Downloads")) {
            [weak self] in self?.save()
        }
        save.bezelStyle = .rounded
        barViews.append(save)

        let bar = NSStackView(views: barViews)
        bar.orientation = .horizontal
        bar.spacing = MacTheme.Spacing.s
        bar.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.s, left: MacTheme.Spacing.l, bottom: MacTheme.Spacing.m,
            right: MacTheme.Spacing.l)
        bar.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView(views: [scrollView, bar])
        column.orientation = .vertical
        column.alignment = .width
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false

        let window = GalleryWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = column
        window.onKey = { [weak self] key in self?.handleKey(key) ?? false }
        window.onDoubleClick = { [weak self] in self?.toggleZoom() }
        self.window = window
        ImageStore.shared.onStored = { [weak self] key in
            guard let self, key == self.items[self.index].key else { return }
            self.render()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowClosed), name: NSWindow.willCloseNotification,
            object: window)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowResized), name: NSWindow.didResizeNotification,
            object: window)
        if let host {
            window.setFrameOrigin(
                NSPoint(x: host.frame.midX - width / 2, y: host.frame.midY - height / 2))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in self?.render() }
    }

    @objc private func windowClosed() {
        ImageStore.shared.onStored = previousEar
        Self.open = nil
    }

    @objc private func windowResized() {
        guard !oneToOne else { return }
        applyMagnification()
    }

    private func handleKey(_ key: String) -> Bool {
        switch key {
        case "left": step(-1)
        case "right": step(1)
        case "z": toggleZoom()
        case "s": save()
        default: return false
        }
        return true
    }

    private func step(_ delta: Int) {
        guard !items.isEmpty else { return }
        index = (index + delta + items.count) % items.count
        oneToOne = false
        render()
    }

    @objc private func toggleZoom() {
        oneToOne.toggle()
        applyMagnification()
    }

    private func render() {
        let item = items[index]
        let counter = items.count > 1 ? "\(index + 1)/\(items.count)" : ""
        guard let entry = ImageStore.shared.entry(forKey: item.key) else {
            window?.title = item.name
            counterLabel.stringValue = [counter, Localized.text("Loading…")]
                .filter { !$0.isEmpty }.joined(separator: "  ·  ")
            imageView.image = nil
            fetch(item.reference, item.key)
            return
        }
        window?.title = item.name
        counterLabel.stringValue = [counter, "\(entry.pixelWidth)×\(entry.pixelHeight)"]
            .filter { !$0.isEmpty }.joined(separator: "  ·  ")
        imageView.image = entry.image
        imageView.setFrameSize(
            NSSize(width: CGFloat(entry.pixelWidth), height: CGFloat(entry.pixelHeight)))
        applyMagnification()
    }

    /// Fit shows the whole picture; 1:1 shows one image pixel per screen pixel — the document
    /// view is sized in image pixels, so that is a magnification of 1/backingScale.
    private func applyMagnification() {
        zoomButton.title = oneToOne ? Localized.text("Fit") : "1:1"
        guard imageView.image != nil else { return }
        if oneToOne {
            let scale = window?.backingScaleFactor ?? 2
            scrollView.magnification = 1 / scale
        } else {
            scrollView.magnify(toFit: imageView.frame)
        }
    }

    private func save() {
        let item = items[index]
        guard let entry = ImageStore.shared.entry(forKey: item.key) else {
            toast?(Localized.text("Still loading — try again in a moment."))
            return
        }
        let filename = ImageBytes.exportFilename(item.name, data: entry.data)
        let target = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(filename)
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let wrote = (try? entry.data.write(to: target)) != nil
        toast?(
            wrote
                ? Localized.text("Saved %@", target.path)
                : Localized.text("Could not write %@", target.path))
    }
}

/// The gallery's window: arrows page, `z` zooms, `s` saves, Esc closes, a double-click anywhere
/// toggles fit and 1:1.
@MainActor
private final class GalleryWindow: FloatingWindow {
    var onKey: ((String) -> Bool)?
    var onDoubleClick: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let name: String
        switch event.keyCode {
        case 123: name = "left"
        case 124: name = "right"
        default: name = event.charactersIgnoringModifiers ?? ""
        }
        if onKey?(name) == true { return }
        super.keyDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() }
        super.mouseUp(with: event)
    }
}

/// A window unowned by any controller — a picture viewer, a summary reader — that holds itself
/// open in a shared registry until the person closes it, and Esc closes it like the panel it is.
@MainActor
class FloatingWindow: NSWindow {
    private static var open: [FloatingWindow] = []

    override init(
        contentRect: NSRect, styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        isReleasedWhenClosed = false
        Self.open.append(self)
    }

    override func close() {
        super.close()
        Self.open.removeAll { $0 === self }
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}
