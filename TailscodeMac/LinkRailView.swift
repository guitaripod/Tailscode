import AppKit
import TailscodeCore

/// What one rail knows about its addresses and how it learns more: Core's reading, the favicons
/// decoded for it, and the fetches it has asked for. The words are Core's `LinkRailReading`, the
/// asking is `LinkRailPolicy.fetchPlan`, the debounce and the network are Core's too; this holds
/// them for the line that draws the rest and the plate that draws the list, which both watch it.
///
/// An address never reads as a page nobody has looked at: the host wears the face until the page's
/// own title arrives and stays if it never does. A fetch that lands writes into the model and the
/// model tells whoever is still watching, so a rail taken out of the transcript mid-fetch is
/// written into harmlessly — nothing holds the model but the views that draw it.
@MainActor
final class LinkRailModel {
    let urls: [String]
    private let source: LinkCardSource
    private(set) var reading: LinkRailReading
    private(set) var icons: [String: NSImage] = [:]
    private var fetches = LinkRailFetches()
    private var watchers: [(owner: Weak, change: () -> Void)] = []
    private(set) var requested: [String] = []

    final class Weak {
        weak var value: AnyObject?
        init(_ value: AnyObject) { self.value = value }
    }

    init(urls: [String], source: LinkCardSource = .live) {
        self.urls = urls
        self.source = source
        var reading = LinkRailReading.placeholder(for: urls)
        for url in urls {
            if let held = source.cachedFace(url) { reading = reading.replacing(held, for: url) }
            if let icon = ImageStore.shared.icon(forKey: url) { icons[url] = icon }
        }
        self.reading = reading
    }

    /// Tells `change` whenever a face or an icon lands, for as long as `owner` is alive.
    func watch(_ owner: AnyObject, _ change: @escaping () -> Void) {
        watchers.removeAll { $0.owner.value == nil }
        watchers.append((Weak(owner), change))
    }

    private func announce() {
        watchers.removeAll { $0.owner.value == nil }
        for watcher in watchers { watcher.change() }
    }

    /// Asks about the first addresses at creation and, once the rail has been opened, about all of
    /// them; an address already asked about is not asked about again.
    func begin(opened: Bool) {
        let fresh = fetches.claim(for: urls, opened: opened)
        requested += fresh
        for url in fresh { fetch(url) }
    }

    private func fetch(_ url: String) {
        let source = source
        guard let target = URL(string: url) else { return }
        if source.cachedFace(url) != nil {
            Task { [weak self] in await self?.paintIcon(url) }
            return
        }
        Task { [weak self] in
            let wanted = await LinkEmbedPolicy.settle(debounce: source.debounce) {
                @MainActor [weak self] in self != nil
            }
            guard wanted else { return }
            let metadata = await source.metadata(url)
            guard let self, !Task.isCancelled else { return }
            self.reading = self.reading.replacing(.settled(for: target, metadata: metadata), for: url)
            self.announce()
            await self.paintIcon(url)
        }
    }

    private func paintIcon(_ url: String) async {
        if let cached = ImageStore.shared.icon(forKey: url) {
            icons[url] = cached
            announce()
            return
        }
        guard let data = await source.favicon(url), !Task.isCancelled else { return }
        let decoded = await Task.detached(priority: .utility) { ImageStore.decode(data) }.value
        guard let decoded else { return }
        ImageStore.shared.store(icon: decoded.image, forKey: url)
        icons[url] = decoded.image
        announce()
    }
}

/// A page's own mark on a small round tile: favicons are mostly dark and a light tile keeps one
/// legible on a dark transcript without washing it out on a light one. Until the icon is known the
/// tile holds the host's glyph, a globe.
@MainActor
final class FaviconChip: NSView {
    private let imageView = NSImageView()
    private let side: CGFloat

    init(side: CGFloat) {
        self.side = side
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        wantsLayer = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setAccessibilityElement(false)
        addSubview(imageView)
        setAccessibilityElement(false)
        show(nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

    override func layout() {
        super.layout()
        let inset = side * 0.18
        imageView.frame = bounds.insetBy(dx: inset, dy: inset)
        layer?.cornerRadius = side / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Self.tile.cgColor
            layer?.borderColor = MacTheme.Color.canvas.cgColor
        }
        layer?.borderWidth = 1
    }

    private static var tile: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.94, alpha: 1) : MacTheme.Color.canvasRaised
        }
    }

    func show(_ icon: NSImage?) {
        paint()
        if let icon {
            imageView.image = icon
            imageView.contentTintColor = nil
        } else {
            imageView.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
                .withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: side * 0.7, weight: .medium))
            imageView.contentTintColor = MacTheme.Color.secondaryLabel
        }
    }
}

/// The rail at rest: a favicon stack, the hosts in link ink, `+N`, and a quiet chevron, on one line
/// of the table's height that never changes with the stage of any fetch. No plate and no card: the
/// line sits on the canvas, and what opens from it floats over the rows below.
///
/// It is one pressable thing for the keyboard and for VoiceOver — a disclosure button saying how
/// many links and which — and the pointer's resting on it is watched by the transcript's own
/// tracking area, never by one of its own.
@MainActor
final class LinkRailLine: NSView, KeyboardPressable {
    let key: String
    let model: LinkRailModel
    var onActivate: ((_ viaKeyboard: Bool) -> Void)?
    var menuActions: (copyAll: () -> Void, openAll: () -> Void)?

    private let stack = NSView()
    private let chips: [FaviconChip]
    private let titleLabel = RowKit.label("", font: MacTheme.Ramp.font(.panelFootnote), color: .linkColor)
    private let hostLabel = RowKit.label("", font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.tertiaryLabel)
    private let moreLabel = RowKit.label("", font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.tertiaryLabel)
    private let chevron = RowKit.label("›", font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.tertiaryLabel)
    private let content = NSView()
    private var expanded = false
    private let height: CGFloat

    private static let chipSide: CGFloat = 14
    private static let overlap: CGFloat = 4

    init(key: String, model: LinkRailModel, height: CGFloat) {
        self.key = key
        self.model = model
        self.height = height
        chips = (0..<min(model.urls.count, LinkRailPolicy.stackSize)).map { _ in
            FaviconChip(side: Self.chipSide)
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        for chip in chips.reversed() {
            chip.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(chip)
        }
        for label in [titleLabel, hostLabel, moreLabel, chevron] {
            content.addSubview(label)
            label.lineBreakMode = .byTruncatingTail
        }
        hostLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        moreLabel.setContentHuggingPriority(.required, for: .horizontal)
        moreLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stackWidth =
            Self.chipSide + CGFloat(max(0, chips.count - 1)) * (Self.chipSide - Self.overlap)
        var constraints: [NSLayoutConstraint] = [
            heightAnchor.constraint(equalToConstant: height),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            content.heightAnchor.constraint(equalToConstant: Self.chipSide + 4),
        ]
        for (index, chip) in chips.enumerated() {
            constraints += [
                chip.leadingAnchor.constraint(
                    equalTo: content.leadingAnchor,
                    constant: CGFloat(index) * (Self.chipSide - Self.overlap)),
                chip.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                chip.widthAnchor.constraint(equalToConstant: Self.chipSide),
                chip.heightAnchor.constraint(equalToConstant: Self.chipSide),
            ]
        }
        constraints += [
            titleLabel.leadingAnchor.constraint(
                equalTo: content.leadingAnchor, constant: stackWidth + MacTheme.Spacing.s),
            titleLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            hostLabel.leadingAnchor.constraint(
                equalTo: model.urls.count == 1 ? titleLabel.trailingAnchor : content.leadingAnchor,
                constant: model.urls.count == 1 ? MacTheme.Spacing.s : stackWidth + MacTheme.Spacing.s),
            hostLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            moreLabel.leadingAnchor.constraint(
                equalTo: hostLabel.trailingAnchor, constant: MacTheme.Spacing.s),
            moreLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            chevron.leadingAnchor.constraint(
                equalTo: moreLabel.trailingAnchor, constant: MacTheme.Spacing.xs),
            chevron.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ]
        NSLayoutConstraint.activate(constraints)
        let single = model.urls.count == 1
        titleLabel.isHidden = !single
        hostLabel.setContentHuggingPriority(single ? .required : .defaultLow, for: .horizontal)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityHelp(Localized.text("Shows the links"))
        model.watch(self) { [weak self] in self?.restate() }
        restate()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var focusRingMaskBounds: NSRect { content.frame.insetBy(dx: -4, dy: 0) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: content.frame.insetBy(dx: -4, dy: 0), xRadius: 6, yRadius: 6).fill()
    }

    /// Where the line has something to press, in its own coordinates: the hosts and the chevron,
    /// not the empty width to their right.
    var hitRect: NSRect { content.frame.insetBy(dx: -MacTheme.Spacing.s, dy: 0) }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(hitRect, cursor: .pointingHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hitRect.contains(convert(point, from: superview)) ? self : hit
    }

    /// The reading, redrawn. The widths of the labels change and the height of the line does not.
    func restate() {
        let reading = model.reading
        for (index, chip) in chips.enumerated() { chip.show(model.icons[reading.urls[index]]) }
        if let single = reading.singleTitle {
            titleLabel.stringValue = single
            hostLabel.stringValue = reading.items[0].face.host
            hostLabel.textColor = MacTheme.Color.tertiaryLabel
        } else {
            titleLabel.stringValue = ""
            hostLabel.stringValue = reading.hostsLine
            hostLabel.textColor = .linkColor
        }
        moreLabel.stringValue = reading.moreLabel ?? ""
        moreLabel.isHidden = reading.moreLabel == nil
        chevron.stringValue = expanded ? "⌄" : "›"
        setAccessibilityLabel(reading.spoken(expanded: expanded))
    }

    func setExpanded(_ open: Bool) {
        guard open != expanded else { return }
        expanded = open
        restate()
        setAccessibilityExpanded(open)
    }

    override func mouseDown(with event: NSEvent) {
        guard hitRect.contains(convert(event.locationInWindow, from: nil)) else {
            return super.mouseDown(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard hitRect.contains(convert(event.locationInWindow, from: nil)) else {
            return super.mouseUp(with: event)
        }
        onActivate?(false)
    }

    override func keyDown(with event: NSEvent) {
        guard [49, 36, 76].contains(event.keyCode) else { return super.keyDown(with: event) }
        onActivate?(true)
    }

    override func accessibilityPerformPress() -> Bool {
        onActivate?(true)
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard hitRect.contains(convert(event.locationInWindow, from: nil)), let menuActions else { return nil }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: LinkRailReading.copyAllTitle) { menuActions.copyAll() })
        menu.addItem(ClosureMenuItem(title: LinkRailReading.openAllTitle) { menuActions.openAll() })
        return menu
    }

    var plateAnchor: NSRect { convert(hitRect, to: nil) }
}

/// One address of the opened rail: its favicon, its title on one line, its host at the trailing
/// edge. It is the actual target, which is why it is as tall as the table says.
@MainActor
private final class LinkRailRow: NSView {
    let url: String
    private let chip = FaviconChip(side: 16)
    private let title = RowKit.label("", font: MacTheme.Ramp.font(.panelLabel), color: MacTheme.Color.label)
    private let host = RowKit.label("", font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.tertiaryLabel)
    private let wash = RowKit.Ground(frame: .zero)

    init(url: String, height: CGFloat) {
        self.url = url
        super.init(frame: .zero)
        wash.radius = 8
        wash.alphaValue = 0
        wash.fill = NSColor.labelColor.withAlphaComponent(0.09)
        addSubview(wash)
        for view in [chip, title, host] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        host.setContentHuggingPriority(.required, for: .horizontal)
        host.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        host.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),
            chip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            chip.centerYAnchor.constraint(equalTo: centerYAnchor),
            chip.widthAnchor.constraint(equalToConstant: 16),
            chip.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: chip.trailingAnchor, constant: 12),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            host.leadingAnchor.constraint(
                greaterThanOrEqualTo: title.trailingAnchor, constant: MacTheme.Spacing.m),
            host.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            host.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.link)
        setAccessibilityHelp(Localized.text("Opens the link"))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        wash.frame = bounds.insetBy(dx: 4, dy: 1)
    }

    var highlighted = false {
        didSet { wash.alphaValue = highlighted ? 1 : 0 }
    }

    func apply(_ face: LinkCardFace, icon: NSImage?) {
        title.stringValue = face.headline
        title.textColor = face.headlineIsQuiet ? MacTheme.Color.secondaryLabel : MacTheme.Color.label
        host.stringValue = face.host
        chip.show(icon)
        setAccessibilityLabel(face.spoken)
    }
}

/// The plate's rows, counted from the top the way they read.
private final class TopDownDocument: NSView {
    nonisolated override var isFlipped: Bool { true }
}

/// The opened rail: a floating list, one layer of glass, over the rows below the line. It lives in
/// the transcript's overlay and never in a row, so the page's layout does not know it exists and no
/// row moves when it comes and goes. Rows are the table's height, `railPlateRows` of them showing
/// and the rest reached by scrolling; the row under the pointer or the keyboard is washed.
@MainActor
final class LinkRailPlateView: NSView {
    let model: LinkRailModel
    var onOpen: ((URL) -> Void)?
    var onCopy: ((String) -> Void)?
    var onPointer: ((Bool) -> Void)?
    var onEscape: (() -> Void)?

    private let rows: [LinkRailRow]
    private let scroll = NSScrollView()
    private let document = TopDownDocument()
    private let glass: NSGlassEffectView
    private let rowHeight: CGFloat
    private(set) var selection: Int?

    init(model: LinkRailModel, metrics: ChatMetrics, width: CGFloat) {
        self.model = model
        rowHeight = CGFloat(metrics.railOpenRowHeight)
        rows = model.urls.map { LinkRailRow(url: $0, height: CGFloat(metrics.railOpenRowHeight)) }
        let visibleHeight = CGFloat(LinkRailPlate.plateHeight(rows: model.urls.count, metrics: metrics))
        let size = NSSize(width: width, height: visibleHeight + 8)
        glass = MacTheme.glass(around: scroll, cornerRadius: MacTheme.Radius.control)
        super.init(frame: NSRect(origin: .zero, size: size))
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(
                x: 0, y: CGFloat(index) * rowHeight + 4, width: width, height: rowHeight)
            document.addSubview(row)
        }
        document.frame = NSRect(
            x: 0, y: 0, width: width, height: CGFloat(rows.count) * rowHeight + 8)
        let clip = RowKit.FlippedClip()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = rows.count > metrics.railPlateRows
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        glass.translatesAutoresizingMaskIntoConstraints = true
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self, userInfo: nil))
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel(Localized.text("Links (%lld)", model.urls.count))
        model.watch(self) { [weak self] in self?.restate() }
        restate()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var plateSize: NSSize { frame.size }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func restate() {
        for (index, row) in rows.enumerated() {
            let item = model.reading.items[index]
            row.apply(item.face, icon: model.icons[item.url])
        }
    }

    override func mouseEntered(with event: NSEvent) { onPointer?(true) }
    override func mouseExited(with event: NSEvent) {
        select(nil)
        onPointer?(false)
    }

    override func mouseMoved(with event: NSEvent) {
        onPointer?(true)
        select(index(at: event))
    }

    override func scrollWheel(with event: NSEvent) {
        scroll.scrollWheel(with: event)
    }

    private func index(at event: NSEvent) -> Int? {
        let point = document.convert(event.locationInWindow, from: nil)
        let index = Int(floor((point.y - 4) / rowHeight))
        return rows.indices.contains(index) ? index : nil
    }

    func select(_ index: Int?) {
        guard index != selection else { return }
        if let selection, rows.indices.contains(selection) { rows[selection].highlighted = false }
        selection = index
        if let index {
            rows[index].highlighted = true
            document.scrollToVisible(rows[index].frame)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let index = index(at: event), let url = URL(string: model.urls[index]) else { return }
        if event.modifierFlags.contains(.command) {
            onCopy?(model.urls[index])
        } else {
            onOpen?(url)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let index = index(at: event) else { return nil }
        select(index)
        let address = model.urls[index]
        let menu = NSMenu()
        menu.addItem(
            ClosureMenuItem(title: Localized.text("Copy address")) { [weak self] in
                self?.onCopy?(address)
            })
        return menu
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: select(min(rows.count - 1, (selection ?? -1) + 1))
        case 126: select(max(0, (selection ?? rows.count) - 1))
        case 36, 76, 49:
            guard let selection, let url = URL(string: model.urls[selection]) else { return }
            onOpen?(url)
        case 53: onEscape?()
        default: super.keyDown(with: event)
        }
    }

    var rowViews: [NSView] { rows }
}
