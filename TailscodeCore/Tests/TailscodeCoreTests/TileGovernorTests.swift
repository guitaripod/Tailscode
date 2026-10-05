import Foundation
import Testing
@testable import TailscodeCore

@Suite("Tile governor")
struct TileGovernorTests {
    private static let focused = PaneID(raw: "focused")

    private static func chats(_ count: Int = 1) -> [PaneFacts] {
        [PaneFacts(id: focused, kind: .chat, focused: true, width: 800, height: 600, lastTouched: 0)]
            + (1..<max(1, count)).map {
                PaneFacts(id: PaneID(raw: "p\($0)"), kind: .chat, width: 400, height: 400)
            }
    }

    /// Runs the governor from `from` to `to` in `step`-second ticks, sampling `sample(t, level)`,
    /// and returns every transition with its time.
    private static func run(
        _ governor: inout TileGovernor, from: TimeInterval = 0, to: TimeInterval,
        step: TimeInterval = 0.5, panes: [PaneFacts] = chats(),
        sample: (TimeInterval, ShedLevel) -> GovernorSample
    ) -> [(TimeInterval, ShedTransition)] {
        var moves: [(TimeInterval, ShedTransition)] = []
        var time = from
        while time <= to + 1e-9 {
            let decision = governor.evaluate(
                now: time, sample: sample(time, governor.level), panes: panes, setting: .auto)
            if let move = decision.transition { moves.append((time, move)) }
            time += step
        }
        return moves
    }

    @Test("Busy at 0.65 for 3 s escalates one level, then needs a fresh 3 s")
    func escalateByBusy() {
        var governor = TileGovernor(cores: 8)
        let moves = Self.run(&governor, to: 6.5) { _, _ in GovernorSample(loopBusy: 0.7) }
        #expect(moves.map(\.0) == [3, 6.5])
        #expect(moves.map(\.1.to) == [.busy, .loaded])
        #expect(moves.first?.1.reason == .loopBusy(0.7))
        #expect(moves.first?.1.event == "shed 0→1 busy")
    }

    @Test("Busy at 0.85 for 1.5 s escalates two levels")
    func escalateByCriticalBusy() {
        var governor = TileGovernor(cores: 8)
        let moves = Self.run(&governor, to: 2) { _, _ in GovernorSample(loopBusy: 0.9) }
        #expect(moves.count == 1)
        #expect(moves.first?.0 == 1.5)
        #expect(moves.first?.1.from == .calm)
        #expect(moves.first?.1.to == .loaded)
    }

    @Test("A stall of 250 ms escalates two levels at once, at most once per 2 s")
    func escalateByStall() {
        var governor = TileGovernor(cores: 8)
        let moves = Self.run(&governor, to: 3) { time, _ in
            GovernorSample(loopBusy: 0.2, worstStall: [0.5, 1.0, 2.5].contains(time) ? 0.3 : 0)
        }
        #expect(moves.map(\.0) == [0.5, 2.5])
        #expect(moves.map(\.1.to) == [.loaded, .critical])
        #expect(moves.first?.1.event == "shed 0→2 stall 300ms")
    }

    @Test("The watchdog jumps straight to critical")
    func watchdog() {
        var governor = TileGovernor(cores: 8)
        let decision = governor.evaluate(
            now: 0, sample: GovernorSample(watchdog: true), panes: Self.chats(), setting: .auto)
        #expect(decision.level == .critical)
        #expect(decision.transition?.reason == .watchdog)
        #expect(decision.reasons == [.watchdog])
    }

    @Test("Floors follow the host, own memory, heat and low power, and lift when they clear",
        arguments: [
            (GovernorSample(host: .strained), ShedLevel.loaded, "memory"),
            (GovernorSample(host: .critical), .critical, "memory"),
            (GovernorSample(ownMemory: 0.7), .loaded, "own"),
            (GovernorSample(ownMemory: 0.9), .critical, "own"),
            (GovernorSample(ownMemory: 0.69), .calm, ""),
            (GovernorSample(thermal: .serious), .loaded, "warm"),
            (GovernorSample(thermal: .critical), .critical, "warm"),
            (GovernorSample(thermal: .fair), .calm, ""),
            (GovernorSample(lowPower: true), .busy, "lowpower"),
        ])
    func floors(sample: GovernorSample, level: ShedLevel, code: String) {
        var governor = TileGovernor(cores: 8)
        let decision = governor.evaluate(now: 0, sample: sample, panes: Self.chats(), setting: .auto)
        #expect(decision.level == level)
        #expect(decision.transition?.reason.code == (code.isEmpty ? nil : code))
        let cleared = governor.evaluate(now: 0.5, sample: GovernorSample(), panes: Self.chats(), setting: .auto)
        #expect(cleared.level == .calm)
        if level != .calm { #expect(cleared.transition?.reason == .relaxed) }
    }

    @Test("A held floor stands until its time, then lifts")
    func heldFloor() {
        var governor = TileGovernor(cores: 8)
        governor.hold(atLeast: .loaded, until: 600)
        #expect(governor.evaluate(now: 0, sample: GovernorSample(), panes: Self.chats(), setting: .auto).level == .loaded)
        #expect(governor.evaluate(now: 599, sample: GovernorSample(), panes: Self.chats(), setting: .auto).reasons == [.unclean])
        #expect(governor.evaluate(now: 600, sample: GovernorSample(), panes: Self.chats(), setting: .auto).level == .calm)
    }

    @Test("Relax waits 20 s below 0.30, then steps at most once per 15 s")
    func relax() {
        var governor = TileGovernor(cores: 8)
        let moves = Self.run(&governor, to: 60) { time, _ in
            GovernorSample(loopBusy: time <= 1.5 ? 0.9 : 0.1)
        }
        #expect(moves.map(\.1.to) == [.loaded, .busy, .calm])
        #expect(moves.map(\.0) == [1.5, 22, 37])
    }

    @Test("Two escalations inside two minutes double the relax delay, up to 120 s, and calm forgets it")
    func relaxDoubling() {
        var governor = TileGovernor(cores: 8)
        #expect(governor.currentRelaxDelay == 20)
        let rises = Self.run(&governor, to: 3) { _, _ in GovernorSample(loopBusy: 0.7) }
        #expect(rises.count == 1)
        #expect(governor.currentRelaxDelay == 20)
        _ = Self.run(&governor, from: 3.5, to: 6.5) { _, _ in GovernorSample(loopBusy: 0.7) }
        #expect(governor.level == .loaded)
        #expect(governor.currentRelaxDelay == 40)
        _ = Self.run(&governor, from: 7, to: 10) { _, _ in GovernorSample(loopBusy: 0.7) }
        #expect(governor.currentRelaxDelay == 80)
        _ = Self.run(&governor, from: 10.5, to: 13.5) { _, _ in GovernorSample(loopBusy: 0.7) }
        #expect(governor.level == .critical)
        #expect(governor.currentRelaxDelay == 120)
        _ = governor.evaluate(now: 613.5, sample: GovernorSample(), panes: Self.chats(), setting: .auto)
        #expect(governor.currentRelaxDelay == 20)
    }

    @Test("A doubled relax delay holds the level longer")
    func doubledDelayHolds() {
        var governor = TileGovernor(cores: 8)
        _ = governor.evaluate(now: 0, sample: GovernorSample(worstStall: 0.3), panes: Self.chats(), setting: .auto)
        _ = governor.evaluate(now: 2, sample: GovernorSample(worstStall: 0.3), panes: Self.chats(), setting: .auto)
        #expect(governor.level == .critical)
        let moves = Self.run(&governor, from: 2.5, to: 45) { _, _ in GovernorSample(loopBusy: 0.1) }
        #expect(moves.first?.0 == 42.5)
    }

    @Test("Ten minutes of load that a shed relieves settles instead of oscillating")
    func noOscillationSettling() {
        var governor = TileGovernor(cores: 8)
        let moves = Self.run(&governor, to: 600) { _, level in
            switch level {
            case .calm: return GovernorSample(loopBusy: 0.9)
            case .busy: return GovernorSample(loopBusy: 0.5)
            default: return GovernorSample(loopBusy: 0.2)
            }
        }
        #expect(moves.count == 2)
        #expect(governor.level == .busy)
    }

    @Test("Ten minutes of load that returns whenever the shed lifts is damped by the doubling")
    func noOscillationDamped() {
        var governor = TileGovernor(cores: 8)
        let moves = Self.run(&governor, to: 600) { _, level in
            GovernorSample(loopBusy: level == .calm ? 0.9 : 0.1)
        }
        let rises = moves.filter { $0.1.to > $0.1.from }.map(\.0)
        #expect(moves.count <= 24)
        #expect(governor.currentRelaxDelay == 120)
        let gaps = zip(rises.dropFirst(), rises).map { $0 - $1 }
        #expect(gaps.suffix(2).allSatisfy { $0 >= 120 })
    }

    @Test("Constant moderate load moves nothing for ten minutes")
    func constantLoad() {
        var governor = TileGovernor(cores: 8)
        let moves = Self.run(&governor, to: 600) { _, _ in GovernorSample(loopBusy: 0.5) }
        #expect(moves.isEmpty)
    }

    @Test("The full budget by cores, level and setting")
    func budgets() {
        #expect(TileGovernor(cores: 4).base == 2)
        #expect(TileGovernor(cores: 12).base == 3)
        #expect(TileGovernor(cores: 28).base == 4)
        let governor = TileGovernor(cores: 16)
        #expect(ShedLevel.allCases.map { governor.fullBudget(level: $0, setting: .auto) } == [4, 3, 1, 1, 1])
        #expect(TileGovernor(cores: 8).fullBudget(level: .busy, setting: .auto) == 2)
        #expect(governor.fullBudget(level: .calm, setting: .count(6)) == 6)
        #expect(governor.fullBudget(level: .loaded, setting: .count(6)) == 6)
        #expect(governor.fullBudget(level: .strained, setting: .count(6)) == 1)
        #expect(governor.fullBudget(level: .busy, setting: .all) == Int.max)
        #expect(governor.fullBudget(level: .critical, setting: .all) == 1)
    }

    @Test("The animation table and peer row windows by level, and reduced motion")
    func animationTable() {
        let rates = ShedLevel.allCases.map { TileGovernor.animation(level: $0, reducedMotion: false) }
        #expect(rates.map(\.tickCap) == [30, 30, 20, 10, 0])
        #expect(rates.map(\.glanceRate) == [4, 2, 1, 0.5, 0])
        #expect(rates.map(\.cascade) == [.focusedOnly, .focusedOnly, .instant, .off, .off])
        #expect(rates.map(\.pulses) == [true, true, true, false, false])
        #expect(rates[0].glanceInterval == 0.25)
        #expect(rates[4].glanceInterval == .infinity)
        #expect(ShedLevel.allCases.map(TileGovernor.peerRowWindow) == [150, 100, 60, 0, 0])
        let reduced = TileGovernor.animation(level: .calm, reducedMotion: true)
        #expect(!reduced.pulses)
        #expect(reduced.cascade == .instant)
        #expect(reduced.tickCap == 30)
        var governor = TileGovernor(cores: 8)
        let decision = governor.evaluate(
            now: 0, sample: GovernorSample(reducedMotion: true), panes: Self.chats(), setting: .auto)
        #expect(decision.level == .calm)
        #expect(!decision.animation.pulses)
    }

    @Test("Full slots go to pinned, then needs-you and failed, then touched running, then recent")
    func assignmentOrder() {
        let now: TimeInterval = 1000
        let panes = [
            PaneFacts(id: Self.focused, kind: .chat, focused: true, width: 800, height: 600, lastTouched: now),
            PaneFacts(id: PaneID(raw: "recent"), kind: .chat, width: 400, height: 400, lastTouched: now - 1),
            PaneFacts(id: PaneID(raw: "stale"), kind: .chat, width: 400, height: 400, attention: .running, lastTouched: now - 600),
            PaneFacts(id: PaneID(raw: "touched"), kind: .chat, width: 400, height: 400, attention: .running, lastTouched: now - 30),
            PaneFacts(id: PaneID(raw: "failed"), kind: .chat, width: 400, height: 400, attention: .failed, lastTouched: now - 900),
            PaneFacts(id: PaneID(raw: "asks"), kind: .chat, width: 400, height: 400, attention: .needsYou, lastTouched: now - 800),
            PaneFacts(id: PaneID(raw: "pinned"), kind: .chat, width: 400, height: 400, lastTouched: now - 1000, pinned: true),
        ]
        func full(_ setting: LiveBudget) -> Set<String> {
            var governor = TileGovernor(cores: 16)
            let decision = governor.evaluate(now: now, sample: GovernorSample(), panes: panes, setting: setting)
            return Set(decision.densities.filter { $0.value == .full }.map(\.key.raw))
        }
        #expect(full(.auto) == ["focused", "pinned", "asks", "failed"])
        #expect(full(.count(5)) == ["focused", "pinned", "asks", "failed", "touched"])
        #expect(full(.count(6)) == ["focused", "pinned", "asks", "failed", "touched", "recent"])
        #expect(full(.all).count == 7)
        var governor = TileGovernor(cores: 16)
        let decision = governor.evaluate(now: now, sample: GovernorSample(), panes: panes, setting: .auto)
        #expect(decision.liveChats == 4)
        #expect(decision.chats == 7)
        #expect(decision.fullBudget == 4)
        #expect(Set(decision.rowWindows.keys.map(\.raw)) == ["pinned", "asks", "failed"])
        #expect(decision.rowWindows.values.allSatisfy { $0 == 150 })
        #expect(decision.densities[PaneID(raw: "recent")] == .glance)
    }

    @Test("Pins are ignored at strained and the chip says the preference was overridden")
    func pinIgnoredAtStrained() {
        let panes = Self.chats() + [
            PaneFacts(id: PaneID(raw: "pinned"), kind: .chat, width: 400, height: 400, pinned: true)
        ]
        var governor = TileGovernor(cores: 16)
        let calm = governor.evaluate(now: 0, sample: GovernorSample(), panes: panes, setting: .auto)
        #expect(calm.densities[PaneID(raw: "pinned")] == .full)
        #expect(!calm.preferenceOverridden)
        governor.hold(atLeast: .strained, until: 100)
        let strained = governor.evaluate(now: 1, sample: GovernorSample(), panes: panes, setting: .auto)
        #expect(strained.level == .strained)
        #expect(strained.densities[PaneID(raw: "pinned")] == .glance)
        #expect(strained.densities[Self.focused] == .full)
        #expect(strained.preferenceOverridden)
        var allLive = TileGovernor(cores: 16)
        allLive.hold(atLeast: .critical, until: 100)
        #expect(allLive.evaluate(now: 0, sample: GovernorSample(), panes: Self.chats(3), setting: .all).preferenceOverridden)
    }

    @Test("A promoted pane dwells 8 s unless the budget drops")
    func dwell() {
        let a = PaneID(raw: "a")
        let b = PaneID(raw: "b")
        func panes(bAsks: Bool) -> [PaneFacts] {
            Self.chats() + [
                PaneFacts(id: a, kind: .chat, width: 400, height: 400, lastTouched: 5),
                PaneFacts(id: b, kind: .chat, width: 400, height: 400, attention: bAsks ? .needsYou : .quiet, lastTouched: 1),
            ]
        }
        var governor = TileGovernor(cores: 8)
        #expect(governor.evaluate(now: 0, sample: GovernorSample(), panes: panes(bAsks: false), setting: .auto).densities[a] == .full)
        let held = governor.evaluate(now: 4, sample: GovernorSample(), panes: panes(bAsks: true), setting: .auto)
        #expect(held.densities[a] == .full)
        #expect(held.densities[b] == .glance)
        let moved = governor.evaluate(now: 8, sample: GovernorSample(), panes: panes(bAsks: true), setting: .auto)
        #expect(moved.densities[b] == .full)
        #expect(moved.densities[a] == .glance)

        var dropping = TileGovernor(cores: 16)
        _ = dropping.evaluate(now: 0, sample: GovernorSample(), panes: panes(bAsks: false), setting: .auto)
        let dropped = dropping.evaluate(now: 1, sample: GovernorSample(host: .strained), panes: panes(bAsks: false), setting: .auto)
        #expect(dropped.fullBudget == 1)
        #expect(dropped.densities[a] == .glance)
        #expect(dropped.densities[b] == .glance)
    }

    @Test("Geometry demotes a small chat to glance, with 16 pt of hysteresis on the way back")
    func geometryHysteresis() {
        let id = PaneID(raw: "a")
        var governor = TileGovernor(cores: 8)
        func density(_ width: Double, _ height: Double = 400) -> PaneDensity? {
            governor.evaluate(
                now: 0, sample: GovernorSample(),
                panes: [PaneFacts(id: id, kind: .chat, focused: true, width: width, height: height)],
                setting: .auto
            ).densities[id]
        }
        #expect(density(300) == .full)
        #expect(density(285) == .full)
        #expect(density(279) == .glance)
        #expect(density(290) == .glance)
        #expect(density(296) == .full)
        #expect(density(296, 205) == .full)
        #expect(density(296, 199) == .glance)
        #expect(density(296, 210) == .glance)
        #expect(density(296, 216) == .full)
        #expect(FullDensityRule().allowsFull(width: 280, height: 200, wasAllowed: true))
    }

    @Test("Hidden panes park, an occluded window parks its chats and videos, slots follow their rules")
    func parking() {
        let hidden = PaneID(raw: "hidden")
        let web = PaneID(raw: "web")
        let empty = PaneID(raw: "empty")
        let v1 = PaneID(raw: "v1")
        let v2 = PaneID(raw: "v2")
        let panes = Self.chats(2) + [
            PaneFacts(id: hidden, kind: .chat, placed: false, width: 0, height: 0, attention: .needsYou),
            PaneFacts(id: web, kind: .web, width: 100, height: 100),
            PaneFacts(id: empty, kind: .empty, width: 100, height: 100),
            PaneFacts(id: v1, kind: .video, width: 400, height: 300),
            PaneFacts(id: v2, kind: .video, width: 400, height: 300),
        ]
        var governor = TileGovernor(cores: 8)
        let open = governor.evaluate(now: 0, sample: GovernorSample(), panes: panes, setting: .auto)
        #expect(open.densities[hidden] == .parked)
        #expect(open.densities[web] == .full)
        #expect(open.densities[empty] == .full)
        #expect(open.densities[v1] == .parked)
        #expect(open.densities[v2] == .parked)
        #expect(open.densities[Self.focused] == .full)
        let lone = governor.evaluate(
            now: 1, sample: GovernorSample(), panes: Self.chats() + [PaneFacts(id: v1, kind: .video, width: 400, height: 300)],
            setting: .auto)
        #expect(lone.densities[v1] == .full)
        let occluded = governor.evaluate(now: 2, sample: GovernorSample(occluded: true), panes: panes, setting: .auto)
        #expect(occluded.densities[Self.focused] == .parked)
        #expect(occluded.densities[PaneID(raw: "p1")] == .parked)
        #expect(occluded.densities[web] == .full)
        #expect(occluded.liveChats == 0)
    }

    @Test("Every level has a code, and the chip words name busy, memory and warm")
    func words() {
        #expect(ShedLevel.allCases.map(\.code) == ["calm", "busy", "loaded", "strained", "critical"])
        #expect(ShedReason.loopBusy(0.7).chipWord == "busy")
        #expect(ShedReason.hostMemory(.strained).chipWord == "memory")
        #expect(ShedReason.thermal(.serious).chipWord == "warm")
    }
}
