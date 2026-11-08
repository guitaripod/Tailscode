import TailscodeCore
import UIKit

/// The microphone beside Send. At rest it is a plain glyph in secondary ink, never a second
/// filled circle beside Send; while the microphone is open it grows into a capsule of five level
/// bars in the accent, wearing a halo that follows the voice. A model being fetched draws as a
/// ring that fills, a microphone that cannot be heard wears a slash, and a held take armed to be
/// thrown away turns the danger tone.
@MainActor
final class DictationButton: UIControl {
    static let restWidth: CGFloat = 34
    static let openWidth: CGFloat = 56
    static let height: CGFloat = 34

    private let glyph = UIImageView()
    private let capsule = UIView()
    private let halo = UIView()
    private let badge = UIImageView()
    private let track = CAShapeLayer()
    private let ring = CAShapeLayer()
    private var bars: [CALayer] = []
    private(set) var face: DictationFace = .ready
    private var hideToken = 0
    private var flashToken = 0
    private var flashing: UIColor?
    var onActivate: (() -> Void)?
    private(set) lazy var widthConstraint = widthAnchor.constraint(equalToConstant: Self.restWidth)

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        isAccessibilityElement = true
        accessibilityTraits = .button

        halo.isUserInteractionEnabled = false
        halo.layer.cornerRadius = Self.height / 2 + 7
        halo.layer.cornerCurve = .continuous
        halo.alpha = 0
        halo.translatesAutoresizingMaskIntoConstraints = false
        addSubview(halo)

        capsule.isUserInteractionEnabled = false
        capsule.layer.cornerRadius = Self.height / 2
        capsule.layer.cornerCurve = .continuous
        capsule.alpha = 0
        capsule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(capsule)
        for _ in 0..<DictationBars.count {
            let bar = CALayer()
            bar.cornerRadius = 1.5
            capsule.layer.addSublayer(bar)
            bars.append(bar)
        }

        glyph.contentMode = .center
        glyph.isUserInteractionEnabled = false
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)

        for shape in [track, ring] {
            shape.fillColor = UIColor.clear.cgColor
            shape.lineWidth = 2.5
            shape.lineCap = .round
            shape.opacity = 0
            layer.addSublayer(shape)
        }

        badge.image = UIImage(
            systemName: "arrow.down.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold))
        badge.isUserInteractionEnabled = false
        badge.alpha = 0
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)

        NSLayoutConstraint.activate([
            widthConstraint,
            heightAnchor.constraint(equalToConstant: Self.height),
            capsule.leadingAnchor.constraint(equalTo: leadingAnchor),
            capsule.trailingAnchor.constraint(equalTo: trailingAnchor),
            capsule.topAnchor.constraint(equalTo: topAnchor),
            capsule.bottomAnchor.constraint(equalTo: bottomAnchor),
            halo.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -7),
            halo.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 7),
            halo.topAnchor.constraint(equalTo: topAnchor, constant: -7),
            halo.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 7),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            badge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (button: DictationButton, _) in
            button.paint()
        }
        apply(.ready, animated: false)
    }

    /// VoiceOver's double tap is a tap: it opens a take hands-free, or stops the one that is open.
    override func accessibilityActivate() -> Bool {
        onActivate?()
        return true
    }

    /// A finger needs 44 points; the glyph needs fewer.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -6, dy: -6).contains(point)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let circle = UIBezierPath(
            arcCenter: CGPoint(x: bounds.midX, y: bounds.midY), radius: 14, startAngle: -.pi / 2,
            endAngle: .pi * 1.5, clockwise: true)
        track.path = circle.cgPath
        ring.path = circle.cgPath
        for shape in [track, ring] {
            shape.bounds = bounds
            shape.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        layoutBars(heights: currentHeights)
    }

    private var currentHeights = [Double](repeating: DictationBars.floor, count: DictationBars.count)

    /// The bars at these heights, `0...1` of the capsule's inner height. Cheap enough for every
    /// frame: no animation, no layout pass.
    func setLevels(_ heights: [Double]) {
        currentHeights = heights
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutBars(heights: heights)
        CATransaction.commit()
    }

    func setHalo(_ level: Double) {
        guard face.isOpen else { return }
        halo.alpha = 0.35 + 0.65 * min(1, max(0, level))
    }

    private func layoutBars(heights: [Double]) {
        let barWidth: CGFloat = 3
        let gap: CGFloat = 3
        let total = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * gap
        let inner = Self.height - 14
        var x = (bounds.width - total) / 2
        for (index, bar) in bars.enumerated() {
            let fraction = CGFloat(index < heights.count ? heights[index] : DictationBars.floor)
            let height = max(barWidth, inner * fraction)
            bar.frame = CGRect(x: x, y: (Self.height - height) / 2, width: barWidth, height: height)
            x += barWidth + gap
        }
    }

    /// Draws a face by moving every property from where it stands to the face's target, so a state
    /// that arrives mid-motion bends the motion rather than restarting it: the width springs, the
    /// tints blend, the glyph is replaced as a symbol, the badge and the ring fade, a held take
    /// lifts and a take armed to send leans toward Send.
    func apply(_ face: DictationFace, animated: Bool) {
        let previous = self.face
        self.face = face
        let reduce = UIAccessibility.isReduceMotionEnabled
        let motion = animated && !reduce
        let open = face.showsBars
        let opening = previous.showsBars != open
        widthConstraint.constant = face == .hidden ? 0 : (open ? Self.openWidth : Self.restWidth)
        setHidden(face == .hidden, animated: animated)
        let changes = {
            self.paintFills()
            self.capsule.alpha = open ? 1 : 0
            self.glyph.alpha = open ? 0 : 1
            if opening { self.halo.alpha = open ? 0.5 : 0 }
            let lift = motion ? self.capsuleTransform(face) : .identity
            self.capsule.transform = lift
            self.halo.transform = lift
            self.badge.alpha = face.wearsDownloadBadge ? 1 : 0
            self.badge.transform =
                face.wearsDownloadBadge || !motion ? .identity : CGAffineTransform(scaleX: 0.6, y: 0.6)
            self.superview?.layoutIfNeeded()
        }
        if motion {
            UIView.animate(
                withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.75, initialSpringVelocity: 0.3,
                options: [.allowUserInteraction, .beginFromCurrentState], animations: changes)
        } else if animated {
            UIView.animate(
                withDuration: 0.15, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState],
                animations: changes)
        } else {
            changes()
        }
        tintGlyph(animated: animated)
        let symbol = UIImage(
            systemName: face.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular))
        if previous.symbol != face.symbol, motion, let symbol {
            glyph.setSymbolImage(symbol, contentTransition: .replace)
        } else {
            glyph.image = symbol
        }
        drawRing(face, animated: animated, reduce: reduce)
        if face == .settling { sinkBars(animated: motion) }
        accessibilityLabel = DictationReading.accessibilityLabel(face)
        accessibilityHint = DictationReading.accessibilityHint(face, surface: .touch)
    }

    /// The ring fades in at nothing, fills between readings, turns while the size is unknown and
    /// eases back to the top when the first reading lands, then fades out once the model is in.
    private func drawRing(_ face: DictationFace, animated: Bool, reduce: Bool) {
        let preparing = face.isPreparing
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.25 : 0)
        CATransaction.setDisableActions(!animated)
        track.opacity = preparing ? 1 : 0
        ring.opacity = preparing ? 1 : 0
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setAnimationDuration(reduce ? 0 : 0.25)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        if let progress = face.progress {
            if ring.animation(forKey: "spin") != nil {
                let angle = ring.presentation()?.value(forKeyPath: "transform.rotation.z") as? Double ?? 0
                ring.removeAnimation(forKey: "spin")
                let back = CABasicAnimation(keyPath: "transform.rotation.z")
                back.fromValue = angle
                back.toValue = 0
                back.duration = 0.25
                ring.add(back, forKey: "settle")
            }
            ring.strokeEnd = CGFloat(max(0.02, progress))
        } else if preparing {
            ring.strokeEnd = 0.25
            if !reduce, ring.animation(forKey: "spin") == nil {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = Double.pi * 2
                spin.duration = 1.1
                spin.repeatCount = .infinity
                ring.add(spin, forKey: "spin")
            }
        } else if ring.animation(forKey: "spin") != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !self.face.isPreparing else { return }
                self.ring.removeAnimation(forKey: "spin")
            }
        } else if ring.strokeEnd > 0.02, ring.strokeEnd < 1 {
            ring.strokeEnd = 1
        }
        CATransaction.commit()
    }

    /// The bars sink to the floor while the last words settle.
    private func sinkBars(animated: Bool) {
        currentHeights = [Double](repeating: DictationBars.floor, count: DictationBars.count)
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.16 : 0)
        CATransaction.setDisableActions(!animated)
        layoutBars(heights: currentHeights)
        CATransaction.commit()
    }

    /// Leaving and coming back fade with the width; the control leaves the layout only once faded.
    private func setHidden(_ hidden: Bool, animated: Bool) {
        hideToken += 1
        let token = hideToken
        if !hidden {
            guard isHidden || alpha < 1 else { return }
            if isHidden {
                alpha = 0
                isHidden = false
            }
            UIView.animate(withDuration: animated ? 0.22 : 0, delay: 0, options: [.beginFromCurrentState]) {
                self.alpha = 1
            }
            return
        }
        guard !isHidden else { return }
        UIView.animate(withDuration: animated ? 0.22 : 0, delay: 0, options: [.beginFromCurrentState]) {
            self.alpha = 0
        } completion: { _ in
            guard self.hideToken == token, self.face == .hidden else { return }
            self.isHidden = true
        }
    }

    /// How a take ended, carried by the rest glyph for a moment: the accent for words kept or sent,
    /// danger for a discard, the warning tone for a problem, then back to its own ink.
    func flash(_ end: DictationEnd) {
        let tone: UIColor
        switch end {
        case .kept, .sent: tone = Theme.Color.accent
        case .discarded: tone = Theme.Color.danger
        case .problem: tone = Theme.Color.warning
        case .nothingHeard: return
        }
        flashToken += 1
        let token = flashToken
        flashing = tone
        tintGlyph(animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.flashToken == token else { return }
            self.flashing = nil
            self.tintGlyph(animated: true)
        }
    }

    /// One pulse when a model has just landed: ready now, and still waiting for a press.
    func pulse() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        UIView.animate(withDuration: 0.16, delay: 0, options: [.allowUserInteraction]) {
            self.glyph.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
        } completion: { _ in
            UIView.animate(
                withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0.4,
                options: [.allowUserInteraction]
            ) { self.glyph.transform = .identity }
        }
    }

    private func capsuleTransform(_ face: DictationFace) -> CGAffineTransform {
        switch face {
        case .listening(.held, .send): return CGAffineTransform(scaleX: 0.86, y: 0.86)
        case .listening(.held, .none): return CGAffineTransform(scaleX: 1.08, y: 1.08)
        default: return .identity
        }
    }

    private func paint() {
        paintFills()
        tintGlyph(animated: false)
    }

    /// The capsule, the halo, the bars and the ring take the face's tone; inside an animation block
    /// the fills blend rather than snap.
    private func paintFills() {
        let fill: UIColor = face.tone == .danger ? Theme.Color.danger : Theme.Color.accent
        capsule.backgroundColor = fill
        halo.backgroundColor = fill.withAlphaComponent(0.16)
        halo.layer.shadowColor = fill.cgColor
        halo.layer.shadowRadius = 10
        halo.layer.shadowOpacity = 0.5
        halo.layer.shadowOffset = .zero
        for bar in bars { bar.backgroundColor = Theme.Color.onAccent.cgColor }
        badge.tintColor = Theme.Color.accent
        track.strokeColor = Theme.Color.separator.cgColor
        ring.strokeColor = Theme.Color.accent.cgColor
    }

    /// The glyph's ink, crossfaded when it changes: a tint is not animatable on an image view.
    private func tintGlyph(animated: Bool) {
        let tint: UIColor
        if let flashing, !face.isOpen {
            tint = flashing
        } else {
            switch face {
            case .blocked: tint = Theme.Color.warning
            case .preparing, .needsModel: tint = Theme.Color.accent
            default: tint = Theme.Color.secondaryLabel
            }
        }
        guard glyph.tintColor != tint else { return }
        guard animated else {
            glyph.tintColor = tint
            return
        }
        UIView.transition(with: glyph, duration: 0.18, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.glyph.tintColor = tint
        }
    }
}

/// The box's lit edge while the microphone is open: drawn round the glass from the microphone's
/// corner, then breathing with the voice. Accent while listening, danger while a held take is
/// armed to be thrown away.
@MainActor
final class DictationEdge: UIView {
    private let line = CAShapeLayer()
    private(set) var isLit = false
    var cornerRadius: CGFloat = 23

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        translatesAutoresizingMaskIntoConstraints = false
        line.fillColor = UIColor.clear.cgColor
        line.lineWidth = 1.5
        line.strokeEnd = 0
        line.shadowOffset = .zero
        line.shadowRadius = 10
        line.shadowOpacity = 0
        layer.addSublayer(line)
        isHidden = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        line.frame = bounds
        line.path = Self.path(in: bounds.insetBy(dx: 0.75, dy: 0.75), radius: cornerRadius)
    }

    /// The outline, starting at the bottom edge near the trailing corner where the microphone
    /// sits, so the light draws out of the control the finger is on.
    private static func path(in rect: CGRect, radius: CGFloat) -> CGPath {
        let r = min(radius, rect.height / 2, rect.width / 2)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: rect.maxX - r - 30, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(withCenter: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(withCenter: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: .pi, endAngle: .pi * 1.5, clockwise: true)
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(withCenter: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: .pi * 1.5, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(withCenter: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: 0, endAngle: .pi / 2, clockwise: true)
        path.close()
        return path.cgPath
    }

    func setLit(_ lit: Bool, danger: Bool, animated: Bool) {
        let color = (danger ? Theme.Color.danger : Theme.Color.accent).cgColor
        line.strokeColor = color
        line.shadowColor = color
        guard lit != isLit else { return }
        isLit = lit
        if lit {
            isHidden = false
            line.removeAnimation(forKey: "fade")
            line.opacity = 1
            guard animated, !UIAccessibility.isReduceMotionEnabled else {
                line.strokeEnd = 1
                return
            }
            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = 0
            draw.toValue = 1
            draw.duration = 0.36
            draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
            line.strokeEnd = 1
            line.add(draw, forKey: "draw")
        } else {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = line.opacity
            fade.toValue = 0
            fade.duration = animated ? 0.3 : 0
            line.opacity = 0
            line.add(fade, forKey: "fade")
            line.strokeEnd = 0
            isHidden = !animated
            if animated {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
                    guard let self, !self.isLit else { return }
                    self.isHidden = true
                }
            }
        }
    }

    /// How brightly the edge burns, from the smoothed voice level.
    func setLevel(_ level: Double) {
        guard isLit else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.opacity = Float(DictationBars.edgeOpacity(level: level))
        line.shadowOpacity = Float(0.25 + 0.55 * min(1, max(0, level)))
        CATransaction.commit()
    }
}

/// The box's last line, in the seat of the row under the words, just left of the microphone: how
/// long the take has run and how to stop it, where a held take will go, how far a model has come,
/// or how a take ended, with Undo after a discard. Plain words on the box's own glass, never a
/// glass of its own, and set in the reader's type size.
@MainActor
final class DictationHintView: UIView {
    private let dot = UIView()
    private let timer = UILabel()
    private let label = UILabel()
    private let undo = UIButton(type: .system)
    private let stack = UIStackView()
    private(set) var hint: DictationHint?
    var onUndo: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        alpha = 0
        dot.layer.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 7).isActive = true
        let metrics = UIFontMetrics(forTextStyle: .footnote)
        timer.font = metrics.scaledFont(for: UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium))
        timer.adjustsFontForContentSizeCategory = true
        timer.textColor = Theme.Color.secondaryLabel
        timer.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.font = metrics.scaledFont(for: UIFont.systemFont(ofSize: 13, weight: .medium))
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        undo.setTitle(DictationReading.undo, for: .normal)
        undo.titleLabel?.font = metrics.scaledFont(for: UIFont.systemFont(ofSize: 13, weight: .semibold))
        undo.titleLabel?.adjustsFontForContentSizeCategory = true
        undo.setContentCompressionResistancePriority(.required, for: .horizontal)
        undo.addAction(UIAction { [weak self] _ in self?.onUndo?() }, for: .primaryActionTriggered)
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [dot, timer, label, undo] { stack.addArrangedSubview(view) }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isAccessibilityElement = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Undo is a short word on a short line, so a finger is given 44 points around it.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let reach = undoReach, reach.contains(point) { return undo }
        return super.hitTest(point, with: event)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        super.point(inside: point, with: event) || undoReach?.contains(point) == true
    }

    private var undoReach: CGRect? {
        guard alpha > 0.01, !undo.isHidden else { return nil }
        let frame = undo.convert(undo.bounds, to: self)
        return frame.insetBy(dx: min(0, (frame.width - 44) / 2), dy: min(0, (frame.height - 44) / 2))
    }

    /// Writes a line. Showing and hiding are the box's: it fades the line in its seat as it moves
    /// the row's other tenants aside.
    func show(_ hint: DictationHint?, undoAvailable: Bool) {
        let changed = hint?.text != self.hint?.text || hint?.style != self.hint?.style
        self.hint = hint
        guard let hint else {
            breathe(false)
            return
        }
        let write = {
            self.timer.text = hint.timer
            self.timer.isHidden = hint.timer == nil
            self.label.text = hint.text
            self.undo.isHidden = !(hint.offersUndo && undoAvailable)
            self.dot.isHidden = hint.style != .live
            self.dot.backgroundColor = Theme.Color.accent
            switch hint.style {
            case .danger: self.label.textColor = Theme.Color.danger
            case .warning: self.label.textColor = Theme.Color.warning
            case .live, .plain: self.label.textColor = Theme.Color.secondaryLabel
            }
            self.undo.tintColor = Theme.Color.accent
        }
        if changed, alpha > 0, !UIAccessibility.isReduceMotionEnabled {
            UIView.transition(with: stack, duration: 0.15, options: [.transitionCrossDissolve, .allowUserInteraction], animations: write)
        } else {
            write()
        }
        breathe(hint.style == .live)
    }

    /// The live dot breathes for as long as the line is live; a new second or a new word leaves the
    /// breath where it is.
    private func breathe(_ on: Bool) {
        guard on, !UIAccessibility.isReduceMotionEnabled else {
            dot.layer.removeAnimation(forKey: "breath")
            return
        }
        guard dot.layer.animation(forKey: "breath") == nil else { return }
        let breath = CABasicAnimation(keyPath: "opacity")
        breath.fromValue = 1
        breath.toValue = 0.35
        breath.duration = 0.9
        breath.autoreverses = true
        breath.repeatCount = .infinity
        dot.layer.add(breath, forKey: "breath")
    }
}
