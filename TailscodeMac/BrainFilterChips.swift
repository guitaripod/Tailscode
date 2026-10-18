import AppKit
import TailscodeCore

/// A chip as a screen reader meets it: the zone, its count, whether it filters, and a press that
/// does what a click does.
final class BrainChipElement: NSAccessibilityElement {
    nonisolated(unsafe) var onPress: (@MainActor () -> Void)?

    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        MainActor.assumeIsolated { onPress() }
        return true
    }
}

/// The zone filters above the step list: one chip per zone the turn used, the voice (SAID) first
/// and the only one that carries its word, the others a glyph and a count. A press toggles a zone
/// and a shift or double press solos it; what the chips hold and what the list shows are one
/// filter in Core, so a chip is a view of it and never a second copy.
@MainActor
final class BrainFilterChips: NSView, NSViewToolTipOwner {
    private weak var host: BrainSurfaceHost?
    private var metrics: NeuralStageMetrics
    private let painter: BrainRowPainter
    private(set) var entries: [Entry] = []
    private var hover: Int?
    private var pressed: Int?
    private var pressedInside = true
    private var focused: Int?
    private var tracking: NSTrackingArea?
    private(set) var isCompact = false

    struct Entry {
        let zone: NeuralZone
        let count: Int
        let isOn: Bool
        let x: CGFloat
        let width: CGFloat
        let label: String?

        var frame: CGRect { CGRect(x: x, y: 0, width: width, height: CGFloat(NeuralStageMetrics.chipsHeight)) }
    }

    static let gap: CGFloat = 4

    init(host: BrainSurfaceHost) {
        self.host = host
        metrics = host.currentMetrics
        painter = BrainRowPainter(inks: host.inks)
        super.init(frame: .zero)
        focusRingType = .none
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(BrainListWords.stepFilters)
        invalidate()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled && !entries.isEmpty }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    func configure(metrics next: NeuralStageMetrics) {
        guard next != metrics else { return }
        metrics = next
        invalidate()
    }

    func retheme() {
        guard let host else { return }
        painter.reset(inks: host.inks)
        invalidate()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        retheme()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { invalidate() }
    }

    /// The chips again from what the turn holds: their widths, their tooltips and their accessible
    /// elements. A chip is 28 high; the row never wraps, so when the chips do not fit at full
    /// width they give up 2 points of glyph padding each.
    func invalidate() {
        guard let host else { return }
        let list = host.model.browseState.list
        let chips = list.zoneChips
        let room = bounds.width
        let full = chips.map { width(for: $0, compact: false) }
        let needed = full.reduce(0, +) + Self.gap * CGFloat(max(chips.count - 1, 0))
        isCompact = room > 0 && needed > room
        var made: [Entry] = []
        var x: CGFloat = 0
        for chip in chips {
            let size = width(for: chip, compact: isCompact)
            made.append(
                Entry(
                    zone: chip.zone, count: chip.count, isOn: chip.isOn, x: x, width: size,
                    label: chip.zone == .say ? chip.zone.displayLabel : nil))
            x += size + Self.gap
        }
        entries = made
        if let focused, !made.indices.contains(focused) { self.focused = nil }
        if let hover, !made.indices.contains(hover) { self.hover = nil }
        rebuildTooltips()
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    private func width(for chip: NeuralStepList.ZoneChip, compact: Bool) -> CGFloat {
        let fonts = painter.fonts
        let digits = fonts.width("\(chip.count)", fonts.chipCount)
        var size = (compact ? 4 : 5) + 18 + 4 + digits + 8
        if chip.zone == .say { size += fonts.saidWidth(chip.zone.displayLabel) + 8 }
        return size
    }

    private func rebuildTooltips() {
        removeAllToolTips()
        for (index, entry) in entries.enumerated() {
            addToolTip(entry.frame, owner: self, userData: UnsafeMutableRawPointer(bitPattern: index + 1))
        }
    }

    func view(
        _ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        guard let data else { return "" }
        let index = Int(bitPattern: data) - 1
        guard entries.indices.contains(index) else { return "" }
        return tooltip(for: entries[index])
    }

    /// What a chip is called and the key that toggles it.
    func tooltip(for entry: Entry) -> String {
        "\(entry.zone.displayLabel) \u{00B7} \(entry.zone.filterKey)"
    }


    private func index(at point: CGPoint) -> Int? {
        entries.firstIndex { $0.frame.contains(point) }
    }

    override func mouseMoved(with event: NSEvent) {
        let found = index(at: convert(event.locationInWindow, from: nil))
        guard found != hover else { return }
        hover = found
        needsDisplay = true
        if found != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
    }

    override func mouseExited(with event: NSEvent) {
        guard hover != nil else { return }
        hover = nil
        pressed = nil
        needsDisplay = true
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        pressed = index(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let held = pressed else { return }
        let over = index(at: convert(event.locationInWindow, from: nil)) == held
        let showing = pressedInside
        guard over != showing else { return }
        pressedInside = over
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let held = pressed else { return }
        let inside = index(at: convert(event.locationInWindow, from: nil)) == held
        pressed = nil
        pressedInside = true
        needsDisplay = true
        if inside {
            activate(held, shift: event.modifierFlags.contains(.shift), clicks: event.clickCount)
        }
    }

    /// A press: the zone toggles; shift or a second press shows only that zone. A second press
    /// on a zone that is already the only one leaves it alone, which is what the person asked for.
    func activate(_ index: Int, shift: Bool, clicks: Int) {
        guard entries.indices.contains(index), let host else { return }
        let zone = entries[index].zone
        let zones = host.model.browseState.list.filter.zones
        let solo = shift || clicks >= 2
        if clicks >= 2, !shift, zones == [zone] {
            host.focusList()
            return
        }
        host.browse(.zoneChip(zone, solo: solo), grabFocus: false)
        host.focusList()
    }


    override func becomeFirstResponder() -> Bool {
        guard !entries.isEmpty else { return false }
        if focused == nil { focused = 0 }
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        focused = nil
        needsDisplay = true
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard let current = focused else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 123 where current > 0:
            focused = current - 1
        case 124 where current < entries.count - 1:
            focused = current + 1
        case 49, 36, 76:
            activate(current, shift: event.modifierFlags.contains(.shift), clicks: 1)
        default:
            super.keyDown(with: event)
            return
        }
        needsDisplay = true
    }


    override func draw(_ dirtyRect: NSRect) {
        for (index, entry) in entries.enumerated() { drawChip(entry, index: index) }
    }

    private func drawChip(_ entry: Entry, index: Int) {
        let colors = painter.colors
        let fonts = painter.fonts
        let height = CGFloat(NeuralStageMetrics.chipsHeight)
        let isSaid = entry.label != nil
        let tone = isSaid ? colors.accent : colors.zone(entry.zone)
        let hot = hover == index || focused == index
        let shape = NSBezierPath(
            roundedRect: CGRect(x: entry.x + 0.5, y: 0.5, width: entry.width - 1, height: height - 1),
            xRadius: height / 2, yRadius: height / 2)
        if pressed == index, pressedInside {
            colors.pressed.setFill()
        } else if entry.isOn {
            tone.withAlphaComponent(0.18).setFill()
        } else {
            colors.card.setFill()
        }
        shape.fill()
        let rest = isSaid ? colors.saidRest : colors.rule2
        (entry.isOn ? tone : (hot ? colors.accent : rest)).setStroke()
        shape.lineWidth = focused == index ? 2 : 1
        shape.stroke()
        let glyphX = entry.x + (isCompact ? 4 : 5) + 9
        BrainRowGlyphs.zone(entry.zone, at: CGPoint(x: glyphX, y: height / 2), color: colors.zone(entry.zone))
        var textX = glyphX + 13
        if let word = entry.label {
            let attributed = NSAttributedString(
                string: word, attributes: MacTheme.Ramp.attributes(.sectionLabel, color: colors.accent))
            let size = attributed.size()
            attributed.draw(at: CGPoint(x: textX, y: (height - size.height) / 2))
            textX += ceil(size.width) + 8
        }
        let count = "\(entry.count)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: fonts.chipCount, .foregroundColor: colors.ink]
        let size = count.size(withAttributes: attributes)
        count.draw(at: CGPoint(x: textX, y: (height - size.height) / 2), withAttributes: attributes)
    }


    override func accessibilityChildren() -> [Any]? {
        entries.enumerated().map { index, entry in
            let element = BrainChipElement()
            element.setAccessibilityRole(.button)
            element.setAccessibilityParent(self)
            element.setAccessibilityLabel(
                "\(entry.zone.displayLabel), \(entry.count)")
            element.setAccessibilityValue(entry.isOn ? BrainListWords.on : BrainListWords.off)
            element.setAccessibilityHelp(tooltip(for: entry))
            element.setAccessibilityFrameInParentSpace(entry.frame)
            element.onPress = { [weak self] in self?.activate(index, shift: false, clicks: 1) }
            return element
        }
    }


    /// The chips as they are drawn, left to right: the zone, the word it carries, the count.
    var summary: [(zone: NeuralZone, label: String?, count: Int, isOn: Bool)] {
        entries.map { ($0.zone, $0.label, $0.count, $0.isOn) }
    }

    func centre(of zone: NeuralZone) -> CGPoint? {
        entries.first { $0.zone == zone }.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
    }
}
