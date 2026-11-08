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
    private var shownWidth: CGFloat = -1
    private var shownGlyphAlpha: CGFloat = -1
    private var shownBadgeAlpha: CGFloat = -1
    private var hideToken = 0
    private var flashToken = 0
    private var flashing: NSColor?
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
        ring.opacity = 0
        layer?.addSublayer(ring)
        glyph.imageScaling = .scaleNone
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        badge.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
        badge.alphaValue = 0
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

    /// The press is measured in the window, never in the control: the control widens into the
    /// capsule under a still finger, and a distance read in its own coordinates would drift by
    /// that growth.
    override func mouseDown(with event: NSEvent) {
        pressPoint = event.locationInWindow
        onDown?(convert(pressPoint, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.locationInWindow.x - pressPoint.x, event.locationInWindow)
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

    /// Draws a face by moving every property from where it stands to the face's target, so a state
    /// that arrives mid-motion bends the motion rather than restarting it: tints blend, the width
    /// springs, the glyph is replaced as a symbol, the badge and the ring fade, a held take lifts.
    func apply(_ face: DictationFace, animated: Bool) {
        let previous = self.face
        self.face = face
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let motion = animated && !reduce
        let open = face.showsBars
        let width = face == .hidden ? 0 : (open ? Self.openWidth : Self.restWidth)
        setHidden(face == .hidden, animated: animated)
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.18 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        CATransaction.setDisableActions(!animated)
        paint()
        capsule.opacity = open ? 1 : 0
        if previous.showsBars != open { halo.opacity = open ? 0.5 : 0 }
        ring.opacity = face.isPreparing ? 1 : 0
        CATransaction.commit()
        drawRingFill(face, reduce: reduce)
        lift(to: Self.scale(for: face), animated: motion)
        let symbol = NSImage(systemSymbolName: face.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        if previous.symbol != face.symbol, motion, let symbol {
            glyph.setSymbolImage(symbol, contentTransition: .replace)
        } else {
            glyph.image = symbol
        }
        let glyphAlpha: CGFloat = open ? 0 : 1
        let badgeAlpha: CGFloat = face.wearsDownloadBadge ? 1 : 0
        if width != shownWidth || glyphAlpha != shownGlyphAlpha || badgeAlpha != shownBadgeAlpha {
            shownWidth = width
            shownGlyphAlpha = glyphAlpha
            shownBadgeAlpha = badgeAlpha
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animated ? (motion && previous.showsBars != open ? 0.32 : 0.18) : 0
                context.timingFunction =
                    motion && previous.showsBars != open
                    ? CAMediaTimingFunction(controlPoints: 0.3, 1.25, 0.5, 1) : CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                self.widthConstraint.constant = width
                self.glyph.alphaValue = glyphAlpha
                self.badge.alphaValue = badgeAlpha
                self.superview?.layoutSubtreeIfNeeded()
            }
        }
        if face == .settling { sinkBars(animated: motion) }
        setAccessibilityLabel(DictationReading.accessibilityLabel(face))
        toolTip = DictationReading.tooltip(face, chord: chord)
    }

    private static func scale(for face: DictationFace) -> CGFloat {
        switch face {
        case .listening(.held, .send): return 0.86
        case .listening(.held, .none): return 1.08
        default: return 1
        }
    }

    /// The capsule's scale follows the hand: lifted while a hold is engaged, shrunk toward Send
    /// while armed to send, sprung from wherever it stands.
    private func lift(to scale: CGFloat, animated: Bool) {
        let target = CATransform3DMakeScale(scale, scale, 1)
        guard !CATransform3DEqualToTransform(capsule.transform, target) else { return }
        let from = capsule.presentation()?.transform ?? capsule.transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        capsule.transform = target
        halo.transform = target
        CATransaction.commit()
        guard animated else { return }
        for layer in [capsule, halo] {
            let spring = CASpringAnimation(keyPath: "transform")
            spring.fromValue = from
            spring.toValue = target
            spring.damping = 14
            spring.stiffness = 260
            spring.mass = 1
            spring.duration = spring.settlingDuration
            layer.add(spring, forKey: "lift")
        }
    }

    /// The ring fills smoothly between readings whatever the redraw asked for, turns while the size
    /// is unknown, eases back to the top when the first reading lands, and keeps turning while it
    /// fades out, so it never snaps upright on its way out.
    private func drawRingFill(_ face: DictationFace, reduce: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(reduce ? 0 : 0.25)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        if let progress = face.progress {
            if ring.animation(forKey: "spin") != nil { settleSpin() }
            ring.strokeEnd = CGFloat(max(0.03, progress))
        } else if face.isPreparing {
            ring.strokeEnd = 0.25
            spin(reduce: reduce)
        } else if ring.animation(forKey: "spin") != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !self.face.isPreparing else { return }
                self.ring.removeAnimation(forKey: "spin")
            }
        } else if ring.strokeEnd > 0.03, ring.strokeEnd < 1 {
            ring.strokeEnd = 1
        }
        CATransaction.commit()
    }

    /// An indeterminate wait turns the quarter arc; Reduced Motion holds it still.
    private func spin(reduce: Bool) {
        guard !reduce, ring.animation(forKey: "spin") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -Double.pi * 2
        spin.duration = 1.1
        spin.repeatCount = .infinity
        ring.add(spin, forKey: "spin")
    }

    /// The first reading lands while the arc is turning: it eases back to the top from wherever it
    /// stands rather than jumping, while the fill grows to the reading.
    private func settleSpin() {
        let angle = ring.presentation()?.value(forKeyPath: "transform.rotation.z") as? Double ?? 0
        ring.removeAnimation(forKey: "spin")
        let back = CABasicAnimation(keyPath: "transform.rotation.z")
        back.fromValue = angle
        back.toValue = 0
        back.duration = 0.25
        back.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(back, forKey: "settle")
    }

    /// The bars sink to the floor while the last words settle, then the capsule narrows.
    private func sinkBars(animated: Bool) {
        heights = [Double](repeating: DictationBars.floor, count: DictationBars.count)
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.16 : 0)
        CATransaction.setDisableActions(!animated)
        layoutBars()
        CATransaction.commit()
    }

    /// Leaving and coming back fade with the width, and the control is taken out of the layout only
    /// once it has faded.
    private func setHidden(_ hidden: Bool, animated: Bool) {
        hideToken += 1
        let token = hideToken
        if !hidden {
            if isHidden {
                alphaValue = 0
                isHidden = false
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animated ? 0.22 : 0
                context.allowsImplicitAnimation = true
                self.alphaValue = 1
            }
            return
        }
        guard !isHidden else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.22 : 0
            context.allowsImplicitAnimation = true
            self.alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hideToken == token, self.face == .hidden else { return }
                self.isHidden = true
            }
        }
    }

    /// How a take ended, carried by the rest glyph for a moment: the accent for words kept or sent,
    /// danger for a discard, the warning tone for a problem, then back to its own ink.
    func flash(_ end: DictationEnd) {
        let tone: NSColor
        switch end {
        case .kept, .sent: tone = MacTheme.Color.accent
        case .discarded: tone = MacTheme.Color.danger
        case .problem: tone = MacTheme.Color.warning
        case .nothingHeard: return
        }
        flashToken += 1
        let token = flashToken
        flashing = tone
        paint()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.flashToken == token else { return }
            self.flashing = nil
            self.paint()
        }
    }

    /// The glyph's ink, crossfaded when it changes: an image view does not blend its tint.
    private func setGlyphTint(_ tint: NSColor) {
        guard glyph.contentTintColor != tint else { return }
        if glyph.contentTintColor != nil, window != nil,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.18
            glyph.layer?.add(fade, forKey: "tint")
        }
        glyph.contentTintColor = tint
    }

    /// One pulse when a speech model has just landed: ready now, and still waiting for a press.
    func pulse() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = glyph.layer else { return }
        let center = CGPoint(x: glyph.bounds.midX, y: glyph.bounds.midY)
        var grown = CATransform3DMakeTranslation(center.x, center.y, 0)
        grown = CATransform3DScale(grown, 1.12, 1.12, 1)
        grown = CATransform3DTranslate(grown, -center.x, -center.y, 0)
        let pulse = CAKeyframeAnimation(keyPath: "transform")
        pulse.values = [CATransform3DIdentity, grown, CATransform3DIdentity]
        pulse.keyTimes = [0, 0.35, 1]
        pulse.duration = 0.45
        pulse.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        layer.add(pulse, forKey: "pulse")
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
        if let flashing, !face.isOpen {
            setGlyphTint(flashing)
            badge.contentTintColor = MacTheme.Color.accent
            return
        }
        let tint: NSColor
        switch face {
        case .blocked: tint = MacTheme.Color.warning
        case .needsModel, .preparing: tint = MacTheme.Color.accent
        default: tint = .secondaryLabelColor
        }
        setGlyphTint(tint)
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

/// The box's last line, inside the field under the words: the timer and how to stop, where a held
/// take will go, or how a take ended, with Undo after a discard. The field shows and hides it.
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
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func undoPressed() { onUndo?() }

    private(set) var showing = false

    var text: String { showing ? label.stringValue : "" }

    func show(_ hint: DictationHint?, undoAvailable: Bool) {
        showing = hint != nil
        guard let hint else { return }
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
