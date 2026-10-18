import AppKit
import TailscodeCore

/// A turn painted as a poster. Geometry and every word are Core's (`NeuralShare.Card`); this only
/// turns points into pixels, and draws the head: the interior and the glass come from the Metal
/// renderer drawn offscreen, the nodes and wires from the same layers the stage draws, laid
/// between them, so the picture is the head the person was looking at at the size of the poster.
@MainActor
enum BrainPoster {
    struct Result {
        let data: Data
        let image: NSImage
        let filename: String
    }

    static let filename = "tailscode-turn.png"

    static func render(
        store: BrainStore, context: TranscriptContext, turnID: String, style: CardStyle, dark: Bool,
        scale: CGFloat
    ) async -> Result? {
        guard let entry = store.entry(turnID), let resting = store.restingModel(turnID) else {
            return nil
        }
        let card = NeuralShare.Card.make(
            turn: entry.turn, prompt: entry.prompt, style: style, dark: dark)
        let look = palette(from: card.palette, dark: dark)
        let hero = await heroImage(
            model: resting, store: store, context: context, turnID: turnID, palette: look,
            card: card, scale: scale)
        let width = Int((NeuralShare.Card.width * Double(scale)).rounded())
        let height = Int((NeuralShare.Card.height * Double(scale)).rounded())
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        let logical = NSSize(width: NeuralShare.Card.width, height: NeuralShare.Card.height)
        bitmap.size = logical
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let made = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        let cg = made.cgContext
        cg.translateBy(x: 0, y: logical.height)
        cg.scaleBy(x: 1, y: -1)
        let flipped = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.current = flipped
        flipped.imageInterpolation = .high
        paint(card, hero: hero, in: cg)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let image = NSImage(size: logical)
        image.addRepresentation(bitmap)
        return Result(data: data, image: image, filename: filename)
    }

    /// The head's own palette for a poster look: the look's colours in the slots the head reads,
    /// with the failure colour the looks do not carry.
    static func palette(from share: AnalyticsShare.Palette, dark: Bool) -> Palette {
        Palette(
            name: "poster", isDark: dark, canvas: share.canvas, canvasRaised: share.raised,
            rule: share.rule, text: share.text, textDim: share.textDim, accent: share.accent,
            accentDim: share.accent, warn: share.warn, danger: "#ff5c7a", info: share.info,
            special: share.special, codeBg: share.raised, subagentBg: share.raised,
            findHit: share.accent, ansi: [])
    }

    private static func heroImage(
        model: NeuralBrainModel, store: BrainStore, context: TranscriptContext, turnID: String,
        palette: Palette, card: NeuralShare.Card, scale: CGFloat
    ) async -> CGImage? {
        let hero = card.hero
        let heightPoints = CGFloat(hero.height)
        let widthPoints = heightPoints * CGFloat(NeuralDesign.width / NeuralDesign.height)
        let pixelsWide = Int((widthPoints * scale).rounded())
        let pixelsHigh = Int((heightPoints * scale).rounded())
        guard let metal = NeuralMetalContext.shared, metal.isSupported else { return nil }
        metal.retain()
        defer { metal.release() }
        let ready = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            metal.prepare { continuation.resume(returning: $0) }
        }
        guard ready, let renderer = NeuralHeadRenderer(context: metal) else { return nil }
        var table = NeuralToneTable(palette: palette, face: model.face)
        table.background = linear(
            Contrast.blend(card.palette.canvas, card.palette.canvasEnd, 0.12)
                ?? card.palette.canvas)
        let frame = model.frame(time: 0, reduceMotion: true)
        guard
            let pair = renderer.snapshot(
                frame: frame, table: table, time: 0, width: pixelsWide, height: pixelsHigh),
            let interior = cgImage(pair.interior), let front = cgImage(pair.front)
        else { return nil }

        let stage = BrainStageView(turnID: turnID, host: nil)
        stage.frame = NSRect(x: 0, y: 0, width: widthPoints, height: heightPoints)
        stage.fixedModel = model
        stage.paletteOverride = palette
        stage.layoutSubtreeIfNeeded()
        stage.refresh(force: true)

        guard
            let ctx = CGContext(
                data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh)
        ctx.draw(interior, in: rect)
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        stage.drawOverlay(in: ctx)
        ctx.restoreGState()
        ctx.draw(front, in: rect)
        return ctx.makeImage()
    }

    private static func linear(_ hex: String) -> NeuralRGB {
        guard let channels = Contrast.channels(hex) else { return NeuralRGB(0, 0, 0) }
        return NeuralRGB(
            powf(Float(channels.red), 2.2), powf(Float(channels.green), 2.2),
            powf(Float(channels.blue), 2.2))
    }

    private static func cgImage(_ surface: NeuralSurface) -> CGImage? {
        guard surface.width > 0, surface.height > 0,
            let provider = CGDataProvider(data: Data(surface.bytes) as CFData)
        else { return nil }
        return CGImage(
            width: surface.width, height: surface.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: surface.bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func paint(_ card: NeuralShare.Card, hero: CGImage?, in ctx: CGContext) {
        let canvas = CGRect(x: 0, y: 0, width: NeuralShare.Card.width, height: NeuralShare.Card.height)
        paintCanvas(card.palette, in: canvas, ctx: ctx)
        if let hero {
            let box = rect(card.hero)
            let aspect = CGFloat(hero.width) / CGFloat(hero.height)
            let width = min(box.width, box.height * aspect)
            let height = width / aspect
            let target = CGRect(
                x: box.midX - width / 2, y: box.midY - height / 2, width: width, height: height)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: target.minY * 2 + target.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(hero, in: target)
            ctx.restoreGState()
        }
        draw(card.brand, card)
        draw(card.tag, card)
        draw(card.count, card)
        draw(card.caption, card)
        if let box = card.subRect, !card.sub.isEmpty { drawRuns(card.sub, in: box, card) }
        for meter in card.meters {
            draw(meter.label, card)
            fill(meter.track, card.color(.rule), ctx)
            fill(meter.bar, card.color(meter.slot), ctx)
            draw(meter.value, card)
        }
        if let quote = card.quote {
            fill(quote.rule, card.color(.accent), ctx)
            draw(quote.label, card)
        }
        draw(card.foot, card)
        draw(card.footTag, card)
    }

    private static func paintCanvas(
        _ palette: AnalyticsShare.Palette, in rect: CGRect, ctx: CGContext
    ) {
        ctx.setFillColor(color(palette.canvas).cgColor)
        ctx.fill(rect)
        guard palette.canvasEnd != palette.canvas,
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [color(palette.canvas).cgColor, color(palette.canvasEnd).cgColor] as CFArray,
                locations: [0, 1])
        else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.drawLinearGradient(
            gradient, start: CGPoint(x: rect.midX, y: rect.minY),
            end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
        ctx.restoreGState()
    }

    private static func rect(_ source: NeuralShare.Rect) -> CGRect {
        CGRect(x: source.x, y: source.y, width: source.width, height: source.height)
    }

    private static func color(_ hex: String) -> NSColor {
        NSColor(hex: hex) ?? .gray
    }

    private static func fill(_ box: NeuralShare.Rect, _ hex: String, _ ctx: CGContext) {
        let target = rect(box)
        let radius = min(target.height / 2, 9)
        ctx.setFillColor(color(hex).cgColor)
        ctx.addPath(
            CGPath(
                roundedRect: target, cornerWidth: min(radius, target.width / 2),
                cornerHeight: radius, transform: nil))
        ctx.fillPath()
    }

    private static func font(_ role: NeuralShare.FontRole) -> NSFont {
        .monospacedSystemFont(ofSize: CGFloat(role.size), weight: role.bold ? .bold : .regular)
    }

    private static func draw(_ label: NeuralShare.Label, _ card: NeuralShare.Card) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = label.alignment == .trailing ? .right : .left
        paragraph.lineBreakMode = label.maxLines > 1 ? .byWordWrapping : .byTruncatingTail
        paragraph.lineHeightMultiple = label.maxLines > 1 ? CGFloat(NeuralShare.Card.quoteLeading) : 1
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(label.font), .foregroundColor: color(card.color(label.slot)),
            .paragraphStyle: paragraph,
        ]
        if label.font.tracking != 0 { attributes[.kern] = label.font.tracking * label.font.size }
        var box = rect(label.rect)
        let face = font(label.font)
        if label.maxLines <= 1 {
            let line = ceil(face.ascender - face.descender + face.leading)
            box.size.height = max(box.height, line)
            let natural = ceil(
                NSAttributedString(string: label.text, attributes: attributes).size().width)
            if natural > box.width, natural <= box.width * 1.15, label.alignment != .trailing {
                box.size.width = natural + 2
            }
        }
        NSAttributedString(string: label.text, attributes: attributes).draw(
            with: box, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
    }

    private static func drawRuns(
        _ runs: [NeuralShare.Run], in box: NeuralShare.Rect, _ card: NeuralShare.Card
    ) {
        let text = NSMutableAttributedString()
        let face = NSFont.monospacedSystemFont(ofSize: CGFloat(NeuralShare.Card.subSize), weight: .regular)
        for run in runs {
            text.append(
                NSAttributedString(
                    string: run.text,
                    attributes: [.font: face, .foregroundColor: color(card.color(run.slot))]))
        }
        text.draw(
            with: rect(box), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// The poster as it will leave, before it leaves. Sharing a picture nobody has seen is a guess, so
/// every road out of an open brain goes through this sheet: the poster drawn in the chosen look, a
/// pop-up that redraws it, and the three ways out. The head is drawn once more at full density when
/// a way out is pressed, so what leaves is sharp and what was shown was quick.
@MainActor
final class BrainSharePanel {
    private static var active: [BrainSharePanel] = []

    private let sheet: NSWindow
    private let preview = NSImageView()
    private let previewHeight: NSLayoutConstraint
    private let looks = NSPopUpButton()
    private weak var store: BrainStore?
    private weak var context: TranscriptContext?
    private let turnID: String
    private var style = CardStyle.app
    private var generation = 0
    private weak var shareAnchor: NSView?

    private static let previewWidth: CGFloat = 400
    static let lookKey = "tailscode.brainShareLook"

    static func present(
        turnID: String, store: BrainStore, context: TranscriptContext, on host: NSWindow
    ) {
        let panel = BrainSharePanel(turnID: turnID, store: store, context: context)
        active.append(panel)
        host.beginSheet(panel.sheet) { _ in active.removeAll { $0 === panel } }
        panel.render()
    }

    private init(turnID: String, store: BrainStore, context: TranscriptContext) {
        self.turnID = turnID
        self.store = store
        self.context = context
        if let id = UserDefaults.standard.string(forKey: Self.lookKey),
            let found = NeuralShare.looks.first(where: { $0.id == id })
        {
            style = found
        }
        sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 640), styleMask: [.titled],
            backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.title = Localized.text("Share this turn")

        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.imageAlignment = .alignTop
        preview.wantsLayer = true
        preview.layer?.cornerRadius = MacTheme.Radius.card
        preview.layer?.masksToBounds = true
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.widthAnchor.constraint(equalToConstant: Self.previewWidth).isActive = true
        previewHeight = preview.heightAnchor.constraint(equalToConstant: 500)
        previewHeight.isActive = true
        preview.setAccessibilityLabel(Localized.text("Poster preview"))

        for candidate in NeuralShare.looks {
            let item = NSMenuItem(title: candidate.name, action: nil, keyEquivalent: "")
            item.image = AnalyticsCardRenderer.swatch(candidate)
            item.toolTip = candidate.tagline
            item.representedObject = candidate.id
            looks.menu?.addItem(item)
            if candidate.id == style.id { looks.select(item) }
        }
        looks.target = self
        looks.action = #selector(lookChanged(_:))
        looks.setAccessibilityLabel(Localized.text("Poster look"))

        let label = NSTextField(labelWithString: Localized.text("Poster look"))
        label.font = MacTheme.Ramp.font(.panelLabel)
        label.textColor = MacTheme.Color.secondaryLabel
        let picker = NSStackView(views: [label, looks, RowKit.spacer()])
        picker.orientation = .horizontal
        picker.spacing = MacTheme.Spacing.s

        let copy = RowKit.ActionButton(title: Localized.text("Copy")) { [weak self] in
            self?.copyPoster()
        }
        let save = RowKit.ActionButton(title: Localized.text("Save…")) { [weak self] in
            self?.savePoster()
        }
        let send = RowKit.ActionButton(title: Localized.text("Share")) { [weak self] in
            self?.sharePoster()
        }
        send.keyEquivalent = "\r"
        shareAnchor = send
        let done = RowKit.ActionButton(title: Localized.text("Done")) { [weak self] in
            self?.close()
        }
        done.keyEquivalent = "\u{1B}"
        let footer = NSStackView(views: [done, RowKit.spacer(), copy, save, send])
        footer.orientation = .horizontal
        footer.spacing = MacTheme.Spacing.s

        let column = NSStackView(views: [picker, preview, footer])
        column.orientation = .vertical
        column.spacing = MacTheme.Spacing.m
        column.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        column.widthAnchor.constraint(equalToConstant: 440).isActive = true
        sheet.contentView = column
    }

    @objc private func lookChanged(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String,
            let picked = NeuralShare.looks.first(where: { $0.id == id }), picked.id != style.id
        else { return }
        style = picked
        UserDefaults.standard.set(picked.id, forKey: Self.lookKey)
        render()
    }

    private var isDark: Bool { NSApp.effectiveAppearance.isDark }

    private func render() {
        generation += 1
        let mine = generation
        guard let store, let context else { return }
        let style = style
        let turnID = turnID
        let dark = isDark
        Task { @MainActor [weak self] in
            let poster = await BrainPoster.render(
                store: store, context: context, turnID: turnID, style: style, dark: dark, scale: 1)
            guard let self, mine == self.generation, let poster else { return }
            self.preview.image = poster.image
            self.previewHeight.constant =
                (Self.previewWidth * poster.image.size.height / poster.image.size.width).rounded()
        }
    }

    private func withPoster(_ use: @escaping @MainActor (BrainPoster.Result) -> Void) {
        guard let store, let context else { return }
        let style = style
        let turnID = turnID
        let dark = isDark
        Task { @MainActor in
            guard
                let poster = await BrainPoster.render(
                    store: store, context: context, turnID: turnID, style: style, dark: dark,
                    scale: 2)
            else { return }
            use(poster)
        }
    }

    private func copyPoster() {
        withPoster { poster in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([poster.image])
        }
    }

    private func savePoster() {
        withPoster { [weak self] poster in
            guard let self else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = poster.filename
            panel.allowedContentTypes = [.png]
            panel.beginSheetModal(for: sheet) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try poster.data.write(to: url, options: .atomic)
                } catch {
                    guard let sheet = self?.sheet else { return }
                    NSAlert(error: error).beginSheetModal(for: sheet)
                }
            }
        }
    }

    private func sharePoster() {
        withPoster { [weak self] poster in
            guard let self, let source = shareAnchor ?? sheet.contentView else { return }
            var items: [Any] = []
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("shared-turn", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(poster.filename, isDirectory: false)
            if (try? poster.data.write(to: url, options: .atomic)) != nil {
                items.append(url)
            } else {
                items.append(poster.image)
            }
            let picker = NSSharingServicePicker(items: items)
            picker.show(relativeTo: source.bounds, of: source, preferredEdge: .minY)
        }
    }

    private func close() {
        sheet.sheetParent?.endSheet(sheet)
    }
}
