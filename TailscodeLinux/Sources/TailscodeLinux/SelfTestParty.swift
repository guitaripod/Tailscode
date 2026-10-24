import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension SelfTest {
    /// The party's six cards, built over the demo fleet in a real popover: the one the chat runs
    /// wears its marker and its ring, a name typed into a card is kept and a name emptied is given
    /// back, two cards swap, a ball steps the level through the model's own and round to the
    /// server's, a slot released goes hollow, the arrows walk from card to card, and at the
    /// popover's own width no card sits on another. The device's own party is put aside while this
    /// runs and put back after.
    static func checkPartyCards() throws -> Int {
        guard gtk_init_check() != 0 else { return 0 }
        var claims = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("party: \(label)") }
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
        PartyDemo.seed()
        defer {
            PartyDemo.restore()
            SettingsFile.capture()
        }

        let cards = PartyDemo.inputs().cards
        try expect(cards.count == 6, "six cards are read, filled or hollow: \(cards.count)")
        try expect(
            cards.map(\.isHollow) == [false, false, false, false, false, true],
            "five slots are held and the sixth is hollow: \(PartyDemo.summary(cards))")
        try expect(
            cards.map(\.isInUse) == [true, false, false, false, false, false],
            "the slot the chat runs is the one marked in use")
        try expect(cards[2].machine != nil, "a slot on another machine wears that machine")

        let levels = ["low", "medium", "high"]
        try expect(
            PartyEdits.nextLevel(after: .level("low"), options: levels) == .level("medium")
                && PartyEdits.nextLevel(after: .level("high"), options: levels) == .server
                && PartyEdits.nextLevel(after: .server, options: levels) == .level("low")
                && PartyEdits.nextLevel(after: .keep, options: levels) == .level("low")
                && PartyEdits.nextLevel(after: .server, options: []) == nil,
            "a ball steps low, medium, high, the server's choice and round again; a model with no levels does not move")

        let window = gtk_window_new()!
        gtk_window_set_default_size(ptr(UnsafeMutableRawPointer(window)), 640, 520)
        let host = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_window_set_child(ptr(UnsafeMutableRawPointer(window)), host)
        defer { gtk_window_destroy(ptr(UnsafeMutableRawPointer(window))) }
        let party = PartyPopover(hooks: PartyDemo.hooks { _ in })
        let shell = party.prepare()
        defer { party.retire() }
        gtk_box_append(ptr(host), shell)
        gtk_window_present(ptr(UnsafeMutableRawPointer(window)))
        pump(0.5)
        guard let grid = party.gridView else { throw SelfTestFailure("party: the popover drew no grid") }
        var least: Int32 = 0
        var natural: Int32 = 0
        var ignoredA: Int32 = 0
        var ignoredB: Int32 = 0
        gtk_widget_measure(
            shell, GTK_ORIENTATION_HORIZONTAL, -1, &least, &natural, &ignoredA, &ignoredB)
        try expect(
            least >= 600 && natural <= 620,
            "the popover asks for about 612 points, whatever its cards and chips say: \(least) to \(natural)")

        func boxes() throws -> [(x: Double, y: Double, width: Double, height: Double)] {
            try grid.views.map { view in
                guard let body = view.anchor, let found = Gtk.bounds(of: body, in: grid.widget)
                else { throw SelfTestFailure("party: a card has no place in the grid") }
                return found
            }
        }
        func overlaps(_ one: (x: Double, y: Double, width: Double, height: Double),
            _ other: (x: Double, y: Double, width: Double, height: Double)) -> Bool {
            one.x < other.x + other.width - 0.5 && other.x < one.x + one.width - 0.5
                && one.y < other.y + other.height - 0.5 && other.y < one.y + one.height - 0.5
        }
        func clear(_ label: String) throws {
            let placed = try boxes()
            for (index, one) in placed.enumerated() {
                try expect(
                    one.width >= 189 && one.height >= 117,
                    "\(label): card \(index + 1) is at least 190 by 118: \(one.width) by \(one.height)")
                for other in placed[(index + 1)...] {
                    try expect(!overlaps(one, other), "\(label): no card sits on another")
                }
            }
        }
        try clear("taking")

        let first = grid.views[0]
        try expect(first.chordWords.contains("IN USE"), "the card in use says so beside its chord: \(first.chordWords)")
        try expect(
            !grid.views[1].chordWords.contains("IN USE") && grid.views[1].chordWords.hasSuffix("2"),
            "the others say their chord and nothing more: \(grid.views[1].chordWords)")
        try expect(
            first.anchor.map { gtk_widget_has_css_class($0, "party-card-use") != 0 } ?? false
                && grid.views[1].anchor.map { gtk_widget_has_css_class($0, "party-card-use") == 0 } ?? false,
            "only the card in use wears the ring")

        gtk_widget_grab_focus(first.anchor!)
        pump(0.1)
        _ = gtk_widget_child_focus(shell, GTK_DIR_RIGHT)
        pump(0.1)
        try expect(grid.focused?.slot == 1, "the right arrow moves the focus to the next card: \(grid.focused?.slot ?? -1)")
        _ = gtk_widget_child_focus(shell, GTK_DIR_DOWN)
        pump(0.1)
        try expect(grid.focused?.slot == 4, "the down arrow moves it to the card below: \(grid.focused?.slot ?? -1)")

        party.toggleEditing()
        pump(0.3)
        try expect(party.editing, "Edit turns the cards editable")
        try clear("editing")

        guard let entry = grid.views[1].entry else { throw SelfTestFailure("party: an edited card has no name field") }
        gtk_editable_set_text(op(entry), "Prime")
        grid.views[1].commit(settling: true)
        pump(0.2)
        try expect(ModelParty.slot(1)?.name == "Prime", "a name typed into a card is kept: \(ModelParty.slot(1)?.name ?? "nil")")
        try expect(party.currentCards[1].title == "Prime", "and the card wears it")
        gtk_editable_set_text(op(entry), "")
        grid.views[1].commit(settling: true)
        pump(0.2)
        try expect(ModelParty.slot(1)?.name == nil, "an emptied name is no name")
        let restored = gtk_editable_get_text(op(entry)).map { String(cString: $0) } ?? ""
        try expect(restored == "Sonnet", "and the field gives the model's own word back: \(restored)")

        let daily = ModelParty.slot(0)?.preset
        let local = ModelParty.slot(2)?.preset
        party.actions.swap(0, 2)
        pump(0.2)
        try expect(
            ModelParty.slot(0)?.preset == local && ModelParty.slot(2)?.preset == daily,
            "two cards swap places")
        try expect(
            party.currentCards[2].title == "Daily" && party.currentCards[0].title == "Local",
            "and the names go with them")
        party.actions.swap(0, 2)
        pump(0.2)

        party.actions.stepLevel(0)
        pump(0.1)
        try expect(ModelParty.slot(0)?.preset.effort == .server, "a ball on high steps to the server's choice")
        party.actions.stepLevel(0)
        pump(0.1)
        try expect(ModelParty.slot(0)?.preset.effort == .level("low"), "and from there round to low")
        party.actions.stepLevel(2)
        pump(0.1)
        try expect(
            ModelParty.slot(2)?.preset.effort == .keep, "a model with no levels does not move")

        party.actions.release(1)
        pump(0.3)
        try expect(ModelParty.slot(1) == nil && party.currentCards[1].isHollow, "a released slot goes hollow")
        try clear("after a release")

        let inputs = PartyDemo.inputs()
        let sonnet = ModelSelection(providerID: "anthropic", modelID: "claude-sonnet-5")
        let carried = PartyEdits.preset(
            for: ModelPick(profileID: "arch", selection: sonnet, isElsewhere: false, serverName: ""),
            inputs: inputs)
        try expect(
            carried == ModelPreset(selection: sonnet, effort: .level("high")),
            "a model offered to the party takes the level this chat holds, carried onto its own: \(String(describing: carried))")
        let paired = ModelPreset(selection: sonnet, effort: .level("low"))
        try expect(
            PartyEdits.preset(
                for: ModelPick(
                    profileID: "arch", selection: sonnet, isElsewhere: false, serverName: "",
                    preset: paired), inputs: inputs) == paired,
            "a pinned pair keeps its own level")
        let qwen = ModelSelection(providerID: "ollama", modelID: "qwen3-coder:30b")
        try expect(
            PartyEdits.preset(
                for: ModelPick(profileID: "macbook", selection: qwen, isElsewhere: true, serverName: "macbook"),
                inputs: inputs)?.effort == .server,
            "a model with no levels is kept at the server's choice")

        let tell = Told()
        PartyRoom.offer(carried!, on: host, inputs: inputs) { tell.say($0) }
        let told = tell.words
        try expect(
            told == [Localized.text("Added to slot %d", 2)] && ModelParty.presets().contains(carried!),
            "offering a model puts it in the first hollow slot and says which: \(told)")
        let haiku = ModelPreset(
            selection: ModelSelection(providerID: "anthropic", modelID: "claude-haiku-4-5"),
            effort: .server)
        try expect(PartyEdits.place(haiku) == .placed(5), "the last hollow slot takes the next model")
        try expect(PartyEdits.place(haiku) == .placed(5), "and the same model at the same level is never placed twice")
        let spare = ModelPreset(selection: qwen, effort: .server)
        PartyRoom.offer(spare, on: host, inputs: inputs) { tell.say($0) }
        pump(0.1)
        try expect(
            !ModelParty.presets().contains(spare) && tell.words.count == 1,
            "offering a seventh model to six held changes nothing until one is chosen to make room")

        party.retire()
        gtk_box_remove(ptr(host), shell)
        PartyDemo.seed()
        let stranded = PartyPopover(hooks: PartyDemo.hooks(onlyOn: ["arch"]) { _ in })
        let strandedShell = stranded.prepare()
        defer { stranded.retire() }
        gtk_box_append(ptr(host), strandedShell)
        pump(0.5)
        try expect(
            stranded.currentCards.contains { $0.isAway },
            "slots no machine here runs are away: \(PartyDemo.summary(stranded.currentCards))")
        var leastAway: Int32 = 0
        var naturalAway: Int32 = 0
        gtk_widget_measure(
            strandedShell, GTK_ORIENTATION_HORIZONTAL, -1, &leastAway, &naturalAway, &ignoredA,
            &ignoredB)
        try expect(
            naturalAway <= 620,
            "away cards and their long words wrap rather than widen the popover: \(naturalAway)")
        return claims
    }
}

private final class Told: @unchecked Sendable {
    private(set) var words: [String] = []
    func say(_ text: String) { words.append(text) }
}
