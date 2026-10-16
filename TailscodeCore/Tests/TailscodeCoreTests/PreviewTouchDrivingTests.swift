import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite struct PreviewTouchDrivingTests {
    private let centre = PreviewTouchPoint(x: 0.5, y: 0.5)

    private func chord(_ character: Character, shift: Bool = false, control: Bool = false, alt: Bool = false) -> KeyChord {
        var state: UInt32 = 0
        if shift { state |= KeyChord.shiftMask }
        if control { state |= KeyChord.controlMask }
        if alt { state |= KeyChord.altMask }
        return KeyChord.canonical(keyval: character.unicodeScalars.first!.value, state: state)!
    }

    @Test func theTouchPreferenceIsOnUntilTurnedOffAndRemembersBoth() throws {
        let suite = try #require(UserDefaults(suiteName: "preview-touch-\(UUID().uuidString)"))
        #expect(PreviewTouchPreference.isOn(defaults: suite))
        PreviewTouchPreference.set(false, defaults: suite)
        #expect(!PreviewTouchPreference.isOn(defaults: suite))
        PreviewTouchPreference.set(true, defaults: suite)
        #expect(PreviewTouchPreference.isOn(defaults: suite))
    }

    @Test func theControlsAppearOnlyWhereTheHostCanTouchAndTheLensIsLook() {
        func read(
            accepts: Bool = true, unsupported: Bool = false, phase: PreviewPhase = .live, lens: PreviewLens = .look,
            on: Bool = true
        ) -> PreviewTouchSurface {
            PreviewTouchSurface.read(acceptsTouch: accepts, unsupported: unsupported, phase: phase, lens: lens, touchOn: on)
        }
        let all = read()
        #expect(all.showsChips && all.pointerOperates && all.homeEnabled && all.keysSurvive)
        let none = read(accepts: false)
        #expect(!none.showsChips && !none.pointerOperates && !none.homeEnabled && !none.keysSurvive)
        #expect(!read(unsupported: true).showsChips)
        #expect(!read(on: false).pointerOperates && read(on: false).showsChips)
        #expect(!read(phase: .reconnecting).pointerOperates)
        #expect(!read(phase: .starting).homeEnabled)
        let inspecting = read(lens: .inspect)
        #expect(!inspecting.pointerOperates && !inspecting.showsChips && !inspecting.keysSurvive)
    }

    @Test func aNotchScrollsTheContentByASwipeAgainstIt() throws {
        var accumulator = PreviewScrollAccumulator()
        let down = accumulator.scroll(dx: 0, dy: 1, unit: .notches, at: centre, now: 10)
        guard case .swipe(let from, let to, let seconds) = try #require(down.gesture) else {
            Issue.record("a notch is a swipe")
            return
        }
        #expect(from.y > to.y)
        #expect(abs(from.x - 0.5) < 0.0001 && abs(to.x - 0.5) < 0.0001)
        #expect(abs((from.y + to.y) / 2 - 0.5) < 0.0001)
        #expect(abs((from.y - to.y) - PreviewScrollAccumulator.lengthPerNotch) < 0.0001)
        #expect(seconds > 0.2 && seconds < 0.5)
        var other = PreviewScrollAccumulator()
        guard case .swipe(let upFrom, let upTo, _) = try #require(other.scroll(dx: 0, dy: -1, unit: .notches, at: centre, now: 1).gesture) else {
            Issue.record("a notch the other way is a swipe")
            return
        }
        #expect(upFrom.y < upTo.y)
    }

    @Test func sidewaysScrollIsASidewaysSwipe() throws {
        var accumulator = PreviewScrollAccumulator()
        guard case .swipe(let from, let to, _) = try #require(accumulator.scroll(dx: 1, dy: 0.2, unit: .notches, at: centre, now: 1).gesture) else {
            Issue.record("a notch to the right is a swipe")
            return
        }
        #expect(from.x > to.x)
        #expect(abs(from.y - to.y) < 0.0001)
    }

    @Test func aSmoothDeltaIsHeldUntilItAddsUpToANotch() throws {
        var accumulator = PreviewScrollAccumulator()
        var swipes = 0
        for step in 0..<20 {
            let reading = accumulator.scroll(dx: 0, dy: 10, unit: .pixels, at: centre, now: 1 + Double(step) * 0.02)
            if reading.gesture != nil { swipes += 1 }
        }
        #expect(swipes >= 1 && swipes <= 3)
        var slow = PreviewScrollAccumulator()
        #expect(slow.scroll(dx: 0, dy: 10, unit: .pixels, at: centre, now: 1).gesture == nil)
        #expect(slow.scroll(dx: 0, dy: 10, unit: .pixels, at: centre, now: 1.05).gesture == nil)
    }

    @Test func atMostOneSwipeLeavesEveryGapAndTheRestIsKept() throws {
        var accumulator = PreviewScrollAccumulator()
        #expect(accumulator.scroll(dx: 0, dy: 1, unit: .notches, at: centre, now: 5).gesture != nil)
        let held = accumulator.scroll(dx: 0, dy: 1, unit: .notches, at: centre, now: 5.03)
        #expect(held.gesture == nil)
        let wait = try #require(held.flushAfter)
        #expect(abs(wait - 0.09) < 0.0001)
        #expect(accumulator.flush(at: centre, now: 5.06) == nil)
        #expect(accumulator.flush(at: centre, now: 5.13) != nil)
        #expect(accumulator.flush(at: centre, now: 5.5) == nil)
    }

    @Test func aLongPauseForgetsWhatWasLeftOver() {
        var accumulator = PreviewScrollAccumulator()
        #expect(accumulator.scroll(dx: 0, dy: 0.6, unit: .notches, at: centre, now: 1).gesture == nil)
        #expect(accumulator.scroll(dx: 0, dy: 0.6, unit: .notches, at: centre, now: 3).gesture == nil)
        #expect(accumulator.scroll(dx: 0, dy: 0.6, unit: .notches, at: centre, now: 3.1).gesture != nil)
    }

    @Test func aScrollNearAnEdgeSlidesInwardAndKeepsItsLength() throws {
        var accumulator = PreviewScrollAccumulator()
        guard case .swipe(let from, let to, _) = try #require(
            accumulator.scroll(dx: 0, dy: 3, unit: .notches, at: PreviewTouchPoint(x: 0.5, y: 0.98), now: 1).gesture)
        else {
            Issue.record("a swipe")
            return
        }
        #expect(max(from.y, to.y) <= 0.97 + 0.0001 && min(from.y, to.y) >= 0.03)
        #expect(abs((from.y - to.y) - 3 * PreviewScrollAccumulator.lengthPerNotch) < 0.0001)
    }

    @Test func aHugeScrollIsCapped() throws {
        var accumulator = PreviewScrollAccumulator()
        guard case .swipe(let from, let to, _) = try #require(accumulator.scroll(dx: 0, dy: 50, unit: .notches, at: centre, now: 1).gesture) else {
            Issue.record("a swipe")
            return
        }
        #expect(abs((from.y - to.y) - PreviewScrollAccumulator.longest) < 0.0001)
    }

    @Test func charactersTypedInABurstAreOneString() {
        var buffer = PreviewTypingBuffer()
        let began = buffer.type("h")
        let continued = buffer.type("i")
        #expect(began && !continued)
        #expect(!buffer.isEmpty)
        let flushed = buffer.flush()
        let again = buffer.flush()
        #expect(flushed == .text("hi"))
        #expect(again == nil && buffer.isEmpty)
        let restarted = buffer.type("a")
        #expect(restarted)
    }

    @Test func aNamedKeyEndsTheBurstAndGoesAfterIt() {
        var buffer = PreviewTypingBuffer()
        _ = buffer.type("o")
        _ = buffer.type("k")
        let ended = buffer.key("return")
        let alone = buffer.key("delete")
        #expect(ended == [.text("ok"), .key("return")])
        #expect(alone == [.key("delete")])
    }

    @Test func keysMeanWhatTheSimulatorKeyboardCanDo() {
        #expect(PreviewKeyReading.action(for: chord("a")) == .type("a"))
        #expect(PreviewKeyReading.action(for: chord("a", shift: true)) == .type("A"))
        #expect(PreviewKeyReading.action(for: chord("!", shift: true)) == .type("!"))
        #expect(PreviewKeyReading.action(for: chord("3")) == .type("3"))
        #expect(PreviewKeyReading.action(for: chord(" ")) == .type(" "))
        let enter = KeyChord.canonical(keyval: Keymap.enter, state: 0)!
        #expect(PreviewKeyReading.action(for: enter) == .key("return"))
        let keypadEnter = KeyChord.canonical(keyval: Keymap.keypadEnter, state: 0)!
        #expect(PreviewKeyReading.action(for: keypadEnter) == .key("return"))
        let backspace = KeyChord.canonical(keyval: Keymap.backspace, state: 0)!
        #expect(PreviewKeyReading.action(for: backspace) == .key("delete"))
        let delete = KeyChord.canonical(keyval: 0xFFFF, state: 0)!
        #expect(PreviewKeyReading.action(for: delete) == .key("delete"))
        let escape = KeyChord.canonical(keyval: Keymap.escape, state: 0)!
        #expect(PreviewKeyReading.action(for: escape) == .stopKeys)
        let keypadSeven = KeyChord.canonical(keyval: 0xFFB7, state: 0)!
        #expect(PreviewKeyReading.action(for: keypadSeven) == .type("7"))
    }

    @Test func chordsWithControlOrAltAndKeysWithoutACharacterAreTheWindows() {
        #expect(PreviewKeyReading.action(for: chord("a", control: true)) == nil)
        #expect(PreviewKeyReading.action(for: chord("a", alt: true)) == nil)
        #expect(PreviewKeyReading.action(for: KeyChord.canonical(keyval: Keymap.escape, state: KeyChord.controlMask)!) == nil)
        #expect(PreviewKeyReading.action(for: KeyChord.canonical(keyval: Keymap.tab, state: 0)!) == nil)
        #expect(PreviewKeyReading.action(for: KeyChord.canonical(keyval: Keymap.up, state: 0)!) == nil)
    }

    @Test func aCharacterTheKeyboardLacksIsTakenAndAnswered() {
        let accented = KeyChord.canonical(keyval: 0x00E9, state: 0)!
        #expect(PreviewKeyReading.action(for: accented) == .cannotType)
    }

    @Test func theQueueIsFirstInFirstOutAndKeepsTextAfterTheTapsBeforeIt() {
        var queue = PreviewTouchQueue()
        queue.enqueue(PreviewTouchItem(ids: [1], kind: .pointer(.tap(centre))))
        queue.enqueue(PreviewTouchItem(ids: [2], kind: .text("a")))
        queue.enqueue(PreviewTouchItem(ids: [3], kind: .text("b")))
        queue.enqueue(PreviewTouchItem(ids: [4], kind: .key("return")))
        #expect(queue.count == 3)
        #expect(queue.dequeue()?.request == .tap(x: 0.5, y: 0.5))
        #expect(queue.dequeue() == PreviewTouchItem(ids: [2, 3], kind: .text("ab")))
        #expect(queue.dequeue()?.request == .key("return"))
        #expect(queue.dequeue() == nil && queue.isEmpty)
    }

    @Test func wheelSwipesInOneDirectionBecomeOneLongerSwipe() throws {
        func wheel(_ notches: Double, id: Int) -> PreviewTouchItem {
            PreviewTouchItem(ids: [id], kind: .wheel(PreviewScrollAccumulator.swipe(notches: notches, vertical: true, centre: centre)))
        }
        var queue = PreviewTouchQueue()
        queue.enqueue(wheel(1, id: 1))
        queue.enqueue(wheel(1, id: 2))
        #expect(queue.count == 1)
        let first = queue.dequeue()
        let joined = try #require(first)
        #expect(joined.ids == [1, 2])
        guard case .wheel(.swipe(let from, let to, _)) = joined.kind else {
            Issue.record("a wheel swipe")
            return
        }
        #expect(abs((from.y - to.y) - 2 * PreviewScrollAccumulator.lengthPerNotch) < 0.0001)
        queue.enqueue(wheel(1, id: 3))
        queue.enqueue(wheel(-1, id: 4))
        #expect(queue.count == 2)
    }

    @Test func aTapBetweenTwoScrollsKeepsThemApart() {
        let wheel = PreviewTouchItem(ids: [1], kind: .wheel(PreviewScrollAccumulator.swipe(notches: 1, vertical: true, centre: centre)))
        var queue = PreviewTouchQueue()
        queue.enqueue(wheel)
        queue.enqueue(PreviewTouchItem(ids: [2], kind: .pointer(.tap(centre))))
        queue.enqueue(wheel)
        #expect(queue.count == 3)
    }

    @Test func aRunawayQueueGivesUpItsOldestScrollsFirst() {
        var queue = PreviewTouchQueue()
        queue.enqueue(PreviewTouchItem(ids: [0], kind: .pointer(.tap(centre))))
        var dropped: [Int] = []
        for id in 1...(PreviewTouchQueue.capacity + 5) {
            let kind: PreviewTouchItem.Kind =
                id % 2 == 0
                ? .pointer(.tap(PreviewTouchPoint(x: Double(id) / 100, y: 0.5)))
                : .wheel(.swipe(from: PreviewTouchPoint(x: Double(id) / 100, y: 0.6), to: PreviewTouchPoint(x: Double(id) / 100, y: 0.5), seconds: 0.2))
            dropped += queue.enqueue(PreviewTouchItem(ids: [id], kind: kind))
        }
        #expect(queue.count == PreviewTouchQueue.capacity)
        #expect(dropped.count == 6)
        #expect(queue.pending.first?.ids == [0])
        #expect(dropped.allSatisfy { $0 % 2 == 1 })
        #expect(queue.clear().count == PreviewTouchQueue.capacity)
        #expect(queue.isEmpty)
    }

    @Test func aRingOpensAtThePressAndFadesOnceTheTouchIsDelivered() throws {
        var feedback = PreviewTouchFeedback()
        feedback.press(id: 1, at: PreviewTouchPoint(x: 0.3, y: 0.7), now: 100)
        let early = try #require(feedback.frame(at: 100.05, reducedMotion: false).rings.first)
        let later = try #require(feedback.frame(at: 100.30, reducedMotion: false).rings.first)
        #expect(early.x == 0.3 && early.y == 0.7)
        #expect(later.radius > early.radius)
        #expect(!early.busy && !later.busy)
        feedback.finish([1], now: 100.19)
        let opened = try #require(feedback.frame(at: 100.40, reducedMotion: false).rings.first)
        #expect(abs(opened.radius - PreviewTouchFeedback.largestRadius) < 0.0001)
        let fading = try #require(feedback.frame(at: 100.55, reducedMotion: false).rings.first)
        #expect(fading.alpha < opened.alpha)
        #expect(feedback.frame(at: 100.71, reducedMotion: false).rings.isEmpty)
        feedback.prune(now: 100.71)
        #expect(feedback.isEmpty)
        #expect(feedback.frame(at: 100.71, reducedMotion: false).settled)
    }

    @Test func aTouchTheHostIsStillWorkingOnTurnsToACalmBusyRing() throws {
        var feedback = PreviewTouchFeedback()
        feedback.press(id: 1, at: PreviewTouchPoint(x: 0.5, y: 0.5), now: 0)
        let holding = try #require(feedback.frame(at: 0.5, reducedMotion: false).rings.first)
        #expect(!holding.busy)
        feedback.lift(1)
        let first = try #require(feedback.frame(at: 0.5, reducedMotion: false).rings.first)
        let second = try #require(feedback.frame(at: 1.1, reducedMotion: false).rings.first)
        #expect(first.busy && second.busy)
        #expect(first.angle != second.angle)
        #expect(first.radius == second.radius && first.alpha == second.alpha)
        feedback.finish([1], now: 1.6)
        let after = try #require(feedback.frame(at: 1.75, reducedMotion: false).rings.first)
        #expect(!after.busy && after.alpha < first.alpha)
        #expect(feedback.frame(at: 2.0, reducedMotion: false).rings.isEmpty)
    }

    @Test func reducedMotionKeepsTheRingStillAndOnlyChangesItsLight() throws {
        var feedback = PreviewTouchFeedback()
        feedback.press(id: 1, at: PreviewTouchPoint(x: 0.5, y: 0.5), now: 0)
        feedback.lift(1)
        let opening = try #require(feedback.frame(at: 0.05, reducedMotion: true).rings.first)
        let opened = try #require(feedback.frame(at: 0.3, reducedMotion: true).rings.first)
        #expect(opening.radius == opened.radius && opening.alpha == opened.alpha)
        let early = try #require(feedback.frame(at: 0.5, reducedMotion: true).rings.first)
        let late = try #require(feedback.frame(at: 1.7, reducedMotion: true).rings.first)
        #expect(early.busy && early.angle == 0 && late.angle == 0 && early.radius == late.radius)
        feedback.finish([1], now: 2)
        let fading = try #require(feedback.frame(at: 2.15, reducedMotion: true).rings.first)
        #expect(fading.radius == early.radius && fading.alpha < early.alpha)
    }

    @Test func aTouchNeverAnsweredIsGivenUpOn() {
        var feedback = PreviewTouchFeedback()
        feedback.press(id: 1, at: centre, now: 0)
        feedback.prune(now: 5)
        #expect(!feedback.isEmpty)
        feedback.prune(now: PreviewTouchFeedback.abandonAfter + 1)
        #expect(feedback.isEmpty)
    }

    @Test func aDragLeavesATrailThatFadesAfterTheFingerLifts() throws {
        var feedback = PreviewTouchFeedback()
        feedback.beginDrag(at: PreviewTouchPoint(x: 0.5, y: 0.8), now: 0)
        feedback.drag(to: PreviewTouchPoint(x: 0.5, y: 0.8001), now: 0.01)
        feedback.drag(to: PreviewTouchPoint(x: 0.5, y: 0.6), now: 0.05)
        feedback.drag(to: PreviewTouchPoint(x: 0.5, y: 0.4), now: 0.1)
        let live = feedback.frame(at: 0.1, reducedMotion: false).trail
        #expect(live.count == 3)
        #expect(live[2].alpha > live[0].alpha)
        feedback.endDrag(now: 0.12)
        let fading = feedback.frame(at: 0.2, reducedMotion: false).trail
        #expect(fading.count == 3 && fading[2].alpha < live[2].alpha)
        #expect(feedback.frame(at: 0.6, reducedMotion: false).trail.isEmpty)
        feedback.prune(now: 0.6)
        #expect(feedback.isEmpty)
        feedback.drag(to: centre, now: 1)
        #expect(feedback.frame(at: 1, reducedMotion: false).trail.count == 1)
    }

    @Test func clearingDropsEverythingAtOnce() {
        var feedback = PreviewTouchFeedback()
        feedback.press(id: 1, at: centre, now: 0)
        feedback.beginDrag(at: centre, now: 0)
        feedback.clear()
        #expect(feedback.isEmpty)
    }
}
