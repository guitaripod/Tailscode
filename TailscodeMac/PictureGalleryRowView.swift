import AppKit
import CodingAgentKit
import TailscodeCore

/// The pictures an agent made, as one square of small tiles rather than a poster each: a turn that
/// looked at sixteen screenshots spends one picture's height on them, and the corner counts the
/// ones the square could not draw. The whole square is one press — it opens the conversation's
/// viewer on this group's first picture, where every picture can be paged through, zoomed and
/// saved — and it lifts on a plate under the pointer like every other picture.
@MainActor
enum PictureGalleryRowView {
    static func make(
        _ pictures: [TranscriptRow.GalleryPicture], context: TranscriptContext
    ) -> NSView {
        let metrics = ChatLayout.metrics
        let side = CGFloat(PictureGalleryLayout.side(metrics: metrics, width: ImagePreview.deskWidth))
        let tiles = PictureGalleryLayout.mosaic(
            count: min(pictures.count, PictureGalleryLayout.maximumTiles), side: Double(side),
            gap: metrics.imageStripGap,
            shape: pictures.first.flatMap { picture in
                ImageStore.shared.entry(forKey: picture.key).map {
                    Double($0.pixelWidth) / Double(max(1, $0.pixelHeight))
                }
            },
            maxWidth: ImagePreview.deskWidth)
        let names = pictures.map { name(of: $0.reference) }
        let spoken = PictureGalleryReading.spoken(count: pictures.count, names: names)
        let view = GalleryView(
            pictures: pictures, tiles: tiles, side: side,
            unshown: PictureGalleryLayout.hidden(count: pictures.count), spoken: spoken,
            name: names.first ?? "")
        for picture in pictures.prefix(PictureGalleryLayout.maximumTiles)
        where ImageStore.shared.entry(forKey: picture.key) == nil {
            context.requestImage?(picture.reference, picture.key)
        }
        let open = context.openImage
        let first = pictures[0]
        let firstName = name(of: first.reference)
        view.onOpen = { open?(first.key, firstName) }
        view.toolTip = spoken
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(spoken)
        HoverPlate.attach(
            to: view, placement: .behind(NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)),
            radius: CGFloat(ChatChrome.Radius.control))
        return view
    }

    private static func name(of reference: FileReference) -> String {
        reference.filename
            ?? reference.path.map { URL(fileURLWithPath: $0, isDirectory: false).lastPathComponent }
            ?? "file"
    }

    /// One square of tiles: each picture cropped to its rectangle, the count of what is not drawn
    /// said over the last one. Drawn rather than laid out, because a gallery is one control and a
    /// control of four crop-clipped image views is four constraints for no extra behaviour.
    private final class GalleryView: NSView {
        var onOpen: (() -> Void)?
        private let pictures: [TranscriptRow.GalleryPicture]
        private let tiles: [PictureGalleryLayout.Tile]
        private let side: CGFloat
        private let unshown: Int
        private let spoken: String
        private let name: String

        init(
            pictures: [TranscriptRow.GalleryPicture], tiles: [PictureGalleryLayout.Tile],
            side: CGFloat, unshown: Int, spoken: String, name: String
        ) {
            self.pictures = pictures
            self.tiles = tiles
            self.side = side
            self.unshown = unshown
            self.spoken = spoken
            self.name = name
            super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
            translatesAutoresizingMaskIntoConstraints = false
            setContentHuggingPriority(.required, for: .horizontal)
            wantsLayer = true
            flowWidth = side
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
        override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

        override func drawFocusRingMask() {
            NSBezierPath(
                roundedRect: bounds, xRadius: CGFloat(ChatChrome.Radius.control),
                yRadius: CGFloat(ChatChrome.Radius.control)
            ).fill()
        }

        override func accessibilityPerformPress() -> Bool {
            onOpen?()
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard [49, 36, 76].contains(event.keyCode), let onOpen else {
                return super.keyDown(with: event)
            }
            onOpen()
        }

        override func mouseDown(with event: NSEvent) {}

        override func mouseUp(with event: NSEvent) {
            guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            onOpen?()
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
            let outer = NSBezierPath(
                roundedRect: bounds, xRadius: CGFloat(ChatChrome.Radius.control),
                yRadius: CGFloat(ChatChrome.Radius.control))
            outer.addClip()
            MacTheme.Color.canvasRaised.setFill()
            outer.fill()
            NSGraphicsContext.current?.saveGraphicsState()
            for tile in tiles {
                let rect = NSRect(
                    x: tile.x, y: tile.y, width: tile.width, height: tile.height)
                draw(picture: pictures[tile.index], in: rect)
                if tile.index == tiles.count - 1, unshown > 0 {
                    draw(badge: "+\(unshown)", in: rect)
                }
            }
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        private func draw(picture: TranscriptRow.GalleryPicture, in rect: NSRect) {
            guard let entry = ImageStore.shared.entry(forKey: picture.key) else {
                NSColor.separatorColor.withAlphaComponent(0.2).setFill()
                rect.fill()
                return
            }
            let image = entry.image
            let size = image.size
            guard size.width > 0, size.height > 0 else { return }
            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(rect: rect).addClip()
            let scale =
                tiles.count == 1
                ? min(rect.width / size.width, rect.height / size.height)
                : max(rect.width / size.width, rect.height / size.height)
            let drawn = NSSize(width: size.width * scale, height: size.height * scale)
            let box = NSRect(
                x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2,
                width: drawn.width, height: drawn.height)
            image.draw(
                in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                hints: nil)
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        private func draw(badge: String, in rect: NSRect) {
            NSColor.black.withAlphaComponent(0.6).setFill()
            rect.fill()
            let font = NSFont.systemFont(ofSize: max(15, rect.height * 0.28), weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: NSColor.white,
            ]
            let text = badge as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(
                at: NSPoint(
                    x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                withAttributes: attributes)
        }
    }
}
