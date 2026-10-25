import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension SelfTest {
    /// The quick ask wearing the party, over the scripted fleet and pressed the way a person
    /// presses it: the first press on the pill opens the six cards and every press after a take
    /// opens them again, a slot on another machine re-aims the machine, the model and the level
    /// together and the card in use follows, the chords and the ring walk the slots, the chooser
    /// opened from the party speaks of a new chat, the popover is never wider or taller than its
    /// window and screen allow, and the party is the one the chat's pill reads. The device's own
    /// party, aim and catalogs are put aside while this runs and put back after.
    static func checkQuickAskParty() throws -> Int {
        guard gtk_init_check() != 0 else { return 0 }
        var claims = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("quick ask party: \(label)") }
            claims += 1
        }
        func pump(_ seconds: Double) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                while g_main_context_iteration(nil, 0) != 0 {}
                usleep(4000)
            }
        }
        MatrixTheme.install()
        defer {
            QuickAskWindow.open?.close()
            ModelChooserWindow.dismissOpen()
            QuickAskPartyDemo.restore()
            SettingsFile.capture()
        }
        guard let ask = QuickAskPartyDemo.present(parent: nil), let party = ask.dial.party else {
            throw SelfTestFailure("quick ask party: the quick ask wears no party on its pill")
        }
        pump(0.6)

        func isOpen() -> Bool { gtk_widget_get_mapped(party.popover) != 0 }
        func press() {
            _ = gtk_widget_activate(ask.dial.button)
            pump(0.35)
        }
        func hint() -> String { gtk_label_get_text(op(ask.hint)).map { String(cString: $0) } ?? "" }
        func chip() -> String {
            gtk_menu_button_get_label(op(ask.target)).map { String(cString: $0) } ?? ""
        }
        func inUse() -> [Int] { ask.partyInputs().cards.filter(\.isInUse).map(\.slot) }
        func editorHasFocus() -> Bool {
            guard let focus = gtk_window_get_focus(ptr(ask.window)) else { return false }
            return focus == ask.editor.widget || gtk_widget_is_ancestor(focus, ask.editor.widget) != 0
        }
        func aimedStrip() -> Int? {
            ask.aimToggles.firstIndex { gtk_toggle_button_get_active(ptr($0)) != 0 }
        }

        try expect(inUse() == [0], "the slot this ask runs is marked in use: \(inUse())")
        try expect(ask.targetServer.id == "arch", "the demo ask starts on arch")

        press()
        try expect(isOpen(), "the first press on the pill opens the party")
        try expect(party.gridView?.views.count == 6, "with its six cards drawn")
        try expect(
            party.currentCards.map(\.isHollow) == [false, false, false, false, false, true],
            "the cards are the device's party: \(PartyDemo.summary(party.currentCards))")
        press()
        try expect(!isOpen(), "a press on the open pill closes it")
        press()
        try expect(isOpen(), "and the next press opens it again in one press")

        party.actions.activate(2)
        pump(0.5)
        try expect(!isOpen(), "taking a card puts the party away")
        try expect(ask.targetServer.id == "macbook", "a slot on another machine re-aims the machine: \(ask.targetServer.id)")
        try expect(
            QuickAskDefaults.model(forProfileID: "macbook")?.modelID == "qwen3-coder:30b",
            "and the model it names")
        try expect(chip().hasPrefix("macbook"), "the target chip says so: \(chip())")
        try expect(aimedStrip() == 1, "and so does the strip of machines: \(String(describing: aimedStrip()))")
        try expect(hint().contains("macbook"), "the hint names the machine: \(hint())")
        try expect(inUse() == [2], "the card in use follows the aim: \(inUse())")
        try expect(
            ask.partyInputs().cards[0].machine?.hasPrefix("arch") == true,
            "and the slot left behind now wears its machine: \(PartyDemo.summary(ask.partyInputs().cards))")
        try expect(editorHasFocus(), "the caret is back in the question after a take")
        press()
        try expect(isOpen(), "the press after a take opens the party in one press")
        party.close()
        pump(0.2)

        ask.takePreset(number: 1)
        pump(0.3)
        try expect(ask.targetServer.id == "arch", "the first chord aims back at arch")
        try expect(
            QuickAskDefaults.model(forProfileID: "arch")?.modelID == "claude-opus-5"
                && QuickAskDefaults.effort(forProfileID: "arch") == "high",
            "with Opus at high")
        try expect(inUse() == [0], "and the first card is in use again: \(inUse())")

        ask.takePreset(number: 2)
        pump(0.3)
        try expect(
            QuickAskDefaults.model(forProfileID: "arch")?.modelID == "claude-sonnet-5"
                && QuickAskDefaults.effort(forProfileID: "arch") == "low",
            "the second chord takes Sonnet at its own level: \(String(describing: QuickAskDefaults.effort(forProfileID: "arch")))")
        try expect(aimedStrip() == 0 && chip().hasPrefix("arch"), "and stays on arch")

        ask.stepPreset(by: 1)
        pump(0.3)
        try expect(
            ask.targetServer.id == "macbook" && inUse() == [2],
            "the ring steps from Sprint to Local, which lives on macbook: \(ask.targetServer.id) \(inUse())")
        ask.stepPreset(by: -1)
        pump(0.3)
        try expect(ask.targetServer.id == "arch" && inUse() == [1], "and back: \(ask.targetServer.id) \(inUse())")
        ask.takePreset(number: 5)
        pump(0.3)
        ask.stepPreset(by: 1)
        pump(0.3)
        try expect(inUse() == [0], "the ring closes: after the last held slot comes the first: \(inUse())")

        ask.takePreset(number: 6)
        try expect(
            hint() == Localized.text("Slot %d is empty", 6) && ask.targetServer.id == "arch",
            "a hollow slot's chord says so and moves nothing: \(hint())")

        let chord = KeyChord.controlMask | KeyChord.altMask
        let digit = { (value: Character) in UInt32(String(value).unicodeScalars.first!.value) }
        try expect(
            ask.partyAction(keyval: digit("3"), state: chord) == .preset(3)
                && ask.partyAction(keyval: 0xFF53, state: chord) == .presetNext
                && ask.partyAction(keyval: 0xFF51, state: chord) == .presetPrevious,
            "Ctrl+Alt+1 to 6 and the arrows are read through the keybinding set")
        try expect(
            ask.partyAction(keyval: digit("3"), state: 0) == nil
                && ask.partyAction(keyval: digit("m"), state: chord) == nil,
            "a bare digit is a letter in the question and the dial's chord is not the party's")

        ask.takeRecent(
            ModelPick(
                profileID: "studio", selection: ModelSelection(providerID: "anthropic", modelID: "sonnet"),
                isElsewhere: true, serverName: "studio", modelName: "Sonnet"))
        pump(0.3)
        try expect(
            ask.targetServer.id == "studio" && aimedStrip() == 2
                && QuickAskDefaults.model(forProfileID: "studio")?.modelID == "sonnet",
            "a recent chip on another machine re-aims there: \(ask.targetServer.id)")
        ask.takePreset(number: 1)
        pump(0.3)
        try expect(
            ask.targetServer.id == "studio"
                && QuickAskDefaults.model(forProfileID: "studio")?.modelID.contains("opus") == true,
            "a slot the aimed machine can run itself is taken there, never on the machine it was filled from: \(ask.targetServer.id) \(String(describing: QuickAskDefaults.model(forProfileID: "studio")))")
        ask.retarget(to: 0)
        ask.takePreset(number: 1)
        pump(0.3)

        let tooltip = gtk_widget_get_tooltip_text(ask.dial.button).map { String(cString: $0) } ?? ""
        try expect(
            tooltip.contains(Localized.text("wheel to step the level")),
            "the pill still says the wheel steps the level: \(tooltip)")
        ask.stepEffort(by: -1)
        pump(0.1)
        try expect(
            QuickAskDefaults.effort(forProfileID: "arch") == "medium",
            "and the wheel's step moves it: \(String(describing: QuickAskDefaults.effort(forProfileID: "arch")))")
        ask.takePreset(number: 1)
        pump(0.2)

        ask.dial.openDial()
        pump(0.35)
        try expect(gtk_widget_get_mapped(ask.dial.dial.popover) != 0, "the dial is one chord away beside the party")
        gtk_popover_popdown(ptr(ask.dial.dial.popover))
        pump(0.2)

        ask.chooseModel()
        pump(0.3)
        try expect(
            ModelChooserWindow.openContext == .chat && ModelChooserWindow.openOffersParty,
            "All models opens the chooser for a new chat, offering Add to party: \(String(describing: ModelChooserWindow.openContext))")
        ModelChooserWindow.dismissOpen()
        pump(0.2)

        press()
        party.actions.activate(5)
        pump(0.4)
        try expect(
            ModelChooserWindow.openContext == .party && !isOpen(),
            "a hollow card puts the party away and opens the chooser in fill mode: \(String(describing: ModelChooserWindow.openContext))")
        ModelChooserWindow.choose(
            ModelPick(
                profileID: "arch",
                selection: ModelSelection(providerID: "anthropic", modelID: "claude-haiku-4-5"),
                isElsewhere: false, serverName: "arch", modelName: "Haiku"))
        pump(0.9)
        try expect(
            ModelParty.slot(5)?.preset.selection.modelID == "claude-haiku-4-5",
            "a pick in fill mode goes into the slot")
        try expect(isOpen(), "and the party opens again to show it")
        try expect(QuickAskWindow.open === ask, "the quick ask is never closed by the chooser or the party")
        party.close()
        pump(0.2)

        PartyEdits.rename(1, "Prime")
        let chatSide = PartyPopover(hooks: PartyDemo.hooks { _ in })
        _ = chatSide.prepare()
        defer { chatSide.retire() }
        try expect(
            chatSide.currentCards[1].title == "Prime" && ask.partyInputs().cards[1].title == "Prime",
            "a slot renamed anywhere is renamed in both: one party")
        party.actions.rename(2, "Zed")
        pump(0.1)
        try expect(
            ModelParty.slot(2)?.name == "Zed" && chatSide.currentCards[2].title == "Zed"
                && (UserDefaults.standard.string(forKey: "tailscode.modelParty") ?? "").contains("Zed"),
            "and a rename made in the quick ask is the chat's, under the one key")

        let fit = ask.partyFit()
        var monitorWidth: Int32 = 0
        var monitorHeight: Int32 = 0
        tailscode_monitor_size(ask.window, &monitorWidth, &monitorHeight)
        try expect(
            fit.ceiling.map { Int32($0) < monitorHeight } ?? true,
            "the party is never asked to be taller than the screen: \(String(describing: fit.ceiling))")
        let pill = Gtk.bounds(of: ask.dial.button, in: ask.window)
        let right = (pill?.x ?? 0) + (pill?.width ?? 0) / 2 + Double(fit.shift) + Double(PartyPopover.width) / 2
        try expect(
            right <= Double(gtk_widget_get_width(ask.window)) && fit.shift < 0,
            "it is shifted until its edge is the window's: \(fit.shift) \(right)")
        press()
        try expect(
            Int32(gtk_widget_get_width(party.popover)) <= PartyPopover.width + 40
                && Int32(gtk_widget_get_height(party.popover)) < monitorHeight,
            "opened, it is no wider than its cards and shorter than the screen")
        party.close()
        pump(0.2)
        party.fit = { PartyFit(ceiling: 200, shift: 0) }
        party.fillForPopup()
        var least: Int32 = 0
        var natural: Int32 = 0
        var ignoredA: Int32 = 0
        var ignoredB: Int32 = 0
        if let child = gtk_popover_get_child(ptr(party.popover)) {
            gtk_widget_measure(
                child, GTK_ORIENTATION_VERTICAL, PartyPopover.width, &least, &natural, &ignoredA,
                &ignoredB)
        }
        try expect(natural > 0 && natural <= 200, "a screen too short for the cards scrolls them: \(natural)")
        party.retire()
        party.fit = { QuickAskWindow.open?.partyFit() ?? PartyFit(ceiling: nil, shift: 0) }
        gtk_popover_set_child(ptr(party.popover), nil)

        ask.addToParty(
            ModelPreset(
                selection: ModelSelection(providerID: "deepseek", modelID: "deepseek-v4-flash"),
                effort: .server), on: ask.dial.button)
        pump(0.4)
        try expect(
            !ModelParty.presets().contains { $0.selection.modelID == "deepseek-v4-flash" },
            "Add to party with six held asks which slot makes room and changes nothing until told")
        var child = gtk_widget_get_first_child(ask.dial.button)
        var room = false
        while let found = child {
            child = gtk_widget_get_next_sibling(found)
            guard gtk_widget_has_css_class(found, "party-pop") != 0, found != party.popover else { continue }
            room = gtk_widget_get_mapped(found) != 0
            gtk_popover_popdown(ptr(found))
        }
        pump(0.3)
        try expect(room, "the question is on screen over the pill, and puts itself away")
        return claims
    }
}
