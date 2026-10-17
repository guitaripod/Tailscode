import TailscodeCore
import UIKit

/// The call's face at call size: the face's own symbol in its own tone on an opaque disc. Connecting
/// turns and listening and the agent working breathe as render-server animation sampled from the
/// face's own motion and begun at media time zero (`CALayer.setActivityMotion`), so they keep
/// absolute phase and cost the main thread nothing per frame. Only speaking, which breathes with
/// the voice's level, eased by `VoiceCallLevels` so a word is seen when it starts and the light
/// does not flicker between syllables, is not a function of time alone, and it alone runs a clock
/// through `VoiceCallFace.intensity`. Hearing, a degraded voice and an ended call hold perfectly
/// still and run nothing at all, and so does everything under Reduce Motion. A frame changes light
/// and a transform, never a size layout depends on.
@MainActor
final class CallFaceView: UIView {
    private let disc = UIView()
    private let glyph = UIImageView()
    private var face: VoiceCallFace = .connecting
    private var link: CADisplayLink?
    private var eased = 0.0
    private var lastStamp: CFTimeInterval = 0
    private var side: CGFloat = 0
    private var sizeConstraints: [NSLayoutConstraint] = []

    var level: () -> Double = { 0 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        disc.isUserInteractionEnabled = false
        disc.translatesAutoresizingMaskIntoConstraints = false
        disc.layer.cornerCurve = .continuous
        glyph.contentMode = .center
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(disc)
        disc.addSubview(glyph)
        NSLayoutConstraint.activate([
            disc.topAnchor.constraint(equalTo: topAnchor),
            disc.bottomAnchor.constraint(equalTo: bottomAnchor),
            disc.leadingAnchor.constraint(equalTo: leadingAnchor),
            disc.trailingAnchor.constraint(equalTo: trailingAnchor),
            glyph.centerXAnchor.constraint(equalTo: disc.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: disc.centerYAnchor),
        ])
        resize()
        paint()
        show(.connecting)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (view: CallFaceView, _) in view.paint()
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: CallFaceView, _) in
            view.resize()
            view.draw()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(motionPreferenceChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { CGSize(width: side, height: side) }

    override func layoutSubviews() {
        super.layoutSubviews()
        disc.layer.cornerRadius = disc.bounds.height / 2
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        window == nil ? stop() : startIfNeeded()
    }

    func show(_ face: VoiceCallFace) {
        guard face != self.face || glyph.image == nil else { return }
        self.face = face
        draw()
        reset()
        startIfNeeded()
    }

    private var motionAllowed: Bool { !UIAccessibility.isReduceMotionEnabled }

    private var animated: Bool { motionAllowed && face.motion.isAnimated }

    /// A disc that grows with the reader's type, within the room a header has for it.
    private func resize() {
        side = min(max(UIFontMetrics(forTextStyle: .body).scaledValue(for: 36), 36), 52)
        NSLayoutConstraint.deactivate(sizeConstraints)
        sizeConstraints = [
            widthAnchor.constraint(equalToConstant: side), heightAnchor.constraint(equalToConstant: side),
        ]
        NSLayoutConstraint.activate(sizeConstraints)
        invalidateIntrinsicContentSize()
    }

    private func paint() {
        disc.backgroundColor = Theme.Color.background
        glyph.tintColor = face.tone.color
    }

    private func draw() {
        glyph.image = UIImage(
            systemName: face.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: side * 0.42, weight: .semibold))
        glyph.tintColor = face.tone.color
    }

    private func reset() {
        glyph.layer.removeAnimation(forKey: Self.motionKey)
        glyph.alpha = 1
        glyph.transform = .identity
        eased = 0
        lastStamp = 0
    }

    private static let motionKey = "activity"

    private var drivenByLevel: Bool {
        if case .speaking = face { return true }
        return false
    }

    private func startIfNeeded() {
        guard animated, window != nil else { return }
        guard drivenByLevel else {
            glyph.layer.setActivityMotion(face.motion, forKey: Self.motionKey)
            return
        }
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.runAtActivityTempo()
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stop() {
        link?.invalidate()
        link = nil
        glyph.layer.removeAnimation(forKey: Self.motionKey)
    }

    @objc private func motionPreferenceChanged() {
        stop()
        reset()
        startIfNeeded()
    }

    @objc private func step(_ link: CADisplayLink) {
        guard animated else {
            stop()
            reset()
            return
        }
        let time = link.timestamp
        let elapsed = lastStamp == 0 ? 0 : time - lastStamp
        lastStamp = time
        let target: Double
        if case .speaking = face { target = level() } else { target = 0 }
        eased = VoiceCallLevels.smoothed(previous: eased, target: target, dt: elapsed)
        let intensity = face.intensity(at: time, level: eased)
        glyph.alpha = intensity
        let scale = Self.scale(of: face, intensity: intensity, at: time)
        glyph.transform = CGAffineTransform(rotationAngle: face.motion.rotation(at: time)).scaledBy(x: scale, y: scale)
    }

    /// A breath is also a size, a small one, anchored at 1 so a still face is exactly its own size.
    /// Speaking is the swell the voice's level lifted, so the size follows the same light.
    private static func scale(of face: VoiceCallFace, intensity: Double, at time: TimeInterval) -> Double {
        if case .speaking = face {
            let floor = ActivityTuning.breathFloor
            return 1 + ActivityTuning.lift * (intensity - floor) / max(0.0001, 1 - floor)
        }
        return face.motion.scale(at: time)
    }
}
