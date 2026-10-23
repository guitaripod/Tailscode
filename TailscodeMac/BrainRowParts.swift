import AppKit
import CodingAgentKit
import TailscodeCore

/// The view the stage and the head's picture live in: a plain flipped view the row moves with one
/// transform, so the head, its nodes and its picture travel as a single thing.
@MainActor
final class BrainCarrierView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let found = super.hitTest(point)
        return found === self ? nil : found
    }

    func setTravel(_ transform: CGAffineTransform) {
        guard let layer else { return }
        layer.sublayerTransform = CATransform3DMakeAffineTransform(transform)
    }
}

/// Megatron's name over the open row's corner: a view of its own so that it stands above the head,
/// which fills that corner in a split, with the one text layer that draws it.
@MainActor
final class BrainWordmarkView: NSView {
    private let text = CATextLayer()

    var words: NSAttributedString? {
        didSet {
            text.string = words
            text.contentsScale = window?.backingScaleFactor ?? 2
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        text.alignmentMode = .left
        text.isWrapped = false
        layer?.addSublayer(text)
        setAccessibilityElement(false)
        isHidden = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        text.frame = bounds
        CATransaction.commit()
    }
}

/// The brain's one standing clock: none. What it does is notice that nobody is looking. A head
/// holds the process's textures while it is open, so an app that has been in the background, hidden
/// or behind another window for a minute and a half lets go of them, and takes them back the moment
/// it is looked at; a window that closes lets go at once.
@MainActor
final class MacBrainIdle {
    static let shared = MacBrainIdle()
    static let delay: TimeInterval = 90

    private var installed = false
    private var timer: Timer?
    private(set) var isIdle = false

    func install() {
        guard !installed else { return }
        installed = true
        let center = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification, NSApplication.didHideNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainThread.call { self?.away() }
            }
        }
        for name in [
            NSApplication.didBecomeActiveNotification, NSApplication.didUnhideNotification,
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainThread.call { self?.back() }
            }
        }
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) {
            note in
            guard let closing = (note.object as? NSWindow).map({ ObjectIdentifier($0) }) else {
                return
            }
            MainThread.call {
                for row in BrainRowView.live where row.window.map({ ObjectIdentifier($0) }) == closing {
                    row.setParked(true, reason: "window")
                }
            }
        }
    }

    func away() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.delay, repeats: false) { [weak self] _ in
            MainThread.call { self?.fallIdle() }
        }
    }

    func fallIdle() {
        timer = nil
        isIdle = true
        BrainCardPictures.shared.dropAll()
        for row in BrainRowView.live { row.setParked(true, reason: "idle") }
    }

    func back() {
        timer?.invalidate()
        timer = nil
        guard isIdle else { return }
        isIdle = false
        for row in BrainRowView.live { row.setParked(false, reason: "idle") }
    }
}
