import Foundation
import Testing

@testable import TailscodeCore

@Suite("Scroll handoff")
struct ScrollHandoffTests {
    typealias Owner = ScrollHandoff.Owner
    typealias Event = ScrollHandoff.Event

    private func metrics(_ offset: Double, content: Double = 600, viewport: Double = 200)
        -> ScrollHandoff.Metrics
    {
        ScrollHandoff.Metrics(offset: offset, content: content, viewport: viewport)
    }

    private func gesture(_ deltas: [Double]) -> [Event] {
        deltas.enumerated().map { index, delta in
            Event(delta: delta, phase: index == 0 ? .began : .changed)
        }
    }

    private func momentum(_ deltas: [Double]) -> [Event] {
        deltas.enumerated().map { index, delta in
            Event(delta: delta, momentum: index == 0 ? .began : .changed)
        }
    }

    /// Plays events against a scroller of the given size, the inner view taking only what it owns
    /// and standing where the previous event left it, and returns each event's owner and where the
    /// inner view ended.
    private func play(
        _ events: [Event], from offset: Double, content: Double = 600, viewport: Double = 200,
        using handoff: inout ScrollHandoff
    ) -> (owners: [Owner], offset: Double) {
        var position = offset
        var owners: [Owner] = []
        for event in events {
            let owner = handoff.route(event, in: metrics(position, content: content, viewport: viewport))
            owners.append(owner)
            if owner == .inner {
                position = min(max(position - event.delta, 0), max(content - viewport, 0))
            }
        }
        return (owners, position)
    }

    @Test("content that fits is always the outer scroller's, whatever the event")
    func fits() {
        var handoff = ScrollHandoff()
        let fitting = metrics(0, content: 180, viewport: 200)
        for event in [
            Event(delta: 5), Event(delta: -5), Event(delta: 0),
            Event(delta: 5, phase: .began), Event(delta: -5, phase: .changed),
            Event(delta: 0, phase: .ended), Event(delta: 5, momentum: .began),
            Event(delta: 5, momentum: .ended),
        ] {
            #expect(handoff.route(event, in: fitting) == .outer)
        }
    }

    @Test("an overflow of a point or less is rounding, and above it the view scrolls")
    func tinyOverflow() {
        var handoff = ScrollHandoff()
        #expect(handoff.route(Event(delta: -3), in: metrics(0, content: 201, viewport: 200)) == .outer)
        #expect(handoff.route(Event(delta: -3), in: metrics(0, content: 200.9, viewport: 200)) == .outer)
        #expect(handoff.route(Event(delta: -3), in: metrics(0, content: 201.5, viewport: 200)) == .inner)
    }

    @Test("a wheel with notches decides every event on its own")
    func discrete() {
        var handoff = ScrollHandoff()
        #expect(handoff.route(Event(delta: -3), in: metrics(0)) == .inner)
        #expect(handoff.route(Event(delta: 3), in: metrics(0)) == .outer)
        #expect(handoff.route(Event(delta: 3), in: metrics(100)) == .inner)
        #expect(handoff.route(Event(delta: -3), in: metrics(100)) == .inner)
        #expect(handoff.route(Event(delta: -3), in: metrics(400)) == .outer)
        #expect(handoff.route(Event(delta: 3), in: metrics(400)) == .inner)
        #expect(handoff.route(Event(delta: 3), in: metrics(100)) == .inner)
    }

    @Test("a wheel hands the page the notch the list cannot use, then takes the next it can")
    func discreteRun() {
        var handoff = ScrollHandoff()
        let run = play(Array(repeating: Event(delta: -50), count: 10), from: 0, using: &handoff)
        #expect(run.owners.prefix(8).allSatisfy { $0 == .inner })
        #expect(run.owners.suffix(2).allSatisfy { $0 == .outer })
        #expect(run.offset == 400)
        let back = play([Event(delta: 50)], from: run.offset, using: &handoff)
        #expect(back.owners == [.inner])
    }

    @Test("a notch is the list's while it can move that way and the page's from the edge")
    func notch() {
        #expect(ScrollHandoff.notch(-1, in: metrics(0)) == .inner)
        #expect(ScrollHandoff.notch(1, in: metrics(0)) == .outer)
        #expect(ScrollHandoff.notch(1, in: metrics(400)) == .inner)
        #expect(ScrollHandoff.notch(-1, in: metrics(400)) == .outer)
        #expect(ScrollHandoff.notch(-1, in: metrics(0, content: 200.5)) == .outer)
    }

    @Test("a wheel never goes to the page while the list could still scroll that way")
    func neverHandsOffWhileMovable() {
        var handoff = ScrollHandoff()
        for offset in stride(from: 0.0, through: 400.0, by: 12.5) {
            for delta in [-40.0, -0.5, 0.5, 40.0] {
                let here = metrics(offset)
                let owner = handoff.route(Event(delta: delta), in: here)
                #expect((owner == .outer) == !here.canMove(delta), "offset \(offset) delta \(delta)")
            }
        }
    }

    @Test("a gesture that begins at the top moving up is the page's from start to end, momentum included")
    func beginsPastTheTop() {
        var handoff = ScrollHandoff()
        let events = gesture([6, 8, 8, 4]) + [Event(delta: 0, phase: .ended)] + momentum([3, 2, 1])
            + [Event(delta: 0, momentum: .ended)]
        let run = play(events, from: 0, using: &handoff)
        #expect(run.owners.allSatisfy { $0 == .outer })
        #expect(run.offset == 0)
    }

    @Test("a gesture that begins at the bottom moving down is the page's, and so is a reversal inside it")
    func beginsPastTheBottom() {
        var handoff = ScrollHandoff()
        let run = play(gesture([-6, -8, 5, 7, -2]), from: 400, using: &handoff)
        #expect(run.owners.allSatisfy { $0 == .outer })
        #expect(run.offset == 400)
    }

    @Test("a gesture that begins mid-list stays the list's to the end, past the edge, and so does its momentum")
    func staysInner() {
        var handoff = ScrollHandoff()
        let events = gesture([-80, -80, -80, -80, -80]) + [Event(delta: 0, phase: .ended)]
            + momentum([-40, -20, -10]) + [Event(delta: 0, momentum: .ended)]
        let run = play(events, from: 100, using: &handoff)
        #expect(run.owners.allSatisfy { $0 == .inner })
        #expect(run.offset == 400)
    }

    @Test("the next gesture from the end is the page's")
    func nextGestureFromTheEnd() {
        var handoff = ScrollHandoff()
        _ = play(gesture([-200, -200]) + [Event(delta: 0, phase: .ended)] + momentum([-5]), from: 100, using: &handoff)
        _ = handoff.route(Event(delta: 0, momentum: .ended), in: metrics(400))
        let next = play(gesture([-10, -10]), from: 400, using: &handoff)
        #expect(next.owners == [.outer, .outer])
    }

    @Test("a reversal inside a gesture the list owns keeps it the list's")
    func innerReversal() {
        var handoff = ScrollHandoff()
        let run = play(gesture([-50, -50, 120, 40, -10]), from: 150, using: &handoff)
        #expect(run.owners.allSatisfy { $0 == .inner })
    }

    @Test("a gesture that begins with no movement chooses on the first that has some")
    func beginsStill() {
        var handoff = ScrollHandoff()
        let up = play(gesture([0, 0, 5, 5]), from: 0, using: &handoff)
        #expect(up.owners == [.inner, .inner, .outer, .outer])
        let down = play(gesture([0, -5, -5]), from: 0, using: &handoff)
        #expect(down.owners == [.inner, .inner, .inner])
    }

    @Test("touching the surface and a stationary finger change nothing")
    func touchAndRest() {
        var handoff = ScrollHandoff()
        #expect(handoff.route(Event(delta: 0, phase: .mayBegin), in: metrics(0)) == .inner)
        #expect(handoff.route(Event(delta: 4, phase: .began), in: metrics(0)) == .outer)
        #expect(handoff.route(Event(delta: 0, phase: .stationary), in: metrics(0)) == .outer)
        #expect(handoff.route(Event(delta: -4, phase: .changed), in: metrics(0)) == .outer)
    }

    @Test("a finger that lands on a coasting list stops it and begins afresh")
    func catchesMomentum() {
        var handoff = ScrollHandoff()
        _ = play(gesture([5, 5]) + [Event(delta: 0, phase: .ended)] + momentum([3, 2]), from: 0, using: &handoff)
        #expect(handoff.route(Event(delta: 0, phase: .mayBegin), in: metrics(0)) == .inner)
        #expect(handoff.route(Event(delta: -6, phase: .began), in: metrics(0)) == .inner)
        #expect(handoff.route(Event(delta: -6, phase: .changed), in: metrics(6)) == .inner)
    }

    @Test("momentum with no gesture before it chooses by where the list stands")
    func orphanMomentum() {
        var handoff = ScrollHandoff()
        #expect(handoff.route(Event(delta: -4, momentum: .began), in: metrics(0)) == .inner)
        var other = ScrollHandoff()
        #expect(other.route(Event(delta: 4, momentum: .began), in: metrics(0)) == .outer)
        #expect(other.route(Event(delta: -4, momentum: .changed), in: metrics(0)) == .outer)
    }

    @Test("the end of the momentum, and a cancelled gesture, let the next one choose again")
    func endsRelease() {
        var handoff = ScrollHandoff()
        _ = play(gesture([5]) + momentum([3]) + [Event(delta: 0, momentum: .ended)], from: 0, using: &handoff)
        #expect(handoff.route(Event(delta: -5, phase: .began), in: metrics(0)) == .inner)
        #expect(handoff.route(Event(delta: 0, phase: .cancelled), in: metrics(0)) == .inner)
        #expect(handoff.route(Event(delta: 5, momentum: .began), in: metrics(0)) == .outer)
    }

    @Test("a wheel between gestures forgets the gesture before it")
    func wheelForgets() {
        var handoff = ScrollHandoff()
        _ = handoff.route(Event(delta: 5, phase: .began), in: metrics(0))
        #expect(handoff.route(Event(delta: -5), in: metrics(0)) == .inner)
        #expect(handoff.route(Event(delta: -5, phase: .changed), in: metrics(0)) == .inner)
    }

    @Test("content that stops overflowing in the middle of a gesture goes to the page, and stays there")
    func shrinksMidGesture() {
        var handoff = ScrollHandoff()
        #expect(handoff.route(Event(delta: -5, phase: .began), in: metrics(100)) == .inner)
        #expect(handoff.route(Event(delta: -5, phase: .changed), in: metrics(105, content: 150)) == .outer)
        #expect(handoff.route(Event(delta: -5, phase: .changed), in: metrics(0)) == .outer)
    }

    @Test("an edge within half a point counts as the edge")
    func edgeTolerance() {
        var handoff = ScrollHandoff()
        #expect(handoff.route(Event(delta: 5, phase: .began), in: metrics(0.3)) == .outer)
        #expect(handoff.route(Event(delta: 5, phase: .began), in: metrics(0.8)) == .inner)
        #expect(handoff.route(Event(delta: -5, phase: .began), in: metrics(399.7)) == .outer)
        #expect(handoff.route(Event(delta: -5, phase: .began), in: metrics(399.0)) == .inner)
    }

    @Test("a reset forgets a gesture that belonged to a view that was rebuilt")
    func reset() {
        var handoff = ScrollHandoff()
        _ = handoff.route(Event(delta: 5, phase: .began), in: metrics(0))
        handoff.reset()
        #expect(handoff.route(Event(delta: -5, phase: .changed), in: metrics(0)) == .inner)
    }
}
