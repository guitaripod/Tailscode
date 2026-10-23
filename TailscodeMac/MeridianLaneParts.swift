import AppKit
import TailscodeCore

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
        label.lineBreakMode = .byClipping
        ground =
            isReset
            ? TintView(
                fill: { MacTheme.Color.canvasRaised },
                stroke: { MacTheme.Color.separator })
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
        var placed: [CGRect] = []
        for view in marks.sorted(by: { ($0.mark.kind == .reset ? 0 : 1) < ($1.mark.kind == .reset ? 0 : 1) }) {
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
            let middle = (bounds.height - size.height) / 2
            func free(_ x: CGFloat, _ y: CGFloat) -> Bool {
                let box = CGRect(x: x, y: y, width: size.width, height: size.height).insetBy(dx: -3, dy: 0)
                return !placed.contains { $0.intersects(box) }
            }
            var y = middle
            var finalX = originX
            search: do {
                for candidate in [middle, 3, bounds.height - size.height - 3] where free(originX, candidate) {
                    y = candidate
                    break search
                }
                for blocker in placed {
                    for shifted in [blocker.maxX + 4, blocker.minX - size.width - 4]
                    where shifted >= 0 && shifted + size.width <= bounds.width && free(shifted, middle) {
                        finalX = shifted
                        break search
                    }
                }
            }
            let frame = CGRect(x: finalX, y: y, width: size.width, height: size.height)
            view.frame = frame
            placed.append(frame)
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
            let dark = DaylightPalette.isDark(appearance)
            let night = DaylightPalette.night(dark: dark)
            let day = DaylightPalette.day(dark: dark)
            colors = [night.cgColor, (night.blended(withFraction: 0.25, of: day) ?? night).cgColor]
        }
        return (colors, [0, 1])
    }
}
