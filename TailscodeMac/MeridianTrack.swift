import AppKit
import TailscodeCore

/// What is drawn over every lane at once: the golden band where everyone is awake, the line for the
/// present, and the scrub line with its glow. It takes no presses; the lanes view reads the pointer.
@MainActor
final class MeridianOverlay: NSView {
    private let band = CALayer()
    private let nowLine = CALayer()
    private let scrubLine = CALayer()
    private let bandTag: TintView
    private let tagLabel = MeridianLabel.framed(.pill, color: MacTheme.Color.accent)
    private var golden: MeridianBoard.Golden?
    private var nowFraction = 0.0
    private var lineFraction = 0.0

    override init(frame frameRect: NSRect) {
        bandTag = TintView(
            fill: { MacTheme.Color.canvasRaised },
            stroke: { MacTheme.Color.separator })
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
            let lastLaneTop = lanes.minY + MeridianMetrics.rowHeight
            bandTag.frame = CGRect(x: band.frame.minX + 6, y: lastLaneTop - 3 - 18, width: width, height: 18)
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
/// with the start of the bars and the last with their end. When the bars are too narrow for all nine
/// to stand apart, every other one is left out rather than letting two overlap.
@MainActor
final class MeridianTickRow: NSView {
    private var labels: [(position: Double, field: NSTextField)] = []

    override var isFlipped: Bool { true }

    func apply(_ ticks: [MeridianBoard.Tick]) {
        if ticks.map(\.label) != labels.map({ $0.field.stringValue }) {
            labels.forEach { $0.field.removeFromSuperview() }
            labels = ticks.map { tick in
                let field = MeridianLabel.framed(.rowStamp, color: MacTheme.Color.secondaryLabel)
                field.stringValue = tick.label
                field.setAccessibilityElement(false)
                addSubview(field)
                return (tick.position, field)
            }
        }
        for entry in labels { entry.field.font = MacTheme.Ramp.font(.rowStamp) }
        needsLayout = true
    }

    var floorWidth: CGFloat {
        let widths = labels.map { MeridianMetrics.fit($0.field).width }
        return widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * 8
    }

    override func layout() {
        super.layout()
        let thin = bounds.width < floorWidth
        for (index, entry) in labels.enumerated() {
            entry.field.isHidden = thin && index % 2 == 1
            let fitted = MeridianMetrics.fit(entry.field)
            entry.field.frame = CGRect(
                x: CGFloat(entry.position) * (bounds.width - fitted.width),
                y: (bounds.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
        }
    }
}
