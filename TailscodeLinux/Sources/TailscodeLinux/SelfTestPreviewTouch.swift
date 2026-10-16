import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

private func previewPump(_ seconds: Double, until done: () -> Bool = { false }) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        while g_main_context_iteration(nil, 0) != 0 {}
        if done() { return true }
        usleep(4000)
    }
    return done()
}

/// What the host would have received, in the order it arrived, and how long each request is held
/// before it answers.
private final class TouchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [TouchRequest] = []
    private var failure: Error?
    private var hold: UInt64 = 0

    var all: [TouchRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    var count: Int { all.count }

    func reset() {
        lock.lock()
        requests = []
        lock.unlock()
    }

    func holdEach(milliseconds: UInt64) {
        lock.lock()
        hold = milliseconds
        lock.unlock()
    }

    func failWith(_ error: Error?) {
        lock.lock()
        failure = error
        lock.unlock()
    }

    private func settings() -> (hold: UInt64, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (hold, failure)
    }

    private func record(_ request: TouchRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    var sink: PreviewTouchSink {
        { [self] request in
            let now = settings()
            if now.hold > 0 { try await Task.sleep(for: .milliseconds(now.hold)) }
            record(request)
            if let error = now.error { throw error }
        }
    }
}

extension SelfTest {
    /// Operating the running app from the picture, with a recording sink standing in for the host:
    /// where a press lands, tap against swipe, the wheel, the keyboard and its rules, the ring that
    /// answers a touch and the busy ring that waits, what hides the controls, and that a pane which
    /// is parked or left owns no task, clock or queued touch.
    static func checkPreviewTouch() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("preview: touch: \(label)") }
            checks += 1
        }
        func near(_ value: Double, _ expected: Double) -> Bool { abs(value - expected) < 0.01 }
        func chord(_ character: Character, shift: Bool = false, control: Bool = false) -> KeyChord {
            var state: UInt32 = 0
            if shift { state |= KeyChord.shiftMask }
            if control { state |= KeyChord.controlMask }
            return KeyChord.canonical(keyval: character.unicodeScalars.first?.value ?? 0x61, state: state)!
        }
        guard var live = PreviewFixtures.state("live") else { throw SelfTestFailure("preview: no live fixture") }
        let tiny = PreviewFixtures.tinyJPEG
        let target = PreviewTarget(host: "mac.local", project: PreviewFixtures.project)
        let stored = PreviewTouchPreference.isOn()
        defer { PreviewTouchPreference.set(stored) }
        PreviewTouchPreference.set(true)

        let silent = PreviewPane(target: target, runs: false)
        silent.applyForTest(live, jpeg: tiny)
        try expect(!silent.touchChipsShown, "a host that cannot touch shows no Touch, Home or Keys")
        try expect(!silent.touchLayerView.isOperating, "and the picture takes no pointer")
        silent.setKeys(true)
        try expect(!silent.keysOn, "Keys cannot be turned on")
        silent.shutdown()

        live.acceptsTouch = true
        let pane = PreviewPane(target: target, runs: false)
        let log = TouchLog()
        pane.useTouchSink(log.sink)
        pane.applyForTest(live, jpeg: tiny)
        let layer = pane.touchLayerView
        try expect(pane.touchChipsShown && layer.isOperating, "a host that can touch shows the controls and takes the pointer")
        try expect(tailscode_touch_active(layer.widget) != 0, "the picture shows the pointer cursor")
        let wide = 120.0
        let tall = 260.0

        layer.point(kind: 0, fx: 0.5, fy: 0.5, width: wide, height: tall)
        let pressed = layer.plan(width: 120, height: 260)
        try expect(pressed.rings.count == 1, "a press draws a ring at once")
        try expect(
            near(pressed.rings[0][0], 60) && near(pressed.rings[0][1], 130), "and puts it under the pointer: \(pressed.rings)")
        try expect(layer.hasTick, "a ring that is moving owns the frame clock")
        layer.point(kind: 2, fx: 0.5, fy: 0.5, width: wide, height: tall)
        try expect(previewPump(2, until: { log.count == 1 }), "a tap reaches the host")
        try expect(log.all.first == .tap(x: 0.5, y: 0.5), "as a tap at the middle of the picture: \(log.all)")
        try expect(
            previewPump(2, until: { layer.advance(); return !layer.hasTick && layer.plan(width: 120, height: 260).rings.isEmpty }),
            "the ring fades and the clock is given back")

        log.reset()
        layer.point(kind: 0, fx: 0.01, fy: 0.5, width: 240, height: 260)
        layer.point(kind: 2, fx: 0.5, fy: 0.5, width: 240, height: 260)
        try expect(!previewPump(0.3, until: { log.count > 0 }), "a press on the margin beside the picture does nothing")
        try expect(layer.plan(width: 240, height: 260).rings.isEmpty, "and draws nothing")

        layer.point(kind: 0, fx: 0.5, fy: 0.8, width: wide, height: tall)
        layer.point(kind: 1, fx: 0.5, fy: 0.55, width: wide, height: tall)
        layer.point(kind: 1, fx: 0.5, fy: 0.3, width: wide, height: tall)
        let dragged = layer.plan(width: 120, height: 260)
        try expect(dragged.trail.count >= 2, "a drag leaves a line behind the pointer: \(dragged.trail.count)")
        usleep(150_000)
        layer.point(kind: 2, fx: 0.5, fy: 0.3, width: wide, height: tall)
        try expect(previewPump(2, until: { log.count == 1 }), "a drag reaches the host once, on release")
        let swipe = log.all.first
        try expect(
            swipe?.action == .swipe && near(swipe?.x ?? -1, 0.5) && near(swipe?.y ?? -1, 0.8)
                && near(swipe?.toX ?? -1, 0.5) && near(swipe?.toY ?? -1, 0.3),
            "as a swipe between the two points: \(log.all)")
        try expect((swipe?.seconds ?? 0) >= PreviewTouchReading.shortestSwipe, "taking as long as the hand took")
        _ = previewPump(1.2, until: { layer.advance(); return !layer.hasTick })

        log.reset()
        layer.point(kind: 0, fx: 0.4, fy: 0.4, width: wide, height: tall)
        layer.point(kind: 1, fx: 0.42, fy: 0.4, width: wide, height: tall)
        layer.point(kind: 2, fx: 0.42, fy: 0.4, width: wide, height: tall)
        try expect(previewPump(2, until: { log.count == 1 }), "a press that barely moved still reaches the host")
        try expect(log.all.first?.action == .tap, "as a tap, because a hand never holds perfectly still")
        _ = previewPump(1.2, until: { layer.advance(); return !layer.hasTick })

        log.reset()
        layer.point(kind: 4, fx: 0.5, fy: 0.5, a: 0, b: 1, width: wide, height: tall)
        try expect(previewPump(2, until: { log.count == 1 }), "a wheel notch reaches the host")
        let notch = log.all.first
        try expect(
            notch?.action == .swipe && (notch?.y ?? 0) > (notch?.toY ?? 1) && near(notch?.x ?? -1, 0.5),
            "as a swipe upward, the way a finger scrolls the content up: \(log.all)")
        _ = previewPump(0.2)
        log.reset()
        for _ in 0..<3 { layer.point(kind: 4, fx: 0.5, fy: 0.5, a: 0, b: -1, width: wide, height: tall) }
        _ = previewPump(0.6)
        try expect(log.count == 2, "three quick notches are one swipe now and the rest a moment later, not three: \(log.count)")
        let back = log.all.last
        try expect(back?.action == .swipe && (back?.toY ?? 0) > (back?.y ?? 1), "and the other way for a notch the other way")
        log.reset()
        layer.point(kind: 5, fx: 0.5, fy: 0.5, a: 0, b: 12, width: wide, height: tall)
        _ = previewPump(0.3)
        try expect(log.count == 0, "a smooth scroll too small to be a notch waits")
        _ = previewPump(1.2, until: { layer.advance(); return !layer.hasTick })

        log.reset()
        pane.setKeys(true)
        try expect(pane.keysOn, "Keys turns on over a live picture")
        try expect(pane.forwardKey(chord("h")) && pane.forwardKey(chord("i", shift: true)), "typed characters are taken")
        try expect(previewPump(1, until: { log.count == 1 }), "a burst of characters is sent")
        _ = previewPump(0.2)
        try expect(log.all == [.text("hI")], "as one string, in order, with shift kept: \(log.all)")
        log.reset()
        _ = pane.forwardKey(chord("o"))
        _ = pane.forwardKey(chord("k"))
        _ = pane.forwardKey(KeyChord.canonical(keyval: Keymap.enter, state: 0) ?? chord("o"))
        _ = pane.forwardKey(KeyChord.canonical(keyval: Keymap.backspace, state: 0) ?? chord("o"))
        try expect(previewPump(1, until: { log.count == 3 }), "Return and Delete are sent")
        try expect(log.all == [.text("ok"), .key("return"), .key("delete")], "after the characters before them: \(log.all)")
        log.reset()
        _ = pane.forwardKey(chord("2"))
        _ = previewPump(0.3)
        try expect(pane.lens == .look && log.all == [.text("2")], "a digit is typed and does not switch the lens while Keys is on")
        try expect(!pane.forwardKey(chord("a", control: true)), "a control chord stays the window's")
        let tab = KeyChord.canonical(keyval: Keymap.tab, state: 0) ?? chord("a")
        try expect(!pane.forwardKey(tab), "and so does a key with no character")
        try expect(pane.forwardKey(KeyChord.canonical(keyval: Keymap.escape, state: 0) ?? chord("a")) && !pane.keysOn, "Escape turns Keys off and is not forwarded")
        log.reset()
        try expect(!pane.forwardKey(chord("a")), "with Keys off a letter is the window's again")
        _ = previewPump(0.2)
        try expect(log.count == 0, "and nothing is sent")

        log.reset()
        log.holdEach(milliseconds: 250)
        layer.point(kind: 0, fx: 0.3, fy: 0.3, width: wide, height: tall)
        layer.point(kind: 2, fx: 0.3, fy: 0.3, width: wide, height: tall)
        pane.setKeys(true)
        _ = pane.forwardKey(chord("a"))
        try expect(previewPump(2, until: { log.count == 2 }), "a tap and the typing after it both arrive")
        try expect(log.all == [.tap(x: 0.3, y: 0.3), .text("a")], "typing waits behind the tap before it: \(log.all)")
        pane.setKeys(false)
        _ = previewPump(1.4, until: { layer.advance(); return !layer.hasTick })

        log.reset()
        log.holdEach(milliseconds: 900)
        layer.point(kind: 0, fx: 0.6, fy: 0.2, width: wide, height: tall)
        layer.point(kind: 2, fx: 0.6, fy: 0.2, width: wide, height: tall)
        _ = previewPump(0.8, until: { layer.advance(); return false })
        let waiting = layer.plan(width: 120, height: 260)
        try expect(waiting.rings.count == 1 && waiting.rings[0][4] == 1, "a touch the host is still working on turns its ring to the calm busy one: \(waiting.rings)")
        try expect(near(waiting.rings[0][0], 72) && near(waiting.rings[0][1], 52), "and the ring stays where the finger was")
        try expect(previewPump(2, until: { log.count == 1 }), "the touch lands")
        try expect(previewPump(2, until: { layer.advance(); return layer.plan(width: 120, height: 260).rings.isEmpty }), "and the busy ring goes")
        log.holdEach(milliseconds: 0)

        pane.pressHomeForTest()
        try expect(previewPump(1, until: { log.count == 2 }) && log.all.last == .button("home"), "Home sends the home button")

        log.failWith(AgentError.http(status: 409, body: "no app"))
        layer.point(kind: 0, fx: 0.5, fy: 0.5, width: wide, height: tall)
        layer.point(kind: 2, fx: 0.5, fy: 0.5, width: wide, height: tall)
        try expect(previewPump(2, until: { pane.touchNoteText != nil }), "a touch the host refuses says why")
        try expect(
            pane.touchNoteText == PreviewTouchReading.failure(AgentError.http(status: 409, body: "")),
            "in Core's words, over the picture and not in a dialog: \(pane.touchNoteText ?? "")")
        log.failWith(nil)
        _ = previewPump(1.4, until: { layer.advance(); return !layer.hasTick })

        let refusing = PreviewPane(target: target, runs: false)
        let refusal = TouchLog()
        refusal.failWith(AgentError.http(status: 501, body: "no"))
        refusing.useTouchSink(refusal.sink)
        refusing.applyForTest(live, jpeg: tiny)
        refusing.touchLayerView.point(kind: 0, fx: 0.5, fy: 0.5, width: wide, height: tall)
        refusing.touchLayerView.point(kind: 2, fx: 0.5, fy: 0.5, width: wide, height: tall)
        try expect(previewPump(2, until: { !refusing.touchChipsShown }), "a host that says it cannot touch takes the controls away")
        refusing.applyForTest(live)
        try expect(!refusing.touchChipsShown && !refusing.touchLayerView.isOperating, "and they stay away for this preview")
        refusing.shutdown()

        let again = PreviewPane(target: target, runs: false)
        again.useTouchSink(log.sink)
        again.applyForTest(live, jpeg: tiny)
        let layerAgain = again.touchLayerView
        try expect(again.touchChipsShown && layerAgain.isOperating, "a new pane for the same host starts with touch")
        again.toggleTouchForTest()
        try expect(!layerAgain.isOperating && again.touchChipsShown && !again.touchIsOn, "Touch off leaves the controls and takes the pointer back")
        try expect(!PreviewTouchPreference.isOn(), "the choice is remembered")
        log.reset()
        layerAgain.point(kind: 0, fx: 0.5, fy: 0.5, width: wide, height: tall)
        layerAgain.point(kind: 2, fx: 0.5, fy: 0.5, width: wide, height: tall)
        _ = previewPump(0.3)
        try expect(log.count == 0 && layerAgain.plan(width: 120, height: 260).rings.isEmpty, "a pane that only watches sends and draws nothing")
        again.pressHomeForTest()
        try expect(previewPump(1, until: { log.count == 1 }), "though Home still works")
        again.shutdown()
        let remembering = PreviewPane(target: target, runs: false)
        remembering.applyForTest(live, jpeg: tiny)
        try expect(!remembering.touchIsOn && !remembering.touchLayerView.isOperating, "another pane reads the remembered choice")
        remembering.shutdown()
        PreviewTouchPreference.set(true)

        let lenses = pane.lenses!
        pane.setKeys(true)
        log.reset()
        try expect(pane.chooseLens(.inspect), "Inspect opens")
        try expect(!pane.keysOn, "leaving Look turns Keys off")
        try expect(!pane.touchChipsShown && !layer.isOperating, "and the touch controls and the pointer stay out of Inspect")
        layer.point(kind: 0, fx: 0.5, fy: 0.5, width: wide, height: tall)
        layer.point(kind: 2, fx: 0.5, fy: 0.5, width: wide, height: tall)
        _ = previewPump(0.3)
        try expect(log.count == 0, "a press in Inspect pins a view and never taps")
        pane.setKeys(true)
        try expect(!pane.keysOn, "Keys cannot be turned on there")
        _ = pane.chooseLens(.look)
        try expect(pane.touchChipsShown && layer.isOperating && !pane.keysOn, "Look brings the pointer back and leaves Keys off")

        pane.setKeys(true)
        pane.focusLost()
        try expect(!pane.keysOn, "a pane that loses the window's focus stops forwarding keys")

        lenses.fit(width: 358)
        try expect(lenses.stageChipsAreStacked, "at 358 wide the chip rows stack")
        try expect(lenses.stageChipsWidth <= 358 - 24, "and the widest is narrow enough to show whole: \(lenses.stageChipsWidth)")
        lenses.fit(width: 600)
        try expect(lenses.stageChipsAreStacked, "at 600 wide seven chips do not fit side by side and still stack")
        lenses.fit(width: 1100)
        try expect(!lenses.stageChipsAreStacked, "a wide pane has them in one row")

        log.reset()
        log.holdEach(milliseconds: 1500)
        layer.point(kind: 0, fx: 0.5, fy: 0.5, width: wide, height: tall)
        layer.point(kind: 2, fx: 0.5, fy: 0.5, width: wide, height: tall)
        layer.point(kind: 4, fx: 0.5, fy: 0.5, a: 0, b: 1, width: wide, height: tall)
        pane.setKeys(true)
        _ = pane.forwardKey(chord("z"))
        _ = previewPump(0.2)
        try expect(pane.touchTasks == 1, "touches in flight are one task")
        pane.park()
        try expect(pane.touchTasks == 0 && pane.lensTasks == 0, "a parked pane owns no touch task")
        try expect(!layer.hasTick && layer.waitingCount == 0 && !layer.isOperating && !pane.keysOn, "no clock, no queued touch, no pointer, no keys")
        _ = previewPump(1.8)
        try expect(log.count == 0, "and nothing that was waiting is sent after it")
        log.holdEach(milliseconds: 0)
        pane.unpark()
        try expect(layer.isOperating && pane.touchChipsShown, "shown again it takes the pointer back")
        layer.point(kind: 0, fx: 0.5, fy: 0.5, width: wide, height: tall)
        layer.point(kind: 2, fx: 0.5, fy: 0.5, width: wide, height: tall)
        try expect(previewPump(2, until: { log.count == 1 }), "and touches again")
        pane.shutdown()
        try expect(pane.touchTasks == 0 && !layer.hasTick && !layer.isOperating, "a shut-down pane owns nothing")
        return checks
    }
}
