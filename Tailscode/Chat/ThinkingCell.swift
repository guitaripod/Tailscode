import TailscodeCore
import UIKit

/// The "agent is working" placeholder shown before any assistant content
/// arrives for the current turn: three softly pulsing dots on the canvas, with no plate.
///
/// The dots say what every other live mark in a transcript says, so they say it in the same words:
/// the swell is `ActivityMotion.working`, read from the display clock at the vocabulary's tempo,
/// and the row goes still when the reader has asked for less motion.
final class ThinkingCell: UICollectionViewCell {
    static let reuseID = "ThinkingCell"

    private let bubble = UIView()
    private lazy var bubbleTop = bubble.topAnchor.constraint(equalTo: contentView.topAnchor)
    private let dots = (0..<3).map { _ in UIView() }

    override init(frame: CGRect) {
        super.init(frame: frame)
        bubble.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bubble)

        let stack = UIStackView(arrangedSubviews: dots)
        stack.axis = .horizontal
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(stack)

        for dot in dots {
            dot.backgroundColor = Theme.Color.secondaryLabel
            dot.layer.cornerRadius = 4
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 8),
                dot.heightAnchor.constraint(equalToConstant: 8),
            ])
        }

        NSLayoutConstraint.activate([
            bubbleTop,
            bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            bubble.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            bubble.heightAnchor.constraint(
                greaterThanOrEqualToConstant: CGFloat(Theme.Chat.metrics.activityRowHeight)),

            stack.centerYAnchor.constraint(equalTo: bubble.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(retune),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var gapAbove: CGFloat = 0 {
        didSet { bubbleTop.constant = gapAbove }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        contentView.layer.removeAllAnimations()
        contentView.alpha = 1
        contentView.transform = .identity
        stop()
    }

    /// A repeating layer animation is stripped off a layer that leaves the window, so the swell is
    /// laid on again whenever the row comes back, and taken off for a row nobody can see.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        window == nil ? stop() : start()
    }

    /// Reads the reader's mind again when they change it mid-turn, because dropping the movement is
    /// the whole of what reduced motion asks for and a row that only asks once keeps swelling until
    /// it happens to leave the window. A cell that is not on screen is left alone: it reads the
    /// setting for itself the moment it comes back.
    @objc private func retune() {
        guard window != nil else { return }
        start()
    }

    private func start() {
        for (index, dot) in dots.enumerated() {
            dot.alpha = 1
            dot.layer.setActivityMotion(
                ActivityMotion.working, lag: Self.lag(of: index, in: dots.count))
        }
    }

    private func stop() {
        for dot in dots { dot.layer.removeAnimation(forKey: "activity") }
    }

    /// How far behind the swell one dot sits: a whole period spread evenly over the dots, so the
    /// light crosses the row as one wave rather than three marks blinking together. The spacing is
    /// the vocabulary's own period divided by what is on screen, never a duration this cell chose.
    private static func lag(of index: Int, in count: Int) -> TimeInterval {
        ActivityTuning.breathPeriod * Double(index) / Double(max(1, count))
    }
}
