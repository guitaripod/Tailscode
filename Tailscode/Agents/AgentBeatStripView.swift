import TailscodeCore
import UIKit

/// The last minute of an agent's pulse, one bar a slice: a flat strip is a stall you can see. Drawn
/// straight from the `[Int]` Core hands over, with nothing allocated per frame, and only when that
/// array changes.
@MainActor
final class AgentBeatStripView: UIView {
    static let barWidth: CGFloat = 3
    static let gap: CGFloat = 1.5
    static let height: CGFloat = 16

    var beat: [Int]? {
        didSet {
            guard beat != oldValue else { return }
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
            accessibilityLabel = beat.map(AgentsWords.beatSpoken)
        }
    }

    var tint: UIColor = Theme.Color.success {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
        semanticContentAttribute = .forceLeftToRight
        isAccessibilityElement = false
        accessibilityTraits = .image
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        let count = CGFloat(beat?.count ?? AgentBeat.buckets)
        return CGSize(
            width: count * Self.barWidth + max(0, count - 1) * Self.gap, height: Self.height)
    }

    override func draw(_ rect: CGRect) {
        guard let beat, let context = UIGraphicsGetCurrentContext() else { return }
        let live = tint.resolvedColor(with: traitCollection)
        let still = Theme.Color.tertiaryLabel.resolvedColor(with: traitCollection)
        let scale = max(1, traitCollection.displayScale)
        let ceiling = CGFloat(AgentBeat.ceiling)
        var x: CGFloat = 0
        for count in beat {
            let share = min(1, CGFloat(count) / ceiling)
            let height = max(1.5, (bounds.height * share * scale).rounded() / scale)
            let bar = CGRect(x: x, y: bounds.height - height, width: Self.barWidth, height: height)
            context.setFillColor((count > 0 ? live : still.withAlphaComponent(0.55)).cgColor)
            context.fill(bar)
            x += Self.barWidth + Self.gap
        }
    }
}

/// A child's todos as a handful of segments and a fraction, the way the board's tree says how far
/// an agent has got.
@MainActor
final class AgentTodoBarView: UIView {
    private static let segmentCount = 6

    var todos: (done: Int, total: Int)? {
        didSet {
            guard todos?.done != oldValue?.done || todos?.total != oldValue?.total else { return }
            setNeedsDisplay()
            accessibilityLabel = todos.map(AgentsWords.todosSpoken)
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
        semanticContentAttribute = .forceLeftToRight
        isAccessibilityElement = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { CGSize(width: 42, height: 6) }

    override func draw(_ rect: CGRect) {
        guard let todos, todos.total > 0, let context = UIGraphicsGetCurrentContext() else { return }
        let lit = Theme.Color.success.resolvedColor(with: traitCollection)
        let dim = Theme.Color.separator.resolvedColor(with: traitCollection)
        let count = min(Self.segmentCount, todos.total)
        let filled = Int((Double(todos.done) / Double(todos.total) * Double(count)).rounded(.down))
        let gap: CGFloat = 2
        let width = (bounds.width - gap * CGFloat(count - 1)) / CGFloat(count)
        for index in 0..<count {
            let segment = CGRect(
                x: CGFloat(index) * (width + gap), y: 0, width: width, height: bounds.height)
            context.setFillColor((index < filled ? lit : dim).cgColor)
            context.addPath(UIBezierPath(roundedRect: segment, cornerRadius: bounds.height / 2).cgPath)
            context.fillPath()
        }
    }
}
