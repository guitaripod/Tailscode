import AgentTestSupport
import AppKit
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension SelfTest {
    /// The dial's one promise a headless check can hold it to: the pill is as wide for every level
    /// a model offers — the server's choice, the coldest word, the heaviest, the power — so the
    /// wheel stepping through them moves nothing to the pill's right, and a face that shows no
    /// meter is the only one allowed to be narrower.
    static func checkDialPill() throws -> Int {
        func expect(_ condition: Bool, _ label: String) throws {
            if !condition { throw SelfTestFailure(label) }
        }
        let options = ["low", "medium", "high", "xhigh", "max", Ultracode.effortLevel]
        let pill = DialPill()
        func width(at level: String?) -> CGFloat {
            pill.setFace(
                ModelDial.face(modelWord: "opus", effort: level, options: options),
                modelTint: nil)
            pill.layoutSubtreeIfNeeded()
            return pill.fittingSize.width
        }
        let widths = ([nil] + options.map(Optional.some)).map { ($0 ?? "server", width(at: $0)) }
        guard let first = widths.first else { throw SelfTestFailure("no faces to measure") }
        for (word, measured) in widths {
            try expect(
                abs(measured - first.1) < 0.5,
                "\(word) sets the pill to \(measured) where \(first.0) set it to \(first.1)")
        }
        try expect(first.1 > 0, "the pill has no width at all")
        let embers = ["minimal", "low", "medium", "high"]
        let emberWidths = embers.map { level -> (String, CGFloat) in
            pill.setFace(
                ModelDial.face(modelWord: "opus", effort: level, options: embers), modelTint: nil)
            pill.layoutSubtreeIfNeeded()
            return (level, pill.fittingSize.width)
        }
        guard let ember = emberWidths.first else { throw SelfTestFailure("no ember to measure") }
        for (word, measured) in emberWidths {
            try expect(
                abs(measured - ember.1) < 0.5,
                "\(word) sets the pill to \(measured) where \(ember.0) set it to \(ember.1)")
        }
        let minimal = ModelDial.face(modelWord: "opus", effort: "minimal", options: embers)
        try expect(minimal.isEmber, "minimal is not read as an ember")
        try expect(minimal.heat == 1, "minimal lights \(minimal.heat) bars rather than one")
        let low = ModelDial.face(modelWord: "opus", effort: "low", options: embers)
        try expect(!low.isEmber, "low is read as an ember")
        let mute = ModelDial.face(modelWord: "opus", effort: nil, options: [])
        try expect(!mute.showsMeter, "a model with no levels still shows a meter")
        return widths.count + emberWidths.count
    }

    /// The dial opened over the fixture fleet with pinned pairs: every pair wears the pill's meter,
    /// the ladder follows the cursor onto another model as a marked preview with the sentence about
    /// the level, ⇥ hands the arrows to the ladder, a search that finds nothing is a message no
    /// cursor can land on, and the menu reads the preset chords from the shortcut set.
    static func checkModelDial() throws -> Int {
        func expect(_ condition: Bool, _ label: String) throws {
            if !condition { throw SelfTestFailure(label) }
        }
        var checks = 0
        let options = ["low", "medium", "high", "xhigh", "max"]
        var state = ModelDialState(
            sources: ModelChooserDemo.sources(), selected: ModelChooserDemo.selected,
            effort: "max", options: options, modelWord: "Opus", quotas: [],
            recents: ModelChooserDemo.recents, presets: ModelDialDemo.presets, agentOptions: [])
        let panel = ModelDialPanel()
        _ = panel.view
        panel.render(state)
        let pairs = state.rows.filter { $0.level != nil }.count
        try expect(pairs >= 2, "only \(pairs) pinned pairs carry a level")
        try expect(
            panel.drawn.rowMeters == pairs,
            "\(panel.drawn.rowMeters) meters drawn for \(pairs) pairs with a level")
        try expect(state.rows.first?.section != nil, "the first row has no section heading")
        try expect(!state.ladderIsPreview, "the dial opens on a preview rather than this chat's model")
        try expect(!panel.drawn.preview, "the live ladder is marked a preview")
        checks += 5

        guard
            let other = state.rows.firstIndex(where: {
                $0.preset == nil && $0.candidate != nil && $0.candidate?.isElsewhere == false
                    && !$0.isCurrent
            })
        else { throw SelfTestFailure("no other model to preview") }
        state.move(to: other)
        panel.renderLadder(state)
        try expect(state.ladderIsPreview, "the cursor on another model leaves the ladder live")
        try expect(panel.drawn.preview, "a preview is not marked as one")
        try expect(
            panel.drawn.rungs == state.rungs.count,
            "\(panel.drawn.rungs) rungs drawn for \(state.rungs.count)")
        let owedCarry = state.carryNotice.flatMap {
            ModelDialPanel.repeats($0, state.headline) ? nil : $0
        }
        try expect(
            panel.drawn.carry == owedCarry,
            "the carry line says \(panel.drawn.carry ?? "nothing") for \(owedCarry ?? "nothing")")
        checks += 4

        _ = state.handle(.switchColumn)
        panel.renderLadder(state)
        try expect(
            panel.drawn.ladderOwnsArrows == (state.column == .ladder),
            "the ladder frame disagrees with the column that owns the arrows")
        let tab = ModelDialState.command(
            for: KeyChord.canonical(keyval: Keymap.tab, state: 0)!, digitsLive: true)
        try expect(tab == .switchColumn, "tab does not switch columns")
        let pin = ModelDialState.command(
            for: KeyChord.canonical(keyval: UInt32(UnicodeScalar("s").value), state: KeyChord.controlMask)!,
            digitsLive: true)
        try expect(pin == .pin, "control-s does not pin")
        checks += 3

        state.search("zzzz-no-such-model")
        panel.render(state)
        try expect(state.rows.first?.isMessage == true, "a search that finds nothing has no message")
        try expect(state.focused?.isMessage != true, "the cursor rests on the message")
        checks += 2

        let set = ShortcutSet.build(overrides: [:])
        let next = MainWindowController.boundChord(for: .presetNext, in: set)
        try expect(
            next?.control == true && next?.alt == true && next?.keyval == 0xFF53,
            "next pinned is not on control-option-right")
        let third = MainWindowController.boundChord(for: .preset(3), in: set)
        try expect(third?.keyval == UInt32(UnicodeScalar("3").value), "the third pair has no chord")
        let rebound = ShortcutSet.build(overrides: ["composer.presetNext": ["ctrl+alt+n"]])
        try expect(
            MainWindowController.boundChord(for: .presetNext, in: rebound)?.keyval
                == UInt32(UnicodeScalar("n").value),
            "a rebound chord does not reach the menu")
        checks += 3
        return checks
    }

    /// The paced reveal, checked where it can actually go wrong on this toolkit: every prefix the
    /// renderer is allowed to see must produce text that has already eaten its own punctuation —
    /// an answer that flashes its asterisks as each `**bold**` closes is the artefact that makes a
    /// smooth reveal look broken — the reservation must never reach past what has been rendered,
    /// and the wave must land every glyph back on the colour it would have had without it.
    static func checkCascade() throws -> Int {
        func expect(_ condition: Bool, _ label: String) throws {
            if !condition { throw SelfTestFailure(label) }
        }
        let source = """
            Here is **bold** text, some *italic*, a `snippet`, a [link](https://x.dev), \
            and ~~struck~~ words.

            - first bullet with `code`
            - second bullet with **weight**

            ## A heading arrives
            """
        let characters = Array(source)
        var checks = 0
        for cut in 0...characters.count {
            let safe = LiveCascade.renderable(String(characters[..<cut]), sealed: false)
            let rendered = MacMarkdown.render(safe, cache: false).string
            for marker in ["**", "~~", "`"] {
                try expect(
                    !rendered.contains(marker),
                    "prefix \(cut) leaked \(marker): \(rendered.debugDescription)")
            }
            checks += 1
        }

        let full = MacMarkdown.render(source, cache: false)
        var live = LiveCascade()
        live.focus("row", rendered: full.string, sealed: false, at: 0)
        try expect(live.revealed == 0, "a row born under our eyes starts empty")
        var time = 0.0
        var last = 0
        while time < 30, !live.isSettled {
            time += 1.0 / 120
            live.focus("row", rendered: full.string, sealed: false, at: time)
            live.advance(to: time)
            try expect(live.revealed >= last, "the reveal went backwards")
            try expect(live.revealed <= full.length, "the reveal ran past what had arrived")
            last = live.revealed
        }
        try expect(live.revealed == full.length, "the reveal never landed on its source")
        checks += 3

        let edge = CascadeTint.edge(ultracode: false, phase: 0.5)
        try expect(
            CascadeTint.hex(edge) == CascadeTint.hex(MacTheme.Color.accent),
            "a plain turn leads with the app's own accent")
        let shown = full.length / 2
        let tail = CascadeTail(
            revealed: shown, span: StreamCascade.span, phase: 0.3, edge: edge,
            spark: CascadeTint.spark(for: edge))
        let painted = tail.paint(full, settled: MacTheme.Color.label)
        try expect(
            painted.length == full.length,
            "the paint changed the layout instead of only the ink")
        try expect(painted.string == full.string, "the paint changed the words, not just the ink")
        let unshown =
            painted.attribute(.foregroundColor, at: shown + 1, effectiveRange: nil) as? NSColor
        try expect(
            (unshown?.alphaComponent ?? 1) == 0,
            "text the reveal has not reached was drawn instead of held")
        let far = shown - StreamCascade.span * 2
        try expect(far > 0, "the sample text is too short to have a settled half")
        try expect(
            (painted.attribute(.foregroundColor, at: far, effectiveRange: nil) as? NSColor)
                == (full.attribute(.foregroundColor, at: far, effectiveRange: nil) as? NSColor),
            "a glyph the wave has passed kept its own colour")
        let atEdge =
            painted.attribute(.foregroundColor, at: shown - 1, effectiveRange: nil) as? NSColor
        try expect(atEdge != nil, "the leading glyph carries the wave")
        try expect(
            (atEdge?.alphaComponent ?? 1) < 1, "the leading glyph fades in rather than popping")
        try expect(
            (atEdge?.alphaComponent ?? 0) >= StreamCascade.entryFloor,
            "the leading glyph appears from a whisper, not from nothing")
        checks += 7
        return checks
    }

    static func checkCompletion() throws -> Int {
        let commands = ["steam-add-game", "usage", "update-zeroclaw", "flyr", "compact"].map {
            AgentCommand(name: $0, details: "", source: .skill)
        }
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("completion case failed: \(label)") }
            checks += 1
        }
        try expect(SlashCompletion.query(in: "/st") == "st", "query reads the word")
        try expect(SlashCompletion.query(in: "/") == "", "bare slash asks for everything")
        try expect(SlashCompletion.query(in: "/goal clear") == nil, "arguments end the query")
        try expect(SlashCompletion.query(in: "plain text") == nil, "prose is not a query")
        try expect(
            SlashCompletion.matches(commands, query: "u").map(\.name) == [
                "update-zeroclaw", "usage",
            ], "prefix matches sort alphabetically")
        try expect(
            SlashCompletion.matches(commands, query: "add").map(\.name) == ["steam-add-game"],
            "a match inside the name still surfaces")
        try expect(
            SlashCompletion.matches(commands, query: "").first?.name == "compact",
            "everything, alphabetically, for a bare slash")
        try expect(
            SlashCompletion.matches(commands, query: "zzz").isEmpty, "no match means no list")

        let offered = CommandCatalogStore.forQuickAsk(commands)
        try expect(
            !offered.contains { $0.name == "compact" || $0.name == "usage" },
            "a quick ask is never offered the commands that read a transcript it has yet to write")
        guard
            case .command(let picked, let arguments) = QuickAskSend.decide(
                text: "/flyr HEL", commands: offered, resolvesFromPromptText: false
            ).kind
        else { throw SelfTestFailure("completion case failed: a typed command runs as a command") }
        try expect(
            picked.name == "flyr" && arguments == "HEL",
            "a typed command runs as a command, arguments and all")
        try expect(
            QuickAskSend.decide(
                text: "/compact keep the plan", commands: commands, resolvesFromPromptText: false
            ).kind == .prompt, "compaction is never what a quick ask means")
        try expect(
            QuickAskSend.decide(
                text: "/flyr HEL", commands: offered, resolvesFromPromptText: true
            ).kind == .prompt, "an agent that resolves its own grammar gets the prompt untouched")
        try expect(
            SlashPresentation.noMatchWording("commit", hasProject: false)
                != SlashPresentation.noMatchWording("commit", hasProject: true),
            "a word missing for want of a project says which reason it is")
        return checks
    }
}
