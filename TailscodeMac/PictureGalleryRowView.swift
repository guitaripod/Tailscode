import AppKit
import CodingAgentKit
import TailscodeCore

/// The pictures an agent made, as one grid of small tiles rather than a poster each: a turn that
/// looked at sixteen screenshots spends one picture's height on them, spread across the width the
/// transcript has, and a chip in the last tile's corner counts the ones the grid could not draw.
/// The block is as wide as the row and never wider, so a gallery takes the same room the brain card
/// above it takes; every tile is its own press — it opens the conversation's viewer on that
/// picture, where every picture can be paged through, zoomed and saved — and the tile under the
/// pointer steps its picture back rather than lifting a plate the width of the row behind it.
/// Every tile is also its own accessibility button and its own stop for the keyboard (arrows move,
/// Space or Return opens), so a picture is as reachable without a pointer as with one.
@MainActor
enum PictureGalleryRowView {
    static func make(
        _ pictures: [TranscriptRow.GalleryPicture], context: TranscriptContext
    ) -> NSView {
        let names = pictures.map { name(of: $0.reference) }
        let spoken = PictureGalleryReading.spoken(count: pictures.count, names: names)
        let view = GalleryView(pictures: pictures, names: names, spoken: spoken)
        let open = context.openImage
        let request = context.requestImage
        view.onOpen = { picture in open?(picture.key, name(of: picture.reference)) }
        view.request = { picture in request?(picture.reference, picture.key) }
        view.toolTip = spoken
        return view
    }

    private static func name(of reference: FileReference) -> String {
        reference.filename
            ?? reference.path.map { URL(fileURLWithPath: $0, isDirectory: false).lastPathComponent }
            ?? "file"
    }

    /// One grid of tiles: each picture cropped to its rectangle, the count of what is not drawn
    /// said in a chip on the last. Drawn rather than laid out, because a gallery is one block of
    /// pictures and a block of twenty crop-clipped image views is twenty constraints for no extra
    /// behaviour; the rectangles come from Core, asked again whenever the row is resized, and each
    /// tile is drawn from the picture's preview rather than its full bitmap.
    final class GalleryView: NSView {
        var onOpen: ((TranscriptRow.GalleryPicture) -> Void)?
        var request: ((TranscriptRow.GalleryPicture) -> Void)?

        private let pictures: [TranscriptRow.GalleryPicture]
        private let names: [String]
        private var tiles: [PictureGalleryLayout.Tile] = []
        private var unshown = 0
        private var laidWidth: CGFloat = 0
        private var hoveredTile: Int?
        private(set) var focusedTile: Int?

        init(pictures: [TranscriptRow.GalleryPicture], names: [String], spoken: String) {
            self.pictures = pictures
            self.names = names
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            wantsLayer = true
            setContentHuggingPriority(.defaultLow, for: .horizontal)
            setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            setAccessibilityRole(.group)
            setAccessibilityLabel(spoken)
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
            focusedTile = focusedTile.flatMap { $0 < tiles.count ? $0 : nil }
            for tile in tiles { request?(pictures[tile.index]) }
            if abs(intrinsicContentSize.height - placed.height) > 0.5 {
                invalidateIntrinsicContentSize()
            }
            rebuildElements()
            needsDisplay = true
        }

        private func ladder(at width: CGFloat) -> PictureGalleryLayout.Arrangement {
            let metrics = ChatLayout.metrics
            let side = PictureGalleryLayout.side(metrics: metrics, width: Double(width))
            return PictureGalleryLayout.grid(
                count: pictures.count, side: side,
                available: Double(width),
                shape: pictures.count == 1
                    ? pictures.first.flatMap { picture in
                        ImageStore.shared.entry(forKey: picture.key).map {
                            Double($0.pixelWidth) / Double(max(1, $0.pixelHeight))
                        }
                    } : nil,
                maxWidth: ImagePreview.deskWidth)
        }

        private func rect(of tile: PictureGalleryLayout.Tile) -> NSRect {
            NSRect(x: tile.x, y: tile.y, width: tile.width, height: tile.height)
        }

        /// One accessibility button per tile drawn, each named for its own picture and opening
        /// that picture: the view draws its tiles itself, so without these a screen reader meets
        /// one lump for the whole grid and every press opens the first picture.
        private func rebuildElements() {
            let elements = tiles.map { tile -> TileElement in
                let element = TileElement()
                element.setAccessibilityRole(.button)
                element.setAccessibilityLabel(
                    Localized.text(
                        "Open %1$@, picture %2$@ of %3$@", names[tile.index],
                        "\(tile.index + 1)", "\(pictures.count)"))
                element.setAccessibilityParent(self)
                element.setAccessibilityFrameInParentSpace(rect(of: tile))
                let picture = pictures[tile.index]
                element.onPress = { [weak self] in self?.onOpen?(picture) }
                return element
            }
            setAccessibilityChildren(elements)
        }

        override func becomeFirstResponder() -> Bool {
            if focusedTile == nil, !tiles.isEmpty { focusedTile = 0 }
            noteFocusRingMaskChanged()
            return super.becomeFirstResponder()
        }

        override var focusRingMaskBounds: NSRect {
            focusedTile.flatMap { tiles.indices.contains($0) ? rect(of: tiles[$0]) : nil } ?? bounds
        }

        override func drawFocusRingMask() {
            NSBezierPath(
                roundedRect: focusRingMaskBounds, xRadius: CGFloat(ChatChrome.Radius.control),
                yRadius: CGFloat(ChatChrome.Radius.control)
            ).fill()
        }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 49, 36, 76:
                guard let focused = focusedTile, tiles.indices.contains(focused) else {
                    return super.keyDown(with: event)
                }
                onOpen?(pictures[tiles[focused].index])
            case 123, 124, 125, 126:
                move(focus: event.keyCode)
            default:
                super.keyDown(with: event)
            }
        }

        /// The arrows walk the tiles: left and right to the neighbour, up and down to the tile
        /// in the other row nearest the same column.
        private func move(focus keyCode: UInt16) {
            guard !tiles.isEmpty else { return }
            let current = focusedTile ?? 0
            let columns = max(1, tiles.filter { $0.y == tiles[0].y }.count)
            let next: Int
            switch keyCode {
            case 123: next = current - 1
            case 124: next = current + 1
            case 125: next = current + columns
            default: next = current - columns
            }
            guard tiles.indices.contains(next), next != current else { return }
            focusedTile = next
            noteFocusRingMaskChanged()
            needsDisplay = true
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
            tile(at: point).map { pictures[$0.index] }
        }

        private func tile(at point: NSPoint) -> PictureGalleryLayout.Tile? {
            tiles.first { rect(of: $0).contains(point) }
        }

        override func mouseEntered(with event: NSEvent) {
            hover(over: convert(event.locationInWindow, from: nil))
        }

        override func mouseMoved(with event: NSEvent) {
            hover(over: convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) {
            hover(over: nil)
        }

        /// Steps back the one tile under the pointer and repaints only it and the tile it left.
        func hover(over point: NSPoint?) {
            let next = point.flatMap { tile(at: $0)?.index }
            guard next != hoveredTile else { return }
            for index in [hoveredTile, next].compactMap({ $0 }) where tiles.indices.contains(index) {
                setNeedsDisplay(rect(of: tiles[index]))
            }
            hoveredTile = next
        }

        var hoveredIndex: Int? { hoveredTile }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(
                NSTrackingArea(
                    rect: bounds,
                    options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
                    owner: self, userInfo: nil))
        }

        override func draw(_ dirtyRect: NSRect) {
            for tile in tiles where rect(of: tile).intersects(dirtyRect) {
                draw(picture: pictures[tile.index], tile: tile)
            }
            if let last = tiles.last, let words = PictureGalleryReading.badge(hidden: unshown),
                chipRect(on: last, words: words).intersects(dirtyRect)
            {
                draw(badge: words, on: last)
            }
        }

        private func draw(picture: TranscriptRow.GalleryPicture, tile: PictureGalleryLayout.Tile) {
            let rect = rect(of: tile)
            let clip = NSBezierPath(
                roundedRect: rect, xRadius: CGFloat(ChatChrome.Radius.control),
                yRadius: CGFloat(ChatChrome.Radius.control))
            guard let entry = ImageStore.shared.entry(forKey: picture.key) else {
                NSGraphicsContext.current?.saveGraphicsState()
                clip.addClip()
                MacTheme.Color.canvasRaised.setFill()
                NSBezierPath(rect: rect).fill()
                NSGraphicsContext.current?.restoreGraphicsState()
                request?(picture)
                return
            }
            let image = entry.preview
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
                in: box, from: .zero, operation: .sourceOver,
                fraction: hoveredTile == tile.index ? 0.86 : 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        private static var chipAttributes: [NSAttributedString.Key: Any] {
            [
                .font: NSFont.systemFont(
                    ofSize: CGFloat(PictureGalleryLayout.chipFontSize), weight: .bold),
                .foregroundColor: NSColor.white,
            ]
        }

        private func chipRect(on tile: PictureGalleryLayout.Tile, words: String) -> NSRect {
            let width = (words as NSString).size(withAttributes: Self.chipAttributes).width
            let chip = PictureGalleryLayout.badge(on: tile, textWidth: Double(width))
            return NSRect(x: chip.x, y: chip.y, width: chip.width, height: chip.height)
        }

        private func draw(badge words: String, on tile: PictureGalleryLayout.Tile) {
            let chip = chipRect(on: tile, words: words)
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(
                roundedRect: chip, xRadius: chip.height / 2, yRadius: chip.height / 2
            ).fill()
            let text = words as NSString
            let size = text.size(withAttributes: Self.chipAttributes)
            text.draw(
                at: NSPoint(x: chip.midX - size.width / 2, y: chip.midY - size.height / 2),
                withAttributes: Self.chipAttributes)
        }
    }

    /// One tile as a screen reader meets it: a button that opens its own picture.
    private final class TileElement: NSAccessibilityElement {
        var onPress: (() -> Void)?

        override func accessibilityPerformPress() -> Bool {
            onPress?()
            return onPress != nil
        }
    }
}
