import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Model dial")
struct ModelDialTests {
    private let claude = ["low", "medium", "high", "xhigh", "max", "ultracode"]

    @Test("The ladder runs cold to hot whatever order the catalog listed")
    func ascending() {
        #expect(ModelDial.ascending(options: ["high", "low", "medium"]) == ["low", "medium", "high"])
        #expect(ModelDial.ascending(options: claude).last == "ultracode")
        #expect(ModelDial.ascending(options: ["deep", "low", "shallow"]) == ["low", "deep", "shallow"])
    }

    @Test("A known tier lights its rank on every model; the power lights every bar")
    func heat() {
        #expect(ModelDial.heat("high", options: claude) == 3)
        #expect(ModelDial.heat("high", options: ["low", "high"]) == 3)
        #expect(ModelDial.heat("max", options: claude) == 5)
        #expect(ModelDial.heat("ultracode", options: claude) == EffortMeter.bars)
        #expect(ModelDial.heat(nil, options: claude) == 0)
        #expect(ModelDial.heat("thinking", options: ["none", "thinking"]) == 2)
        #expect(ModelDial.heat("shallow", options: ["shallow", "deep"]) == 3)
    }

    @Test("A step is pinned at both ends and starts from the server's stop")
    func step() {
        #expect(ModelDial.step("high", by: 1, options: claude) == "xhigh")
        #expect(ModelDial.step("high", by: -1, options: claude) == "medium")
        #expect(ModelDial.step("low", by: -1, options: claude) == nil)
        #expect(ModelDial.step(nil, by: -1, options: claude) == nil)
        #expect(ModelDial.step(nil, by: 1, options: claude) == "low")
        #expect(ModelDial.step("ultracode", by: 1, options: claude) == "ultracode")
        #expect(ModelDial.step("max", by: 1, options: claude) == "ultracode")
        #expect(ModelDial.step("high", by: 1, options: []) == nil)
        #expect(ModelDial.step("xhigh", by: 1, options: ["low", "high"]) == "low")
    }

    @Test("The rungs read top down with the power first and the server last")
    func rungs() {
        let rungs = ModelDial.rungs(options: claude)
        #expect(rungs.map(\.level) == ["ultracode", "max", "xhigh", "high", "medium", "low", nil])
        #expect(rungs.first?.isPower == true)
        #expect(rungs.last?.isServer == true)
        #expect(rungs.map(\.key) == [6, 5, 4, 3, 2, 1, 0])
        #expect(ModelDial.rung(forKey: 3, options: claude)?.level == "high")
        #expect(ModelDial.rung(forKey: 0, options: claude)?.level == nil)
        #expect(ModelDial.rung(forKey: 9, options: claude) == nil)
        #expect(rungs.allSatisfy { !$0.caption.isEmpty })
    }

    @Test("The headline counts the levels and the pill reads the model's own state")
    func faces() {
        #expect(ModelDial.headline(modelName: "Sonnet 5", options: claude) == "Sonnet 5 takes six levels")
        #expect(ModelDial.headline(modelName: "Qwen", options: []) == "Qwen takes no effort level")
        let high = ModelDial.face(modelWord: "Sonnet", effort: "high", options: claude)
        #expect(high.effortWord == "high")
        #expect(high.heat == 3)
        #expect(!high.isServer && !high.isPower)
        let server = ModelDial.face(modelWord: "Sonnet", effort: nil, options: claude)
        #expect(server.isServer)
        #expect(server.heat == 0)
        #expect(server.showsMeter)
        let stranded = ModelDial.face(modelWord: "Grok", effort: "xhigh", options: ["low", "high"])
        #expect(stranded.isServer, "a level the model cannot take is the server deciding")
        let none = ModelDial.face(modelWord: "Qwen", effort: "high", options: [])
        #expect(!none.showsMeter)
        #expect(none.effortWord == nil)
        let power = ModelDial.face(modelWord: "Fable", effort: "ultracode", options: claude)
        #expect(power.isPower && power.heat == EffortMeter.bars)
    }

    private func state(effort: String? = "high", query: String = "") -> ModelDialState {
        var state = ModelDialState(
            sources: ModelChooserDemo.sources(), selected: ModelChooserDemo.selected,
            effort: effort, options: claude, modelWord: "Opus", quotas: [],
            recents: ModelChooserDemo.recents, favorites: [])
        if !query.isEmpty { state.search(query) }
        return state
    }

    @Test("The column opens on this chat's model and ends on the catalog's door")
    func column() {
        let dial = state()
        #expect(dial.focused?.isCurrent == true)
        #expect(dial.rows.first?.section != nil)
        #expect(dial.rows.last?.opensCatalog == true)
        #expect(dial.rows.contains { $0.kind == .serverDefault })
        #expect(dial.rows.contains { $0.candidate?.isElsewhere == true })
        #expect(dial.rows.filter { $0.candidate?.isElsewhere == true }.first?.section?.hasPrefix("Also on") == true)
    }

    @Test("Arrows walk the models without changing anything; enter takes the row")
    func walk() {
        var dial = state()
        let start = dial.cursor
        #expect(dial.handle(.down) == .moved)
        #expect(dial.cursor == start + 1)
        #expect(dial.effort == "high")
        let picked = dial.handle(.activate)
        guard case .pick(let pick) = picked else {
            Issue.record("enter did not pick")
            return
        }
        #expect(pick.selection != nil)
        #expect(dial.handle(.bottom) == .moved)
        #expect(dial.handle(.activate) == .openCatalog)
        #expect(dial.handle(.dismiss) == .dismiss)
    }

    @Test("Effort is live: arrows and digits change it the moment they land")
    func effort() {
        var dial = state()
        #expect(dial.handle(.hotter) == .effort("xhigh"))
        #expect(dial.effort == "xhigh")
        #expect(dial.handle(.colder) == .effort("high"))
        #expect(dial.handle(.digit(0)) == .effort(nil))
        #expect(dial.currentRung?.isServer == true)
        #expect(dial.handle(.digit(6)) == .effort("ultracode"))
        #expect(dial.handle(.digit(9)) == .unhandled)
        dial.search("gpt")
        #expect(!dial.digitsPickEffort)
        #expect(dial.handle(.digit(3)) == .unhandled, "a digit in a query names a model")
    }

    @Test("A query answers from the whole fleet, not the shortlist")
    func search() {
        let dial = state(query: "nemotron")
        #expect(dial.rows.contains { $0.title.lowercased().contains("nemotron") })
        #expect(dial.focused?.candidate != nil)
        #expect(dial.rows.last?.opensCatalog == true)
    }

    @Test("Chords map the way the chooser's do, digits only while the search is empty")
    func chords() {
        func chord(_ keyval: UInt32, control: Bool = false) -> KeyChord {
            KeyChord.canonical(keyval: keyval, state: control ? KeyChord.controlMask : 0)!
        }
        #expect(ModelDialState.command(for: chord(Keymap.up), digitsLive: true) == .up)
        #expect(ModelDialState.command(for: chord(0xFF53), digitsLive: true) == .hotter)
        #expect(ModelDialState.command(for: chord(0xFF51), digitsLive: true) == .colder)
        #expect(ModelDialState.command(for: chord(0xFF51), digitsLive: false) == nil, "a bare arrow moves the caret in a query")
        #expect(ModelDialState.command(for: chord(0xFF51, control: true), digitsLive: false) == .colder)
        #expect(ModelDialState.command(for: chord(Keymap.enter), digitsLive: true) == .activate)
        #expect(ModelDialState.command(for: chord(Keymap.enter, control: true), digitsLive: true) == .openAll)
        #expect(ModelDialState.command(for: chord(0x33), digitsLive: true) == .digit(3))
        #expect(ModelDialState.command(for: chord(0x33), digitsLive: false) == nil)
        #expect(ModelDialState.command(for: chord(0x73, control: true), digitsLive: true) == .star)
        #expect(ModelDialState.command(for: chord(Keymap.escape), digitsLive: true) == .dismiss)
    }

    @Test("The dial's chords are registered on both desktops' composer")
    func bindings() {
        let set = ShortcutSet.build(overrides: [:])
        #expect(set.issues.isEmpty)
        func action(_ spec: String, _ context: KeyContext) -> KeyAction? {
            guard let chord = KeySpec.parse(spec)?.chords.first else { return nil }
            guard case .run(let action) = set.resolve(
                chord, context: context, pending: [], awaitingApproval: false)
            else { return nil }
            return action
        }
        #expect(action("ctrl+alt+up", .insert) == .effortHotter)
        #expect(action("ctrl+alt+down", .normal) == .effortColder)
        #expect(action("ctrl+alt+m", .insert) == .modelDial)
    }
}
