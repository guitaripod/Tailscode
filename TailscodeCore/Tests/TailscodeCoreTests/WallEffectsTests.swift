import Foundation
import Testing

@testable import TailscodeCore

private func event(_ kind: WallEvent.Kind, _ tile: String = "a", worker: String? = nil) -> WallEvent {
    WallEvent(kind: kind, tile: tile, worker: worker)
}

private func played(
    _ events: [WallEvent], at t: TimeInterval = 10, style: WallStyle = .studio,
    contexts: [String: (from: Double, to: Double)] = [:]
) -> [WallEffect] {
    var queue = WallEffectQueue()
    queue.add(events, at: t, style: style, contexts: contexts)
    return queue.live
}

private func effect(
    _ kind: WallEffect.Kind = .pulse, tile: String = "a", start: TimeInterval = 0,
    duration: TimeInterval = 5, isProtected: Bool? = nil
) -> WallEffect {
    WallEffect(
        kind: kind, tile: tile, start: start, duration: duration, ink: .working, isProtected: isProtected)
}

@Suite struct WallEffectMappingTests {
    @Test func aStepIsASparkInTheTilesColour() {
        let made = played([event(.step)])
        #expect(made.count == 1)
        #expect(made[0].kind == .spark && made[0].duration == 0.45 && made[0].ink == .tile)
        #expect(made[0].start == 10 && made[0].amplitude == 1 && made[0].tile == "a")
    }

    @Test func aWorkerStartingIsAThreadAndEndingIsADissolve() {
        let thread = played([event(.workerStarted, worker: "w")])
        #expect(thread.map(\.kind) == [.thread] && thread[0].duration == 1.1)
        #expect(thread[0].ink == .working && thread[0].worker == "w")
        let dissolve = played([event(.workerEnded, worker: "w")])
        #expect(dissolve.map(\.kind) == [.dissolve] && dissolve[0].duration == 1.5)
        #expect(dissolve[0].ink == .dim && dissolve[0].worker == "w")
    }

    @Test func finishingExhalesAndRipplesTheGround() {
        let made = played([event(.finished)])
        #expect(made.map(\.kind) == [.exhale, .groundRipple])
        #expect(made.map(\.duration) == [1.8, 2.2])
        #expect(made.allSatisfy { $0.ink == .finished && !$0.isProtected })
    }

    @Test func stoppedIsADimPulse() {
        let made = played([event(.stopped)])
        #expect(made.map(\.kind) == [.pulse] && made[0].duration == 1.0 && made[0].ink == .dim)
    }

    @Test func anAskKnocksTwiceThirtyFourHundredthsApart() {
        let made = played([event(.asked)], at: 20)
        #expect(made.map(\.kind) == [.knock, .knock])
        #expect(made.map(\.start) == [20, 20.34])
        #expect(made.allSatisfy { $0.duration == 1.3 && $0.ink == .needs && $0.isProtected })
        #expect(made[0].seed != made[1].seed)
    }

    @Test func answeringIsApprovedInTheWorkingColour() {
        let made = played([event(.answered)])
        #expect(made.map(\.kind) == [.approved] && made[0].duration == 1.4 && made[0].ink == .working)
    }

    @Test func aFailureFracturesAndRipplesRedAndNeverGetsDropped() {
        let made = played([event(.failed)])
        #expect(made.map(\.kind) == [.fracture, .groundRipple])
        #expect(made.map(\.duration) == [1.6, 2.4])
        #expect(made.allSatisfy { $0.ink == .failed && $0.isProtected })
    }

    @Test func retriesPulseAmberAndComingBackPulsesWorking() {
        let retry = played([event(.retried)])
        #expect(retry.map(\.kind) == [.pulse] && retry[0].duration == 1.2 && retry[0].ink == .needs)
        for kind in [WallEvent.Kind.resumed, .back] {
            let back = played([event(kind)])
            #expect(back.map(\.kind) == [.pulse] && back[0].duration == 1.0 && back[0].ink == .working)
        }
    }

    @Test func arrivalsGatherAndDeparturesScatter() {
        let joined = played([event(.joined)])
        #expect(joined.map(\.kind) == [.gather] && joined[0].duration == 1.3 && joined[0].ink == .tile)
        let left = played([event(.left)])
        #expect(left.map(\.kind) == [.scatter] && left[0].duration == 1.2 && left[0].ink == .tile)
    }

    @Test func goingQuietAwayOrStuckMakesNoGesture() {
        for kind in [WallEvent.Kind.quiet, .away, .workerQuiet, .workerStuck] {
            #expect(played([event(kind, worker: "w")]).isEmpty)
        }
    }

    @Test func aCompactionDrainsFromTheContextTheCallerKnows() {
        let made = played([event(.compacted)], contexts: ["a": (from: 0.9, to: 0.2)])
        #expect(made.map(\.kind) == [.drain] && made[0].duration == 2.6)
        #expect(made[0].from == 0.9 && made[0].to == 0.2)
        #expect(played([event(.compacted)]).isEmpty)
        #expect(played([event(.compacted, "b")], contexts: ["a": (from: 0.9, to: 0.2)]).isEmpty)
    }

    @Test func theDrainStillPlaysAtZeroWhenEffectsAreOffOrTheMoveIsOff() {
        let contexts = ["a": (from: 0.9, to: 0.2)]
        let off = played([event(.compacted)], style: .studio.with { $0.effects = .off }, contexts: contexts)
        #expect(off.map(\.kind) == [.drain] && off[0].amplitude == 0)
        let night = played([event(.compacted)], style: .nightDesk, contexts: contexts)
        #expect(night.map(\.kind) == [.drain] && night[0].amplitude == 0)
        let lively = played([event(.compacted)], style: .showcase, contexts: contexts)
        #expect(lively[0].amplitude == 1.6)
    }

    @Test func livelyScalesTheAmplitudeAndOffDropsEverythingElse() {
        #expect(played([event(.asked)], style: .showcase).allSatisfy { $0.amplitude == 1.6 })
        let off = WallStyle.studio.with { $0.effects = .off }
        let all = WallEvent.Kind.allCases.filter { $0 != .compacted }.map { event($0, worker: "w") }
        #expect(played(all, style: off).isEmpty)
    }

    @Test func aMoveSwitchedOffMakesNothing() {
        let nightDesk = WallStyle.nightDesk
        #expect(played([event(.step), event(.joined, "b"), event(.workerStarted, worker: "w")], style: nightDesk).isEmpty)
        #expect(!played([event(.asked), event(.failed, "b"), event(.finished, "c")], style: nightDesk).isEmpty)
    }

    @Test func stillDropsTheMovingOnesAndFadesTheRest() {
        let still = WallStyle.studio.with { $0.still = true }
        for kind in [WallEvent.Kind.step, .workerStarted, .workerEnded, .joined, .left] {
            #expect(played([event(kind, worker: "w")], style: still).isEmpty)
        }
        let kinds: [WallEvent.Kind] = [.finished, .stopped, .asked, .answered, .failed, .retried, .resumed, .back]
        for kind in kinds {
            let made = played([event(kind)], style: still)
            #expect(made.count == 1)
            #expect(made[0].kind == .fade && made[0].duration == 0.8)
        }
        #expect(played([event(.asked)], style: still)[0].isProtected)
        #expect(played([event(.failed)], style: still)[0].isProtected)
        let drain = played([event(.compacted)], style: still, contexts: ["a": (from: 0.8, to: 0.1)])
        #expect(drain.map(\.kind) == [.drain])
    }

    @Test func seedsAreStableAndDifferByTileKindAndMoment() {
        let one = played([event(.finished)], at: 3)
        let again = played([event(.finished)], at: 3)
        #expect(one.map(\.seed) == again.map(\.seed))
        #expect(one[0].seed != one[1].seed)
        #expect(played([event(.finished, "b")], at: 3)[0].seed != one[0].seed)
        #expect(played([event(.finished)], at: 4)[0].seed != one[0].seed)
    }
}

@Suite struct WallEffectTimingTests {
    @Test func progressClampsAndWaitsForItsStart() {
        let made = effect(start: 10, duration: 2)
        #expect(made.progress(at: 5) == 0 && !made.isStarted(at: 5))
        #expect(made.isStarted(at: 10) && made.progress(at: 10) == 0)
        #expect(made.progress(at: 11) == 0.5)
        #expect(made.progress(at: 12) == 1 && made.progress(at: 99) == 1)
    }

    @Test func onlyAsksAndFailuresAreProtected() {
        #expect(effect(.knock).isProtected && effect(.fracture).isProtected)
        #expect(WallEffect(kind: .groundRipple, tile: "a", start: 0, duration: 1, ink: .failed).isProtected)
        #expect(!WallEffect(kind: .groundRipple, tile: "a", start: 0, duration: 1, ink: .finished).isProtected)
        #expect(!effect(.pulse).isProtected && !effect(.spark).isProtected)
    }
}

@Suite struct WallEffectQueueTests {
    @Test func aBurstOfStepsCoalescesToOneSparkPerTile() {
        var queue = WallEffectQueue()
        queue.add([event(.step), event(.step), event(.step, "b")], at: 10, style: .studio)
        #expect(queue.live.count == 2)
        queue.add([event(.step)], at: 10.4, style: .studio)
        #expect(queue.live.count == 2)
        queue.add([event(.step)], at: 10.5, style: .studio)
        #expect(queue.live.count == 3)
        #expect(queue.live.filter { $0.tile == "a" }.count == 2)
    }

    @Test func aTileHoldsThreeAndDropsItsOldestUnprotectedForANewOne() {
        var queue = WallEffectQueue()
        for index in 0..<3 { queue.add(effect(.pulse, start: Double(index))) }
        queue.add(effect(.exhale, start: 3))
        #expect(queue.live.map(\.start) == [1, 2, 3])
        queue.add(effect(.pulse, tile: "b", start: 4))
        #expect(queue.live.count == 4)
    }

    @Test func aTileFullOfProtectedEffectsRefusesAnUnprotectedOneButTakesAProtectedOne() {
        var queue = WallEffectQueue()
        for index in 0..<3 { queue.add(effect(.knock, start: Double(index))) }
        queue.add(effect(.pulse, start: 5))
        #expect(queue.live.count == 3 && queue.live.allSatisfy { $0.kind == .knock })
        queue.add(effect(.fracture, start: 6))
        #expect(queue.live.count == 4 && queue.live.last?.kind == .fracture)
    }

    @Test func aTileMakesRoomByDroppingTheOldestUnprotectedNotAProtectedOne() {
        var queue = WallEffectQueue()
        queue.add(effect(.knock, start: 0))
        queue.add(effect(.pulse, start: 1))
        queue.add(effect(.pulse, start: 2))
        queue.add(effect(.exhale, start: 3))
        #expect(queue.live.map(\.start) == [0, 2, 3])
    }

    @Test func theWholeWallHoldsFortyAndDropsTheOldestUnprotected() {
        var queue = WallEffectQueue()
        for index in 0..<40 { queue.add(effect(.pulse, tile: "t\(index)", start: Double(index))) }
        #expect(queue.live.count == 40)
        queue.add(effect(.pulse, tile: "new", start: 100))
        #expect(queue.live.count == 40)
        #expect(queue.live.first?.tile == "t1" && queue.live.last?.tile == "new")
    }

    @Test func aFullWallOfProtectedEffectsRefusesTheUnprotectedAndStillTakesAProtectedOne() {
        var queue = WallEffectQueue()
        for index in 0..<40 { queue.add(effect(.knock, tile: "t\(index)", start: Double(index))) }
        queue.add(effect(.pulse, tile: "new", start: 100))
        #expect(queue.live.count == 40 && !queue.live.contains { $0.tile == "new" })
        queue.add(effect(.fracture, tile: "new", start: 101))
        #expect(queue.live.count == 41 && queue.live.last?.tile == "new")
        #expect(queue.live.filter { $0.kind == .knock }.count == 40)
    }

    @Test func aRefusedEffectLeavesTheQueueAsItWas() {
        var queue = WallEffectQueue()
        queue.add(effect(.pulse, tile: "t", start: 0))
        for index in 0..<2 { queue.add(effect(.knock, tile: "t", start: Double(index + 1))) }
        let before = queue.live
        for index in 0..<37 { queue.add(effect(.knock, tile: "k\(index)", start: 10)) }
        queue.add(effect(.pulse, tile: "t", start: 50))
        #expect(queue.live.contains { $0.tile == "t" && $0.kind == .pulse && $0.start == 50 })
        #expect(!queue.live.contains(before[0]))
        let full = queue.live
        queue.add(effect(.pulse, tile: "x", start: 60))
        #expect(queue.live.count == full.count)
    }

    @Test func pruneDropsTheEndedAndKeepsTheRest() {
        var queue = WallEffectQueue()
        queue.add(effect(.pulse, tile: "a", start: 0, duration: 1))
        queue.add(effect(.pulse, tile: "b", start: 0, duration: 3))
        queue.add(effect(.pulse, tile: "c", start: 5, duration: 1))
        queue.prune(at: 2)
        #expect(queue.live.map(\.tile) == ["b", "c"])
        #expect(queue.isActive(at: 2) && !queue.isEmpty)
        queue.prune(at: 9)
        #expect(queue.isEmpty && !queue.isActive(at: 9))
    }

    @Test func aQueueIsActiveUntilItsLastEffectEnds() {
        var queue = WallEffectQueue()
        #expect(!queue.isActive(at: 0))
        queue.add([event(.asked)], at: 0, style: .studio)
        #expect(queue.isActive(at: 1.6))
        #expect(!queue.isActive(at: 1.7))
    }
}
