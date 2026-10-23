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
        case .field, .forge, .sound: return chip.value
        case .cutout: return chip.label
        case .avoid:
            return chip.value.isEmpty
                ? chip.label + "…" : Localized.text("%@ · %@", chip.label, chip.value)
        case .seed: return chip.value
        case .reference:
            return chip.value.isEmpty ? chip.label : chip.value
        }
    }

    /// The decision's own word, drawn in the quieter ink before its value — the Video lane's pills
    /// read "Size 1280×704" where the Image lane's, which sit beside the composer's own, read the
    /// value alone. A pill whose title already carries the word has no second one.
    private var lead: String? {
        guard chip.isLabelled, chip.kind != .avoid else { return nil }
        return chip.label
    }

    private static let padding: CGFloat = 10
    private static let symbolSide: CGFloat = 14

    var preferredWidth: CGFloat {
        var width = Self.padding + Self.symbolSide + 5 + StudioTheme.width(of: title, role: .control) + Self.padding
        if let lead { width += StudioTheme.width(of: lead, role: .control) + 5 }
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
        var textX = Self.padding + Self.symbolSide + 5
        if let lead {
            let quiet = MacTheme.Ramp.attributes(.control, color: colour.withAlphaComponent(0.62))
            let leadSize = (lead as NSString).size(withAttributes: quiet)
            (lead as NSString).draw(
                at: NSPoint(x: textX, y: (bounds.height - leadSize.height) / 2), withAttributes: quiet)
            textX += ceil(leadSize.width) + 5
        }
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(
            at: NSPoint(x: textX, y: (bounds.height - size.height) / 2), withAttributes: attributes)
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
    var onWords: ((NSView, StudioWordsField) -> Void)?
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

    private let brief: any StudioBriefing
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

    init(brief: any StudioBriefing) {
        self.brief = brief
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
        let next = brief.chips()
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
        estimate.stringValue = brief.estimateLine
        estimate.setAccessibilityLabel(brief.estimateLine)
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
        if chip.kind == .cutout {
            brief.toggle(chip)
        } else if let field = brief.wordsField(for: chip) {
            onWords?(anchor, field)
        } else if let menu = brief.menu(for: chip, gallery: { [weak self] in self?.onPickLibrary?(anchor) }) {
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
        if chip.kind == .cutout {
            let toggle = ClosureMenuItem(title: chip.label) { [weak self] in self?.brief.toggle(chip) }
            toggle.state = chip.isOn ? .on : .off
            toggle.subtitle = ImageGenStudioWords.cutoutDetail
            return toggle
        }
        if let field = brief.wordsField(for: chip) {
            return ClosureMenuItem(title: title) { [weak self] in self?.onWords?(anchor, field) }
        }
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = brief.menu(for: chip, gallery: { [weak self] in self?.onPickLibrary?(anchor) })
        return holder
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
        case .cutout, .avoid, .sound, .forge:
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
        let pasteItem = ClosureMenuItem(title: ImageGenReferenceSource.clipboard.title) {
            paste(studio: studio)
        }
        pasteItem.image = StudioTheme.symbol(ImageGenReferenceSource.clipboard.symbol, size: 12)
        if StudioDrop.read(.general) == nil { pasteItem.action = nil }
        menu.addItem(pasteItem)
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
            MainThread.call {
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
