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

    private init() {}

    func entry(forKey key: String) -> DecodedImage? {
        entries[key]
    }

    /// Decoded pictures are kept across chat switches, bounded: past the cap the least recently
    /// decoded is released — its bytes are still on disk, one frame away.
    func store(_ entry: DecodedImage, forKey key: String) {
        entries[key] = entry
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
    private static let thumbWidth: CGFloat = 220
    private static let thumbHeight: CGFloat = 140

    static func make(_ reference: FileReference, key: String, context: TranscriptContext) -> NSView {
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
            frame.layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
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

/// The picture at full size in its own window, and a save that hands over the bytes the server
/// sent — never a re-encode of the bitmap a row downsampled to display.
@MainActor
enum ImageViewer {
    static func present(entry: DecodedImage, name: String, host: NSWindow?, toast: ((String) -> Void)?) {
        let hostFrame = host?.frame ?? NSRect(x: 0, y: 0, width: 1080, height: 800)
        let width = max(960, hostFrame.width - 120)
        let height = max(700, hostFrame.height - 100)

        let imageView = NSImageView(image: entry.image)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        imageView.setContentCompressionResistancePriority(.init(1), for: .vertical)

        let sizeLabel = RowKit.label(
            "\(entry.pixelWidth)×\(entry.pixelHeight)", font: MacTheme.Font.caption(),
            color: MacTheme.Color.secondaryLabel)
        let data = entry.data
        let filename = name
        let save = RowKit.ActionButton(title: Localized.text("Save to Downloads")) {
            let target = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads", isDirectory: true)
                .appendingPathComponent(filename)
            try? FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let wrote = (try? data.write(to: target)) != nil
            toast?(
                wrote
                    ? Localized.text("Saved %@", target.path)
                    : Localized.text("Could not write %@", target.path))
        }
        save.bezelStyle = .rounded
        save.translatesAutoresizingMaskIntoConstraints = false

        let bar = NSStackView(views: [sizeLabel, RowKit.spacer(), save])
        bar.orientation = .horizontal
        bar.spacing = MacTheme.Spacing.s
        bar.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.s, left: MacTheme.Spacing.l, bottom: MacTheme.Spacing.m,
            right: MacTheme.Spacing.l)
        bar.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView(views: [imageView, bar])
        column.orientation = .vertical
        column.alignment = .width
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false

        let window = FloatingWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = name
        window.contentView = column
        if let host {
            window.setFrameOrigin(
                NSPoint(
                    x: host.frame.midX - width / 2,
                    y: host.frame.midY - height / 2))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }
}

/// A window unowned by any controller — a picture viewer, a summary reader — that holds itself
/// open in a shared registry until the person closes it, and Esc closes it like the panel it is.
@MainActor
final class FloatingWindow: NSWindow {
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
