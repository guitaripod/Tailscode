import Foundation
import Testing
@testable import TailscodeCore

@Suite("Tile drain")
struct TileDrainTests {
    private final class Pane: @unchecked Sendable {
        let id = PaneID()
        let box = LatestWins<Int>()
        let applied = Tally<Int>()
        let cost: TimeInterval
        let clock: ManualClock

        init(clock: ManualClock, cost: TimeInterval = 0) {
            self.clock = clock
            self.cost = cost
        }

        func slot(_ priority: DrainPriority, every interval: TimeInterval = 0) -> DrainSlot {
            DrainSlot(
                pane: id, priority: priority, minInterval: interval,
                hasWork: { [box] in box.isDirty },
                apply: { [self] in
                    if let value = box.take() { applied.add(value) }
                    clock.advance(cost)
                })
        }
    }

    @Test("Slots apply in priority order: focused, attention, full, glance")
    func priorityOrder() {
        let clock = ManualClock()
        let drain = TileDrain(clock: clock, budget: 1)
        let glance = Pane(clock: clock)
        let full = Pane(clock: clock)
        let attention = Pane(clock: clock)
        let focused = Pane(clock: clock)
        let tokens = [
            drain.register(glance.slot(.glance)), drain.register(full.slot(.full)),
            drain.register(attention.slot(.attention)), drain.register(focused.slot(.focused)),
        ]
        for pane in [glance, full, attention, focused] { pane.box.post(1) }
        let outcome = drain.run()
        #expect(outcome.applied == [focused.id, attention.id, full.id, glance.id])
        #expect(outcome.leftover == 0)
        _ = tokens
    }

    @Test("Settled means silent: no dirty slot applies nothing and asks for nothing")
    func silentWhenSettled() {
        let clock = ManualClock()
        let drain = TileDrain(clock: clock)
        let pane = Pane(clock: clock)
        let token = drain.register(pane.slot(.full))
        clock.resetDrains()
        let outcome = drain.run()
        #expect(outcome == DrainOutcome())
        #expect(clock.drainRequests == 0)
        token.cancel()
    }

    @Test("The deadline stops the pass after at least one slot and leftovers ask for another drain")
    func deadlineAndLeftovers() {
        let clock = ManualClock()
        let drain = TileDrain(clock: clock, budget: 0.004)
        let panes = (0..<4).map { _ in Pane(clock: clock, cost: 0.003) }
        let tokens = panes.map { drain.register($0.slot(.full)) }
        for pane in panes { pane.box.post(1) }
        clock.resetDrains()
        let first = drain.run()
        #expect(first.applied.count == 2)
        #expect(first.leftover == 2)
        #expect(clock.drainRequests == 1)
        let second = drain.run()
        #expect(second.applied.count == 2)
        #expect(Set(first.applied + second.applied).count == 4)
        _ = tokens
    }

    @Test("A late frame still makes progress: one ready slot runs even past the deadline")
    func alwaysProgress() {
        let clock = ManualClock()
        let drain = TileDrain(clock: clock)
        let pane = Pane(clock: clock)
        let token = drain.register(pane.slot(.glance))
        pane.box.post(7)
        let outcome = drain.run(until: clock.now() - 10)
        #expect(outcome.applied == [pane.id])
        #expect(pane.applied.all == [7])
        token.cancel()
    }

    @Test("Peers of one class take turns when the budget only fits one")
    func rotation() {
        let clock = ManualClock()
        let drain = TileDrain(clock: clock, budget: 0.001)
        let panes = (0..<3).map { _ in Pane(clock: clock, cost: 0.002) }
        let tokens = panes.map { drain.register($0.slot(.full)) }
        var order: [PaneID] = []
        for _ in 0..<6 {
            for pane in panes { pane.box.post(1) }
            order += drain.run().applied
        }
        #expect(order.count == 6)
        let ids = panes.map(\.id)
        #expect(order == ids + ids)
        _ = tokens
    }

    @Test("A slot's minimum interval holds it back and reports when it is due")
    func minInterval() {
        let clock = ManualClock()
        let drain = TileDrain(clock: clock)
        let glance = Pane(clock: clock)
        let token = drain.register(glance.slot(.glance, every: 0.5))
        glance.box.post(1)
        #expect(drain.run().applied == [glance.id])
        glance.box.post(2)
        clock.advance(0.1)
        clock.resetDrains()
        let held = drain.run()
        #expect(held.applied.isEmpty)
        #expect(held.leftover == 0)
        #expect(held.wakeAt == clock.now() + 0.4)
        #expect(clock.drainRequests == 0)
        clock.advance(0.4)
        #expect(drain.run().applied == [glance.id])
        #expect(glance.applied.all == [1, 2])
        token.cancel()
    }

    @Test("A cancelled token stops its slot; cancelling twice is harmless")
    func tokenCancel() {
        let clock = ManualClock()
        let drain = TileDrain(clock: clock)
        let pane = Pane(clock: clock)
        let token = drain.register(pane.slot(.full))
        #expect(drain.count == 1)
        token.cancel()
        token.cancel()
        #expect(drain.count == 0)
        pane.box.post(1)
        #expect(drain.run().applied.isEmpty)
    }

    @Test("Registering a dirty slot and updating its priority ask for a drain")
    func registerWakes() {
        let clock = ManualClock()
        let drain = TileDrain(clock: clock)
        let pane = Pane(clock: clock)
        pane.box.post(1)
        clock.resetDrains()
        let token = drain.register(pane.slot(.glance))
        #expect(clock.drainRequests == 1)
        drain.update(token, to: pane.slot(.focused))
        #expect(clock.drainRequests == 2)
        let other = Pane(clock: clock)
        let second = drain.register(other.slot(.full))
        other.box.post(1)
        #expect(drain.run().applied == [pane.id, other.id])
        token.cancel()
        second.cancel()
    }
}
