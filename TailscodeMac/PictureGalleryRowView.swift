import AppKit
import CodingAgentKit
import TailscodeCore

/// The pictures an agent made, as one grid of small tiles rather than a poster each: a turn that
/// looked at sixteen screenshots spends one picture's height on them, spread across the width the
/// transcript has, and the last tile's corner counts the ones the grid could not draw. The block is
/// as wide as the row and never wider, so a gallery takes the same room the brain card above it
/// takes; every tile is its own press — it opens the conversation's viewer on that picture, where
/// every picture can be paged through, zoomed and saved — and the grid steps its pictures back
/// under the pointer rather than lifting a plate the width of the row behind them.
@MainActor
enum PictureGalleryRowView {
    static func make(
        _ pictures: [TranscriptRow.GalleryPicture], context: TranscriptContext
    ) -> NSView {
        let names = pictures.map { name(of: $0.reference) }
        let spoken = PictureGalleryReading.spoken(count: pictures.count, names: names)
        let view = GalleryView(pictures: pictures, spoken: spoken)
        let open = context.openImage
        let request = context.requestImage
        view.onOpen = { picture in open?(picture.key, name(of: picture.reference)) }
        view.request = { picture in request?(picture.reference, picture.key) }
        view.toolTip = spoken
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(spoken)
        return view
    }

    private static func name(of reference: FileReference) -> String {
        reference.filename
            ?? reference.path.map { URL(fileURLWithPath: $0, isDirectory: false).lastPathComponent }
            ?? "file"
    }

    /// One grid of tiles: each picture cropped to its rectangle, the count of what is not drawn
    /// said over the last one. Drawn rather than laid out, because a gallery is one block of
    /// pictures and a block of twenty crop-clipped image views is twenty constraints for no extra
    /// behaviour; the rectangles come from Core, asked again whenever the row is resized.
    final class GalleryView: NSView {
        var onOpen: ((TranscriptRow.GalleryPicture) -> Void)?
        var request: ((TranscriptRow.GalleryPicture) -> Void)?

        private let pictures: [TranscriptRow.GalleryPicture]
        private let spoken: String
        private var tiles: [PictureGalleryLayout.Tile] = []
        private var unshown = 0
        private var laidWidth: CGFloat = 0
        private var hovered = false

        init(pictures: [TranscriptRow.GalleryPicture], spoken: String) {
            self.pictures = pictures
            self.spoken = spoken
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            wantsLayer = true
            setContentHuggingPriority(.defaultLow, for: .horizontal)
            setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
        override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        /// One picture tall, whatever the width: the tiles fold into a second row rather than
        /// growing the block, so a gallery never pushes the answer further down the page.
        override var intrinsicContentSize: NSSize {
            let width = bounds.width > 1 ? bounds.width : CGFloat(ImagePreview.deskWidth)
            return NSSize(width: NSView.noIntrinsicMetric, height: ladder(at: width).height)
        }

        override func layout() {
            super.layout()
            let width = bounds.width
            guard width > 1, abs(width - laidWidth) > 0.5 else { return }
            laidWidth = width
            let placed = ladder(at: width)
            tiles = placed.tiles
            unshown = placed.hidden
            for tile in tiles { request?(pictures[tile.index]) }
            if abs(intrinsicContentSize.height - placed.height) > 0.5 {
                invalidateIntrinsicContentSize()
            }
            needsDisplay = true
        }

        private func ladder(at width: CGFloat) -> PictureGalleryLayout.Arrangement {
            let metrics = ChatLayout.metrics
            let side = PictureGalleryLayout.side(metrics: metrics, width: Double(width))
            return PictureGalleryLayout.grid(
                count: pictures.count, side: side,
                available: Double(width),
                shape: pictures.first.flatMap { picture in
                    ImageStore.shared.entry(forKey: picture.key).map {
                        Double($0.pixelWidth) / Double(max(1, $0.pixelHeight))
                    }
                },
                maxWidth: ImagePreview.deskWidth)
        }

        override func drawFocusRingMask() {
            NSBezierPath(
                roundedRect: bounds, xRadius: CGFloat(ChatChrome.Radius.control),
                yRadius: CGFloat(ChatChrome.Radius.control)
            ).fill()
        }

        override func accessibilityPerformPress() -> Bool {
            guard let first = pictures.first else { return false }
            onOpen?(first)
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard [49, 36, 76].contains(event.keyCode), let first = pictures.first else {
                return super.keyDown(with: event)
            }
            onOpen?(first)
        }

        override func mouseDown(with event: NSEvent) {}

        override func mouseUp(with event: NSEvent) {
            guard let picture = picture(at: convert(event.locationInWindow, from: nil)) else {
                return
            }
            onOpen?(picture)
        }

        /// The picture under a point in this view's own coordinates, so a press knows which tile it
        /// landed on and a check can ask the same question the press asks.
        func picture(at point: NSPoint) -> TranscriptRow.GalleryPicture? {
            guard let tile = tiles.first(where: {
                NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height).contains(point)
            }) else { return nil }
            return pictures[tile.index]
        }

        override func mouseEntered(with event: NSEvent) {
            hovered = true
            needsDisplay = true
        }

        override func mouseExited(with event: NSEvent) {
            hovered = false
            needsDisplay = true
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(
                NSTrackingArea(
                    rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                    owner: self, userInfo: nil))
        }

        override func draw(_ dirtyRect: NSRect) {
            for tile in tiles {
                draw(
                    picture: pictures[tile.index],
                    in: NSRect(x: tile.x, y: tile.y, width: tile.width, height: tile.height))
            }
            if let last = tiles.last, unshown > 0 {
                draw(
                    badge: "+\(unshown)",
                    in: NSRect(x: last.x, y: last.y, width: last.width, height: last.height))
            }
        }

        private func draw(picture: TranscriptRow.GalleryPicture, in rect: NSRect) {
            let clip = NSBezierPath(
                roundedRect: rect, xRadius: CGFloat(ChatChrome.Radius.control),
                yRadius: CGFloat(ChatChrome.Radius.control))
            guard let entry = ImageStore.shared.entry(forKey: picture.key) else {
                NSGraphicsContext.current?.saveGraphicsState()
                clip.addClip()
                MacTheme.Color.canvasRaised.setFill()
                NSBezierPath(rect: rect).fill()
                NSGraphicsContext.current?.restoreGraphicsState()
                return
            }
            let image = entry.image
            let size = image.size
            guard size.width > 0, size.height > 0, rect.width > 0, rect.height > 0 else { return }
            NSGraphicsContext.current?.saveGraphicsState()
            clip.addClip()
            let scale =
                tiles.count == 1
                ? min(rect.width / size.width, rect.height / size.height)
                : max(rect.width / size.width, rect.height / size.height)
            let drawn = NSSize(width: size.width * scale, height: size.height * scale)
            let box = NSRect(
                x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2,
                width: drawn.width, height: drawn.height)
            image.draw(
                in: box, from: .zero, operation: .sourceOver, fraction: hovered ? 0.86 : 1,
                respectFlipped: true, hints: nil)
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        private func draw(badge: String, in rect: NSRect) {
            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(
                roundedRect: rect, xRadius: CGFloat(ChatChrome.Radius.control),
                yRadius: CGFloat(ChatChrome.Radius.control)
            ).addClip()
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(rect: rect).fill()
            let font = NSFont.systemFont(ofSize: max(13, rect.height * 0.3), weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: NSColor.white,
            ]
            let text = badge as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(
                at: NSPoint(
                    x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                withAttributes: attributes)
            NSGraphicsContext.current?.restoreGraphicsState()
        }
    }
}
