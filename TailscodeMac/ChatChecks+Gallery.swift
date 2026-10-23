import AppKit
import CodingAgentKit
import TailscodeCore

extension ChatChecks {
    /// The pictures an agent made rest as one gallery square, and a picture the person sent stays
    /// where it is: consecutive agent pictures gather under the first one's key, a person's own and
    /// a document break the run, and the square is a picture tall.
    static func galleries(_ expect: (Bool, String) throws -> Void) throws {
        func picture(_ name: String) -> FileReference {
            FileReference(path: "/tmp/\(name)", mime: "image/png", filename: name)
        }
        let rows: [TranscriptRow] = [
            TranscriptRow(key: "m:a", kind: .file(picture("a.png"), mine: false, messageID: "m")),
            TranscriptRow(key: "m:b", kind: .file(picture("b.png"), mine: false, messageID: "m")),
            TranscriptRow(key: "m:t", kind: .reasoning("between")),
            TranscriptRow(key: "m:mine", kind: .file(picture("mine.png"), mine: true, messageID: "m")),
            TranscriptRow(key: "m:c", kind: .file(picture("c.png"), mine: false, messageID: "m")),
        ]
        let gathered = TranscriptRow.gallery(rows)
        let described = gathered.map { row -> String in
            switch row.kind {
            case .pictures(let pictures): return "gallery:" + pictures.map(\.key).joined(separator: ",")
            case .file: return "file"
            default: return "other"
            }
        }
        try expect(
            described == ["gallery:m:a,m:b", "other", "file", "gallery:m:c"],
            "consecutive agent pictures gather, a person's own does not: \(described)")
        try expect(
            gathered[0].key == "m:a", "a gallery keeps the key of its first picture")
        try expect(TranscriptRow.gallery(gathered) == gathered, "gathering is idempotent")
        let side = PictureGalleryLayout.side(metrics: ChatLayout.metrics, width: ImagePreview.deskWidth)
        let sheet = PictureGalleryLayout.grid(count: 10, side: side, available: 420)
        try expect(
            sheet.tiles.count == 10 && sheet.hidden == 0 && sheet.height <= side + 0.001
                && Set(sheet.tiles.map(\.y)) == [0, 91],
            "ten pictures in a row are a grid of two rows, one picture tall: \(sheet.tiles.count) tiles, \(sheet.height) tall")
        let crowded = PictureGalleryLayout.grid(count: 26, side: side, available: 420)
        try expect(
            crowded.hidden > 0 && crowded.tiles.count + crowded.hidden == 26,
            "a grid takes the columns it can and counts the rest: \(crowded.tiles.count) + \(crowded.hidden)")
        try expect(
            PictureGalleryReading.spoken(count: 2, names: ["a.png", "b.png"]) == "2 pictures, a.png, b.png",
            "the gallery says how many pictures it holds and which")
        try galleryPixels(expect)
    }

    /// The gallery as it is drawn, out of the view and into pixels: the tiles show the inks they
    /// were handed, a chip in the last tile's corner counts the pictures it cannot draw, a press
    /// lands on the picture under it rather than on the group's first, and a lone picture keeps its
    /// own shape instead of being cropped.
    private static func galleryPixels(_ expect: (Bool, String) throws -> Void) throws {
        func swatch(_ color: NSColor) -> NSImage {
            NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
                color.setFill()
                rect.fill()
                return true
            }
        }
        func picture(
            _ name: String, _ color: NSColor, pixels: NSSize = NSSize(width: 64, height: 64)
        ) -> (TranscriptRow.GalleryPicture, NSColor) {
            let key = "gallery-check:\(name)"
            ImageStore.shared.store(
                DecodedImage(
                    image: swatch(color), data: Data(),
                    pixelWidth: Int(pixels.width), pixelHeight: Int(pixels.height)),
                forKey: key)
            return (
                TranscriptRow.GalleryPicture(
                    key: key,
                    reference: FileReference(path: "/tmp/\(name)", mime: "image/png", filename: name)),
                color
            )
        }
        let inks: [NSColor] = [
            NSColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1),
            NSColor(srgbRed: 0.1, green: 0.8, blue: 0.1, alpha: 1),
            NSColor(srgbRed: 0.1, green: 0.2, blue: 0.9, alpha: 1),
            NSColor(srgbRed: 0.9, green: 0.8, blue: 0.1, alpha: 1),
            NSColor(srgbRed: 0.8, green: 0.2, blue: 0.7, alpha: 1),
        ]
        let crowd = (0..<26).map { picture("s\($0).png", inks[$0 % inks.count]) }

        let column = TranscriptColumn(frame: NSRect(x: 0, y: 0, width: 420, height: 600))
        column.metrics = ChatLayout.metrics
        var opened: String?
        let context = TranscriptContext()
        context.openImage = { key, _ in opened = key }
        let row = TranscriptRow(key: crowd[0].0.key, kind: .pictures(crowd.map(\.0)))
        let gallery = row.makeView(context: context)
        column.addArrangedSubview(gallery, spacing: ChatLayout.spacing(of: row.kind))
        stage(column)
        column.layoutSubtreeIfNeeded()

        let side = CGFloat(PictureGalleryLayout.side(metrics: ChatLayout.metrics, width: 420))
        try expect(
            gallery.frame.width == 420 && gallery.frame.height == side,
            "in a column a gallery takes the row's width and one picture's height: \(gallery.frame.size)")
        let placed = PictureGalleryLayout.grid(
            count: 26, side: Double(side), available: 420)
        if let second = placed.tiles.dropFirst().first,
            let view = gallery as? PictureGalleryRowView.GalleryView,
            let pressed = view.picture(
                at: NSPoint(x: second.x + second.width / 2, y: second.y + second.height / 2))
        {
            view.onOpen?(pressed)
            try expect(
                opened == crowd[1].0.key,
                "a press lands on the tile under it, and that is the picture the viewer opens on: \(opened ?? "-")")
        }

        let width = Int(420)
        let height = Int(side.rounded())
        guard width > 0, height > 0,
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let bitmaps = NSGraphicsContext(bitmapImageRep: rep)
        else { throw SelfTestFailure("compact chat: the gallery would not draw into a bitmap") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = bitmaps
        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: CGFloat(height))
        flip.scaleX(by: 1, yBy: -1)
        flip.concat()
        gallery.draw(gallery.bounds)
        bitmaps.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        func ink(_ x: Double, _ y: Double) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
            guard let color = rep.colorAt(x: Int(x.rounded()), y: Int(y.rounded())),
                let space = color.usingColorSpace(.sRGB)
            else { return nil }
            return (space.redComponent, space.greenComponent, space.blueComponent)
        }
        func isInk(_ drawn: (r: CGFloat, g: CGFloat, b: CGFloat)?, _ expected: NSColor) -> Bool {
            guard let drawn, let want = expected.usingColorSpace(.sRGB) else { return false }
            return abs(drawn.r - want.redComponent) < 0.08
                && abs(drawn.g - want.greenComponent) < 0.08
                && abs(drawn.b - want.blueComponent) < 0.08
        }
        for (index, tile) in placed.tiles.enumerated() where index < 3 {
            let drawn = ink(tile.x + tile.width / 2, tile.y + tile.height / 2)
            try expect(
                isInk(drawn, crowd[index].1),
                "tile \(index) is the picture it was handed: \(String(describing: drawn))")
        }
        if let last = placed.tiles.last, let words = PictureGalleryReading.badge(hidden: placed.hidden) {
            let measured = (words as NSString).size(
                withAttributes: [
                    .font: NSFont.systemFont(
                        ofSize: CGFloat(PictureGalleryLayout.chipFontSize), weight: .bold)
                ]
            ).width
            let chip = PictureGalleryLayout.badge(on: last, textWidth: Double(measured))
            let want = crowd[last.index].1.usingColorSpace(.sRGB)
            let brightness = (want?.redComponent ?? 0) + (want?.greenComponent ?? 0) + (want?.blueComponent ?? 0)
            let under = ink(chip.x + 3.5, chip.y + chip.height / 2)
            try expect(
                under.map { $0.r + $0.g + $0.b < brightness * 0.7 } ?? false,
                "the count is a dark chip in the last tile's corner: \(String(describing: under))")
            let clear = ink(last.x + last.width * 0.3, last.y + last.height * 0.3)
            try expect(
                isInk(clear, crowd[last.index].1),
                "and the rest of that tile is still its picture: \(String(describing: clear))")
        }
        if let view = gallery as? PictureGalleryRowView.GalleryView, placed.tiles.count > 3 {
            let first = placed.tiles[0]
            let third = placed.tiles[2]
            view.hover(over: NSPoint(x: third.x + 2, y: third.y + 2))
            try expect(view.hoveredIndex == 2, "the pointer steps back the tile under it alone")
            view.hover(over: NSPoint(x: first.x + 2, y: first.y + 2))
            try expect(view.hoveredIndex == 0, "and moving to another tile moves the step with it")
            view.hover(over: nil)
            try expect(view.hoveredIndex == nil, "leaving the grid steps nothing back")
            opened = nil
            let elements = (view.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
            try expect(
                elements.count == placed.tiles.count,
                "every tile drawn is an accessibility element: \(elements.count) of \(placed.tiles.count)")
            if elements.count > 3 {
                try expect(
                    (elements[3].accessibilityLabel() ?? "").contains("s3.png"),
                    "each element is named for its own picture: \(elements[3].accessibilityLabel() ?? "-")")
                _ = elements[3].accessibilityPerformPress()
                try expect(
                    opened == crowd[3].0.key,
                    "a VoiceOver press opens that tile's picture, not the first: \(opened ?? "-")")
            }
        }
        let rows = [
            TranscriptRow(key: "g1", kind: .pictures(crowd.prefix(3).map(\.0))),
            TranscriptRow(
                key: "f1",
                kind: .file(
                    FileReference(path: "/x/doc.pdf", mime: "application/pdf"), mine: false,
                    messageID: "m")),
            TranscriptRow(
                key: "f2",
                kind: .file(
                    FileReference(path: "/x/one.png", mime: "image/png"), mine: false,
                    messageID: "m")),
            TranscriptRow(key: "g2", kind: .pictures(crowd.suffix(2).map(\.0))),
        ]
        let items = ImageViewer.items(in: rows)
        try expect(
            items.map(\.key) == crowd.prefix(3).map(\.0.key) + ["f2"] + crowd.suffix(2).map(\.0.key),
            "the viewer's pictures are every tile of every gallery in reading order: \(items.map(\.key))")
        try expect(
            items.firstIndex { $0.key == crowd[2].0.key } == 2
                && items.firstIndex { $0.key == crowd[25].0.key } == 5,
            "a press on a tile starts the viewer at that tile's index")

        let wide = picture("wide.png", inks[0], pixels: NSSize(width: 200, height: 100))
        let lone = PictureGalleryRowView.make([wide.0], context: TranscriptContext())
        let loneSide = CGFloat(PictureGalleryLayout.side(metrics: ChatLayout.metrics, width: 420))
        lone.frame = NSRect(x: 0, y: 0, width: 420, height: loneSide)
        lone.layoutSubtreeIfNeeded()
        try expect(
            lone.intrinsicContentSize.height == loneSide,
            "a lone picture is one picture tall: \(lone.intrinsicContentSize.height)")
        let loneTile = PictureGalleryLayout.grid(
            count: 1, side: Double(loneSide), available: 420, shape: 2, maxWidth: 420).tiles[0]
        try expect(
            abs(loneTile.width / loneTile.height - 2) < 0.001,
            "a lone 2:1 picture is a 2:1 tile, fitted whole rather than cropped")
    }

    static func timing(_ expect: (Bool, String) throws -> Void) throws {
        var hover = RailHover()
        hover.pointer(on: .rail("a"), at: 0)
        hover.advance(to: 0.119)
        try expect(hover.open == nil, "a pointer that has rested 119 ms has opened nothing")
        hover.advance(to: 0.120)
        try expect(hover.open == "a", "120 ms of rest opens the plate")
        hover.pointer(on: .plate, at: 0.2)
        hover.pointer(on: .none, at: 1.0)
        hover.advance(to: 1.249)
        try expect(hover.open == "a", "leaving for 249 ms keeps it open")
        hover.pointer(on: .plate, at: 1.25)
        hover.advance(to: 3)
        try expect(hover.open == "a" && hover.deadline == nil, "coming back onto the plate cancels the close")
        hover.pointer(on: .none, at: 3)
        hover.advance(to: 3.25)
        try expect(hover.open == nil, "250 ms away closes it")
        hover.pointer(on: .rail("a"), at: 4)
        hover.advance(to: 4.2)
        hover.escape()
        try expect(hover.open == nil, "Esc closes at once")
        hover.pointer(on: .rail("a"), at: 5)
        hover.pointer(on: .none, at: 5.05)
        hover.advance(to: 6)
        try expect(hover.open == nil, "a pointer that passes over a rail opens nothing")
        hover.pointer(on: .rail("a"), at: 7)
        hover.advance(to: 7.2)
        hover.pointer(on: .rail("b"), at: 7.3)
        hover.advance(to: 7.4)
        try expect(hover.open == "a", "the first rail stays until the second has rested")
        hover.advance(to: 7.42)
        try expect(hover.open == "b", "resting on another rail moves the plate to it")
        hover.openNow("c")
        try expect(hover.open == "c" && hover.deadline == nil, "a press or a key opens at once")
    }
}
