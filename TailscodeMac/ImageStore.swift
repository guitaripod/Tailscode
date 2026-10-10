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
    private var icons: [String: NSImage] = [:]
    private var iconOrder: [String] = []
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

    func icon(forKey key: String) -> NSImage? {
        icons[key]
    }

    /// The little pictures link cards wear, kept apart from the transcript's own so a chat full of
    /// cards cannot push a screenshot out. Bounded the same way: past the cap the least recently
    /// stored is released, and its bytes are one cached fetch away.
    func store(icon: NSImage, forKey key: String) {
        icons[key] = icon
        iconOrder.removeAll { $0 == key }
        iconOrder.append(key)
        while iconOrder.count > 96 {
            icons[iconOrder.removeFirst()] = nil
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
///
/// A row that has no picture yet draws a placeholder of a fixed size and says that it wants bytes.
/// It does not say when: the placeholder is a fixed frame and the thumbnail that replaces it is the
/// picture's own shape, so a decode that lands above the viewport is a height change above whoever
/// has scrolled back. Which of those wants are worth crossing the tailnet for right now is the
/// transcript's judgement, made against where the row actually sits.
@MainActor
enum ImageRowView {
    /// A picture as a thumbnail: never taller than the table's bound, as wide as its proportions
    /// make it, with its filename as the tooltip and the accessibility label rather than a caption
    /// row under it. Its row is exactly the picture and hugs its width, which is what lets the
    /// column set consecutive pictures side by side in one strip.
    static func make(
        _ reference: FileReference, mine: Bool, key: String, context: TranscriptContext
    ) -> NSView {
        let maxHeight = CGFloat(
            ImagePreview.deskBound(ChatLayout.metrics.imageMaxHeight, mine: mine))
        let name =
            reference.filename
            ?? reference.path.map { URL(fileURLWithPath: $0, isDirectory: false).lastPathComponent }
            ?? "file"
        let isImage = (reference.mime ?? "").hasPrefix("image/")
        guard isImage else {
            return RowKit.label(
                "📎 \(name)", font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.secondaryLabel)
        }

        if let entry = ImageStore.shared.entry(forKey: key) {
            let size = PictureThumb.size(
                pixels: CGSize(width: entry.pixelWidth, height: entry.pixelHeight),
                maxHeight: maxHeight, maxWidth: PictureThumb.widest)
            let imageView = PictureView(image: entry.image)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = 6
            imageView.layer?.masksToBounds = true
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.setContentHuggingPriority(.required, for: .horizontal)
            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(equalToConstant: size.width),
                imageView.heightAnchor.constraint(equalToConstant: size.height),
            ])
            let open = context.openImage
            imageView.addGestureRecognizer(
                ClickRelay { open?(key, name) })
            imageView.onPress = { open?(key, name) }
            HoverPlate.attach(
                to: imageView, placement: .behind(NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)),
                radius: 9)
            imageView.setAccessibilityRole(.button)
            imageView.setAccessibilityLabel(Localized.text("Open %@", name))
            imageView.toolTip = name
            imageView.flowWidth = size.width
            return imageView
        }
        let size = PictureThumb.placeholder(maxHeight: maxHeight)
        let frame = GroundView(cornerRadius: 6, fill: MacTheme.Color.canvasRaised)
        frame.translatesAutoresizingMaskIntoConstraints = false
        frame.setContentHuggingPriority(.required, for: .horizontal)
        let label = RowKit.label(
            Localized.text("🖼 %@ — loading…", name), font: MacTheme.Ramp.font(.panelFootnote),
            color: MacTheme.Color.tertiaryLabel)
        frame.addSubview(label)
        NSLayoutConstraint.activate([
            frame.widthAnchor.constraint(equalToConstant: size.width),
            frame.heightAnchor.constraint(equalToConstant: size.height),
            label.centerXAnchor.constraint(equalTo: frame.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: frame.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: frame.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: frame.trailingAnchor, constant: -6),
        ])
        frame.toolTip = name
        frame.flowWidth = size.width
        context.requestImage?(reference, key)
        return frame
    }

    /// A thumbnail that opens the way a button does: clicked, pressed with Space or Return once Full
    /// Keyboard Access puts it in the Tab loop, or pressed by VoiceOver. A picture that only a
    /// mouse could open was a picture a keyboard user could see and never reach.
    final class PictureView: NSImageView, KeyboardPressable {
        var onPress: (() -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
        override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }
        override var focusRingMaskBounds: NSRect { bounds }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func drawFocusRingMask() {
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }

        override func keyDown(with event: NSEvent) {
            guard [49, 36, 76].contains(event.keyCode), let onPress else {
                return super.keyDown(with: event)
            }
            onPress()
        }

        override func accessibilityPerformPress() -> Bool {
            onPress?()
            return onPress != nil
        }
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

    /// The name every window of one kind remembers its size and place under, so the next one opens
    /// where the last was left rather than at a size somebody already had to fix once.
    private var frameMemory: String?

    /// Puts the window where the last one of its kind was left, and says whether there was one.
    @discardableResult
    func restoreFrame(named name: String) -> Bool {
        frameMemory = name
        return setFrameUsingName(name)
    }

    override func close() {
        if let frameMemory { saveFrame(usingName: frameMemory) }
        super.close()
        Self.open.removeAll { $0 === self }
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}
