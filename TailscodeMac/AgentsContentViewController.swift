import AppKit
import TailscodeCore

/// Where the window's ⌘. goes: stopping the agent that is selected, which the Chat menu's own Stop
/// Turn must never do from here, since that one answers for a different chat.
@MainActor
final class AgentsWindow: NSWindow {
    var onStop: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "." {
            onStop?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The content column: the Now face and the Hour face, one showing at a time, under the one gate
/// that says whether anybody can see them.
@MainActor
final class AgentsContentViewController: NSViewController {
    private final class Root: NSView {
        var onGate: (() -> Void)?
        lazy var gate = DisplayGate(self) { [weak self] in self?.onGate?() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            gate.attach()
            onGate?()
        }

        override func draw(_ dirtyRect: NSRect) {
            MacTheme.Color.canvas.setFill()
            dirtyRect.fill()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }
    }

    private let root = Root()
    let board: AgentsBoardViewController
    let hour: AgentsHourViewController
    var onGate: (() -> Void)? {
        get { root.onGate }
        set { root.onGate = newValue }
    }

    var isVisibleToEyes: Bool { root.gate.isOpen }

    init(board: AgentsBoardViewController, hour: AgentsHourViewController) {
        self.board = board
        self.hour = hour
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = root
        for child in [board, hour] {
            addChild(child)
            child.view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child.view)
            NSLayoutConstraint.activate([
                child.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                child.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                child.view.topAnchor.constraint(equalTo: root.topAnchor),
                child.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }
        show(.now)
    }

    func show(_ mode: AgentsWindowController.Mode) {
        board.view.isHidden = mode != .now
        hour.view.isHidden = mode != .hour
    }
}
