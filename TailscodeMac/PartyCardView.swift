import AppKit
import CodingAgentKit
import TailscodeCore

/// Every number the party's popover is laid out from, scaled by the type size in force so a larger
/// scale widens the cards rather than crushing the words in them.
@MainActor
enum PartyMetrics {
    static var scale: CGFloat { MacTheme.UIScale.factor }
    static var width: CGFloat { 3 * cardWidth + 2 * gap + 2 * inset }
    static var inset: CGFloat { 14 * scale }
    static var gap: CGFloat { 10 * scale }
    static var cardWidth: CGFloat { ((612 * scale - 2 * inset - 2 * gap) / 3).rounded() }
    static var baseHeight: CGFloat { 118 * scale }
    static var pad: CGFloat { 12 * scale }
    static var radius: CGFloat { 16 * scale }
    static var ball: CGFloat { 40 * scale }
    static var hollowBall: CGFloat { 32 * scale }
    static var barWidth: CGFloat { 3 * scale }
    static var barGap: CGFloat { 2 * scale }
    static var barsSize: NSSize {
        NSSize(width: 5 * barWidth + 4 * barGap, height: 13 * scale)
    }
    static var textWidth: CGFloat { cardWidth - 2 * pad }

    static var titleFont: NSFont { .systemFont(ofSize: 15 * scale, weight: .semibold) }
    static var subtitleFont: NSFont { .systemFont(ofSize: 12 * scale) }
    static var chordFont: NSFont { .monospacedSystemFont(ofSize: 11 * scale, weight: .regular) }
    static var chipFont: NSFont { .systemFont(ofSize: 10.5 * scale, weight: .medium) }
    static var slotFont: NSFont { .systemFont(ofSize: 13 * scale) }

    static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    /// The height `text` takes wrapped to `width` in `font`, never more than `maxLines` lines: a
    /// name wraps rather than being cut, and the card is as tall as the longest of them needs.
    static func height(of text: String, font: NSFont, width: CGFloat, maxLines: Int) -> CGFloat {
        guard !text.isEmpty, width > 0 else { return 0 }
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        let line = lineHeight(font)
        return min(max(ceil(rect.height), line), line * CGFloat(maxLines))
    }

    static func chordText(_ slot: Int) -> String { "⌃⌥\(slot + 1)" }

    /// The house colour of the model behind a card, or the quiet register for one that has none.
    static func hue(of card: PartyCard) -> NSColor {
        card.chip.map(MacTheme.Color.modelIdentity) ?? MacTheme.Color.secondaryLabel
    }

    /// What a card needs at the popover's width: the ball, the name and the line under it, and the
    /// machine's chip, each as tall as its words are when wrapped.
    struct Measure {
        let titleHeight: CGFloat
        let subtitleHeight: CGFloat
        let chip: NSSize?
        let height: CGFloat
    }

    static func chipWidth(for text: String) -> NSSize {
        let room = textWidth - barsSize.width - 6 * scale
        let inner = room - 12 * scale
        let natural = ceil((text as NSString).size(withAttributes: [.font: chipFont]).width)
        let width = min(natural, inner)
        let height = Self.height(of: text, font: chipFont, width: width, maxLines: 2)
        return NSSize(width: width + 12 * scale, height: height + 4 * scale)
    }

    static func measure(_ card: PartyCard) -> Measure {
        guard !card.isHollow else {
            return Measure(titleHeight: 0, subtitleHeight: 0, chip: nil, height: baseHeight)
        }
        let title = height(of: card.title, font: titleFont, width: textWidth, maxLines: 2)
        let chip = card.machine.map { chipWidth(for: Localized.text("on %@", $0)) }
        let reserve = card.takesLevels && chip == nil ? barsSize.width + 6 * scale : 0
        let subtitle = height(
            of: card.subtitle, font: subtitleFont, width: textWidth - reserve, maxLines: 2)
        let chipSpace = chip.map { 3 * scale + $0.height } ?? 0
        let needed = pad + ball + 4 * scale + title + subtitle + chipSpace + pad
        return Measure(
            titleHeight: title, subtitleHeight: subtitle, chip: chip,
            height: max(baseHeight, ceil(needed)))
    }
}

/// The five bars that say how hard a model thinks, climbing left to right, the first `lit` in the
/// card's colour and the rest in the quiet register.
@MainActor
final class PartyBarsView: NSView {
    var lit = 0 {
        didSet { needsDisplay = true }
    }
    var hue: NSColor = MacTheme.Color.accent {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let heights: [CGFloat] = [5, 7, 9, 11, 13]
        let scale = PartyMetrics.scale
        for (index, base) in heights.enumerated() {
            let x = CGFloat(index) * (PartyMetrics.barWidth + PartyMetrics.barGap)
            let bar = NSRect(
                x: x, y: 0, width: PartyMetrics.barWidth, height: base * scale)
            (index < lit ? hue : MacTheme.Color.tertiaryLabel.withAlphaComponent(0.4)).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1 * scale, yRadius: 1 * scale).fill()
        }
    }
}

/// The machine a slot lives on, as the small pill under the model's line. It wraps rather than
/// cutting a long machine name, because which machine a tap would move the work to is exactly
/// what a person has to read.
@MainActor
final class PartyMachineChip: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.isSelectable = false
        label.font = PartyMetrics.chipFont
        label.textColor = MacTheme.Color.secondaryLabel
        label.maximumNumberOfLines = 2
        label.alignment = .center
        addSubview(label)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(machine: String) {
        label.stringValue = Localized.text("on %@", machine)
        toolTip = label.stringValue
        needsLayout = true
    }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: 6 * PartyMetrics.scale, dy: 2 * PartyMetrics.scale)
        layer?.cornerRadius = bounds.height / 2
        restyle()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
        }
    }
}

/// The card's own surface. Flipped so its parts are placed from the top down, the way the card is
/// read.
private final class PartyFace: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// What a drag of a card in edit mode reports to the grid that holds it.
enum PartyDrag {
    case began(NSPoint)
    case moved(NSPoint)
    case ended(NSPoint)
}

/// One slot of the party: a ball in the model's colour, the name a person gave it or the model's
/// own word, the model and level under it, the level's bars, the machine when it is not this one.
///
/// It is a control in the sense that matters: one focusable thing that takes a press, answers to
/// the arrows, Return and Space, and speaks `card.spoken`. In edit mode the same surface renames
/// in place, steps the level from the ball's button and is carried to another slot by hand.
@MainActor
final class PartyCardView: NSView {
    private(set) var card: PartyCard
    private(set) var isEditing = false
    var onPress: ((PartyCardView) -> Void)?
    var onStepLevel: ((PartyCardView) -> Void)?
    var onRename: ((PartyCardView, String) -> Void)?
    var onDrag: ((PartyCardView, PartyDrag) -> Void)?
    var onKey: ((PartyCardView, NSEvent) -> Bool)?
    var onFocus: ((PartyCardView) -> Void)?
    var onMenu: ((PartyCardView) -> NSMenu?)?

    private let face = PartyFace()
    private let ball = PartyBallView()
    private let chordLabel = NSTextField(labelWithString: "")
    private let titleField = NSTextField()
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let slotLabel = NSTextField(labelWithString: "")
    private let bars = PartyBarsView()
    private let chip = PartyMachineChip()
    private let dash = CAShapeLayer()
    private let underline = NSView()
    private var hovered = false
    private var pressed = false
    private var breathing = false
    private var measured: PartyMetrics.Measure
    private var renameCancelled = false
    var isDropTarget = false {
        didSet { restyle() }
    }

    init(card: PartyCard) {
        self.card = card
        measured = PartyMetrics.measure(card)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(face)
        face.wantsLayer = true
        face.layer?.cornerCurve = .continuous
        face.layer?.masksToBounds = false
        dash.fillColor = nil
        dash.lineWidth = 1.5
        dash.lineDashPattern = [5, 4]
        face.layer?.addSublayer(dash)
        chordLabel.font = PartyMetrics.chordFont
        chordLabel.alignment = .right
        chordLabel.lineBreakMode = .byClipping
        titleField.font = PartyMetrics.titleFont
        titleField.isBordered = false
        titleField.isBezeled = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.lineBreakMode = .byWordWrapping
        titleField.cell?.wraps = true
        titleField.cell?.isScrollable = false
        titleField.cell?.usesSingleLineMode = false
        titleField.maximumNumberOfLines = 2
        titleField.isEditable = false
        titleField.isSelectable = false
        titleField.delegate = self
        subtitleLabel.isSelectable = false
        subtitleLabel.font = PartyMetrics.subtitleFont
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.textColor = MacTheme.Color.secondaryLabel
        slotLabel.font = PartyMetrics.slotFont
        slotLabel.alignment = .center
        slotLabel.textColor = MacTheme.Color.secondaryLabel
        underline.wantsLayer = true
        underline.layer?.cornerRadius = 1
        underline.isHidden = true
        for view in [ball, chordLabel, titleField, underline, subtitleLabel, slotLabel, bars, chip]
            as [NSView]
        {
            face.addSubview(view)
        }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self, userInfo: nil))
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        apply(card, editing: false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(
            roundedRect: bounds, xRadius: PartyMetrics.radius, yRadius: PartyMetrics.radius
        ).fill()
    }

    override func becomeFirstResponder() -> Bool {
        onFocus?(self)
        noteFocusRingMaskChanged()
        return true
    }

    override func resignFirstResponder() -> Bool {
        noteFocusRingMaskChanged()
        return true
    }

    var needed: CGFloat { measured.height }
    var isRenaming: Bool { titleField.currentEditor() != nil }

    /// What the card shows is always the reading's: a rename in flight is put back to the kept
    /// name the moment the party changes, so what is on screen is what was saved.
    func apply(_ fresh: PartyCard, editing: Bool) {
        card = fresh
        isEditing = editing
        measured = PartyMetrics.measure(fresh)
        let hue = PartyMetrics.hue(of: fresh)
        ball.show(hue: fresh.isHollow ? nil : hue, away: fresh.isAway)
        bars.hue = hue
        bars.lit = fresh.bars
        bars.isHidden = fresh.isHollow || !fresh.takesLevels
        chordLabel.isHidden = fresh.isHollow
        chordLabel.stringValue =
            fresh.isInUse
            ? PartyMetrics.chordText(fresh.slot) + " · " + Localized.text("In use").uppercased()
            : PartyMetrics.chordText(fresh.slot)
        chordLabel.textColor = fresh.isInUse ? hue : MacTheme.Color.tertiaryLabel
        titleField.isHidden = fresh.isHollow
        subtitleLabel.isHidden = fresh.isHollow
        slotLabel.isHidden = !fresh.isHollow
        titleField.stringValue = fresh.title
        titleField.toolTip = fresh.title
        titleField.isEditable = editing && !fresh.isHollow
        titleField.isSelectable = editing && !fresh.isHollow
        titleField.textColor = MacTheme.Color.label
        subtitleLabel.stringValue = fresh.subtitle
        slotLabel.stringValue =
            editing
            ? Localized.text("Fill slot %d", fresh.slot + 1)
            : Localized.text("Slot %d", fresh.slot + 1)
        chip.isHidden = fresh.machine == nil
        if let machine = fresh.machine { chip.show(machine: machine) }
        setAccessibilityLabel(fresh.spoken)
        face.alphaValue = fresh.isAway ? 0.45 : 1
        underline.isHidden = !(editing && !fresh.isHollow)
        needsLayout = true
        restyle()
        applyBreathing()
    }

    override func layout() {
        super.layout()
        face.frame = bounds
        let pad = PartyMetrics.pad
        let width = bounds.width
        let text = PartyMetrics.textWidth
        if card.isHollow {
            let size = PartyMetrics.hollowBall
            let label = PartyMetrics.lineHeight(PartyMetrics.slotFont)
            let top = (bounds.height - size - 6 * PartyMetrics.scale - label) / 2
            ball.frame = NSRect(x: (width - size) / 2, y: top, width: size, height: size)
            slotLabel.frame = NSRect(
                x: pad, y: top + size + 6 * PartyMetrics.scale, width: width - 2 * pad,
                height: label)
        } else {
            let size = PartyMetrics.ball
            ball.frame = NSRect(x: pad, y: pad, width: size, height: size)
            let chord = PartyMetrics.lineHeight(PartyMetrics.chordFont)
            chordLabel.frame = NSRect(
                x: pad + size + 6 * PartyMetrics.scale, y: pad,
                width: width - 2 * pad - size - 6 * PartyMetrics.scale, height: chord)
            var y = pad + size + 4 * PartyMetrics.scale
            titleField.frame = NSRect(x: pad - 2, y: y, width: text + 4, height: measured.titleHeight)
            y += measured.titleHeight
            underline.frame = NSRect(
                x: pad, y: y - 1 * PartyMetrics.scale, width: text, height: 1.5 * PartyMetrics.scale)
            let reserve = card.takesLevels && measured.chip == nil
                ? PartyMetrics.barsSize.width + 6 * PartyMetrics.scale : 0
            subtitleLabel.frame = NSRect(
                x: pad, y: y, width: text - reserve, height: measured.subtitleHeight)
            if let size = measured.chip {
                chip.frame = NSRect(
                    x: pad, y: bounds.height - pad - size.height, width: size.width,
                    height: size.height)
            }
            bars.frame = NSRect(
                x: width - pad - PartyMetrics.barsSize.width,
                y: bounds.height - pad - PartyMetrics.barsSize.height,
                width: PartyMetrics.barsSize.width, height: PartyMetrics.barsSize.height)
        }
        face.layer?.cornerRadius = PartyMetrics.radius
        dash.path = CGPath(
            roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), cornerWidth: PartyMetrics.radius,
            cornerHeight: PartyMetrics.radius, transform: nil)
        dash.frame = bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        guard let layer = face.layer else { return }
        let hue = PartyMetrics.hue(of: card)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dash.isHidden = !card.isHollow
            dash.strokeColor = MacTheme.Color.tertiaryLabel.cgColor
            underline.layer?.backgroundColor = hue.cgColor
            if card.isHollow {
                layer.backgroundColor = NSColor.clear.cgColor
                layer.borderWidth = 0
                layer.shadowOpacity = 0
            } else {
                let lift = hovered || pressed ? 0.09 : 0.05
                layer.backgroundColor = NSColor.labelColor.withAlphaComponent(lift).cgColor
                layer.borderWidth = card.isInUse || isDropTarget ? 2 * PartyMetrics.scale : 1
                layer.borderColor =
                    (isDropTarget
                        ? MacTheme.Color.accent : card.isInUse ? hue : MacTheme.Color.separator)
                    .cgColor
                layer.shadowColor = hue.cgColor
                layer.shadowRadius = 10 * PartyMetrics.scale
                layer.shadowOffset = .zero
                layer.shadowOpacity = card.isInUse && !lifted ? 0.45 : 0
            }
            CATransaction.commit()
        }
    }

    /// While a turn runs, the in-use card's halo swells and settles on the shared absolute clock,
    /// so two cards, or the same card after a redraw, are always at the same point of the breath.
    func setBreathing(_ on: Bool) {
        breathing = on
        applyBreathing()
    }

    private func applyBreathing() {
        guard let layer = face.layer else { return }
        layer.removeAnimation(forKey: "breath")
        guard breathing, card.isInUse, EffortHeat.motionAllowed else { return }
        let pulse = TailscodeCore.ActivityPulse(period: 2.6, floor: 0.35)
        let steps = 32
        let animation = CAKeyframeAnimation(keyPath: "shadowOpacity")
        animation.values = (0...steps).map { step -> Float in
            Float(0.5 * pulse.intensity(at: Double(step) / Double(steps) * pulse.period))
        }
        animation.duration = pulse.period
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        let phase = pulse.phase(at: Date.timeIntervalSinceReferenceDate)
        animation.beginTime = CACurrentMediaTime() - phase * pulse.period
        layer.add(animation, forKey: "breath")
    }

    private(set) var lifted = false

    /// The card carried by hand: a little larger, a little askew, with a shadow under it. The
    /// transform rides on this view's sublayers because AppKit owns the view layer's own.
    func setLifted(_ on: Bool) {
        guard lifted != on else { return }
        lifted = on
        var transform = CATransform3DIdentity
        if on {
            transform = CATransform3DRotate(CATransform3DMakeScale(1.04, 1.04, 1), 0.03, 0, 0, 1)
        }
        let layer = self.layer
        layer?.sublayerTransform = transform
        face.layer?.shadowColor = on ? NSColor.black.cgColor : PartyMetrics.hue(of: card).cgColor
        face.layer?.shadowRadius = on ? 16 * PartyMetrics.scale : 10 * PartyMetrics.scale
        face.layer?.shadowOffset = on ? CGSize(width: 0, height: -8) : .zero
        face.layer?.shadowOpacity = on ? 0.4 : (card.isInUse ? 0.45 : 0)
        face.layer?.masksToBounds = false
    }

    func focusRename() {
        guard isEditing, !card.isHollow, let window else { return }
        renameCancelled = false
        window.makeFirstResponder(titleField)
        titleField.currentEditor()?.selectAll(nil)
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        restyle()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        restyle()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if isEditing, !card.isHollow, titleField.frame.contains(local) { return titleField }
        return self
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onMenu?(self)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let window else { return }
        let start = event.locationInWindow
        let canDrag = isEditing && !card.isHollow
        var carried = false
        pressed = true
        restyle()
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                pressed = false
                restyle()
                let point = convert(next.locationInWindow, from: nil)
                if carried {
                    onDrag?(self, .ended(next.locationInWindow))
                } else if bounds.contains(point) {
                    pressUp(at: point)
                }
                return
            }
            let travelled = hypot(
                next.locationInWindow.x - start.x, next.locationInWindow.y - start.y)
            if canDrag, !carried, travelled > 4 {
                carried = true
                onDrag?(self, .began(start))
            }
            if carried { onDrag?(self, .moved(next.locationInWindow)) }
        }
        pressed = false
        restyle()
    }

    private func pressUp(at point: NSPoint) {
        guard isEditing, !card.isHollow else {
            onPress?(self)
            return
        }
        let local = ball.convert(point, from: self)
        if ball.buttonContains(local) { onStepLevel?(self) }
    }

    override func keyDown(with event: NSEvent) {
        guard onKey?(self, event) == true else {
            super.keyDown(with: event)
            return
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?(self)
        return true
    }
}

extension PartyCardView: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        let limit = ModelParty.nameLimit
        guard titleField.stringValue.count > limit else { return }
        titleField.stringValue = String(titleField.stringValue.prefix(limit))
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        defer { renameCancelled = false }
        guard !renameCancelled else {
            titleField.stringValue = card.title
            return
        }
        onRename?(self, titleField.stringValue)
    }

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            window?.makeFirstResponder(self)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            renameCancelled = true
            window?.makeFirstResponder(self)
            return true
        default:
            return false
        }
    }
}
