import AppKit
import CodingAgentKit
import TailscodeCore

/// One line of the board, as a value: the table is a pure function of these, which is what lets a
/// publish that changed one agent's line touch one row instead of the list.
enum AgentsItem: Equatable {
    case summary(String)
    case empty
    case header(AgentsSection, count: Int, unread: Int)
    case ask(AgentAskCard, AgentsActions.Phase)
    case row(AgentRow, AgentsSection)
    case finish(AgentFinish)

    var id: String {
        switch self {
        case .summary: return "summary"
        case .empty: return "empty"
        case .header(let section, _, _): return "header:" + section.rawValue
        case .ask(let card, _): return "ask:" + card.id
        case .row(let row, let section): return "row:" + section.rawValue + ":" + row.id
        case .finish(let finish): return "finish:" + finish.id
        }
    }

    var sessionKey: String? {
        switch self {
        case .ask(let card, _): return card.id
        case .row(let row, _): return row.id
        case .finish(let finish): return finish.id
        default: return nil
        }
    }

    var isSelectable: Bool {
        switch self {
        case .ask, .row: return true
        default: return false
        }
    }
}

/// The board's list: arrows move the selection, Return opens the selected agent's chat, Space folds
/// the inspector, and the context menu offers the same three verbs a row has.
@MainActor
final class AgentsTableView: NSTableView {
    var onOpenChat: (() -> Void)?
    var onToggleInspector: (() -> Void)?
    var menuProvider: ((Int) -> NSMenu?)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 36, 76: onOpenChat?()
        case 49: onToggleInspector?()
        default: super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        return menuProvider?(row)
    }
}

/// The ground of one list line: a fill for a selected row, an outline for a selected card, a wash
/// under a pointer resting on a row, and a hairline between rows.
@MainActor
final class AgentsTableRowView: NSTableRowView {
    enum Kind { case plain, card, row }

    var kind: Kind = .plain {
        didSet { if kind != oldValue { needsDisplay = true } }
    }
    private var hovered = false {
        didSet { if hovered != oldValue { needsDisplay = true } }
    }
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = kind == .row }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        let inset = bounds.insetBy(dx: MacTheme.Spacing.s, dy: 2)
        if hovered, !isSelected {
            MacTheme.Color.label.withAlphaComponent(0.05).setFill()
            NSBezierPath(
                roundedRect: inset, xRadius: MacTheme.Radius.control, yRadius: MacTheme.Radius.control
            ).fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        switch kind {
        case .row:
            let shape = bounds.insetBy(dx: MacTheme.Spacing.s, dy: 2)
            MacTheme.Color.accent.withAlphaComponent(isEmphasized ? 0.2 : 0.12).setFill()
            NSBezierPath(
                roundedRect: shape, xRadius: MacTheme.Radius.control, yRadius: MacTheme.Radius.control
            ).fill()
        case .card:
            let shape = bounds.insetBy(dx: MacTheme.Spacing.m - 1, dy: MacTheme.Spacing.xs - 1)
            let path = NSBezierPath(
                roundedRect: shape, xRadius: MacTheme.Radius.card + 1, yRadius: MacTheme.Radius.card + 1)
            path.lineWidth = 2
            MacTheme.Color.accent.withAlphaComponent(isEmphasized ? 0.9 : 0.5).setStroke()
            path.stroke()
        case .plain:
            break
        }
    }
}
