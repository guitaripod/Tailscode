import AppKit
import ImageIO
import TailscodeCore
import UniformTypeIdentifiers

/// The 56-point square at the dock's leading edge: a dashed drop target while nothing is held, the
/// picture itself once one is — with a small × to let it go — and a click either way opens the places
/// a reference can come from. A tile dragged from the shelf, a file from Finder and pixels copied from
/// a browser all land here.
@MainActor
final class StudioStartSlot: NSView {
    var onPickLibrary: ((NSView) -> Void)?
    var isEnabled = true {
        didSet { alphaValue = isEnabled ? 1 : 0.55 }
    }

    private let brief: any StudioBriefing
    private let caption = StudioTheme.label(.panelFootnote, color: MacTheme.Color.onGlassSecondary, alignment: .center)
    private var thumbnailID: String?
    private var thumbnail: CGImage?
    private var thumbnailTask: Task<Void, Never>?
    private var dropping = false
    private var hovering = false
    private var tracking: NSTrackingArea?
    private var removeRect: NSRect {
        NSRect(x: bounds.maxX - 18, y: bounds.minY - 2, width: 20, height: 20)
    }

    init(brief: any StudioBriefing) {
        self.brief = brief
        super.init(frame: .zero)
        caption.stringValue = Localized.text("Start from")
        addSubview(caption)
        registerForDraggedTypes(StudioDrop.registered)
        setAccessibilityRole(.button)
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Lights the target while a drag that could fill it is over the dock — the slot is the dock's
    /// drop target, so a picture dropped anywhere on the dock arrives here.
    func lightUp(_ on: Bool) {
        dropping = on
        needsDisplay = true
    }

    private var holdsStart = false

    func reload() {
        let held = brief.startHold
        holdsStart = held != nil
        caption.isHidden = held != nil
        if let held {
            if held.id != thumbnailID {
                thumbnailID = held.id
                thumbnail = nil
                loadThumbnail(held)
            }
            setAccessibilityLabel(
                Localized.text("Start from: %@", held.name))
            toolTip = held.tooltip
        } else {
            thumbnailID = nil
            thumbnail = nil
            thumbnailTask?.cancel()
            setAccessibilityLabel(brief.startEmptyTitle)
            toolTip = brief.startEmptyHint
        }
        needsDisplay = true
        needsLayout = true
    }

    private func loadThumbnail(_ held: StudioStartHold) {
        thumbnailTask?.cancel()
        let id = held.id
        thumbnailTask = Task { [weak self] in
            let image = await held.thumbnail()
            guard let self, !Task.isCancelled, self.thumbnailID == id else { return }
            self.thumbnail = image
            self.needsDisplay = true
        }
    }

    override func layout() {
        super.layout()
        let height = StudioTheme.height(of: .panelFootnote)
        caption.frame = NSRect(x: -4, y: bounds.height - height - 7, width: bounds.width + 8, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        if holdsStart {
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            if let thumbnail {
                let scale = max(
                    bounds.width / CGFloat(thumbnail.width), bounds.height / CGFloat(thumbnail.height))
                let size = NSSize(width: CGFloat(thumbnail.width) * scale, height: CGFloat(thumbnail.height) * scale)
                NSImage(cgImage: thumbnail, size: size).draw(
                    in: NSRect(
                        x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                        width: size.width, height: size.height))
            } else {
                MacTheme.Color.onGlass.withAlphaComponent(0.1).setFill()
                shape.fill()
                StudioTheme.symbol("photo", size: 18)?.draw(
                    in: NSRect(x: bounds.midX - 10, y: bounds.midY - 10, width: 20, height: 20))
            }
            NSGraphicsContext.restoreGraphicsState()
            MacTheme.Color.onGlass.withAlphaComponent(0.25).setStroke()
            shape.lineWidth = 1
            shape.stroke()
            drawRemove()
            return
        }
        (dropping ? MacTheme.Color.accent : MacTheme.Color.onGlassSecondary.withAlphaComponent(0.7)).setStroke()
        shape.lineWidth = 1
        shape.setLineDash([4, 3], count: 2, phase: 0)
        shape.stroke()
        if dropping {
            MacTheme.Color.accent.withAlphaComponent(0.12).setFill()
            shape.fill()
        }
        let plus = NSBezierPath()
        let cx = bounds.midX
        let cy: CGFloat = 19
        plus.move(to: NSPoint(x: cx - 5, y: cy))
        plus.line(to: NSPoint(x: cx + 5, y: cy))
        plus.move(to: NSPoint(x: cx, y: cy - 5))
        plus.line(to: NSPoint(x: cx, y: cy + 5))
        MacTheme.Color.onGlassSecondary.setStroke()
        plus.lineWidth = 1.3
        plus.lineCapStyle = .round
        plus.stroke()
    }

    private func drawRemove() {
        let badge = NSRect(x: bounds.maxX - 17, y: 3, width: 14, height: 14)
        MacTheme.Color.canvas.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: badge).fill()
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: badge.minX + 4, y: badge.minY + 4))
        cross.line(to: NSPoint(x: badge.maxX - 4, y: badge.maxY - 4))
        cross.move(to: NSPoint(x: badge.maxX - 4, y: badge.minY + 4))
        cross.line(to: NSPoint(x: badge.minX + 4, y: badge.maxY - 4))
        MacTheme.Color.label.setStroke()
        cross.lineWidth = 1.3
        cross.lineCapStyle = .round
        cross.stroke()
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        let point = convert(event.locationInWindow, from: nil)
        if holdsStart, NSRect(x: bounds.maxX - 20, y: 0, width: 20, height: 20).contains(point) {
            brief.releaseStart()
            return
        }
        openMenu()
    }

    private func openMenu() {
        let menu = NSMenu()
        brief.fillStartMenu(menu) { [weak self] in
            guard let self else { return }
            self.onPickLibrary?(self)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }

    override func accessibilityPerformPress() -> Bool {
        openMenu()
        return true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isEnabled, StudioDrop.accepts(sender.draggingPasteboard) else { return [] }
        dropping = true
        needsDisplay = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropping = false
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropping = false
        needsDisplay = true
        guard let drop = StudioDrop.read(sender.draggingPasteboard) else { return false }
        brief.hold(drop: drop) { _ in }
        return true
    }
}

/// A line of words asked for in a small popover: what a picture must keep out of the frame, what a
/// clip's sound is. Empty is the ordinary case — the machine decides and a render stays fast.
@MainActor
final class StudioWordsPopover: NSViewController, NSTextFieldDelegate {
    private let field = NSTextField()
    private let words: StudioWordsField
    private let apply: (String) -> Void
    private let cancel: () -> Void

    init(words: StudioWordsField, apply: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        self.words = words
        self.apply = apply
        self.cancel = cancel
        super.init(nibName: nil, bundle: nil)
        field.stringValue = words.current
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 128))
        let title = StudioTheme.label(.panelLabel, color: MacTheme.Color.label)
        title.stringValue = words.title
        let hint = StudioTheme.label(.panelFootnote, color: MacTheme.Color.secondaryLabel, lines: 3)
        hint.stringValue = words.hint
        field.placeholderString = words.placeholder
        field.font = MacTheme.Ramp.font(.panelLabel)
        field.delegate = self
        let apply = NSButton(title: ImageGenWords.applyTitle, target: self, action: #selector(applyPressed))
        apply.bezelStyle = .rounded
        apply.keyEquivalent = "\r"
        let cancel = NSButton(title: ImageGenWords.cancelTitle, target: self, action: #selector(cancelPressed))
        cancel.bezelStyle = .rounded
        title.frame = NSRect(x: 16, y: 96, width: 288, height: 18)
        hint.frame = NSRect(x: 16, y: 56, width: 288, height: 38)
        field.frame = NSRect(x: 16, y: 36, width: 288, height: 22)
        apply.frame = NSRect(x: 320 - 16 - 80, y: 6, width: 80, height: 26)
        cancel.frame = NSRect(x: 320 - 16 - 80 - 8 - 80, y: 6, width: 80, height: 26)
        for view in [title, hint, field, apply, cancel] { root.addSubview(view) }
        view = root
    }

    @objc private func applyPressed() { apply(field.stringValue) }
    @objc private func cancelPressed() { cancel() }
}

/// The machine's own gallery as a place to pick a reference from: the shelf's data in a grid, opened
/// as a popover over the slot that asked. A picture picked here is named by the machine, so nothing
/// travels.
@MainActor
final class StudioLibraryPicker: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private let brief: any StudioBriefing
    private let pick: (ImageGenLibraryItem) -> Void
    private let collection = NSCollectionView()
    private let note = StudioTheme.label(.panelFootnote, color: MacTheme.Color.secondaryLabel)
    private var items: [ImageGenLibraryItem] = []

    init(brief: any StudioBriefing, pick: @escaping (ImageGenLibraryItem) -> Void) {
        self.brief = brief
        self.pick = pick
        super.init(nibName: nil, bundle: nil)
        items = brief.library.items
        brief.watchLibrary(self) { [weak self] in
            guard let self else { return }
            self.items = self.brief.library.items
            self.note.stringValue = self.brief.library.line
            self.collection.reloadData()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { brief.unwatchLibrary(self) }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 380))
        note.stringValue = brief.library.line
        note.frame = NSRect(x: 16, y: 352, width: 388, height: 16)
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 88, height: 88)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.backgroundColors = [.clear]
        collection.register(StudioPickerTile.self, forItemWithIdentifier: StudioPickerTile.identifier)
        let scroll = NSScrollView(frame: NSRect(x: 8, y: 8, width: 404, height: 336))
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        root.addSubview(note)
        root.addSubview(scroll)
        view = root
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(
        _ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let tile = collectionView.makeItem(
            withIdentifier: StudioPickerTile.identifier, for: indexPath)
        guard let tile = tile as? StudioPickerTile else { return tile }
        tile.show(items[indexPath.item], library: brief.library)
        return tile
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let index = indexPaths.first?.item, items.indices.contains(index) else { return }
        pick(items[index])
    }
}

@MainActor
final class StudioPickerTile: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("studio.picker.tile")
    private var task: Task<Void, Never>?
    private let picture = NSImageView()

    override func loadView() {
        picture.imageScaling = .scaleAxesIndependently
        picture.wantsLayer = true
        picture.layer?.cornerRadius = 10
        picture.layer?.cornerCurve = .continuous
        picture.layer?.masksToBounds = true
        view = picture
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        task?.cancel()
        picture.image = nil
    }

    func show(_ item: ImageGenLibraryItem, library: MacImageLibrary) {
        picture.setAccessibilityLabel(library.facts(of: item)?.recipe?.prompt ?? item.filename)
        if let held = library.cachedThumbnail(of: item) {
            picture.image = held
            return
        }
        task?.cancel()
        task = Task { [weak self] in
            let image = await library.thumbnail(of: item)
            guard !Task.isCancelled else { return }
            self?.picture.image = image
        }
    }
}
