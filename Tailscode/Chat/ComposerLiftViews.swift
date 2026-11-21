import TailscodeCore
import UIKit

/// The handle on a prompt box's top edge. It is there only while the box has words out of sight
/// or has been lifted: a press toggles the page, and a pull along the edge it sits on is taken by
/// the box itself.
@MainActor
final class ComposerHandle: UIControl {
    private let pill = UIView()
    private(set) var isShown = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        pill.backgroundColor = Theme.Color.tertiaryLabel
        pill.layer.cornerRadius = 2.25
        pill.isUserInteractionEnabled = false
        pill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 72),
            heightAnchor.constraint(equalToConstant: 22),
            pill.centerXAnchor.constraint(equalTo: centerXAnchor),
            pill.topAnchor.constraint(equalTo: topAnchor, constant: 8.5),
            pill.widthAnchor.constraint(equalToConstant: 36),
            pill.heightAnchor.constraint(equalToConstant: 4.5),
        ])
        alpha = 0
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -24, dy: 0).contains(point)
    }

    func show(_ shown: Bool, lifted: Bool) {
        accessibilityLabel =
            lifted
            ? String(localized: "Shrink the message box")
            : String(localized: "Show the whole message")
        guard shown != isShown else { return }
        isShown = shown
        isUserInteractionEnabled = shown
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.alpha = shown ? 1 : 0
        }
    }

    override var isHighlighted: Bool {
        didSet { pill.backgroundColor = isHighlighted ? Theme.Color.secondaryLabel : Theme.Color.tertiaryLabel }
    }
}

/// The two keys an empty prompt box offers at the end of its first line: the slash that opens the
/// commands and the at-sign that finds a file. A phone keeps both two keyboards away, and a box
/// that shows them is also a box that says it understands them.
@MainActor
final class ComposerDoors: UIStackView {
    var onPress: ((String) -> Void)?
    private let command = ComposerDoors.key("/", says: MentionWords.commandsDoor)
    private let file = ComposerDoors.key("@", says: MentionWords.door)

    override init(frame: CGRect) {
        super.init(frame: frame)
        axis = .horizontal
        spacing = 6
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        for (key, letter) in [(command, "/"), (file, "@")] {
            key.isHidden = true
            key.alpha = 0
            key.addAction(UIAction { [weak self] _ in self?.onPress?(letter) }, for: .touchUpInside)
            addArrangedSubview(key)
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (doors: ComposerDoors, _) in
            for key in [doors.command, doors.file] {
                key.layer.borderColor = Theme.Color.separator.cgColor
            }
        }
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    private static func key(_ letter: String, says spoken: String) -> SlopButton {
        let key = SlopButton(type: .system)
        key.setTitle(letter, for: .normal)
        key.titleLabel?.font = Theme.Font.mono(15)
        key.setTitleColor(Theme.Color.secondaryLabel, for: .normal)
        key.layer.cornerRadius = 8
        key.layer.cornerCurve = .continuous
        key.layer.borderWidth = 1
        key.layer.borderColor = Theme.Color.separator.cgColor
        key.accessibilityLabel = spoken
        key.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            key.widthAnchor.constraint(equalToConstant: 30),
            key.heightAnchor.constraint(equalToConstant: 26),
        ])
        return key
    }

    func show(command showsCommand: Bool, file showsFile: Bool) {
        set(command, shown: showsCommand)
        set(file, shown: showsFile)
    }

    private func set(_ key: UIButton, shown: Bool) {
        guard key.isHidden == shown else { return }
        key.isHidden = !shown
        guard shown, window != nil, !UIAccessibility.isReduceMotionEnabled else {
            key.alpha = shown ? 1 : 0
            return
        }
        UIView.animate(withDuration: 0.22, delay: 0.05, options: [.beginFromCurrentState, .allowUserInteraction]) {
            key.alpha = 1
        }
    }
}

/// Words that run on past an edge of a prompt box fade into it, so the box never cuts a line
/// through its middle and the edge says there is more that way.
@MainActor
final class ComposerEdgeFade {
    private let mask = CAGradientLayer()

    init() {
        mask.startPoint = CGPoint(x: 0.5, y: 0)
        mask.endPoint = CGPoint(x: 0.5, y: 1)
    }

    func refresh(on textView: UITextView) {
        let bounds = textView.bounds
        let hidden = textView.contentSize.height - bounds.height
        let scrolls = textView.isScrollEnabled && hidden > 1 && bounds.height > 44
        let above = scrolls && textView.contentOffset.y > 1
        let below = scrolls && textView.contentOffset.y < hidden - 4
        guard above || below else {
            if textView.layer.mask != nil { textView.layer.mask = nil }
            return
        }
        let clear = UIColor.clear.cgColor
        let solid = UIColor.black.cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = bounds
        mask.colors = [above ? clear : solid, solid, solid, below ? clear : solid]
        mask.locations = [
            0, NSNumber(value: Double(20 / bounds.height)),
            NSNumber(value: Double(1 - 14 / bounds.height)), 1,
        ]
        CATransaction.commit()
        if textView.layer.mask !== mask { textView.layer.mask = mask }
    }
}
