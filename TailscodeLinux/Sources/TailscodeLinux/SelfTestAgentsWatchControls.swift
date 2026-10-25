import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

final class FakeInhibitor: WatchInhibiting {
    private(set) var held: [UInt32] = []
    private(set) var acquires = 0
    private(set) var releases = 0
    private var next: UInt32 = 40

    func acquire(reason: String) -> UInt32 {
        acquires += 1
        next += 1
        held.append(next)
        return next
    }

    func release(_ cookie: UInt32) {
        releases += 1
        held.removeAll { $0 == cookie }
    }
}

extension SelfTest {
    /// Fullscreen, keep-awake and the keys that are the wall's own: the header and pointer that
    /// leave after three idle seconds and return with a movement, the inhibit held exactly while
    /// the wall asks for it, and keys that do nothing in a lens that is not the wall.
    static func checkWatchControls(_ check: WatchCheck) throws {
        let window = check.open(size: (1920, 1080))
        let view = window.watchView
        let controls: WatchControls = window.controls
        let clock = view.context.clock
        let fake = FakeInhibitor()
        controls.inhibitor = fake
        try check.expect(!controls.isFullscreen && !controls.isInhibiting, "the wall starts windowed and lets the screen sleep")
        _ = window.handleKey(keyval: Keymap.functionKey(11), state: 0)
        try check.expect(
            controls.isFullscreen && fake.held.count == 1 && controls.keepAwake,
            "F11 enters fullscreen and holds the inhibit: \(fake.held)")
        clock.advance(by: 2)
        controls.evaluateIdle(now: clock.now)
        try check.expect(controls.chromeShown && !controls.pointerHidden, "the header stays for the first seconds")
        clock.advance(by: 2)
        window.secondPassed()
        try check.expect(!controls.chromeShown && controls.pointerHidden, "after three idle seconds the header and the pointer go")
        controls.noteInput()
        try check.expect(controls.chromeShown && !controls.pointerHidden, "and return with the first movement")
        let opened = check.log.opened.count

        _ = window.handleKey(keyval: 0x6B, state: 0)
        try check.expect(
            !controls.keepAwake && fake.held.isEmpty && fake.releases == 1,
            "k lets the screen sleep again while fullscreen")
        _ = window.handleKey(keyval: 0x6B, state: 0)
        try check.expect(controls.keepAwake && fake.held.count == 1, "and holds it again")
        _ = window.handleKey(keyval: Keymap.escape, state: 0)
        try check.expect(
            !controls.isFullscreen && fake.held.isEmpty && !controls.pointerHidden,
            "Esc leaves fullscreen and gives the inhibit back")
        controls.setKeepAwake(true)
        try check.expect(fake.held.count == 1, "keep-awake can be asked for windowed")
        _ = window.handleKey(keyval: 0x6B, state: 0)
        try check.expect(fake.held.isEmpty, "and withdrawn")

        let first = view.orderedKeys[0]
        _ = window.handleKey(keyval: 0x31, state: 0)
        check.pump(0.4)
        try check.expect(
            window.selectedKey == first && view.peekLayer.isShown,
            "1 opens the first tile's peek over the wall: \(window.selectedKey ?? "-")")
        _ = window.handleKey(keyval: Keymap.escape, state: 0)
        try check.expect(window.selectedKey == nil && !view.peekLayer.isShown, "Esc closes the peek first")
        _ = window.handleKey(keyval: Keymap.tab, state: 0)
        try check.expect(view.focusedKey == first, "Tab walks the tiles")
        _ = window.handleKey(keyval: Keymap.enter, state: 0)
        check.pump(0.4)
        try check.expect(window.selectedKey == first, "and Enter opens the one it is on")
        window.deselect()
        _ = window.handleKey(keyval: 0x64, state: 0)
        try check.expect(check.log.opened.count == opened, "no key opened a chat")

        window.show(.now)
        let before = view.dim.amount
        _ = window.handleKey(keyval: 0x64, state: 0)
        _ = window.handleKey(keyval: 0x31, state: 0)
        try check.expect(
            window.selectedKey == nil && view.dim.amount == before && !controls.isFullscreen,
            "the wall's letters do nothing in Now")
        _ = window.handleKey(keyval: Keymap.functionKey(11), state: 0)
        try check.expect(controls.isFullscreen && !controls.wantsQuietChrome, "but F11 does, and Now keeps its header")
        _ = window.handleKey(keyval: Keymap.functionKey(11), state: 0)
        window.show(.watch)

        let chord = window.handleKey(keyval: 0x41, state: KeyChord.controlMask | KeyChord.shiftMask)
        try check.expect(chord, "Ctrl+Shift+A inside the wall still closes the window")
        check.pump(0.4)
        try check.expect(AgentsWindow.current == nil, "which is gone")

        let again = check.open(size: (1280, 720))
        let two: WatchControls = again.controls
        let fakeTwo = FakeInhibitor()
        two.inhibitor = fakeTwo
        two.setFullscreen(true)
        try check.expect(fakeTwo.held.count == 1, "fullscreen again holds the inhibit")
        check.close(again)
        try check.expect(
            fakeTwo.held.isEmpty && fakeTwo.releases == 1,
            "and closing the window gives it back: \(fakeTwo.releases)")
        let real = GtkInhibitor()
        let cookie = real.acquire(reason: "agents wall check")
        real.release(cookie)
        try check.expect(true, "the compositor's own inhibit answers: cookie \(cookie)")
    }
}
