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
            shape.isHidden = true
            layer.addSublayer(shape)
        }

        badge.image = UIImage(
            systemName: "arrow.down.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold))
        badge.isUserInteractionEnabled = false
        badge.isHidden = true
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

    /// Draws a face. Opening and closing animate the capsule's width and the glyph's crossfade;
    /// the rest of a face is set at once, because a state is a fact rather than a flourish.
    func apply(_ face: DictationFace, animated: Bool) {
        let wasOpen = self.face.showsBars
        self.face = face
        let open = face.showsBars
        widthConstraint.constant = face == .hidden ? 0 : (open ? Self.openWidth : Self.restWidth)
        let changes = {
            self.capsule.alpha = open ? 1 : 0
            self.glyph.alpha = open ? 0 : 1
            self.halo.alpha = open ? 0.5 : 0
            self.capsule.transform = self.capsuleTransform(face)
            self.superview?.layoutIfNeeded()
        }
        paint()
        if animated, wasOpen != open, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(
                withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.4,
                options: [.allowUserInteraction, .beginFromCurrentState], animations: changes)
        } else if animated {
            UIView.animate(withDuration: 0.15, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState], animations: changes)
        } else {
            changes()
        }
        glyph.image = UIImage(
            systemName: face.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular))
        badge.isHidden = !face.wearsDownloadBadge
        let preparing = face.isPreparing
        track.isHidden = !preparing
        ring.isHidden = !preparing
        if preparing {
            if let progress = face.progress {
                ring.removeAnimation(forKey: "spin")
                ring.strokeStart = 0
                ring.strokeEnd = CGFloat(max(0.02, progress))
            } else if ring.animation(forKey: "spin") == nil {
                ring.strokeStart = 0
                ring.strokeEnd = 0.25
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = Double.pi * 2
                spin.duration = 1.1
                spin.repeatCount = .infinity
                ring.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                ring.frame = bounds
                ring.add(spin, forKey: "spin")
            }
        } else {
            ring.removeAnimation(forKey: "spin")
        }
        if face == .settling { setLevels([Double](repeating: DictationBars.floor, count: DictationBars.count)) }
        accessibilityLabel = DictationReading.accessibilityLabel(face)
        accessibilityHint = DictationReading.accessibilityHint(face, surface: .touch)
        isHidden = face == .hidden
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
        case .listening(.held, _): return CGAffineTransform(scaleX: 1.06, y: 1.06)
        default: return .identity
        }
    }

    private func paint() {
        let fill: UIColor = face.tone == .danger ? Theme.Color.danger : Theme.Color.accent
        capsule.backgroundColor = fill
        halo.backgroundColor = fill.withAlphaComponent(0.16)
        halo.layer.shadowColor = fill.cgColor
        halo.layer.shadowRadius = 10
        halo.layer.shadowOpacity = 0.5
        halo.layer.shadowOffset = .zero
        for bar in bars { bar.backgroundColor = Theme.Color.onAccent.cgColor }
        switch face {
        case .blocked: glyph.tintColor = Theme.Color.warning
        case .preparing, .needsModel: glyph.tintColor = Theme.Color.accent
        default: glyph.tintColor = Theme.Color.secondaryLabel
        }
        badge.tintColor = Theme.Color.accent
        track.strokeColor = Theme.Color.separator.cgColor
        ring.strokeColor = Theme.Color.accent.cgColor
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

/// The capsule over the box that says what to do now: how long the take has run and how to stop
/// it, where a held take will go, how far a model has come, or how a take ended, with Undo after a
/// discard.
@MainActor
final class DictationHintView: UIView {
    private let glass = Theme.Glass.view(interactive: false)
    private let tint = UIView()
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
        isHidden = true
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.layer.cornerRadius = 15
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true
        addSubview(glass)
        tint.translatesAutoresizingMaskIntoConstraints = false
        tint.layer.cornerRadius = 15
        tint.layer.cornerCurve = .continuous
        tint.isUserInteractionEnabled = false
        addSubview(tint)

        dot.layer.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 7).isActive = true
        timer.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        timer.textColor = Theme.Color.secondaryLabel
        label.font = UIFont.systemFont(ofSize: 13.5, weight: .medium)
        label.adjustsFontForContentSizeCategory = false
        undo.setTitle(DictationReading.undo, for: .normal)
        undo.titleLabel?.font = UIFont.systemFont(ofSize: 13.5, weight: .semibold)
        undo.addAction(UIAction { [weak self] _ in self?.onUndo?() }, for: .primaryActionTriggered)
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [dot, timer, label, undo] { stack.addArrangedSubview(view) }
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            tint.leadingAnchor.constraint(equalTo: leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: trailingAnchor),
            tint.topAnchor.constraint(equalTo: topAnchor),
            tint.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 3)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ hint: DictationHint?, undoAvailable: Bool) {
        let changed = hint?.text != self.hint?.text || hint?.style != self.hint?.style
        self.hint = hint
        guard let hint else {
            guard !isHidden else { return }
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState]) {
                self.alpha = 0
            } completion: { _ in
                if self.hint == nil { self.isHidden = true }
            }
            return
        }
        timer.text = hint.timer
        timer.isHidden = hint.timer == nil
        label.text = hint.text
        undo.isHidden = !(hint.offersUndo && undoAvailable)
        let danger = hint.style == .danger
        dot.isHidden = hint.style != .live
        dot.backgroundColor = Theme.Color.accent
        tint.backgroundColor = danger ? Theme.Color.danger : .clear
        label.textColor = danger ? .white : (hint.style == .warning ? Theme.Color.warning : Theme.Color.label)
        timer.textColor = danger ? .white : Theme.Color.secondaryLabel
        undo.tintColor = Theme.Color.accent
        accessibilityLabel = [hint.timer, hint.text].compactMap { $0 }.joined(separator: ", ")
        breathe(hint.style == .live)
        guard isHidden || alpha < 1 else {
            if changed, !UIAccessibility.isReduceMotionEnabled {
                UIView.transition(with: self, duration: 0.15, options: [.transitionCrossDissolve, .allowUserInteraction]) {}
            }
            return
        }
        isHidden = false
        transform = UIAccessibility.isReduceMotionEnabled ? .identity : CGAffineTransform(translationX: 0, y: 6)
        UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.alpha = 1
            self.transform = .identity
        }
    }

    private func breathe(_ on: Bool) {
        dot.layer.removeAnimation(forKey: "breath")
        guard on, !UIAccessibility.isReduceMotionEnabled else { return }
        let breath = CABasicAnimation(keyPath: "opacity")
        breath.fromValue = 1
        breath.toValue = 0.35
        breath.duration = 0.9
        breath.autoreverses = true
        breath.repeatCount = .infinity
        dot.layer.add(breath, forKey: "breath")
    }
}
