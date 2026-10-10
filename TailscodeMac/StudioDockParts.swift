import AppKit
import ImageIO
import TailscodeCore
import UniformTypeIdentifiers

/// A pill drawn the way the chat composer's own pills read: a small capsule of the ink the glass
/// derives its own register from, a symbol down its left edge, the value beside it and a chevron when
/// it opens something. It draws itself rather than wearing a bezel, so a value is measured to its
/// ink and is never clipped — the row that holds it decides whether it fits at all.
@MainActor
final class StudioChipButton: NSView {
    var onPress: ((StudioChipButton) -> Void)?
    var isEnabled = true {
        didSet { if isEnabled != oldValue { needsDisplay = true; alphaValue = isEnabled ? 1 : 0.5 } }
    }

    private(set) var chip: StudioChip
    let opens: Bool
    private var tracking: NSTrackingArea?
    private var hovering = false
    private var pressing = false

    init(chip: StudioChip, opens: Bool) {
        self.chip = chip
        self.opens = opens
        super.init(frame: .zero)
        setAccessibilityRole(.button)
        configureAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(_ next: StudioChip) {
        guard next != chip else { return }
        chip = next
        configureAccessibility()
        needsDisplay = true
    }

    private func configureAccessibility() {
        setAccessibilityLabel(chip.spoken)
        toolTip = chip.spoken
    }

    /// What the pill says, which is the value for a decision that has one and the decision's own
    /// word for a switch — a switch's state is carried by its symbol as well as its fill.
    var title: String {
        switch chip.kind {
        case .field: return chip.value
        case .cutout: return chip.label
        case .avoid:
            return chip.value.isEmpty
                ? chip.label + "…" : Localized.text("%@ · %@", chip.label, chip.value)
        case .seed: return chip.value
        case .reference:
            return chip.value.isEmpty ? chip.label : chip.value
        }
    }

    private static let padding: CGFloat = 10
    private static let symbolSide: CGFloat = 14

    var preferredWidth: CGFloat {
        var width = Self.padding + Self.symbolSide + 5 + StudioTheme.width(of: title, role: .control) + Self.padding
        if opens { width += 12 }
        return ceil(width)
    }

    private var ink: NSColor {
        if chip.isWarning { return MacTheme.Color.danger }
        return MacTheme.Color.onGlass
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        let base: CGFloat = pressing ? 0.2 : (hovering ? 0.15 : 0.09)
        if chip.isOn {
            MacTheme.Color.accent.withAlphaComponent(pressing ? 0.34 : 0.24).setFill()
        } else {
            MacTheme.Color.onGlass.withAlphaComponent(base).setFill()
        }
        shape.fill()
        if chip.isWarning {
            MacTheme.Color.danger.withAlphaComponent(0.9).setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
        let colour = ink
        if let symbol = StudioTheme.symbol(chip.symbol, size: 11, weight: .medium) {
            let tinted = NSImage(size: symbol.size, flipped: false) { rect in
                symbol.draw(in: rect)
                colour.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            let side = Self.symbolSide
            let scale = min(side / max(tinted.size.width, 1), side / max(tinted.size.height, 1), 1.3)
            let size = NSSize(width: tinted.size.width * scale, height: tinted.size.height * scale)
            tinted.draw(
                in: NSRect(
                    x: Self.padding + (side - size.width) / 2, y: (bounds.height - size.height) / 2,
                    width: size.width, height: size.height))
        }
        let attributes = MacTheme.Ramp.attributes(.control, color: colour)
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(
            at: NSPoint(x: Self.padding + Self.symbolSide + 5, y: (bounds.height - size.height) / 2),
            withAttributes: attributes)
        if opens {
            let chevron = NSBezierPath()
            let x = bounds.width - Self.padding - 3
            let y = bounds.height / 2
            chevron.move(to: NSPoint(x: x - 3, y: y - 1.5))
            chevron.line(to: NSPoint(x: x, y: y + 1.5))
            chevron.line(to: NSPoint(x: x + 3, y: y - 1.5))
            colour.withAlphaComponent(0.7).setStroke()
            chevron.lineWidth = 1.2
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            chevron.stroke()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        pressing = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressing = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressing = false
        needsDisplay = true
        if isEnabled, inside { onPress?(self) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onPress?(self)
        return true
    }
}

/// The dock's second row: Core's decisions that apply to what is chosen, the switches beside them
/// and the estimate at the foot. It lays its pills out by frame and never clips one — a pill is whole
/// or it is in "More", and under 760 points of window height they are all in one "Settings" — and the
/// estimate gives way before a pill does.
@MainActor
final class StudioChipRow: NSView {
    var onAvoid: ((NSView) -> Void)?
    var onPickLibrary: ((NSView) -> Void)?
    var isEnabled = true {
        didSet {
            for button in buttons { button.isEnabled = isEnabled }
            more.isEnabled = isEnabled
            settings.isEnabled = isEnabled
        }
    }

    var folded = false {
        didSet {
            guard folded != oldValue else { return }
            needsLayout = true
        }
    }

    private let studio: MacImageStudio
    private var chips: [StudioChip] = []
    private var buttons: [StudioChipButton] = []
    private let more = StudioChipButton(
        chip: StudioChip(
            kind: .field(.engine), label: ImageGenWords.moreTitle, value: ImageGenWords.moreTitle,
            symbol: "ellipsis", isOn: false, isWarning: false), opens: true)
    private let settings = StudioChipButton(
        chip: StudioChip(
            kind: .field(.engine), label: Localized.text("Settings"), value: Localized.text("Settings"),
            symbol: "slider.horizontal.3", isOn: false, isWarning: false), opens: true)
    private let estimate = StudioTheme.label(.panelFootnote, color: MacTheme.Color.secondaryLabel)
    private var overflow: [StudioChip] = []

    init(studio: MacImageStudio) {
        self.studio = studio
        super.init(frame: .zero)
        addSubview(more)
        addSubview(settings)
        addSubview(estimate)
        more.onPress = { [weak self] button in self?.openOverflow(from: button) }
        settings.onPress = { [weak self] button in self?.openSettings(from: button) }
        estimate.alignment = .right
        estimate.setAccessibilityElement(true)
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func reload() {
        let blocked = studio.engineBlocked != nil
        let next = StudioChips.read(slot: studio.slot, engineBlocked: blocked)
        let same = next.map(\.kind) == chips.map(\.kind)
        chips = next
        if !same {
            for button in buttons { button.removeFromSuperview() }
            buttons = next.map { chip in
                let button = StudioChipButton(chip: chip, opens: Self.opens(chip.kind))
                button.onPress = { [weak self] pressed in self?.press(pressed.chip, from: pressed) }
                button.isEnabled = isEnabled
                addSubview(button)
                return button
            }
        } else {
            for (button, chip) in zip(buttons, next) { button.update(chip) }
        }
        estimate.stringValue = studio.estimateLine
        estimate.setAccessibilityLabel(studio.estimateLine)
        needsLayout = true
    }

    private static func opens(_ kind: StudioChip.Kind) -> Bool {
        switch kind {
        case .cutout: return false
        default: return true
        }
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let gap: CGFloat = 6
        let estimateWidth = min(
            ceil(estimate.intrinsicContentSize.width) + 4, max(0, bounds.width * 0.3))
        if folded {
            settings.isHidden = false
            more.isHidden = true
            for button in buttons { button.isHidden = true }
            let width = settings.preferredWidth
            settings.frame = NSRect(x: 0, y: 0, width: width, height: height)
            placeEstimate(after: width + gap, width: estimateWidth)
            return
        }
        settings.isHidden = true
        let total = buttons.reduce(CGFloat(0)) { $0 + $1.preferredWidth + gap }
        var room = bounds.width
        var showEstimate = estimateWidth > 0
        if total + (showEstimate ? estimateWidth + 8 : 0) <= room {
            more.isHidden = true
            overflow = []
            place(buttons, gap: gap, height: height)
            placeEstimate(after: total, width: estimateWidth)
            return
        }
        showEstimate = false
        room = bounds.width - more.preferredWidth - gap
        var used: CGFloat = 0
        var fitting = 0
        for button in buttons {
            let next = used + button.preferredWidth + gap
            guard next <= room else { break }
            used = next
            fitting += 1
        }
        let shown = Array(buttons.prefix(fitting))
        overflow = Array(chips.dropFirst(fitting))
        for button in buttons.dropFirst(fitting) { button.isHidden = true }
        place(shown, gap: gap, height: height)
        more.isHidden = overflow.isEmpty
        more.frame = NSRect(x: used, y: 0, width: more.preferredWidth, height: height)
        estimate.isHidden = !showEstimate
    }

    private func place(_ shown: [StudioChipButton], gap: CGFloat, height: CGFloat) {
        var x: CGFloat = 0
        for button in shown {
            button.isHidden = false
            let width = button.preferredWidth
            button.frame = NSRect(x: x, y: 0, width: width, height: height)
            x += width + gap
        }
    }

    private func placeEstimate(after used: CGFloat, width: CGFloat) {
        let available = bounds.width - used - 8
        guard width > 0, available > 60 else {
            estimate.isHidden = true
            return
        }
        estimate.isHidden = false
        let shown = min(width, available)
        estimate.frame = NSRect(
            x: bounds.width - shown, y: (bounds.height - StudioTheme.height(of: .panelFootnote)) / 2,
            width: shown, height: StudioTheme.height(of: .panelFootnote))
    }

    private func press(_ chip: StudioChip, from anchor: NSView) {
        switch chip.kind {
        case .cutout:
            studio.setCutout(!studio.slot.cutout)
        case .avoid:
            onAvoid?(anchor)
        default:
            guard let menu = StudioChipMenu.menu(for: chip.kind, studio: studio, library: { [weak self] in self?.onPickLibrary?(anchor) }) else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
        }
    }

    private func openOverflow(from anchor: NSView) {
        let menu = NSMenu()
        for chip in overflow { menu.addItem(item(for: chip, anchor: anchor)) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

    private func openSettings(from anchor: NSView) {
        let menu = NSMenu()
        for chip in chips { menu.addItem(item(for: chip, anchor: anchor)) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

    private func item(for chip: StudioChip, anchor: NSView) -> NSMenuItem {
        let title = chip.value.isEmpty ? chip.label : "\(chip.label) · \(chip.value)"
        switch chip.kind {
        case .cutout:
            let toggle = ClosureMenuItem(title: chip.label) { [weak self] in
                guard let self else { return }
                self.studio.setCutout(!self.studio.slot.cutout)
            }
            toggle.state = chip.isOn ? .on : .off
            toggle.subtitle = ImageGenStudioWords.cutoutDetail
            return toggle
        case .avoid:
            return ClosureMenuItem(title: title) { [weak self] in self?.onAvoid?(anchor) }
        default:
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = StudioChipMenu.menu(
                for: chip.kind, studio: studio, library: { [weak self] in self?.onPickLibrary?(anchor) })
            return holder
        }
    }
}

/// The small list each pill opens: Core's own choices with Core's own words, and the one the slot
/// holds checked. A chip that is a switch or a field of free words opens nothing here.
@MainActor
enum StudioChipMenu {
    static func menu(
        for kind: StudioChip.Kind, studio: MacImageStudio, library: @escaping @MainActor () -> Void
    ) -> NSMenu? {
        let menu = NSMenu()
        switch kind {
        case .field(.engine):
            for engine in ImageGenEngine.allCases {
                let item = ClosureMenuItem(title: engine.label) { studio.choose(engine: engine) }
                item.state = studio.slot.engine == engine ? .on : .off
                var note = engine.detail
                if let sighting = studio.sighting, sighting.reachable, !sighting.available(engine) {
                    note = ImageGenWords.engineUnavailable(
                        engine, missing: sighting.missing(for: engine).count)
                }
                item.subtitle = note
                menu.addItem(item)
            }
        case .field(.aspect):
            for aspect in ImageGenAspect.allCases {
                let item = ClosureMenuItem(title: aspect.short) { studio.choose(aspect: aspect) }
                item.state = studio.slot.aspect == aspect ? .on : .off
                item.subtitle = aspect.ratioLabel
                menu.addItem(item)
            }
        case .field(.size):
            for size in ImageGenSize.allCases {
                let item = ClosureMenuItem(title: size.title) { studio.choose(size: size) }
                item.state = studio.slot.size == size ? .on : .off
                item.subtitle = size.detail
                menu.addItem(item)
            }
        case .field(.detail):
            for detail in ImageGenDetail.allCases {
                let item = ClosureMenuItem(title: detail.short) { studio.choose(detail: detail) }
                item.state = studio.slot.detail == detail ? .on : .off
                item.subtitle = detail.detail
                menu.addItem(item)
            }
        case .seed:
            let hold = ClosureMenuItem(title: ImageGenStudioWords.holdSeedTitle) {
                studio.toggleSeedHold()
            }
            hold.state = studio.slot.seed.isHeld ? .on : .off
            hold.subtitle = ImageGenStudioWords.holdSeedDetail(seed: studio.slot.seed)
            if !studio.slot.seed.isHeld, studio.slot.seed.last == nil { hold.action = nil }
            menu.addItem(hold)
        case .reference:
            StudioReferenceMenu.fill(menu, studio: studio, library: library)
        case .cutout, .avoid:
            return nil
        }
        return menu
    }
}

/// Where a reference can come from on a Mac — the file system, the pasteboard and the machine's own
/// gallery — and the pictures already attached, each one tap from being let go of. Shared by the
/// start-from slot and the reference chip so the two can never offer different things.
@MainActor
enum StudioReferenceMenu {
    static func fill(_ menu: NSMenu, studio: MacImageStudio, library: @escaping @MainActor () -> Void) {
        let more = !studio.slot.references.isEmpty
        let file = ClosureMenuItem(title: ImageGenReferenceSource.files.title + "…") {
            chooseFile(studio: studio)
        }
        file.image = StudioTheme.symbol(ImageGenReferenceSource.files.symbol, size: 12)
        menu.addItem(file)
        let paste = ClosureMenuItem(title: ImageGenReferenceSource.clipboard.title) {
            paste(studio: studio)
        }
        paste.image = StudioTheme.symbol(ImageGenReferenceSource.clipboard.symbol, size: 12)
        if StudioDrop.read(.general) == nil { paste.action = nil }
        menu.addItem(paste)
        let gallery = ClosureMenuItem(title: ImageGenReferenceSource.library.title + "…") { library() }
        gallery.image = StudioTheme.symbol(ImageGenReferenceSource.library.symbol, size: 12)
        menu.addItem(gallery)
        guard more else { return }
        menu.addItem(.separator())
        for reference in studio.slot.references {
            let path = reference.path
            let item = ClosureMenuItem(title: "\(ImageGenWords.removeReference) \(reference.name)") {
                studio.release(path)
            }
            menu.addItem(item)
        }
    }

    static func chooseFile(studio: MacImageStudio) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = ImageGenWords.attachTitle
        panel.begin { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                studio.hold(ImageGenReference(path: url.path))
            }
        }
    }

    static func paste(studio: MacImageStudio) {
        guard let drop = StudioDrop.read(.general) else { return }
        StudioDrop.hold(drop, in: studio) { _ in }
    }
}

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

    private let studio: MacImageStudio
    private let caption = StudioTheme.label(.panelFootnote, color: MacTheme.Color.onGlassSecondary, alignment: .center)
    private var thumbnailPath: String?
    private var thumbnail: CGImage?
    private var thumbnailTask: Task<Void, Never>?
    private var dropping = false
    private var hovering = false
    private var tracking: NSTrackingArea?
    private var removeRect: NSRect {
        NSRect(x: bounds.maxX - 18, y: bounds.minY - 2, width: 20, height: 20)
    }

    init(studio: MacImageStudio) {
        self.studio = studio
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

    func reload() {
        let held = studio.slot.reference
        caption.isHidden = held != nil
        if let held {
            let path = held.path.isEmpty ? (held.kept.flatMap { studio.library.thumbnailPath(of: $0) } ?? "") : held.path
            if path != thumbnailPath {
                thumbnailPath = path
                thumbnail = nil
                loadThumbnail(path)
            }
            setAccessibilityLabel(
                Localized.text("Start from: %@", held.name))
            toolTip = ImageGenWords.referenceHint(held)
        } else {
            thumbnailPath = nil
            thumbnail = nil
            thumbnailTask?.cancel()
            setAccessibilityLabel(ImageGenWords.attachTitle)
            toolTip = ImageGenWords.attachHint
        }
        needsDisplay = true
        needsLayout = true
    }

    private func loadThumbnail(_ path: String) {
        thumbnailTask?.cancel()
        guard !path.isEmpty else { return }
        thumbnailTask = Task { [weak self] in
            let image = await Task.detached {
                FileManager.default.contents(atPath: path).flatMap {
                    MacImageLibrary.downsample($0, longestSide: 160)
                }
            }.value
            guard let self, !Task.isCancelled, self.thumbnailPath == path else { return }
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
        if studio.slot.reference != nil {
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
        if studio.slot.reference != nil, NSRect(x: bounds.maxX - 20, y: 0, width: 20, height: 20).contains(point) {
            studio.hold(nil)
            return
        }
        openMenu()
    }

    private func openMenu() {
        let menu = NSMenu()
        StudioReferenceMenu.fill(menu, studio: studio) { [weak self] in
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
        StudioDrop.hold(drop, in: studio) { _ in }
        return true
    }
}

/// The two-part control at the words box's trailing edge: Enhance asks the filed helper for the
/// paragraph, the chevron opens the list of every model on the way that could write it.
@MainActor
final class StudioEnhanceControl: NSView {
    enum Mode: Equatable {
        case find
        case looking
        case ready(ImageGenHelper)
        case off(ImageGenHelper)
        case writing
        case disabled
    }

    var onEnhance: (() -> Void)?
    var onPicker: ((NSView) -> Void)?
    var state: Mode = .find {
        didSet {
            guard state != oldValue else { return }
            refresh()
        }
    }

    private var hovering: Region?
    private var tracking: NSTrackingArea?

    private enum Region { case main, picker }

    init() {
        super.init(frame: .zero)
        setAccessibilityRole(.button)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var title: String {
        switch state {
        case .find, .ready: return ImageGenWords.enhanceTitle
        case .looking: return ImageGenRewriteWords.lookingTitle
        case .off: return ImageGenWords.enhanceTitle + " · " + ImageGenWords.offMark
        case .writing: return ImageGenWords.enhancingTitle
        case .disabled: return ImageGenWords.enhanceTitle
        }
    }

    private func refresh() {
        switch state {
        case .ready(let helper): toolTip = ImageGenWords.enhanceHint(helper)
        case .find: toolTip = ImageGenWords.enhanceLookingHint
        case .off: toolTip = ImageGenWords.helperOffHint
        default: toolTip = nil
        }
        setAccessibilityLabel(title)
        alphaValue = state == .disabled ? 0.45 : 1
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private static let chevronWidth: CGFloat = 24

    override var intrinsicContentSize: NSSize {
        NSSize(width: 12 + 14 + 4 + StudioTheme.width(of: title, role: .control) + 6 + Self.chevronWidth, height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        MacTheme.Color.onGlass.withAlphaComponent(0.12).setFill()
        shape.fill()
        if let hovering {
            let region = hovering == .main
                ? NSRect(x: 0, y: 0, width: bounds.width - Self.chevronWidth, height: bounds.height)
                : NSRect(x: bounds.width - Self.chevronWidth, y: 0, width: Self.chevronWidth, height: bounds.height)
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            MacTheme.Color.onGlass.withAlphaComponent(0.1).setFill()
            region.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        let ink = MacTheme.Color.onGlass
        let attributes = MacTheme.Ramp.attributes(.control, color: ink)
        if let spark = StudioTheme.symbol("sparkle", size: 10, weight: .semibold) {
            let tinted = NSImage(size: spark.size, flipped: false) { rect in
                spark.draw(in: rect)
                ink.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: 10, y: (bounds.height - 12) / 2, width: 12, height: 12))
        }
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(
            at: NSPoint(x: 26, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        let chevron = NSBezierPath()
        let x = bounds.width - Self.chevronWidth / 2 - 1
        let y = bounds.height / 2
        chevron.move(to: NSPoint(x: x - 3, y: y - 1.5))
        chevron.line(to: NSPoint(x: x, y: y + 1.5))
        chevron.line(to: NSPoint(x: x + 3, y: y - 1.5))
        ink.withAlphaComponent(0.7).setStroke()
        chevron.lineWidth = 1.2
        chevron.lineCapStyle = .round
        chevron.stroke()
    }

    private func region(at point: NSPoint) -> Region {
        point.x >= bounds.width - Self.chevronWidth ? .picker : .main
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        hovering = region(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = nil
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), state != .disabled else { return }
        switch region(at: point) {
        case .main:
            if state != .writing, state != .looking { onEnhance?() }
        case .picker:
            onPicker?(self)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard state != .disabled, state != .writing, state != .looking else { return false }
        onEnhance?()
        return true
    }
}

/// Generate beside the words — or Stop in its place while the machine works, because those are the
/// same place on the same hand. The accent is spent here once: the primary action of the whole surface.
@MainActor
final class StudioGoButton: NSView {
    enum Mode { case generate, stop }

    var onPress: (() -> Void)?
    var mode: Mode = .generate {
        didSet { if mode != oldValue { refresh() } }
    }

    var isEnabled = true {
        didSet { if isEnabled != oldValue { refresh() } }
    }

    private var pressing = false
    private var hovering = false
    private var tracking: NSTrackingArea?
    var title = ImageGenWords.renderTitle(mode: .generate) {
        didSet { if title != oldValue { refresh() } }
    }

    init() {
        super.init(frame: .zero)
        setAccessibilityRole(.button)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func refresh() {
        setAccessibilityLabel(mode == .stop ? ImageGenWords.stopTitle : title)
        setAccessibilityEnabled(isEnabled)
        toolTip = mode == .stop ? ImageGenWords.stopTitle + " (⎋)" : title + " (⌘↩)"
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        let label: String
        let hint: String
        let ink: NSColor
        switch mode {
        case .generate:
            label = title
            hint = "⌘↩"
            if isEnabled {
                (pressing ? MacTheme.Color.accent.blended(withFraction: 0.2, of: .black) ?? MacTheme.Color.accent : MacTheme.Color.accent).setFill()
                ink = MacTheme.Color.onAccent
            } else {
                MacTheme.Color.onGlass.withAlphaComponent(0.1).setFill()
                ink = MacTheme.Color.onGlassSecondary
            }
        case .stop:
            label = ImageGenWords.stopTitle
            hint = "⎋"
            MacTheme.Color.onGlass.withAlphaComponent(pressing ? 0.22 : (hovering ? 0.18 : 0.13)).setFill()
            ink = MacTheme.Color.onGlass
        }
        shape.fill()
        let main = MacTheme.Ramp.attributes(.control, color: ink)
        let small = MacTheme.Ramp.attributes(.panelFootnote, color: ink.withAlphaComponent(0.75))
        let labelSize = (label as NSString).size(withAttributes: main)
        let hintSize = (hint as NSString).size(withAttributes: small)
        let glyph: CGFloat = mode == .stop ? 14 : 0
        let total = glyph + (mode == .stop ? 8 : 0) + labelSize.width + 10 + hintSize.width
        var x = (bounds.width - total) / 2
        if mode == .stop {
            MacTheme.Color.danger.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: (bounds.height - 10) / 2, width: 10, height: 10), xRadius: 2, yRadius: 2).fill()
            x += glyph + 8 - 4
        }
        (label as NSString).draw(at: NSPoint(x: x, y: (bounds.height - labelSize.height) / 2), withAttributes: main)
        (hint as NSString).draw(
            at: NSPoint(x: x + labelSize.width + 10, y: (bounds.height - hintSize.height) / 2),
            withAttributes: small)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        pressing = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressing = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressing = false
        needsDisplay = true
        if isEnabled, inside { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onPress?()
        return true
    }
}

/// A rewrite, as the card that rises out of the dock over the stage's lower third: who is writing,
/// the paragraph as it streams, and the four things to do with it — use these words, keep mine, write
/// again, or one line to change. Opaque raised canvas, because it carries prose and prose never sits
/// on glass; it floats above the stage and moves nothing.
@MainActor
final class StudioRewriteCard: StudioRaisedView {
    static let riseDistance: CGFloat = 20

    var onUse: (() -> Void)?
    var onKeep: (() -> Void)?
    var onAgain: (() -> Void)?
    var onRevise: ((String) -> Void)?

    private let headline = StudioTheme.label(.panelLabel, color: MacTheme.Color.label)
    private let scroll = NSScrollView()
    private let text = NSTextView()
    private let use = NSButton(title: ImageGenRewriteWords.useTitle, target: nil, action: nil)
    private let keep = NSButton(title: ImageGenRewriteWords.keepTitle, target: nil, action: nil)
    private let again = NSButton(title: ImageGenRewriteWords.againTitle, target: nil, action: nil)
    private let instruction = NSTextField()
    private var draft: ImageGenRewriteDraft?

    init() {
        super.init(radius: 16)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 0, height: 2)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        for button in [use, keep, again] {
            button.bezelStyle = .rounded
            button.controlSize = .regular
            button.target = self
        }
        use.action = #selector(usePressed)
        use.keyEquivalent = ""
        use.bezelColor = MacTheme.Color.accent
        keep.action = #selector(keepPressed)
        again.action = #selector(againPressed)
        use.toolTip = ImageGenRewriteWords.useHint
        keep.toolTip = ImageGenRewriteWords.keepHint
        again.toolTip = ImageGenRewriteWords.againHint
        instruction.placeholderString = ImageGenRewriteWords.instructionPlaceholder
        instruction.font = MacTheme.Ramp.font(.panelFootnote)
        instruction.bezelStyle = .roundedBezel
        instruction.target = self
        instruction.action = #selector(revisePressed)
        for view in [headline, scroll, instruction, use, keep, again] { addSubview(view) }
        setAccessibilityRole(.group)
        setAccessibilityLabel(ImageGenRewriteWords.chooseTitle)
        restyle()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged), name: MacTheme.Chrome.didRepaint, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    @objc private func themeChanged() { restyle() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        headline.font = MacTheme.Ramp.font(.panelLabel)
        text.font = MacTheme.Ramp.font(.cardBody)
        text.textColor = MacTheme.Color.label
    }

    func show(_ next: ImageGenRewriteDraft) {
        let grew = draft?.written != next.written
        draft = next
        headline.stringValue = next.headline
        switch next.phase {
        case .failed:
            headline.textColor = MacTheme.Color.danger
        default:
            headline.textColor = MacTheme.Color.label
        }
        if grew {
            text.string = next.written
            text.scrollToEndOfDocument(nil)
        }
        let writing = next.isWriting
        use.isEnabled = next.isUsable
        use.isHidden = writing
        again.isHidden = writing
        keep.title = writing ? ImageGenRewriteWords.stopTitle : ImageGenRewriteWords.keepTitle
        instruction.isHidden = writing || !next.isUsable
        if case .failed = next.phase {
            text.string = next.original
            again.isHidden = false
        }
        setAccessibilityValue(next.announcement)
        needsLayout = true
    }

    /// As tall as the paragraph it holds, between four lines and ten: a short rewrite is a short card
    /// and a long one scrolls inside it rather than growing over the whole stage.
    func fitting(width: CGFloat) -> CGFloat {
        let font = MacTheme.Ramp.font(.cardBody)
        let words = draft?.written ?? ""
        let measured = (words as NSString).boundingRect(
            with: NSSize(width: max(80, width - 32), height: 1000),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height
        let line = ceil(font.ascender - font.descender + font.leading)
        let body = min(max(ceil(measured) + 8, line * 4), line * 10)
        return 14 + StudioTheme.height(of: .panelLabel) + 8 + body + 10 + 28 + 14
    }

    func dismiss(animated: Bool) {
        guard !isHidden else { return }
        draft = nil
        guard animated else {
            isHidden = true
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = StudioTheme.rewriteRise
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.draft == nil else { return }
                self.isHidden = true
                self.alphaValue = 1
            }
        })
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 16
        let width = bounds.width - 2 * pad
        let headlineHeight = StudioTheme.height(of: .panelLabel)
        headline.frame = NSRect(x: pad, y: 14, width: width, height: headlineHeight)
        let bottom = bounds.height - 14
        let rowHeight: CGFloat = 28
        let buttonsY = bottom - rowHeight
        var x = pad
        if !use.isHidden {
            let size = use.fittingSize
            use.frame = NSRect(x: x, y: buttonsY, width: size.width, height: rowHeight)
            x += size.width + 8
        }
        let keepSize = keep.fittingSize
        keep.frame = NSRect(x: x, y: buttonsY, width: keepSize.width, height: rowHeight)
        x += keepSize.width + 8
        if !again.isHidden {
            let size = again.fittingSize
            again.frame = NSRect(x: x, y: buttonsY, width: size.width, height: rowHeight)
            x += size.width + 12
        }
        if !instruction.isHidden {
            instruction.frame = NSRect(x: x, y: buttonsY, width: max(0, bounds.width - pad - x), height: rowHeight)
        }
        let textTop = 14 + headlineHeight + 8
        scroll.frame = NSRect(x: pad, y: textTop, width: width, height: max(0, buttonsY - 10 - textTop))
        text.frame.size.width = scroll.contentSize.width
    }

    @objc private func usePressed() { onUse?() }
    @objc private func keepPressed() { onKeep?() }
    @objc private func againPressed() { onAgain?() }

    @objc private func revisePressed() {
        let line = instruction.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        instruction.stringValue = ""
        onRevise?(line)
    }
}

/// The avoid list, asked for in a small popover: a line of words the picture must keep out of the
/// frame. Empty is the ordinary case — guidance stays low and a render stays fast.
@MainActor
final class StudioAvoidPopover: NSViewController, NSTextFieldDelegate {
    private let field = NSTextField()
    private let apply: (String) -> Void
    private let cancel: () -> Void

    init(current: String, apply: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        self.apply = apply
        self.cancel = cancel
        super.init(nibName: nil, bundle: nil)
        field.stringValue = current
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 128))
        let title = StudioTheme.label(.panelLabel, color: MacTheme.Color.label)
        title.stringValue = ImageGenWords.avoidTitle
        let hint = StudioTheme.label(.panelFootnote, color: MacTheme.Color.secondaryLabel, lines: 3)
        hint.stringValue = ImageGenWords.avoidHint
        field.placeholderString = ImageGenWords.avoidPlaceholder
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
    private let studio: MacImageStudio
    private let pick: (ImageGenLibraryItem) -> Void
    private let collection = NSCollectionView()
    private let note = StudioTheme.label(.panelFootnote, color: MacTheme.Color.secondaryLabel)
    private var items: [ImageGenLibraryItem] = []

    init(studio: MacImageStudio, pick: @escaping (ImageGenLibraryItem) -> Void) {
        self.studio = studio
        self.pick = pick
        super.init(nibName: nil, bundle: nil)
        items = studio.library.items
        studio.watch(self) { [weak self] change in
            guard case .shelf = change, let self else { return }
            self.items = self.studio.library.items
            self.note.stringValue = self.studio.library.line
            self.collection.reloadData()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { studio.unwatch(self) }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 380))
        note.stringValue = studio.library.line
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
        tile.show(items[indexPath.item], library: studio.library)
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
