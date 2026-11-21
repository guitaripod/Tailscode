import TailscodeCore
import UIKit

/// The prompt box's one button, drawn from `SendFace`: its glyph is the verb a press will perform.
/// A change of verb is the glyph replacing itself, the plate springs as the box gains its first
/// words, and words that go out leave upward on the beat the prompt rises on.
///
/// The plate and the glyph move, never the button itself: a held dictation take lights and scales
/// the button from outside, and two hands on one transform is a fight.
@MainActor
final class ComposerSendButton: SlopButton {
    private let plate = UIView()
    private let glyph = UIImageView()
    private(set) var face: SendFace = .idle
    private var launching = false

    static let side: CGFloat = 34
    private static let glyphPoint: CGFloat = 15

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        plate.isUserInteractionEnabled = false
        plate.layer.cornerRadius = Self.side / 2
        plate.translatesAutoresizingMaskIntoConstraints = false
        glyph.isUserInteractionEnabled = false
        glyph.contentMode = .center
        glyph.tintColor = Theme.Color.onAccent
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(plate)
        plate.addSubview(glyph)
        NSLayoutConstraint.activate([
            plate.topAnchor.constraint(equalTo: topAnchor),
            plate.bottomAnchor.constraint(equalTo: bottomAnchor),
            plate.leadingAnchor.constraint(equalTo: leadingAnchor),
            plate.trailingAnchor.constraint(equalTo: trailingAnchor),
            glyph.centerXAnchor.constraint(equalTo: plate.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
        ])
        plate.clipsToBounds = true
        apply(.idle)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (button: ComposerSendButton, _) in
            button.plate.backgroundColor = Self.fill(button.face)
            button.glyph.tintColor = Self.ink(button.face)
        }
    }

    private static func image(_ face: SendFace) -> UIImage? {
        UIImage(
            systemName: face.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: glyphPoint, weight: .bold))
    }

    private static func fill(_ face: SendFace) -> UIColor {
        switch face {
        case .idle, .takeBack: return Theme.Color.separator
        case .stop: return Theme.Color.danger
        case .send, .queue, .save: return Theme.Color.accent
        }
    }

    private static func ink(_ face: SendFace) -> UIColor {
        face == .takeBack ? Theme.Color.label : Theme.Color.onAccent
    }

    private func apply(_ face: SendFace) {
        self.face = face
        glyph.image = Self.image(face)
        glyph.tintColor = Self.ink(face)
        plate.backgroundColor = Self.fill(face)
        isEnabled = face.acts
        accessibilityLabel = face.spoken
    }

    /// Wears a face. Arming — the first words in an empty box — springs the plate; any other
    /// change of verb replaces the glyph in place.
    func show(_ next: SendFace, animated: Bool) {
        guard next != face else { return }
        let previous = face
        guard animated, window != nil, !UIAccessibility.isReduceMotionEnabled, !launching else {
            apply(next)
            return
        }
        self.face = next
        isEnabled = next.acts
        accessibilityLabel = next.spoken
        if previous.symbol == next.symbol {
            glyph.image = Self.image(next)
        } else if let image = Self.image(next) {
            glyph.setSymbolImage(image, contentTransition: .replace.downUp)
        }
        UIView.animate(withDuration: 0.2, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.plate.backgroundColor = Self.fill(next)
            self.glyph.tintColor = Self.ink(next)
        }
        if previous == .idle, next.tone == .accent { spring(from: 0.84) }
    }

    private func spring(from scale: CGFloat) {
        plate.transform = CGAffineTransform(scaleX: scale, y: scale)
        UIView.animate(
            withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.52, initialSpringVelocity: 0.6,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.plate.transform = .identity
        }
    }

    /// The glyph leaves through the top of the plate and the next face rises in from under it.
    /// The caller has already decided what the button is next; this only delays showing it until
    /// the arrow is gone.
    func launch(then next: @escaping () -> SendFace) {
        guard window != nil, !UIAccessibility.isReduceMotionEnabled, !launching else {
            apply(next())
            return
        }
        launching = true
        let travel = Self.side * 0.72
        UIView.animate(
            withDuration: 0.16, delay: 0, options: [.curveEaseIn, .allowUserInteraction],
            animations: {
                self.glyph.transform = CGAffineTransform(translationX: 0, y: -travel)
                self.glyph.alpha = 0
            },
            completion: { _ in
                self.launching = false
                self.apply(next())
                self.glyph.transform = CGAffineTransform(translationX: 0, y: travel * 0.6)
                UIView.animate(
                    withDuration: 0.36, delay: 0.04, usingSpringWithDamping: 0.74,
                    initialSpringVelocity: 0.4, options: [.allowUserInteraction]
                ) {
                    self.glyph.transform = .identity
                    self.glyph.alpha = 1
                }
            })
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue, !UIAccessibility.isReduceMotionEnabled else { return }
            let scale: CGFloat = isHighlighted ? 0.9 : 1
            UIView.animate(
                withDuration: isHighlighted ? 0.12 : 0.34, delay: 0,
                usingSpringWithDamping: isHighlighted ? 1 : 0.6, initialSpringVelocity: 0.3,
                options: [.allowUserInteraction, .beginFromCurrentState]
            ) {
                self.plate.transform = CGAffineTransform(scaleX: scale, y: scale)
            }
        }
    }
}
