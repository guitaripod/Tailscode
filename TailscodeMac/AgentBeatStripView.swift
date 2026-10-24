import AppKit
import TailscodeCore

/// The last minute of an agent's pulse: one bar per slice, as tall as the number of times the
/// device saw it move. A flat strip is a stall you can see, so a slice with nothing in it is a
/// hairline on the floor and never an absent bar. Drawn straight from the `[Int]` Core gave, with
/// no allocation per pass, and only when those numbers change.
@MainActor
final class AgentBeatStripView: NSView {
    static let barWidth: CGFloat = 2
    static let gap: CGFloat = 2
    static let height: CGFloat = 14

    var beat: [Int] = [] {
        didSet {
            guard beat != oldValue else { return }
            invalidateIntrinsicContentSize()
            setAccessibilityLabel(AgentsWords.beat(beat))
            needsDisplay = true
        }
    }

    var tone: ActivityTone = .live {
        didSet { if tone != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let count = CGFloat(max(beat.count, AgentBeat.buckets))
        return NSSize(
            width: count * (Self.barWidth + Self.gap) - Self.gap,
            height: Self.height * MacTheme.UIScale.factor)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, !beat.isEmpty else { return }
        let active = tone.color
        let quiet = MacTheme.Color.tertiaryLabel
        let height = bounds.height
        let ceiling = CGFloat(AgentBeat.ceiling)
        for (index, count) in beat.enumerated() {
            let x = CGFloat(index) * (Self.barWidth + Self.gap)
            let tall = count > 0 ? max(3, height * CGFloat(min(count, AgentBeat.ceiling)) / ceiling) : 1
            context.setFillColor((count > 0 ? active : quiet).cgColor)
            context.fill(CGRect(x: x, y: height - tall, width: Self.barWidth, height: tall))
        }
    }
}
