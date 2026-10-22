import AppKit
import CodingAgentKit
import TailscodeCore

/// The page can always be scrolled past an open Megatron. The step list and the account are
/// scrollers inside the transcript's own, and a pointer resting on one must not trap the page:
/// these checks put a real open brain in a real scroll view in a window on screen and read where
/// the list and the page end up.
///
/// A wheel with notches goes through `scrollWheel` itself, end to end. A trackpad gesture cannot:
/// AppKit's scroll view takes the first event of a phased gesture into a loop that waits for the
/// rest from the window server, so a synthetic gesture (`CGEvent` scroll wheels with their phase
/// fields, read back as `NSEvent`) is put to the view's decision, `owner(of:)`, and the scroller
/// it names is moved by the event's delta. What stays unproven here is what the window server and
/// AppKit's own tracking do around that decision: which view a gesture is latched to, and
/// momentum as the system generates it.
@MainActor
enum BrainScrollChecks {
    private typealias Expect = (Bool, String) throws -> Void

    private struct Rig {
        let fixture: BrainFixture
        let outer: NSScrollView
        let row: BrainRowView
    }

    static func run(_ expect: (Bool, String) throws -> Void) throws -> Int {
        var checks = 0
        let counted: Expect = { condition, label in
            try expect(condition, "scroll: \(label)")
            checks += 1
        }
        try events(counted)
        try list(counted)
        try account(counted)
        try horizontal(counted)
        return checks
    }

    private static func spin(_ seconds: Double = 0.05) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private static func rig(width: CGFloat = 1300, open index: Int) -> Rig? {
        let fixture = BrainFixture(width: width)
        let outer = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 560))
        outer.drawsBackground = false
        outer.hasVerticalScroller = true
        outer.scrollerStyle = .overlay
        let host = NSView(frame: outer.frame)
        host.addSubview(outer)
        fixture.window.contentView = host
        outer.documentView = fixture.root
        fixture.root.setFrameSize(NSSize(width: width, height: 1600))
        fixture.window.setContentSize(host.frame.size)
        fixture.root.layoutSubtreeIfNeeded()
        let top = NSScreen.main?.visibleFrame.maxY ?? 800
        fixture.window.setFrameTopLeftPoint(NSPoint(x: 20, y: top))
        fixture.window.orderFrontRegardless()
        guard let row = fixture.open(index) else {
            fixture.tearDown()
            return nil
        }
        row.superview?.layoutSubtreeIfNeeded()
        row.layoutSubtreeIfNeeded()
        row.account?.refresh(immediate: true)
        row.account?.layoutSubtreeIfNeeded()
        row.account?.realize()
        spin(0.1)
        return Rig(fixture: fixture, outer: outer, row: row)
    }

    /// How far a scroller stands from the top of what it holds, whichever way its document is flipped.
    private static func fromTop(_ scroll: NSScrollView) -> CGFloat {
        let clip = scroll.contentView.bounds
        let all = scroll.contentView.documentRect
        return scroll.documentView?.isFlipped == true ? clip.minY - all.minY : all.maxY - clip.maxY
    }

    private static func span(_ scroll: NSScrollView) -> CGFloat {
        max(0, scroll.contentView.documentRect.height - scroll.contentView.bounds.height)
    }

    private static func place(_ scroll: NSScrollView, at distance: CGFloat) {
        let clip = scroll.contentView.bounds
        let all = scroll.contentView.documentRect
        let wanted = min(max(distance, 0), span(scroll))
        let y = scroll.documentView?.isFlipped == true ? all.minY + wanted : all.maxY - clip.height - wanted
        scroll.contentView.scroll(to: NSPoint(x: clip.minX, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        spin(0.02)
    }

    private static let began: Int64 = 1
    private static let changed: Int64 = 2
    private static let ended: Int64 = 4
    private static let cancelled: Int64 = 8
    private static let mayBegin: Int64 = 128
    private static let momentumBegan: Int64 = 1
    private static let momentumChanged: Int64 = 2
    private static let momentumEnded: Int64 = 3

    private static func wheel(
        _ dy: Int32 = 0, dx: Int32 = 0, phase: Int64 = 0, momentum: Int64 = 0, continuous: Bool = true
    ) -> NSEvent? {
        guard
            let cg = CGEvent(
                scrollWheelEvent2Source: nil, units: continuous ? .pixel : .line, wheelCount: 2, wheel1: dy,
                wheel2: dx, wheel3: 0)
        else { return nil }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous ? 1 : 0)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        return NSEvent(cgEvent: cg)
    }

    /// A wheel with notches through the view's own `scrollWheel`, which eases the content in over the next few frames. A phased
    /// event is not: AppKit's scroll view takes a gesture's first event into a loop that waits for
    /// the rest of the gesture from the window server, and a synthetic gesture never finishes it.
    private static func notch(_ delta: Int32, to view: HandoffScrollView) {
        guard let event = wheel(delta, continuous: false) else { return }
        view.scrollWheel(with: event)
        spin(0.4)
    }

    /// A gesture as the view's decision sees it, each event a real `NSEvent` with its phase read
    /// back from the system's own type. Where the owner is the list or the page it is moved by the
    /// event's delta, which is what the scroll views would do with it.
    private static func play(
        _ events: [NSEvent?], inner: HandoffScrollView, outer: NSScrollView
    ) -> [ScrollHandoff.Owner] {
        var owners: [ScrollHandoff.Owner] = []
        for case let event? in events {
            let owner = inner.owner(of: event)
            owners.append(owner)
            let target: NSScrollView = owner == .inner ? inner : outer
            place(target, at: fromTop(target) - event.scrollingDeltaY)
        }
        return owners
    }

    private static func gesture(_ deltas: [Int32], lifting: Bool = true, coasting: [Int32] = []) -> [NSEvent?] {
        var events: [NSEvent?] = deltas.enumerated().map { index, delta in
            wheel(delta, phase: index == 0 ? began : changed)
        }
        if lifting { events.append(wheel(0, phase: ended)) }
        events += coasting.enumerated().map { index, delta in
            wheel(delta, momentum: index == 0 ? momentumBegan : momentumChanged)
        }
        if !coasting.isEmpty { events.append(wheel(0, momentum: momentumEnded)) }
        return events
    }

    private static func events(_ expect: Expect) throws {
        guard let one = wheel(-7, phase: began), let two = wheel(3, momentum: momentumChanged) else {
            try expect(false, "synthetic scroll events can be made")
            return
        }
        try expect(one.scrollingDeltaY == -7 && one.phase == .began, "a synthetic trackpad event carries its delta and phase")
        try expect(two.momentumPhase == .changed && two.phase.isEmpty, "a synthetic momentum event carries its momentum phase")
        try expect(wheel(-1, continuous: false)?.phase.isEmpty == true, "a synthetic wheel has no phase")
        try expect(wheel(0, dx: -9)?.scrollingDeltaX == -9, "and a sideways delta")
    }

    /// One scroller inside the page, driven through every case: the list is the page's when it
    /// cannot move, its own when it can, and a gesture it began is its own to the end.
    private static func exercise(
        _ name: String, rig: Rig, inner: HandoffScrollView, _ expect: Expect
    ) throws {
        let outer = rig.outer
        let room = span(inner)
        try expect(inner.frame.width > 100, "\(name) has a width (\(inner.frame))")
        try expect(room > 80, "\(name) has room to scroll (\(Int(room)) pt)")
        try expect(span(outer) > 200, "the page has room to scroll (\(Int(span(outer))) pt; scroll view \(outer.frame) clip \(outer.contentView.bounds) document \(String(describing: outer.documentView?.frame)) window \(rig.fixture.window.frame))")
        let page = min(span(outer) / 2, 300)

        func begin(listAt: CGFloat) {
            handoffReset(inner)
            place(outer, at: page)
            place(inner, at: listAt)
        }

        begin(listAt: room / 2)
        var owners = play(gesture([-10, -10, -10, -10]), inner: inner, outer: outer)
        try expect(owners.allSatisfy { $0 == .inner }, "\(name): a gesture that begins mid-list is the list's")
        try expect(fromTop(inner) > room / 2 + 1 && abs(fromTop(outer) - page) < 0.5, "\(name): the list moves and the page does not")

        begin(listAt: 0)
        owners = play(gesture([12, 12, 12], coasting: [6, 4, 2]), inner: inner, outer: outer)
        try expect(owners.allSatisfy { $0 == .outer }, "\(name): a gesture that begins at the top moving up is the page's, momentum included")
        try expect(fromTop(inner) == 0 && fromTop(outer) < page - 1, "\(name): the page moves up and the list stays")

        begin(listAt: room)
        owners = play(gesture([-12, -12, -12], coasting: [-6, -4, -2]), inner: inner, outer: outer)
        try expect(owners.allSatisfy { $0 == .outer }, "\(name): a gesture that begins at the bottom moving down is the page's, momentum included")
        try expect(abs(fromTop(inner) - room) < 0.5 && fromTop(outer) > page + 1, "\(name): the page moves down and the list stays")

        begin(listAt: room - 20)
        owners = play(gesture([-30, -30, -30, -30, -30, -30], coasting: [-20, -10]), inner: inner, outer: outer)
        try expect(owners.allSatisfy { $0 == .inner }, "\(name): a gesture that runs the list to its end stays the list's, its momentum too")
        try expect(abs(fromTop(inner) - room) < 0.5 && abs(fromTop(outer) - page) < 0.5, "\(name): and the page does not move under it")
        owners = play(gesture([-12, -12, -12]), inner: inner, outer: outer)
        try expect(owners.allSatisfy { $0 == .outer } && fromTop(outer) > page + 1, "\(name): the next gesture, from the end, is the page's")

        begin(listAt: room / 2)
        owners = play(gesture([-10, -10]) + gesture([30, 30]), inner: inner, outer: outer)
        try expect(owners.allSatisfy { $0 == .inner }, "\(name): a list moving both ways keeps both gestures")

        begin(listAt: room / 2)
        let before = inner.handedOff
        notch(-1, to: inner)
        place(inner, at: 0)
        notch(1, to: inner)
        place(outer, at: page)
        place(inner, at: room)
        notch(-1, to: inner)
        try expect(inner.handedOff == before + 2, "\(name): of three wheel notches the list can use one, and the two it cannot go on to the page")
    }

    private static func handoffReset(_ view: HandoffScrollView) { view.resetHandoff() }

    private static func list(_ expect: Expect) throws {
        guard let rig = rig(open: 1), let list = rig.row.list else {
            try expect(false, "the second turn's brain opens in a scroll view")
            return
        }
        defer { rig.fixture.tearDown() }
        try exercise("the step list", rig: rig, inner: list.scroll, expect)
        try expect(list.scroll.verticalScrollElasticity == .none, "the step list never rubber-bands")
    }

    private static func account(_ expect: Expect) throws {
        guard let rig = rig(open: 1), let account = rig.row.account else {
            try expect(false, "the second turn's account opens in a scroll view")
            return
        }
        defer { rig.fixture.tearDown() }
        try exercise("the account", rig: rig, inner: account.scroll, expect)
    }

    /// A scroller that goes sideways hands the page every vertical delta and keeps the sideways.
    private static func horizontal(_ expect: Expect) throws {
        let outer = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 1200))
        outer.documentView = page
        let inner = HandoffScrollView(frame: NSRect(x: 0, y: 100, width: 300, height: 100))
        inner.hasHorizontalScroller = true
        inner.hasVerticalScroller = false
        inner.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 100))
        page.addSubview(inner)

        let vertical = gesture([-10, -10, 10, 10]).compactMap { $0 }.map { inner.owner(of: $0) }
        try expect(vertical.allSatisfy { $0 == .outer }, "a sideways scroller hands every vertical delta on")
        let sideways = [wheel(0, dx: -12, phase: began), wheel(0, dx: -12, phase: changed), wheel(0, phase: ended)]
            .compactMap { $0 }.map { inner.owner(of: $0) }
        try expect(sideways.allSatisfy { $0 == .inner }, "and keeps the sideways ones")
        let afterwards = [wheel(0, dx: -12, phase: began), wheel(0, phase: ended), wheel(0, dx: -6, momentum: momentumBegan), wheel(0, momentum: momentumEnded)]
            .compactMap { $0 }.map { inner.owner(of: $0) }
        try expect(afterwards.allSatisfy { $0 == .inner }, "a sideways gesture keeps its axis to the end, the events that move nothing and its momentum included")
        let fits = HandoffScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        fits.hasHorizontalScroller = true
        fits.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        try expect(wheel(0, dx: -12, phase: began).map { fits.owner(of: $0) } == .outer, "and hands on a sideways gesture it has no room for")
    }
}
