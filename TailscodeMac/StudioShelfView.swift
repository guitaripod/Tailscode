import AppKit
import TailscodeCore
import UniformTypeIdentifiers

/// What this machine has made, newest first, always with its picture: the machine's folder merged with
/// this session's own, a job in flight leading as a tile that wears the sketch it is painting. It is a
/// 112-point rail beside the stage, and under 960 points of window width a strip above the dock — the
/// same tiles either way, 88 points square, aspect-filled, eight apart, the one on stage ringed in the
/// accent. A tile is a picture: click puts it on stage, double-click opens it full size, right-click
/// offers the same verbs the stage does, and dragging one out hands Finder or another app a file
/// promise of the original bytes the machine wrote — never the thumbnail it is drawn from.
@MainActor
final class StudioShelfView: NSView, NSCollectionViewDelegate {
    enum Orientation { case rail, strip }

    var orientation: Orientation = .rail {
        didSet {
            guard orientation != oldValue else { return }
            flow.scrollDirection = orientation == .rail ? .vertical : .horizontal
            scroll.hasVerticalScroller = orientation == .rail
            scroll.hasHorizontalScroller = orientation == .strip
            heading.isHidden = orientation == .strip
            applyInsets()
            needsLayout = true
            collection.reloadData()
        }
    }

    private weak var lane: (any StudioLane)?
    private let heading = StudioTheme.label(.sectionLabel, color: MacTheme.Color.secondaryLabel)
    private let note = StudioTheme.label(.panelFootnote, color: MacTheme.Color.secondaryLabel, lines: 6)
    private let scroll = NSScrollView()
    private let collection = StudioCollectionView()
    private let flow = NSCollectionViewFlowLayout()
    private var items: [StudioShelfItem] = []
    private var byID: [String: StudioShelfItem] = [:]
    private lazy var source = NSCollectionViewDiffableDataSource<Int, String>(collectionView: collection) {
        [weak self] collection, indexPath, id in
        let tile = collection.makeItem(withIdentifier: StudioTileItem.identifier, for: indexPath)
        guard let tile = tile as? StudioTileItem, let self, let lane = self.lane, let item = self.byID[id]
        else { return tile }
        tile.show(item, lane: lane, selected: lane.selectedTile == id)
        tile.onActivate = { [weak self] in self?.lane?.select(tile: id) }
        tile.onOpen = { [weak self] in
            guard let self, let item = self.byID[id] else { return }
            self.lane?.select(tile: id)
            self.lane?.perform(.action(.open), on: item)
        }
        tile.menuProvider = { [weak self] in self?.menu(for: id) }
        return tile
    }

    init(lane: any StudioLane) {
        self.lane = lane
        super.init(frame: .zero)
        heading.stringValue = Localized.text("Shelf").uppercased()
        heading.setAccessibilityElement(false)
        flow.itemSize = NSSize(width: StudioTheme.tile, height: StudioTheme.tile)
        flow.minimumLineSpacing = StudioTheme.gutter
        flow.minimumInteritemSpacing = StudioTheme.gutter
        flow.scrollDirection = .vertical
        collection.collectionViewLayout = flow
        collection.delegate = self
        collection.isSelectable = true
        collection.allowsMultipleSelection = false
        collection.backgroundColors = [.clear]
        collection.register(StudioTileItem.self, forItemWithIdentifier: StudioTileItem.identifier)
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        collection.setDraggingSourceOperationMask(.copy, forLocal: true)
        scroll.documentView = collection
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        addSubview(heading)
        addSubview(scroll)
        addSubview(note)
        applyInsets()
        setAccessibilityRole(.list)
        setAccessibilityLabel(Localized.text("Shelf"))
        _ = source
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func applyInsets() {
        flow.sectionInset =
            orientation == .rail
            ? NSEdgeInsets(top: 2, left: 12, bottom: 12, right: 12)
            : NSEdgeInsets(top: 4, left: 16, bottom: 4, right: 16)
    }

    /// The shelf the lane describes, applied as a difference so a job tile slides in rather than the
    /// column being rebuilt under a hand that is scrolling it.
    func reload(animated: Bool = true) {
        guard let lane else { return }
        let next = lane.shelf
        let ids = next.map(\.id)
        let changed = ids != items.map(\.id)
        let old = byID
        items = next
        byID = Dictionary(uniqueKeysWithValues: next.map { ($0.id, $0) })
        collection.studioItems = next
        if changed {
            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0])
            snapshot.appendItems(ids)
            let slide = animated && StudioTheme.motionAllowed && window != nil
            if slide {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = StudioTheme.tileSlide
                    source.apply(snapshot, animatingDifferences: true)
                }
            } else {
                source.apply(snapshot, animatingDifferences: false)
            }
        }
        for tile in collection.visibleItems().compactMap({ $0 as? StudioTileItem }) {
            guard let id = tile.itemID, let item = byID[id] else { continue }
            if old[id] != item || tile.isSelectedTile != (lane.selectedTile == id) {
                tile.show(item, lane: lane, selected: lane.selectedTile == id)
            }
        }
        refreshJob()
        updateNote()
    }

    func refreshSelection() {
        guard let lane else { return }
        for tile in collection.visibleItems().compactMap({ $0 as? StudioTileItem }) {
            guard let id = tile.itemID else { continue }
            tile.setSelected(lane.selectedTile == id)
        }
        scrollSelectionIntoView()
    }

    func refreshTile(_ id: String) {
        guard let lane, let item = byID[id] else { return }
        for tile in collection.visibleItems().compactMap({ $0 as? StudioTileItem }) where tile.itemID == id {
            tile.show(item, lane: lane, selected: lane.selectedTile == id)
        }
    }

    /// The sketch and the sampler's count on the job's tile, moved in place: a frame changes one
    /// layer's contents and one badge and never the tile's size.
    func refreshJob() {
        guard let lane else { return }
        for tile in collection.visibleItems().compactMap({ $0 as? StudioTileItem }) where tile.isJob {
            tile.setJob(sketch: lane.jobSketch, badge: lane.jobBadge, fraction: lane.jobFraction)
        }
    }

    private func scrollSelectionIntoView() {
        guard let lane, let id = lane.selectedTile, let index = items.firstIndex(where: { $0.id == id })
        else { return }
        collection.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: [.nearestVerticalEdge, .nearestHorizontalEdge])
    }

    private func updateNote() {
        let text = lane?.shelfNote
        note.stringValue = text ?? (items.isEmpty ? ImageGenLibraryWords.emptyTitle : "")
        note.isHidden = note.stringValue.isEmpty
        needsLayout = true
    }

    override func layout() {
        super.layout()
        switch orientation {
        case .rail:
            let headingHeight = StudioTheme.height(of: .sectionLabel)
            heading.frame = NSRect(x: 16, y: 6, width: bounds.width - 24, height: headingHeight)
            var top = headingHeight + 12
            if !note.isHidden {
                let height = note.attributedStringValue.boundingRect(
                    with: NSSize(width: bounds.width - 24, height: 400),
                    options: [.usesLineFragmentOrigin]).height
                note.frame = NSRect(x: 12, y: top, width: bounds.width - 24, height: ceil(height) + 2)
                top += ceil(height) + 12
            }
            scroll.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        case .strip:
            let side = max(32, bounds.height - 8)
            flow.itemSize = NSSize(width: side, height: side)
            if !note.isHidden, items.isEmpty {
                note.frame = NSRect(x: 16, y: (bounds.height - 16) / 2, width: bounds.width - 32, height: 16)
            } else {
                note.frame = .zero
            }
            scroll.frame = bounds
        }
        if orientation == .rail { flow.itemSize = NSSize(width: StudioTheme.tile, height: StudioTheme.tile) }
    }

    private func menu(for id: String) -> NSMenu? {
        guard let lane, let item = byID[id], !item.isJob else { return nil }
        let menu = NSMenu()
        for verb in lane.tileVerbs(for: item) {
            let title: String
            let symbol: String
            switch verb {
            case .putOnStage:
                title = ImageGenAction.stage.title
                symbol = ImageGenAction.stage.symbol
            case .action(let action):
                title = action.title
                symbol = action.symbol
            }
            let entry = ClosureMenuItem(title: title) { [weak lane] in lane?.perform(verb, on: item) }
            entry.image = StudioTheme.symbol(symbol, size: 12)
            menu.addItem(entry)
        }
        return menu
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        collectionView.deselectItems(at: indexPaths)
        guard let index = indexPaths.first?.item, items.indices.contains(index) else { return }
        let item = items[index]
        guard !item.isJob else { return }
        lane?.select(tile: item.id)
    }

    func collectionView(
        _ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent
    ) -> Bool {
        guard let index = indexPaths.first?.item, items.indices.contains(index) else { return false }
        return !items[index].isJob
    }

    func collectionView(
        _ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath
    ) -> NSPasteboardWriting? {
        guard let lane, items.indices.contains(indexPath.item) else { return nil }
        let item = items[indexPath.item]
        guard !item.isJob else { return nil }
        let name = lane.tileFileName(item)
        let type = UTType(filenameExtension: (name as NSString).pathExtension) ?? .png
        let provider = StudioTilePromise(fileType: type.identifier, delegate: StudioPromiseSource.shared)
        provider.tileID = item.id
        provider.userInfo = StudioPromiseRequest(item: item, name: name, lane: lane)
        return provider
    }
}

/// A collection view that knows which tile a click landed on without selecting it, because on this
/// shelf a click acts and the one on stage is the one that wears the ring.
@MainActor
final class StudioCollectionView: NSCollectionView {
    var studioItems: [StudioShelfItem] = []

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let path = indexPathForItem(at: point),
            let tile = item(at: path) as? StudioTileItem
        else { return nil }
        return tile.menuProvider?()
    }
}

/// A shelf tile as it travels in a drag: the machine's file as a promise, and the tile's name beside
/// it so a drag that never leaves the window is read as the tile it is.
final class StudioTilePromise: NSFilePromiseProvider, @unchecked Sendable {
    nonisolated(unsafe) var tileID = ""

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [StudioDrop.tileType]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == StudioDrop.tileType { return tileID }
        return super.pasteboardPropertyList(forType: type)
    }
}

@MainActor
struct StudioPromiseRequest {
    let item: StudioShelfItem
    let name: String
    let lane: any StudioLane
}

/// Writes the original bytes where Finder or another app asked for the file. The promise is kept
/// when the drop lands, not when the drag starts, so a drag that goes nowhere costs the machine no
/// download.
@MainActor
final class StudioPromiseSource: NSObject, NSFilePromiseProviderDelegate {
    static let shared = StudioPromiseSource()

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (filePromiseProvider.userInfo as? StudioPromiseRequest)?.name ?? "picture.png"
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        .main
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        nonisolated(unsafe) let finish = completionHandler
        let request = filePromiseProvider.userInfo as? StudioPromiseRequest
        guard let request else {
            finish(CocoaError(.fileNoSuchFile))
            return
        }
        Task { @MainActor in
            guard let file = await request.lane.tileFile(request.item) else {
                finish(CocoaError(.fileReadUnknown))
                return
            }
            do {
                try file.data.write(to: url, options: .atomic)
                finish(nil)
            } catch {
                finish(error)
            }
        }
    }
}

/// One tile: a picture aspect-filled into eighty-eight points, the ring on the one on stage, and —
/// for the job in flight — the sketch it is painting with the sampler's count and a line under it.
@MainActor
final class StudioTileItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("studio.tile")

    var onActivate: (() -> Void)?
    var onOpen: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    private(set) var itemID: String?
    private(set) var isJob = false
    private(set) var isSelectedTile = false
    private var task: Task<Void, Never>?
    private var tile: StudioTileView? { view as? StudioTileView }

    override func loadView() {
        let tile = StudioTileView()
        tile.onClick = { [weak self] count in
            if count >= 2 { self?.onOpen?() } else { self?.onActivate?() }
        }
        view = tile
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        task?.cancel()
        itemID = nil
        tile?.reset()
    }

    func show(_ item: StudioShelfItem, lane: any StudioLane, selected: Bool) {
        let changed = itemID != item.id
        itemID = item.id
        isJob = item.isJob
        isSelectedTile = selected
        tile?.configure(item: item, selected: selected, tooltip: lane.tileTooltip(item))
        if item.isJob {
            tile?.setJob(sketch: lane.jobSketch, badge: lane.jobBadge, fraction: lane.jobFraction)
            return
        }
        guard changed || tile?.hasPicture == false else { return }
        task?.cancel()
        task = Task { [weak self, weak lane] in
            guard let lane else { return }
            let image = await lane.tileThumbnail(item)
            guard !Task.isCancelled, self?.itemID == item.id else { return }
            self?.tile?.setPicture(image)
        }
    }

    func setSelected(_ selected: Bool) {
        isSelectedTile = selected
        tile?.setSelected(selected)
    }

    func setJob(sketch: CGImage?, badge: String?, fraction: Double?) {
        tile?.setJob(sketch: sketch, badge: badge, fraction: fraction)
    }
}

@MainActor
final class StudioTileView: NSView {
    var onClick: ((Int) -> Void)?
    private(set) var hasPicture = false
    private let picture = CALayer()
    private let ring = CALayer()
    private let wash = CALayer()
    private let bar = CALayer()
    private let badge = StudioPill()
    private let glyph = NSImageView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        picture.contentsGravity = .resizeAspectFill
        picture.masksToBounds = true
        picture.cornerRadius = 12
        picture.cornerCurve = .continuous
        wash.cornerRadius = 12
        wash.cornerCurve = .continuous
        ring.cornerRadius = 12
        ring.cornerCurve = .continuous
        ring.borderWidth = 2
        ring.isHidden = true
        bar.isHidden = true
        layer?.addSublayer(wash)
        layer?.addSublayer(picture)
        layer?.addSublayer(bar)
        layer?.addSublayer(ring)
        glyph.imageScaling = .scaleProportionallyDown
        addSubview(glyph)
        addSubview(badge)
        badge.isHidden = true
        setAccessibilityRole(.button)
        restyle()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged), name: MacTheme.Chrome.didRepaint, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func themeChanged() { restyle() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            wash.backgroundColor = MacTheme.Color.canvasRaised.cgColor
            ring.borderColor = MacTheme.Color.accent.cgColor
            bar.backgroundColor = MacTheme.Color.accent.cgColor
        }
        glyph.contentTintColor = MacTheme.Color.tertiaryLabel
    }

    func reset() {
        picture.contents = nil
        hasPicture = false
        ring.isHidden = true
        bar.isHidden = true
        badge.isHidden = true
        glyph.image = nil
    }

    func configure(item: StudioShelfItem, selected: Bool, tooltip: String) {
        toolTip = tooltip
        setAccessibilityLabel(item.words.isEmpty ? (item.isJob ? Localized.text("Painting") : Localized.text("Picture")) : item.words)
        setSelected(selected)
        if item.kind == .clip {
            glyph.image = StudioTheme.symbol("play.fill", size: 16)
        } else if !hasPicture {
            glyph.image = StudioTheme.symbol("photo", size: 18)
        }
        glyph.isHidden = hasPicture
    }

    func setSelected(_ selected: Bool) {
        ring.isHidden = !selected
        setAccessibilitySelected(selected)
    }

    func setPicture(_ image: NSImage?) {
        hasPicture = image != nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.contents = image
        CATransaction.commit()
        glyph.isHidden = hasPicture
    }

    func setJob(sketch: CGImage?, badge text: String?, fraction: Double?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.contents = sketch
        hasPicture = sketch != nil
        glyph.isHidden = sketch != nil
        if let fraction {
            bar.isHidden = false
            bar.frame = CGRect(x: 0, y: bounds.height - 3, width: bounds.width * CGFloat(max(0, min(1, fraction))), height: 3)
        } else {
            bar.isHidden = true
        }
        CATransaction.commit()
        if let text {
            badge.text = text
            badge.isHidden = false
        } else {
            badge.isHidden = true
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [picture, wash, ring] { layer.frame = bounds }
        CATransaction.commit()
        glyph.frame = NSRect(x: bounds.midX - 12, y: bounds.midY - 12, width: 24, height: 24)
        let size = badge.fittingSize
        badge.frame = NSRect(x: 6, y: 6, width: size.width, height: size.height)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onClick?(2) }
        super.mouseDown(with: event)
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?(1)
        return true
    }
}
