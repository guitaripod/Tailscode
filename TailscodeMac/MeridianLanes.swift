import AppKit
import TailscodeCore

/// The measures the sheet's lanes are laid out from, so the rows, the hour ticks, the overlay and the
/// scrubber agree on where the day starts and ends.
@MainActor
enum MeridianMetrics {
    static var labelWidth: CGFloat { 232 * MacTheme.UIScale.factor }
    static let columnGap: CGFloat = 18
    static let rowHeight: CGFloat = 44
    static let rowGap: CGFloat = 10
    static let tickHeight: CGFloat = 16
    static let barHeight: CGFloat = 40
    static let barRadius: CGFloat = 13
    static let trackHeight: CGFloat = 30
    static let thumbSize = CGSize(width: 18, height: 24)
    static let lineOverhangTop: CGFloat = 8
    static let lineOverhangBottom: CGFloat = 4
    static let glide: TimeInterval = 0.18

    static var barInset: CGFloat { labelWidth + columnGap }

    static func height(lanes: Int) -> CGFloat {
        let rows = CGFloat(lanes) * rowHeight + CGFloat(max(0, lanes - 1)) * rowGap
        return tickHeight + rowGap + rows + rowGap + trackHeight
    }

    static var motionAllowed: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// How big a one-line label's words are with the cell's own padding: the attributed string's
    /// bare width is a few points short of what the field needs and the field answers with an
    /// ellipsis.
    static func fit(_ field: NSTextField) -> NSSize {
        let size = field.cell?.cellSize ?? field.intrinsicContentSize
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }
}

/// A mark on a lane: a reset as a tick the lane's whole height with a dark pill beside it that can be
/// pressed to be told when the window reopens, or an alarm as a small diamond with its time. The pill
/// moves to the other side of the tick where it would run off the end of the lane.
@MainActor
final class MeridianMarkView: NSView {
    let mark: MeridianBoard.Mark
    var onPress: ((MeridianBoard.Mark) -> Void)?
    var labelOnLeft = false {
        didSet {
            guard labelOnLeft != oldValue else { return }
            needsLayout = true
        }
    }

    private let ground: TintView?
    private let diamond = CALayer()
    private let label: NSTextField

    override var isFlipped: Bool { true }

    init(mark: MeridianBoard.Mark) {
        self.mark = mark
        let isReset = mark.kind == .reset
        label = StudioTheme.label(
            isReset ? .pill : .rowStamp,
            color: isReset ? MacTheme.Color.info : MacTheme.Color.label)
        label.stringValue = mark.label
        ground =
            isReset
            ? TintView(
                fill: { MacTheme.Color.canvas.blended(withFraction: 0.35, of: .black)?.withAlphaComponent(0.92) ?? MacTheme.Color.canvas })
            : nil
        super.init(frame: .zero)
        wantsLayer = true
        if let ground {
            ground.translatesAutoresizingMaskIntoConstraints = true
            addSubview(ground)
        } else {
            diamond.bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
            diamond.cornerRadius = 1.5
            diamond.setAffineTransform(CGAffineTransform(rotationAngle: .pi / 4))
            layer?.addSublayer(diamond)
        }
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(isReset ? .button : .staticText)
        setAccessibilityLabel(mark.label)
        NotificationCenter.default.addObserver(
            self, selector: #selector(repaint), name: MacTheme.Chrome.didRepaint, object: nil)
        repaint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { NotificationCenter.default.removeObserver(self) }

    private var textWidth: CGFloat { MeridianMetrics.fit(label).width }

    var size: CGSize {
        mark.kind == .reset
            ? CGSize(width: textWidth + 18, height: 22) : CGSize(width: textWidth + 16, height: 16)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        mark.kind == .reset && bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func resetCursorRects() {
        if mark.kind == .reset { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard mark.kind == .reset, bounds.contains(convert(event.locationInWindow, from: nil)) else {
            return
        }
        onPress?(mark)
    }

    override func accessibilityPerformPress() -> Bool {
        guard mark.kind == .reset else { return false }
        onPress?(mark)
        return true
    }

    override func layout() {
        super.layout()
        let labelSize = MeridianMetrics.fit(label)
        if let ground {
            ground.frame = bounds
            ground.layer?.cornerRadius = bounds.height / 2
            label.frame = CGRect(
                x: 9, y: (bounds.height - labelSize.height) / 2, width: textWidth,
                height: labelSize.height)
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            diamond.position = CGPoint(x: labelOnLeft ? bounds.width - 5 : 5, y: bounds.midY)
            CATransaction.commit()
            label.frame = CGRect(
                x: labelOnLeft ? 0 : 14, y: (bounds.height - labelSize.height) / 2, width: textWidth,
                height: labelSize.height)
        }
    }

    @objc private func repaint() {
        label.font = MacTheme.Ramp.font(mark.kind == .reset ? .pill : .rowStamp)
        needsLayout = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            diamond.backgroundColor = MacTheme.Color.mark.cgColor
            diamond.borderColor = MacTheme.Color.canvas.cgColor
            diamond.borderWidth = 1
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        repaint()
    }
}

/// One place's whole day as a bar forty points tall: Core's daylight gradient between the night and
/// day colours, an hour grid, the sun where it stood at noon, and whatever marks the lane carries.
/// The bar knows nothing of the line or the scrub; those are drawn over every lane at once.
@MainActor
final class MeridianLaneBar: NSView {
    var onMark: ((MeridianBoard.Mark) -> Void)?

    private let clip = CALayer()
    private let gradient = CAGradientLayer()
    private let grid = CAShapeLayer()
    private let sunDot = CALayer()
    private let rim = CALayer()
    private var ticks: [CALayer] = []
    private var marks: [MeridianMarkView] = []
    private(set) var lane: MeridianBoard.Lane?
    private var minutes = 1440

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clip.masksToBounds = true
        clip.cornerRadius = MeridianMetrics.barRadius
        clip.cornerCurve = .continuous
        clip.zPosition = -1
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        grid.lineWidth = 1
        grid.fillColor = nil
        sunDot.bounds = CGRect(x: 0, y: 0, width: 14, height: 14)
        sunDot.cornerRadius = 7
        sunDot.shadowOffset = .zero
        sunDot.shadowRadius = 9
        sunDot.shadowOpacity = 0.7
        rim.cornerRadius = MeridianMetrics.barRadius
        rim.cornerCurve = .continuous
        rim.borderWidth = 1
        clip.addSublayer(gradient)
        clip.addSublayer(grid)
        clip.addSublayer(sunDot)
        clip.addSublayer(rim)
        layer?.addSublayer(clip)
        setAccessibilityElement(false)
        NotificationCenter.default.addObserver(
            self, selector: #selector(repaint), name: MacTheme.Chrome.didRepaint, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { NotificationCenter.default.removeObserver(self) }

    var gradientLayer: CAGradientLayer { gradient }

    var sunLayer: CALayer { sunDot }

    var markViews: [MeridianMarkView] { marks }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    func apply(lane: MeridianBoard.Lane, minutes: Int) {
        self.lane = lane
        self.minutes = minutes
        let wanted = lane.marks.map { "\($0.id)|\($0.label)" }
        if wanted != marks.map({ "\($0.mark.id)|\($0.mark.label)" }) {
            marks.forEach { $0.removeFromSuperview() }
            marks = lane.marks.map { mark in
                let view = MeridianMarkView(mark: mark)
                view.onPress = { [weak self] pressed in self?.onMark?(pressed) }
                addSubview(view)
                return view
            }
            rebuildTicks()
        }
        repaint()
        needsLayout = true
    }

    private func rebuildTicks() {
        ticks.forEach { $0.removeFromSuperlayer() }
        ticks = lane?.marks.filter { $0.kind == .reset }.map { _ in
            let tick = CALayer()
            clip.insertSublayer(tick, below: rim)
            return tick
        } ?? []
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let box = CGRect(
            x: 0, y: (bounds.height - MeridianMetrics.barHeight) / 2, width: bounds.width,
            height: MeridianMetrics.barHeight)
        clip.frame = box
        let local = clip.bounds
        gradient.frame = local
        grid.frame = local
        rim.frame = local
        let path = CGMutablePath()
        let hours = Int((Double(minutes) / 60).rounded(.up))
        for hour in 1..<max(hours, 1) {
            let x = (CGFloat(hour) * 60 / CGFloat(minutes)) * local.width
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: local.height))
        }
        grid.path = path
        if let noon = lane?.bar.noon, lane?.bar.hasSun == true {
            sunDot.isHidden = false
            sunDot.position = CGPoint(x: local.width * CGFloat(noon), y: local.midY)
        } else {
            sunDot.isHidden = true
        }
        let resets = lane?.marks.filter { $0.kind == .reset } ?? []
        for (tick, mark) in zip(ticks, resets) {
            tick.frame = CGRect(
                x: local.width * CGFloat(mark.position) - 1, y: 0, width: 2, height: local.height)
        }
        CATransaction.commit()
        for view in marks {
            let size = view.size
            let x = bounds.width * CGFloat(view.mark.position)
            var originX = x + (view.mark.kind == .reset ? 8 : -5)
            if view.mark.kind == .reset {
                if originX + size.width > bounds.width - 4 { originX = x - 8 - size.width }
            } else {
                let flips = originX + size.width > bounds.width - 2
                view.labelOnLeft = flips
                if flips { originX = x + 5 - size.width }
            }
            view.frame = CGRect(
                x: originX, y: (bounds.height - size.height) / 2, width: size.width,
                height: size.height)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        repaint()
    }

    @objc private func repaint() {
        guard let lane else { return }
        let paint =
            lane.bar.hasSun
            ? DaylightPalette.gradient(for: lane.bar, appearance: effectiveAppearance)
            : Self.flat(appearance: effectiveAppearance)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.colors = paint.colors
        gradient.locations = paint.locations
        effectiveAppearance.performAsCurrentDrawingAppearance {
            grid.strokeColor = MacTheme.Color.label.withAlphaComponent(0.06).cgColor
            rim.borderColor = MacTheme.Color.label.withAlphaComponent(0.1).cgColor
            let sun = DaylightPalette.sun.cgColor
            sunDot.backgroundColor = sun
            sunDot.shadowColor = sun
            for tick in ticks { tick.backgroundColor = MacTheme.Color.info.cgColor }
        }
        CATransaction.commit()
    }

    private static func flat(appearance: NSAppearance) -> (colors: [CGColor], locations: [NSNumber]) {
        var colors: [CGColor] = []
        appearance.performAsCurrentDrawingAppearance {
            let night = DaylightPalette.night
            colors = [night.cgColor, (night.blended(withFraction: 0.25, of: DaylightPalette.day) ?? night).cgColor]
        }
        return (colors, [0, 1])
    }
}

/// One lane: a tile with the body that is up there, the place and who it is for, the time the line
/// reads there and the day it falls on, and the bar. A lane the person pinned can be taken away from
/// its corner, from its menu or from the accessibility actions; the viewer's own lane cannot.
@MainActor
final class MeridianLaneRow: NSView {
    var onRemove: ((String) -> Void)?
    var onMove: ((String, Int) -> Void)?
    var onMark: ((MeridianBoard.Mark) -> Void)?
    var canMoveUp = false
    var canMoveDown = false

    let bar = MeridianLaneBar()
    private let tile = TintView(fill: { MacTheme.Color.canvasRaised }, radius: 9)
    private let glyph = NSImageView()
    private let name = StudioTheme.label(.rowTitleStrong)
    private let subtitle = StudioTheme.label(.panelFootnote, color: MacTheme.Color.secondaryLabel)
    private let time = StudioTheme.label(.statusLine, alignment: .right)
    private let day = StudioTheme.label(.panelFootnote, color: MacTheme.Color.secondaryLabel, alignment: .right)
    private let remove = NSButton()
    private(set) var lane: MeridianBoard.Lane?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glyph.imageScaling = .scaleNone
        glyph.setAccessibilityElement(false)
        tile.translatesAutoresizingMaskIntoConstraints = true
        remove.isBordered = false
        remove.imagePosition = .imageOnly
        remove.target = self
        remove.action = #selector(removePressed)
        remove.isHidden = true
        remove.translatesAutoresizingMaskIntoConstraints = true
        bar.onMark = { [weak self] mark in self?.onMark?(mark) }
        for view in [tile, glyph, name, subtitle, time, day, remove, bar] { addSubview(view) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self))
        NotificationCenter.default.addObserver(
            self, selector: #selector(restyle), name: MacTheme.Chrome.didRepaint, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { NotificationCenter.default.removeObserver(self) }

    var laneID: String { lane?.id ?? "" }

    func apply(lane: MeridianBoard.Lane, minutes: Int) {
        self.lane = lane
        name.stringValue = lane.name
        subtitle.stringValue = lane.subtitle
        time.stringValue = lane.time
        day.stringValue = lane.dayWord
        bar.apply(lane: lane, minutes: minutes)
        restyle()
        remove.isHidden = true
        needsLayout = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(lane.name), \(lane.time), \(lane.dayWord)")
    }

    @objc private func restyle() {
        guard let lane else { return }
        name.font = MacTheme.Ramp.font(.rowTitleStrong)
        subtitle.font = MacTheme.Ramp.font(.panelFootnote)
        time.font = MacTheme.Ramp.font(.statusLine)
        day.font = MacTheme.Ramp.font(.panelFootnote)
        switch lane.isUp {
        case .some(true):
            glyph.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .medium))
            glyph.contentTintColor = DaylightPalette.sun
        case .some(false):
            glyph.image = NSImage(systemSymbolName: "moon", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
            glyph.contentTintColor = DaylightPalette.moon
        case .none:
            glyph.image = nil
        }
        remove.image = NSImage(
            systemSymbolName: "xmark.circle.fill", accessibilityDescription: Localized.text("Remove"))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        remove.contentTintColor = MacTheme.Color.secondaryLabel
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let labelWidth = MeridianMetrics.labelWidth
        let tileSide: CGFloat = 30
        tile.frame = CGRect(x: 0, y: (bounds.height - tileSide) / 2, width: tileSide, height: tileSide)
        let glyphSize = glyph.image?.size ?? .zero
        glyph.frame = CGRect(
            x: tile.frame.midX - glyphSize.width / 2, y: tile.frame.midY - glyphSize.height / 2,
            width: glyphSize.width, height: glyphSize.height)
        let timeWidth = max(MeridianMetrics.fit(time).width, 44)
        let dayWidth = MeridianMetrics.fit(day).width
        let rightWidth = max(timeWidth, dayWidth)
        let timeHeight = StudioTheme.height(of: .statusLine)
        let dayHeight = StudioTheme.height(of: .panelFootnote)
        let rightTop = (bounds.height - timeHeight - dayHeight) / 2
        time.frame = CGRect(x: labelWidth - rightWidth, y: rightTop, width: rightWidth, height: timeHeight)
        day.frame = CGRect(
            x: labelWidth - rightWidth, y: rightTop + timeHeight, width: rightWidth, height: dayHeight)
        let reserved: CGFloat = lane?.isRemovable == true ? 22 : 0
        let textX = tileSide + 10
        let textWidth = max(0, labelWidth - rightWidth - 10 - textX - reserved)
        let nameHeight = StudioTheme.height(of: .rowTitleStrong)
        let subHeight = StudioTheme.height(of: .panelFootnote)
        let textTop = (bounds.height - nameHeight - subHeight) / 2
        name.frame = CGRect(x: textX, y: textTop, width: textWidth, height: nameHeight)
        subtitle.frame = CGRect(x: textX, y: textTop + nameHeight, width: textWidth, height: subHeight)
        remove.frame = CGRect(
            x: labelWidth - rightWidth - 10 - 18, y: (bounds.height - 18) / 2, width: 18, height: 18)
        let barX = MeridianMetrics.barInset
        bar.frame = CGRect(x: barX, y: 0, width: max(0, bounds.width - barX), height: bounds.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === remove || hit is MeridianMarkView ? hit : self
    }

    override func mouseEntered(with event: NSEvent) {
        remove.isHidden = lane?.isRemovable != true
    }

    override func mouseExited(with event: NSEvent) {
        remove.isHidden = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let lane, lane.isRemovable else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let items: [(String, Selector, Bool)] = [
            (Localized.text("Remove"), #selector(removePressed), true),
            (Localized.text("Move up"), #selector(moveLaneUp), canMoveUp),
            (Localized.text("Move down"), #selector(moveLaneDown), canMoveDown),
        ]
        for (title, action, enabled) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            menu.addItem(item)
        }
        return menu
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let lane, lane.isRemovable else { return nil }
        var actions = [
            NSAccessibilityCustomAction(name: Localized.text("Remove")) { [weak self] in
                self?.removePressed()
                return true
            }
        ]
        if canMoveUp {
            actions.append(
                NSAccessibilityCustomAction(name: Localized.text("Move up")) { [weak self] in
                    self?.moveLaneUp()
                    return true
                })
        }
        if canMoveDown {
            actions.append(
                NSAccessibilityCustomAction(name: Localized.text("Move down")) { [weak self] in
                    self?.moveLaneDown()
                    return true
                })
        }
        return actions
    }

    @objc private func removePressed() {
        guard let lane, lane.isRemovable else { return }
        onRemove?(lane.id)
    }

    @objc private func moveLaneUp() {
        guard let lane else { return }
        onMove?(lane.id, -1)
    }

    @objc private func moveLaneDown() {
        guard let lane else { return }
        onMove?(lane.id, 1)
    }
}

/// What is drawn over every lane at once: the golden band where everyone is awake, the line for the
/// present, and the scrub line with its glow. It takes no presses; the lanes view reads the pointer.
@MainActor
final class MeridianOverlay: NSView {
    private let band = CALayer()
    private let nowLine = CALayer()
    private let scrubLine = CALayer()
    private let bandTag: TintView
    private let tagLabel = StudioTheme.label(.pill, color: MacTheme.Color.accent)
    private var golden: MeridianBoard.Golden?
    private var nowFraction = 0.0
    private var lineFraction = 0.0

    override init(frame frameRect: NSRect) {
        bandTag = TintView(
            fill: { MacTheme.Color.canvas.blended(withFraction: 0.3, of: .black)?.withAlphaComponent(0.85) ?? MacTheme.Color.canvas })
        super.init(frame: frameRect)
        wantsLayer = true
        scrubLine.shadowOffset = .zero
        scrubLine.shadowRadius = 8
        scrubLine.shadowOpacity = 0.6
        for layer in [band, nowLine, scrubLine] { self.layer?.addSublayer(layer) }
        bandTag.translatesAutoresizingMaskIntoConstraints = true
        bandTag.addSubview(tagLabel)
        addSubview(bandTag)
        setAccessibilityElement(false)
        NotificationCenter.default.addObserver(
            self, selector: #selector(repaint), name: MacTheme.Chrome.didRepaint, object: nil)
        repaint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { NotificationCenter.default.removeObserver(self) }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var scrubLayer: CALayer { scrubLine }

    var bandLayer: CALayer { band }

    var isShowingBand: Bool { !band.isHidden }

    func apply(board: MeridianBoard) {
        golden = board.golden
        nowFraction = board.nowPosition
        tagLabel.stringValue = board.golden?.label ?? ""
        place()
    }

    func setLine(_ fraction: Double, animated: Bool) {
        lineFraction = fraction
        let target = CGPoint(x: bounds.width * CGFloat(fraction), y: scrubLine.position.y)
        CATransaction.begin()
        if animated, MeridianMetrics.motionAllowed {
            CATransaction.setAnimationDuration(MeridianMetrics.glide)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
            scrubLine.removeAnimation(forKey: "position")
        }
        scrubLine.position = target
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        place()
    }

    private func place() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let lanes = CGRect(
            x: 0, y: MeridianMetrics.lineOverhangBottom, width: bounds.width,
            height: max(0, bounds.height - MeridianMetrics.lineOverhangTop - MeridianMetrics.lineOverhangBottom))
        if let golden, bounds.width > 0 {
            band.isHidden = false
            band.frame = CGRect(
                x: bounds.width * CGFloat(golden.start), y: lanes.minY,
                width: bounds.width * CGFloat(golden.end - golden.start), height: lanes.height)
            let labelSize = MeridianMetrics.fit(tagLabel)
            let width = labelSize.width + 18
            bandTag.frame = CGRect(x: band.frame.minX + 6, y: lanes.maxY - 3 - 18, width: width, height: 18)
            bandTag.layer?.cornerRadius = 9
            tagLabel.frame = CGRect(
                x: 9, y: (18 - labelSize.height) / 2, width: max(0, width - 18),
                height: labelSize.height)
            bandTag.isHidden = band.frame.minX + 6 + width > bounds.width
        } else {
            band.isHidden = true
            bandTag.isHidden = true
        }
        nowLine.frame = CGRect(
            x: bounds.width * CGFloat(nowFraction) - 1, y: lanes.minY, width: 2, height: lanes.height)
        scrubLine.bounds = CGRect(x: 0, y: 0, width: 2, height: bounds.height)
        scrubLine.position = CGPoint(x: bounds.width * CGFloat(lineFraction), y: bounds.midY)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        repaint()
    }

    @objc private func repaint() {
        tagLabel.font = MacTheme.Ramp.font(.pill)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            band.backgroundColor = MacTheme.Color.accent.withAlphaComponent(0.12).cgColor
            nowLine.backgroundColor = MacTheme.Color.label.withAlphaComponent(0.35).cgColor
            scrubLine.backgroundColor = MacTheme.Color.accent.cgColor
            scrubLine.shadowColor = MacTheme.Color.accent.cgColor
        }
    }
}

/// The track under the lanes: a pill thirty points tall with a thumb at the line, which the pointer
/// drags and the keyboard steps. A press on the track moves the line there with a short glide; a drag
/// follows the pointer at once. To assistive technologies it is a slider on the minute being read.
@MainActor
final class MeridianTrackView: NSView {
    var onScrub: ((Double, Bool) -> Void)?
    var onStep: ((Int) -> Void)?

    private let thumb = CALayer()
    private var fraction = 0.0
    private var valueText = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        thumb.bounds = CGRect(origin: .zero, size: MeridianMetrics.thumbSize)
        thumb.cornerRadius = MeridianMetrics.thumbSize.width / 2
        thumb.borderWidth = 3
        thumb.shadowOffset = .zero
        thumb.shadowRadius = 7
        thumb.shadowOpacity = 0.7
        layer?.addSublayer(thumb)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel(Localized.text("Scrub time"))
        NotificationCenter.default.addObserver(
            self, selector: #selector(repaint), name: MacTheme.Chrome.didRepaint, object: nil)
        repaint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { NotificationCenter.default.removeObserver(self) }

    var thumbLayer: CALayer { thumb }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        placeThumb(animated: false)
    }

    func apply(fraction: Double, value: String, animated: Bool) {
        self.fraction = fraction
        valueText = value
        placeThumb(animated: animated)
    }

    private func placeThumb(animated: Bool) {
        let half = MeridianMetrics.thumbSize.width / 2
        let x = min(max(bounds.width * CGFloat(fraction), half), max(half, bounds.width - half))
        CATransaction.begin()
        if animated, MeridianMetrics.motionAllowed {
            CATransaction.setAnimationDuration(MeridianMetrics.glide)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
            thumb.removeAnimation(forKey: "position")
        }
        thumb.position = CGPoint(x: x, y: bounds.midY)
        CATransaction.commit()
    }

    private func fraction(for event: NSEvent) -> Double {
        let x = convert(event.locationInWindow, from: nil).x
        return min(max(Double(x / max(bounds.width, 1)), 0), 1)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onScrub?(fraction(for: event), true)
    }

    override func mouseDragged(with event: NSEvent) {
        onScrub?(fraction(for: event), false)
    }

    override func keyDown(with event: NSEvent) {
        let big = event.modifierFlags.contains(.shift) ? 15 : 1
        switch event.keyCode {
        case 123: onStep?(-big)
        case 124: onStep?(big)
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityValue() -> Any? { valueText }

    override func accessibilityPerformIncrement() -> Bool {
        onStep?(15)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        onStep?(-15)
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        repaint()
    }

    @objc private func repaint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = MacTheme.Color.canvasRaised.cgColor
            layer?.borderColor = MacTheme.Color.separator.cgColor
            thumb.backgroundColor = MacTheme.Color.accent.cgColor
            thumb.borderColor = MacTheme.Color.canvas.cgColor
            thumb.shadowColor = MacTheme.Color.accent.cgColor
        }
    }
}

/// The hour ticks above the lanes, set in the viewer's own hours and laid so the first stands flush
/// with the start of the bars and the last with their end.
@MainActor
final class MeridianTickRow: NSView {
    private var labels: [(position: Double, field: NSTextField)] = []

    override var isFlipped: Bool { true }

    func apply(_ ticks: [MeridianBoard.Tick]) {
        if ticks.map(\.label) != labels.map({ $0.field.stringValue }) {
            labels.forEach { $0.field.removeFromSuperview() }
            labels = ticks.map { tick in
                let field = StudioTheme.label(.rowStamp, color: MacTheme.Color.secondaryLabel)
                field.stringValue = tick.label
                field.setAccessibilityElement(false)
                addSubview(field)
                return (tick.position, field)
            }
        }
        for entry in labels { entry.field.font = MacTheme.Ramp.font(.rowStamp) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        for entry in labels {
            let fitted = MeridianMetrics.fit(entry.field)
            let width = fitted.width
            let height = fitted.height
            entry.field.frame = CGRect(
                x: CGFloat(entry.position) * (bounds.width - width), y: (bounds.height - height) / 2,
                width: width, height: height)
        }
    }
}

/// Every lane, the hour ticks, what lies over them and the scrubber, placed by frame in one column so
/// the bars, the line and the track can never disagree about where an hour is. A press on a lane's bar
/// reads the pointer as a moment, exactly as the track does.
@MainActor
final class MeridianLanesView: NSView {
    var onScrub: ((Double, Bool) -> Void)?
    var onStep: ((Int) -> Void)?
    var onRemove: ((String) -> Void)?
    var onMove: ((String, Int) -> Void)?
    var onMark: ((MeridianBoard.Mark) -> Void)?

    private let ticks = MeridianTickRow()
    private let overlay = MeridianOverlay()
    let track = MeridianTrackView()
    private let hint = StudioTheme.label(.panelFootnote, color: MacTheme.Color.secondaryLabel)
    private(set) var rows: [MeridianLaneRow] = []
    private(set) var board: MeridianBoard?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        hint.stringValue = Localized.text("Drag to read every desk at that moment")
        track.onScrub = { [weak self] fraction, animated in self?.onScrub?(fraction, animated) }
        track.onStep = { [weak self] delta in self?.onStep?(delta) }
        addSubview(ticks)
        addSubview(overlay)
        addSubview(hint)
        addSubview(track)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var overlayView: MeridianOverlay { overlay }

    var laneCount: Int { board?.lanes.count ?? 0 }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric, height: MeridianMetrics.height(lanes: max(laneCount, 1)))
    }

    private var lanesTop: CGFloat { MeridianMetrics.tickHeight + MeridianMetrics.rowGap }

    private var lanesBottom: CGFloat {
        lanesTop + CGFloat(rows.count) * MeridianMetrics.rowHeight
            + CGFloat(max(0, rows.count - 1)) * MeridianMetrics.rowGap
    }

    func apply(_ board: MeridianBoard, animateLine: Bool) {
        let changed = rows.map(\.laneID) != board.lanes.map(\.id)
        if changed {
            rows.forEach { $0.removeFromSuperview() }
            rows = board.lanes.map { _ in
                let row = MeridianLaneRow()
                row.onRemove = { [weak self] id in self?.onRemove?(id) }
                row.onMove = { [weak self] id, delta in self?.onMove?(id, delta) }
                row.onMark = { [weak self] mark in self?.onMark?(mark) }
                addSubview(row, positioned: .below, relativeTo: overlay)
                return row
            }
        }
        self.board = board
        let pinned = board.lanes.filter(\.isRemovable)
        for (row, lane) in zip(rows, board.lanes) {
            row.canMoveUp = lane.isRemovable && pinned.first?.id != lane.id
            row.canMoveDown = lane.isRemovable && pinned.last?.id != lane.id
            row.apply(lane: lane, minutes: board.minutes)
        }
        ticks.apply(board.ticks)
        hint.font = MacTheme.Ramp.font(.panelFootnote)
        if changed {
            invalidateIntrinsicContentSize()
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
        overlay.apply(board: board)
        overlay.setLine(board.linePosition, animated: animateLine)
        track.apply(fraction: board.linePosition, value: board.head, animated: animateLine)
    }

    override func layout() {
        super.layout()
        let barX = MeridianMetrics.barInset
        let barWidth = max(0, bounds.width - barX)
        ticks.frame = CGRect(x: barX, y: 0, width: barWidth, height: MeridianMetrics.tickHeight)
        var y = lanesTop
        for row in rows {
            row.frame = CGRect(x: 0, y: y, width: bounds.width, height: MeridianMetrics.rowHeight)
            y += MeridianMetrics.rowHeight + MeridianMetrics.rowGap
        }
        let trackY = rows.isEmpty ? y : lanesBottom + MeridianMetrics.rowGap
        track.frame = CGRect(x: barX, y: trackY, width: barWidth, height: MeridianMetrics.trackHeight)
        let hintHeight = StudioTheme.height(of: .panelFootnote)
        hint.frame = CGRect(
            x: 0, y: trackY + (MeridianMetrics.trackHeight - hintHeight) / 2,
            width: MeridianMetrics.labelWidth, height: hintHeight)
        let overlayTop = lanesTop - MeridianMetrics.lineOverhangTop
        let overlayHeight = lanesBottom - lanesTop + MeridianMetrics.lineOverhangTop
            + MeridianMetrics.lineOverhangBottom
        overlay.frame = CGRect(x: barX, y: overlayTop, width: barWidth, height: overlayHeight)
    }

    override func mouseDown(with event: NSEvent) {
        guard let fraction = barFraction(event) else { return super.mouseDown(with: event) }
        onScrub?(fraction, true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let fraction = barFraction(event, clamped: true) else { return }
        onScrub?(fraction, false)
    }

    private func barFraction(_ event: NSEvent, clamped: Bool = false) -> Double? {
        let point = convert(event.locationInWindow, from: nil)
        let barX = MeridianMetrics.barInset
        let width = bounds.width - barX
        guard width > 0 else { return nil }
        let inside = point.x >= barX && point.x <= bounds.width && point.y >= lanesTop && point.y <= lanesBottom
        guard inside || clamped else { return nil }
        return min(max(Double((point.x - barX) / width), 0), 1)
    }
}
