import AppKit
import TailscodeCore

/// A scroll view that lives inside another scroller and keeps only the scrolling it can use. The
/// step list, the account, a diff and an output block sit in the transcript, so a pointer resting
/// on one is also resting on the page: an event the inner view could not move (its content fits,
/// or the gesture began at the edge it moves past) goes on to the enclosing scroller as the same
/// event, phase and momentum intact, and `ScrollHandoff` in Core decides once per gesture so a
/// list the person began scrolling is theirs until they lift. With no elasticity along the way
/// nothing rubber-bands, so a short list never takes the rest of a gesture for itself.
///
/// It also says when a person moved it, the only scroll that pauses a list following a running
/// turn: a wheel with notches eases the content after the event is handled, so a scroll that
/// follows one closely is still theirs.
@MainActor
final class HandoffScrollView: NSScrollView {
    private(set) var isWheeling = false
    private(set) var isLiveScrolling = false
    private(set) var handedOff = 0
    var onUserScroll: (() -> Void)?
    var acceptsFocus = true

    private var handoff = ScrollHandoff()
    private var movesVertically = true
    private var axisPending = true
    private var lastWheel = -1.0
    private static let wheelTail = 0.5

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsetsZero
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .none
        usesPredominantAxisScrolling = true
        contentView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(liveBegan), name: NSScrollView.willStartLiveScrollNotification,
            object: self)
        center.addObserver(
            self, selector: #selector(liveEnded), name: NSScrollView.didEndLiveScrollNotification,
            object: self)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    isolated deinit { NotificationCenter.default.removeObserver(self) }

    override var acceptsFirstResponder: Bool { acceptsFocus && super.acceptsFirstResponder }

    @objc private func liveBegan() {
        isLiveScrolling = true
        onUserScroll?()
    }

    @objc private func liveEnded() { isLiveScrolling = false }

    var isUserScrolling: Bool {
        isWheeling || isLiveScrolling || CACurrentMediaTime() - lastWheel < Self.wheelTail
    }

    /// Runs a scroll as if the wheel had made it, for the checks: the real wheel is the system's.
    func simulateUserScroll(_ body: () -> Void) {
        isWheeling = true
        body()
        isWheeling = false
    }

    override func scrollWheel(with event: NSEvent) {
        guard let outer = nextResponder, owner(of: event) == .outer else {
            takeWheel(event)
            return
        }
        handedOff += 1
        outer.scrollWheel(with: event)
    }

    private func takeWheel(_ event: NSEvent) {
        lastWheel = CACurrentMediaTime()
        isWheeling = true
        onUserScroll?()
        super.scrollWheel(with: event)
        isWheeling = false
    }

    func resetHandoff() {
        handoff.reset()
        axisPending = true
        movesVertically = true
    }

    /// Who an event belongs to, from the axis its gesture moves on and where this view stands along it.
    func owner(of event: NSEvent) -> ScrollHandoff.Owner {
        let sent = ScrollHandoff.Event(
            delta: Double(delta(of: event)), phase: Self.phase(event.phase),
            momentum: Self.phase(event.momentumPhase))
        return handoff.route(sent, in: metrics(vertical: movesVertically))
    }

    /// The delta along the gesture's axis. The axis is the one the first event that moved was
    /// moving on, and it holds for the rest of the gesture and its momentum: an event that moves
    /// nothing, like the one that ends a gesture, belongs to the axis the gesture was on.
    private func delta(of event: NSEvent) -> CGFloat {
        let begins = event.phase.contains(.began) || event.phase.contains(.mayBegin)
            || (event.phase.isEmpty && event.momentumPhase.isEmpty)
        if begins {
            axisPending = true
            movesVertically = true
        }
        let across = event.scrollingDeltaX
        let along = event.scrollingDeltaY
        if axisPending, along != 0 || across != 0 {
            movesVertically = abs(along) >= abs(across)
            axisPending = false
        }
        return movesVertically ? along : across
    }

    /// The view's place along an axis, which is nothing to scroll along one it has no scroller for.
    private func metrics(vertical: Bool) -> ScrollHandoff.Metrics {
        guard let document = documentView, vertical ? hasVerticalScroller : hasHorizontalScroller else {
            return ScrollHandoff.Metrics(offset: 0, content: 0, viewport: 0)
        }
        let clip = contentView.bounds
        let all = contentView.documentRect
        if vertical {
            let offset = document.isFlipped ? clip.minY - all.minY : all.maxY - clip.maxY
            return ScrollHandoff.Metrics(
                offset: Double(offset), content: Double(all.height), viewport: Double(clip.height))
        }
        return ScrollHandoff.Metrics(
            offset: Double(clip.minX - all.minX), content: Double(all.width), viewport: Double(clip.width))
    }

    private static func phase(_ phase: NSEvent.Phase) -> ScrollHandoff.Phase {
        if phase.contains(.mayBegin) { return .mayBegin }
        if phase.contains(.began) { return .began }
        if phase.contains(.changed) { return .changed }
        if phase.contains(.stationary) { return .stationary }
        if phase.contains(.ended) { return .ended }
        if phase.contains(.cancelled) { return .cancelled }
        return .none
    }
}
