import Foundation
import Testing

@testable import TailscodeCore

@Suite("Global summon")
struct GlobalSummonTests {

    @Test("The standard chord round-trips and reads the same on both desktops")
    func standard() {
        let chord = SummonChord.standard
        #expect(chord.spec == "ctrl+alt+a")
        #expect(SummonChord(spec: chord.spec) == chord)
        #expect(chord.display(on: .linux) == "Ctrl+Alt+A")
        #expect(chord.display(on: .apple) == "⌃⌥A")
        #expect(SummonJudge.judge(chord, on: .linux) == .fine)
        #expect(SummonJudge.judge(chord, on: .apple) == .fine)
    }

    @Test("A spec is read however it is spelled and written down one way")
    func parsing() {
        #expect(SummonChord(spec: "Control+Option+A")?.spec == "ctrl+alt+a")
        #expect(SummonChord(spec: "cmd+shift+space")?.spec == "shift+super+space")
        #expect(SummonChord(spec: "super+f12")?.spec == "super+f12")
        #expect(SummonChord(spec: "ctrl+alt") == nil)
        #expect(SummonChord(spec: "ctrl+alt+quokka") == nil)
        #expect(SummonChord(spec: "ctrl+alt+a+b") == nil)
    }

    @Test("Every key knows what all four claimants call it")
    func keyNames() {
        let chord = SummonChord(control: true, alt: true, key: "a")
        #expect(chord.portalTrigger == "CTRL+ALT+a")
        #expect(chord.xBinding == "Ctrl+Alt+a")
        #expect(chord.hyprBinding == "CTRL ALT, a")
        #expect(chord.gtkAccelerator == "<Control><Alt>a")
        #expect(chord.appleKeyCode == 0)
        #expect(chord.appleModifierMask == 0x1800)
        for name in SummonKeys.names {
            let info = SummonKeys.info(name)
            #expect(info != nil)
            #expect(info?.apple != nil)
        }
    }

    @Test("A chord that would steal a machine-wide gesture is refused by name")
    func refusals() {
        let selection = SummonChord(control: true, shift: true, key: "right")
        #expect(SummonJudge.judge(selection, on: .linux).isRefused)
        #expect(SummonJudge.judge(selection, on: .linux).note?.contains("selection") == true)
        #expect(SummonJudge.judge(SummonChord(alt: true, key: "up"), on: .linux).isRefused)
        #expect(SummonJudge.judge(SummonChord(key: "a"), on: .linux).isRefused)
        #expect(SummonJudge.judge(SummonChord(shift: true, key: "a"), on: .linux).isRefused)
        #expect(SummonJudge.judge(SummonChord(alt: true, key: "tab"), on: .linux).isRefused)
        #expect(SummonJudge.judge(SummonChord(control: true, key: "c"), on: .linux).isRefused)
        #expect(SummonJudge.judge(SummonChord(meta: true, key: "c"), on: .apple).isRefused)
        #expect(SummonJudge.judge(SummonChord(meta: true, key: "c"), on: .linux) != .fine)
        #expect(SummonJudge.judge(SummonChord(control: true, key: "c"), on: .apple) == .fine)
    }

    @Test("A bare function key is allowed and says what it costs")
    func functionKeys() {
        let judgement = SummonJudge.judge(SummonChord(key: "f12"), on: .linux)
        #expect(!judgement.isRefused)
        #expect(judgement.note != nil)
    }

    @Test("The desktop is read from the session rather than guessed")
    func desktops() {
        #expect(SummonDesktop.detect(["XDG_CURRENT_DESKTOP": "KDE"]) == .kde)
        #expect(SummonDesktop.detect(["XDG_CURRENT_DESKTOP": "GNOME"]) == .gnome)
        #expect(SummonDesktop.detect(["HYPRLAND_INSTANCE_SIGNATURE": "x"]) == .hyprland)
        #expect(SummonDesktop.detect(["SWAYSOCK": "/run/x"]) == .sway)
        #expect(SummonDesktop.detect(["DESKTOP_SESSION": "i3"]) == .i3)
        #expect(SummonDesktop.detect([:]) == .other)
    }

    @Test("Every desktop is handed a line in its own language")
    func recipes() {
        for desktop in SummonDesktop.allCases {
            let recipe = SummonRecipe.make(
                chord: .standard, desktop: desktop, command: "tailscode --ask")
            #expect(recipe.binding.contains("tailscode --ask"))
            #expect(!recipe.instruction.isEmpty)
        }
        let hypr = SummonRecipe.make(
            chord: .standard, desktop: .hyprland, command: "tailscode --ask")
        #expect(hypr.binding == "bind = CTRL ALT, a, exec, tailscode --ask")
        let sway = SummonRecipe.make(chord: .standard, desktop: .sway, command: "tailscode --ask")
        #expect(sway.binding == "bindsym Ctrl+Alt+a exec tailscode --ask")
    }

    @Test("Only a key the machine is actually holding reads as bound")
    func states() {
        #expect(SummonState.bound(.standard, reach: .always).isLive)
        #expect(!SummonState.awaiting(.standard, where: "KDE Plasma").isLive)
        #expect(!SummonState.taken(.standard, by: "Konsole").isLive)
        #expect(!SummonState.unavailable("no portal").isLive)
        #expect(!SummonState.off.isLive)
        #expect(
            SummonState.bound(.standard, reach: .whileRunning).detail(on: .linux)?
                .contains("while Tailscode is running") == true)
        #expect(
            SummonState.bound(.standard, reach: .always).detail(on: .linux)?
                .contains("does not need to be running") == true)
        for state: SummonState in [
            .off, .bound(.standard, reach: .always),
            .reassigned(.standard, trigger: "Meta+A", reach: .whileRunning),
            .awaiting(.standard, where: "KDE Plasma"),
            .taken(.standard, by: "Konsole"), .taken(.standard, by: nil),
            .unavailable("This session has nothing to ask for a key."),
        ] {
            #expect(!state.line(on: .linux).isEmpty)
            #expect(state.detail(on: .linux) != nil)
        }
        #expect(
            SummonState.taken(.standard, by: "Konsole").detail(on: .linux)?.contains("Konsole")
                == true)
    }
}
