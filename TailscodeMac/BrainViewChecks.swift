import AppKit
import CodingAgentKit
import TailscodeCore

/// A conversation laid out the way a pane lays it out, in a window that is never ordered front:
/// the demo's turns (or any messages) through the row builder, a transcript column holding the
/// rows' views, and a store whose choices rebuild the rows and restate the views in place. The
/// harness for every claim about the open brain's views.
@MainActor
final class BrainFixture {
    let store = BrainStore()
    let context = TranscriptContext()
    let builder = TranscriptRowBuilder()
    let root: NSView
    let column = TranscriptColumn()
    let window: NSWindow
    private(set) var messages: [ChatMessage]
    private(set) var rows: [TranscriptRow] = []
    private(set) var views: [String: BrainRowView] = [:]
    var running: Bool

    init(
        messages: [ChatMessage] = NeuralDemo.conversation(), running: Bool = false,
        width: CGFloat = 900
    ) {
        self.messages = messages
        self.running = running
        context.brains = store
        builder.brains = store
        root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 1600))
        column.spacing = MacTheme.Spacing.m
        column.metrics = ChatLayout.metrics
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: root.topAnchor),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
        ])
        window = NSWindow(
            contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = root
        store.onChange = { [weak self] in self?.rebuild() }
        rebuild()
        root.layoutSubtreeIfNeeded()
    }

    var brainRows: [(row: TranscriptRow, brain: BrainRow)] {
        rows.compactMap {
            guard case .brain(let brain) = $0.kind else { return nil }
            return ($0, brain)
        }
    }

    /// The rows built again from the messages, the brain views made or restated to match.
    func rebuild() {
        rows = builder.rows(for: messages, turnOpen: running)
        for entry in brainRows {
            if let view = views[entry.brain.turnID] {
                view.restate(entry.brain)
            } else if let view = entry.row.makeView(context: context) as? BrainRowView {
                views[entry.brain.turnID] = view
                column.addArrangedSubview(view, spacing: entry.row.spacing)
            }
        }
        root.layoutSubtreeIfNeeded()
    }

    func replace(messages next: [ChatMessage], running: Bool? = nil) {
        messages = next
        if let running { self.running = running }
        rebuild()
    }

    func resize(to width: CGFloat) {
        root.setFrameSize(NSSize(width: width, height: root.frame.height))
        window.setContentSize(root.frame.size)
        root.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
    }

    /// The view of the nth brain (oldest first), opened through the store the way a press does.
    @discardableResult
    func open(_ index: Int) -> BrainRowView? {
        guard store.order.indices.contains(index) else { return nil }
        let id = store.order[index]
        store.setOpen(true, turnID: id)
        finishMoves()
        return views[id]
    }

    func view(_ index: Int) -> BrainRowView? {
        store.order.indices.contains(index) ? views[store.order[index]] : nil
    }

    /// Lets every move that is running land at once.
    func finishMoves() {
        for view in views.values where view.mover != nil { view.finishMove(snapOpen: view.row.isOpen) }
        root.layoutSubtreeIfNeeded()
    }

    func tearDown() {
        for view in views.values { view.removeFromSuperview() }
        views = [:]
        window.close()
    }
}

/// The open brain's claims about its views, checked headlessly: the card, the open layout at every
/// width, the move, the keys, the account's wiring, the clocks and the textures.
@MainActor
enum BrainViewChecks {
    static func run() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("neural trace views: \(label)") }
            checks += 1
        }
        let was = DisplayGate.assumesVisible
        DisplayGate.assumesVisible = true
        BrainPictures.rendersSynchronously = true
        defer {
            DisplayGate.assumesVisible = was
            BrainPictures.rendersSynchronously = false
        }
        guard MacBrain.isEnabled else { return 0 }
        try BrainOwnChecks.run(expect)
        _ = try BrainListChecks.run(expect)
        checks += try BrainAccountChecks.run(expect)
        return checks
    }
}
