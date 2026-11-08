import AppKit
import TailscodeCore

/// The microphone beside Send. At rest a plain glyph; while the microphone is open it grows into
/// a capsule of five level bars in the accent, the same face the phone wears. It takes its own
/// presses — down opens, a quick release leaves the microphone open, a hold keeps it open while
/// held, and dragging away arms a cancel — because a button's click arrives only on the way up,
/// too late for the first word.
@MainActor
final class MacDictationButton: NSView {
    static let restWidth: CGFloat = 26
    static let openWidth: CGFloat = 48
    static let height: CGFloat = 26

    var onDown: ((NSPoint) -> Void)?
    var onDrag: ((CGFloat, NSPoint) -> Void)?
    var onUp: (() -> Void)?
    var onActivate: (() -> Void)?

    private let glyph = NSImageView()
    private let capsule = CALayer()
    private let halo = CALayer()
    private let ring = CAShapeLayer()
    private let badge = NSImageView()
    private var bars: [CALayer] = []
    private var heights = [Double](repeating: DictationBars.floor, count: DictationBars.count)
    private var pressPoint: NSPoint = .zero
    private(set) var face: DictationFace = .ready
    private(set) lazy var widthConstraint = widthAnchor.constraint(equalToConstant: Self.restWidth)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = false
        halo.cornerRadius = Self.height / 2 + 5
        halo.opacity = 0
        capsule.cornerRadius = Self.height / 2
        capsule.cornerCurve = .continuous
        capsule.opacity = 0
        layer?.addSublayer(halo)
        layer?.addSublayer(capsule)
        for _ in 0..<DictationBars.count {
            let bar = CALayer()
            bar.cornerRadius = 1.25
            capsule.addSublayer(bar)
            bars.append(bar)
        }
        ring.fillColor = NSColor.clear.cgColor
        ring.lineWidth = 2
        ring.lineCap = .round
        ring.isHidden = true
        layer?.addSublayer(ring)
        glyph.imageScaling = .scaleNone
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        badge.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        NSLayoutConstraint.activate([
            widthConstraint,
            heightAnchor.constraint(equalToConstant: Self.height),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor),
            badge.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        apply(.ready, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        onActivate?()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        pressPoint = convert(event.locationInWindow, from: nil)
        onDown?(pressPoint)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onDrag?(point.x - pressPoint.x, event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        onUp?()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        capsule.frame = bounds
        halo.frame = bounds.insetBy(dx: -5, dy: -5)
        ring.frame = bounds
        ring.path = CGPath(
            ellipseIn: CGRect(x: bounds.midX - 11, y: bounds.midY - 11, width: 22, height: 22), transform: nil)
        layoutBars()
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    func setLevels(_ heights: [Double]) {
        self.heights = heights
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutBars()
        CATransaction.commit()
    }

    func setHalo(_ level: Double) {
        guard face.isOpen else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        halo.opacity = Float(0.3 + 0.7 * min(1, max(0, level)))
        CATransaction.commit()
    }

    private func layoutBars() {
        let width: CGFloat = 2.5
        let gap: CGFloat = 2.5
        let total = CGFloat(bars.count) * width + CGFloat(bars.count - 1) * gap
        let inner = bounds.height - 10
        var x = (bounds.width - total) / 2
        for (index, bar) in bars.enumerated() {
            let fraction = CGFloat(index < heights.count ? heights[index] : DictationBars.floor)
            let height = max(width, inner * fraction)
            bar.frame = CGRect(x: x, y: (bounds.height - height) / 2, width: width, height: height)
            x += width + gap
        }
    }

    func apply(_ face: DictationFace, animated: Bool) {
        let wasOpen = self.face.showsBars
        self.face = face
        let open = face.showsBars
        isHidden = face == .hidden
        paint()
        glyph.image = NSImage(systemSymbolName: face.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        badge.isHidden = !face.wearsDownloadBadge
        ring.isHidden = !face.isPreparing
        ring.strokeEnd = CGFloat(max(0.03, face.progress ?? 0.25))
        let width = face == .hidden ? 0 : (open ? Self.openWidth : Self.restWidth)
        let changes = {
            self.widthConstraint.animator().constant = width
            self.glyph.animator().alphaValue = open ? 0 : 1
            self.superview?.layoutSubtreeIfNeeded()
        }
        capsule.opacity = open ? 1 : 0
        halo.opacity = open ? 0.5 : 0
        if case .listening(.held, .send) = face {
            capsule.setAffineTransform(CGAffineTransform(scaleX: 0.86, y: 0.86))
        } else {
            capsule.setAffineTransform(.identity)
        }
        if animated, wasOpen != open, NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.25, 0.5, 1)
                context.allowsImplicitAnimation = true
                changes()
            }
        } else {
            widthConstraint.constant = width
            glyph.alphaValue = open ? 0 : 1
        }
        if face == .settling { setLevels([Double](repeating: DictationBars.floor, count: DictationBars.count)) }
        setAccessibilityLabel(DictationReading.accessibilityLabel(face))
        toolTip = DictationReading.tooltip(face, chord: chord)
    }

    var chord: String?

    private func paint() {
        let fill: NSColor = face.tone == .danger ? MacTheme.Color.danger : MacTheme.Color.accent
        effectiveAppearance.performAsCurrentDrawingAppearance {
            capsule.backgroundColor = fill.cgColor
            halo.backgroundColor = fill.withAlphaComponent(0.16).cgColor
            for bar in bars { bar.backgroundColor = NSColor.white.cgColor }
            ring.strokeColor = MacTheme.Color.accent.cgColor
        }
        switch face {
        case .blocked: glyph.contentTintColor = MacTheme.Color.warning
        case .needsModel, .preparing: glyph.contentTintColor = MacTheme.Color.accent
        default: glyph.contentTintColor = .secondaryLabelColor
        }
        badge.contentTintColor = MacTheme.Color.accent
    }
}

/// The prompt box's lit edge while the microphone is open: drawn round the field from the corner
/// where the microphone sits, then breathing with the voice.
@MainActor
final class MacDictationEdge: NSView {
    private let line = CAShapeLayer()
    private(set) var isLit = false
    var cornerRadius: CGFloat = 8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = false
        line.fillColor = NSColor.clear.cgColor
        line.lineWidth = 1.5
        line.strokeEnd = 0
        line.shadowOffset = .zero
        line.shadowRadius = 8
        line.shadowOpacity = 0
        layer?.addSublayer(line)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        line.frame = bounds
        let rect = bounds.insetBy(dx: 0.75, dy: 0.75)
        let path = CGMutablePath()
        let r = min(cornerRadius, rect.height / 2)
        path.move(to: CGPoint(x: rect.maxX - r - 24, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: r)
        path.closeSubpath()
        line.path = path
    }

    func setLit(_ lit: Bool, danger: Bool, animated: Bool) {
        let color = (danger ? MacTheme.Color.danger : MacTheme.Color.accent).cgColor
        line.strokeColor = color
        line.shadowColor = color
        guard lit != isLit else { return }
        isLit = lit
        if lit {
            isHidden = false
            line.opacity = 1
            line.strokeEnd = 1
            guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = 0
            draw.toValue = 1
            draw.duration = 0.36
            draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
            line.add(draw, forKey: "draw")
        } else {
            line.opacity = 0
            line.strokeEnd = 0
            isHidden = true
        }
    }

    func setLevel(_ level: Double) {
        guard isLit else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.opacity = Float(DictationBars.edgeOpacity(level: level))
        line.shadowOpacity = Float(0.2 + 0.5 * min(1, max(0, level)))
        CATransaction.commit()
    }
}

/// The line over the box that says what to do now, inside the composer's own glass rather than on
/// glass of its own: the timer and how to stop, where a held take will go, or how a take ended,
/// with Undo after a discard.
@MainActor
final class MacDictationHint: NSView {
    private let dot = NSTextField(labelWithString: "●")
    private let timer = NSTextField(labelWithString: "")
    private let label = NSTextField(labelWithString: "")
    private let undo = NSButton(title: DictationReading.undo, target: nil, action: nil)
    var onUndo: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        dot.font = .systemFont(ofSize: 8)
        dot.textColor = MacTheme.Color.accent
        timer.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        timer.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        undo.bezelStyle = .inline
        undo.isBordered = false
        undo.contentTintColor = MacTheme.Color.accent
        undo.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        undo.target = self
        undo.action = #selector(undoPressed)
        let stack = NSStackView(views: [dot, timer, label, undo])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func undoPressed() { onUndo?() }

    var text: String { isHidden ? "" : label.stringValue }

    func show(_ hint: DictationHint?, undoAvailable: Bool) {
        guard let hint else {
            isHidden = true
            return
        }
        isHidden = false
        dot.isHidden = hint.style != .live
        timer.stringValue = hint.timer ?? ""
        timer.isHidden = hint.timer == nil
        label.stringValue = hint.text
        switch hint.style {
        case .danger: label.textColor = MacTheme.Color.danger
        case .warning: label.textColor = MacTheme.Color.warning
        case .live, .plain: label.textColor = .secondaryLabelColor
        }
        undo.isHidden = !(hint.offersUndo && undoAvailable)
        setAccessibilityLabel([hint.timer, hint.text].compactMap { $0 }.joined(separator: ", "))
    }
}
