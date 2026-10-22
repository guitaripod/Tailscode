import AppKit
import TailscodeCore

/// The rows themselves: one view as tall as the whole turn that draws only what the window shows.
/// A row is drawn by hand, so a turn of two thousand steps costs what the nine on screen cost, and
/// the only things that are views are the one or two marks that breathe on a step still running.
@MainActor
final class BrainListRowsView: NSView {
    private unowned let owner: BrainListView
    private var pulses: [String: CAShapeLayer] = [:]
    private var tracking: NSTrackingArea?
    private(set) var rowsDrawn = 0
    private(set) var paints = 0

    init(owner: BrainListView) {
        self.owner = owner
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        owner.pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        owner.pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) { owner.pointerMoved(to: nil) }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.control) {
            owner.contextPressed(at: point, event: event)
        } else {
            owner.pressed(at: point, clicks: event.clickCount)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        owner.contextPressed(at: convert(event.locationInWindow, from: nil), event: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let list = owner.snapshot.list
        let painter = owner.painter
        guard list.visibleCount > 0 else {
            rowsDrawn = 0
            return
        }
        let range = list.visibleRange(offset: dirtyRect.minY, height: max(dirtyRect.height, 1))
        let query = list.filter.query
        let cursor = owner.snapshot.cursor
        let hovered = owner.pointerRowID ?? owner.snapshot.hovered
        let width = bounds.width
        let reveal = owner.revealRows
        let relativeFirst = owner.firstVisiblePosition
        var drawn = 0
        for position in range {
            guard let row = list.row(atVisible: position) else { continue }
            var state = BrainRowPainter.State()
            state.isCursor = cursor == row.id
            state.isHovered = hovered == row.id
            state.pointerHere = owner.pointerRowID == row.id
            state.copyHot = owner.pointerCopy && state.pointerHere
            state.copied = owner.copiedID == row.id
            state.query = query
            state.wide = owner.isWide
            state.markIsLayer = pulses[row.id] != nil
            var y = CGFloat(list.offset(ofVisible: position))
            if let reveal, reveal.count > 0 {
                let index = max(0, position - relativeFirst)
                let at = min(index, reveal.count - 1)
                state.alpha = CGFloat(reveal.alpha(at))
                if index < reveal.count { y -= CGFloat(reveal.offset(index)) }
            }
            if let arrival = owner.arrival, row.index >= arrival.from {
                let t = min(1, (BrainClock.now - arrival.start) / owner.arrivalDuration)
                y += CGFloat(NeuralRowReveal.travel * (1 - NeuralTransition.easeOutCubic(t)))
                state.alpha = CGFloat(t)
            }
            let previous = position > 0 ? list.row(atVisible: position - 1) : nil
            let next = list.row(atVisible: position + 1)
            painter.paint(row, previous: previous, next: next, y: y, width: width, state: state)
            drawn += 1
        }
        rowsDrawn = drawn
        paints += 1
    }

    /// The marks of the steps still out on the machine, each one a layer that breathes by itself so
    /// the list owns no clock while a turn runs: a dot for a running step and the pause bars of one
    /// that waits on the person.
    func syncPulses() {
        let list = owner.snapshot.list
        var wanted: [String: (CGPoint, NeuralVerdict.Step)] = [:]
        if list.visibleCount > 0 {
            let reach = 40
            let first = max(0, owner.firstVisiblePosition - reach)
            let last = min(list.visibleCount, owner.firstVisiblePosition + owner.visibleRowCount + reach)
            for position in first..<max(first, last) {
                guard let row = list.row(atVisible: position) else { continue }
                guard row.verdict == .running || row.verdict == .waiting else { continue }
                guard let mark = owner.painter.markPlan(for: row, width: bounds.width, wide: owner.isWide)
                else { continue }
                let band: CGFloat = row.isSaid ? 28 : CGFloat(row.height())
                wanted[row.id] = (
                    CGPoint(x: mark.glyphX, y: CGFloat(list.offset(ofVisible: position)) + band / 2),
                    row.verdict
                )
                if wanted.count >= 16 { break }
            }
        }
        for (id, layer) in pulses where wanted[id] == nil {
            layer.removeFromSuperlayer()
            pulses[id] = nil
        }
        guard let host = layer else { return }
        for (id, entry) in wanted {
            let made: CAShapeLayer
            if let held = pulses[id] {
                made = held
            } else {
                made = CAShapeLayer()
                made.bounds = CGRect(x: 0, y: 0, width: 13, height: 13)
                host.addSublayer(made)
                pulses[id] = made
            }
            made.position = entry.0
            let color = owner.painter.colors.verdict(entry.1).cgColor
            made.fillColor = color
            made.path = entry.1 == .running ? Self.dotPath : Self.barsPath
            made.isHidden = owner.pointerRowID == id
            BrainMotion.breathe(made, entry.1 == .running ? .breath : .heartbeat)
        }
        needsDisplay = true
    }

    var pulseCount: Int { pulses.count }
    var pulsesBreathe: Bool { pulses.values.contains { BrainMotion.isBreathing($0) } }

    private static let dotPath: CGPath = {
        let radius: CGFloat = 13 * 0.3
        return CGPath(
            ellipseIn: CGRect(x: 6.5 - radius, y: 6.5 - radius, width: radius * 2, height: radius * 2),
            transform: nil)
    }()

    private static let barsPath: CGPath = {
        let path = CGMutablePath()
        let height: CGFloat = 13 * 0.7
        let width: CGFloat = max(1.8, 13 * 0.17)
        for offset in [-13 * 0.28, 13 * 0.28] as [CGFloat] {
            path.addRoundedRect(
                in: CGRect(x: 6.5 + offset - width / 2, y: 6.5 - height / 2, width: width, height: height),
                cornerWidth: width / 2, cornerHeight: width / 2)
        }
        return path
    }()

    func pulsesHideRow(_ id: String?) {
        for (key, layer) in pulses { layer.isHidden = key == id }
    }

    override func accessibilityChildren() -> [Any]? {
        owner.accessibilityRowElements(in: self)
    }

    override func accessibilitySelectedChildren() -> [Any]? {
        let selected = owner.accessibilityRowElements(in: self).filter { ($0 as? BrainRowElement)?.isSelected == true }
        return selected
    }
}

/// A row as a screen reader meets it: its words, whether it is the cursor, and a press that does
/// what a click does.
final class BrainRowElement: NSAccessibilityElement {
    let stepID: String
    nonisolated(unsafe) var isSelected = false
    nonisolated(unsafe) var onPress: (@MainActor () -> Void)?

    init(stepID: String) {
        self.stepID = stepID
        super.init()
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        MainThread.call { onPress() }
        return true
    }

    override func isAccessibilitySelected() -> Bool { isSelected }
}
