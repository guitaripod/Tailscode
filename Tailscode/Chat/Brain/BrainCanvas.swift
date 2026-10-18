import TailscodeCore
import UIKit

/// What the brain draws on the transcript's own canvas, as opposed to on the dark head: the card,
/// the chips, the list, the account. Every colour comes from the theme's tokens, which resolve
/// against the trait collection the view is in, so a card on Dawn and a card on System wear the
/// colours their own canvas can read. The lifted tones that sit on the head live in `BrainInk`.
enum BrainCanvas {
    /// A tone as ink on the canvas: the corrected palette's slot for it.
    static func tone(_ tone: NeuralTone, face: NeuralFace? = nil) -> UIColor {
        switch tone {
        case .live: return Theme.Color.accent
        case .attention: return Theme.Color.warning
        case .danger: return Theme.Color.danger
        case .quiet: return Theme.Color.secondaryLabel
        case .identity: return Theme.Color.modelFamily(face?.family)
        }
    }

    /// A zone's colour on the canvas: the same slot the head lights it with.
    static func zone(_ zone: NeuralZone) -> UIColor {
        switch zone {
        case .think: return Theme.Color.label
        case .sense: return Theme.Color.info
        case .act: return Theme.Color.accent
        case .shell: return Theme.Color.special
        case .delegate: return Theme.Color.secondaryLabel
        case .say: return Theme.Color.accent
        }
    }

    static func nodeTone(_ tone: NeuralNodeTone, zone zoneValue: NeuralZone) -> UIColor {
        switch tone {
        case .zone: return zone(zoneValue)
        case .live: return Theme.Color.accent
        case .attention: return Theme.Color.warning
        case .danger: return Theme.Color.danger
        case .quiet: return Theme.Color.secondaryLabel
        }
    }

    /// The symbol a verdict wears, so amber and red are told apart by shape and word and never by
    /// colour alone: a retry arrow for a fixed error, a cross for a failure, a triangle for a hit
    /// error, pause bars for waiting, a dashed clock for stuck and a square for stopped.
    static func symbol(for verdict: NeuralVerdict.Step) -> String? {
        switch verdict {
        case .done: return nil
        case .fixed: return "arrow.trianglehead.2.clockwise.rotate.90"
        case .failed: return "xmark"
        case .tryingAgain: return "exclamationmark.triangle"
        case .running: return "circle.dotted"
        case .waiting: return "pause.fill"
        case .stalled: return "clock.badge.exclamationmark"
        case .stopped: return "stop.fill"
        }
    }

    static func symbol(for verdict: NeuralVerdict.Turn) -> String {
        switch verdict {
        case .done: return "checkmark"
        case .doneAfterRetries: return "checkmark"
        case .failed: return "xmark"
        case .needsYou: return "pause.fill"
        case .working: return "circle.dotted"
        case .stuck: return "clock.badge.exclamationmark"
        case .stopped: return "stop.fill"
        case .didntAnswer: return "ellipsis"
        }
    }

    static func symbol(for glyph: NeuralLiveCard.Glyph) -> String {
        switch glyph {
        case .pulse: return "circle.fill"
        case .pauseBars: return "pause.fill"
        case .dashedClock: return "clock.badge.exclamationmark"
        case .triangle: return "exclamationmark.triangle.fill"
        }
    }

    static func image(_ name: String, size: CGFloat, weight: UIImage.SymbolWeight = .semibold) -> UIImage? {
        UIImage(
            systemName: name,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: weight))
    }

    /// The minimum a finger is given around anything small.
    static let hit: CGFloat = 44
}

extension UIColor {
    /// This colour at `alpha` of its own: a wash.
    func wash(_ alpha: CGFloat) -> UIColor { withAlphaComponent(alpha) }
}

/// A zone's node shape at icon size, in one tone, for chips, rows and card headers.
@MainActor
final class BrainShapeIcon: UIView {
    private let shape = CAShapeLayer()
    private var zoneShape = NeuralShape.circle
    private var filled = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        shape.lineWidth = 1.5
        shape.lineJoin = .round
        layer.addSublayer(shape)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = min(bounds.width, bounds.height) / 2 - 2
        shape.path = BrainShapes.path(zoneShape, radius: radius * 0.85)
        shape.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    func set(shape new: NeuralShape, color: UIColor, filled isFilled: Bool = false) {
        zoneShape = new
        filled = isFilled
        shape.strokeColor = color.cgColor
        shape.fillColor = isFilled ? color.withAlphaComponent(0.22).cgColor : nil
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize { CGSize(width: 18, height: 18) }
}

extension UIColor {
    /// A glow colour set as words on the page: a light theme lifts its glow toward white for the
    /// dark dome, and ink on a pale card needs the colour taken back toward the card's own text.
    func darkenedForText(_ traits: UITraitCollection) -> UIColor {
        guard traits.palette?.isDark == false || traits.userInterfaceStyle == .light else {
            return self
        }
        return mixed(with: Theme.Color.label.resolvedColor(with: traits), 0.45)
    }
}
