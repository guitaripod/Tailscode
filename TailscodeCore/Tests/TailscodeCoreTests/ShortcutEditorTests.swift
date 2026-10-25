import Foundation
import Testing

@testable import TailscodeCore

/// The rebinding screen's facts are only trustworthy if the spec grammar round-trips, the file
/// keeps what a person wrote by hand, and the editor refuses or narrows a key the way a text field
/// and a shell need it to; these tests pin those rules against the shipped table.
@Suite("Shortcut spelling, file, editor and registry", .serialized)
struct ShortcutEditorTests {
    @Test("Every shipped default spec parses and spells back to the same chords and contexts")
    func shippedDefaultsRoundTrip() throws {
        for definition in ShortcutRegistry.all {
            for spec in definition.defaults {
                let parsed = try #require(KeySpec.parse(spec), "\(definition.id): \(spec)")
                let written = KeySpec.spec(parsed.chords, contexts: parsed.contexts)
                let reparsed = try #require(KeySpec.parse(written), "\(spec) wrote as \(written)")
                #expect(reparsed.chords == parsed.chords, "\(spec) wrote as \(written)")
                #expect(reparsed.contexts == parsed.contexts, "\(spec) wrote as \(written)")
            }
        }
    }

    @Test("A hand-written list of specs parses and spells back to the same chords and contexts")
    func handListRoundTrip() throws {
        let specs = [
            "ctrl+shift+h", "J", "g g", "ctrl+w shift+w", "ctrl+alt+shift+o", "f5", "shift+tab",
            "ctrl+backspace", "alt+pageup", "ctrl+comma", "ctrl+plus", "ctrl+minus", "normal:f",
            "normal,insert:ctrl+b", "ctrl+w equal",
        ]
        for spec in specs {
            let parsed = try #require(KeySpec.parse(spec), "\(spec) does not parse")
            let written = KeySpec.spec(parsed.chords, contexts: parsed.contexts)
            let reparsed = try #require(KeySpec.parse(written), "\(spec) wrote as \(written)")
            #expect(reparsed.chords == parsed.chords, "\(spec) wrote as \(written)")
            #expect(reparsed.contexts == parsed.contexts, "\(spec) wrote as \(written)")
        }
    }

    @Test("A lone Shift on a letter is written as the capital and modifiers keep their order")
    func chordSpellingOrder() throws {
        let capitalJ = try #require(KeySpec.parse("J")).chords[0]
        #expect(capitalJ.spec == "J")
        let ctrlShiftH = try #require(KeySpec.parse("ctrl+shift+h")).chords[0]
        #expect(ctrlShiftH.spec == "ctrl+shift+h")
        let allThree = try #require(KeySpec.parse("shift+alt+ctrl+o")).chords[0]
        #expect(allThree.spec == "ctrl+alt+shift+o")
        let enter = try #require(KeySpec.parse("return")).chords[0]
        #expect(enter.spec == "enter")
        let escape = try #require(KeySpec.parse("esc")).chords[0]
        #expect(escape.spec == "escape")
    }

    @Test("Keycaps read Ctrl, Shift and the letter on Linux, and the Apple glyphs on Apple")
    func keycaps() throws {
        let chord = try #require(KeySpec.parse("ctrl+shift+h")).chords[0]
        #expect(chord.caps(on: .linux) == ["Ctrl", "Shift", "H"])
        #expect(chord.caps(on: .apple) == ["⌃", "⇧", "H"])
        let f5 = try #require(KeySpec.parse("f5")).chords[0]
        #expect(f5.caps(on: .linux).last == "F5")
        #expect(f5.caps(on: .apple).last == "F5")
    }

    @Test("Applying a change to a missing file starts from notes and the shipped table")
    func applyToMissingFile() throws {
        let data = try ShortcutFile.applying(["chat.next": .bind(["e", "ctrl+e"])], to: nil)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["_readme"] != nil)
        #expect(object["_defaults"] is [String: Any])
        #expect(object["chat.next"] as? [String] == ["e", "ctrl+e"])
    }

    @Test("Applying a change keeps hand-written notes, other ids and ids from a newer build")
    func applyKeepsHandWrittenKeys() throws {
        let existing = Data(
            """
            {"_note": "keep", "chat.archive": "x", "future.thing": "y"}
            """.utf8)
        let data = try ShortcutFile.applying(
            ["chat.next": .bind(["e", "ctrl+e"])], to: existing)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["_note"] as? String == "keep")
        #expect(object["chat.archive"] as? String == "x")
        #expect(object["future.thing"] as? String == "y")
        #expect(object["chat.next"] as? [String] == ["e", "ctrl+e"])
        #expect(object["_defaults"] == nil)
    }

    @Test("An empty binding writes null and a single key writes a bare string")
    func bindingShapes() throws {
        let cleared = try ShortcutFile.applying(["chat.next": .bind([])], to: Data("{}".utf8))
        let clearedObject = try #require(
            try JSONSerialization.jsonObject(with: cleared) as? [String: Any])
        #expect(clearedObject["chat.next"] is NSNull)

        let single = try ShortcutFile.applying(["chat.next": .bind(["x"])], to: Data("{}".utf8))
        let singleObject = try #require(
            try JSONSerialization.jsonObject(with: single) as? [String: Any])
        #expect(singleObject["chat.next"] as? String == "x")
    }

    @Test("Restoring a default removes the id from the file")
    func restoreRemovesKey() throws {
        let existing = Data(#"{"chat.next": "e", "_note": "keep"}"#.utf8)
        let data = try ShortcutFile.applying(["chat.next": .restoreDefault], to: existing)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["chat.next"] == nil)
        #expect(object["_note"] as? String == "keep")
    }

    @Test("A file that is not a JSON object is refused rather than overwritten")
    func unreadableFileIsRefused() {
        #expect(throws: ShortcutFile.Failure.unreadable) {
            try ShortcutFile.applying(["chat.next": .bind(["e"])], to: Data("[1,2]".utf8))
        }
        #expect(throws: ShortcutFile.Failure.unreadable) {
            try ShortcutFile.applying(["chat.next": .bind(["e"])], to: Data("not json".utf8))
        }
    }

    @Test("Parsing a file reads strings, lists and nulls and reports unknown and mistyped ids")
    func parseReadsValuesAndIssues() throws {
        let data = Data(
            """
            {
              "_note": "ignored",
              "chat.new": "x",
              "chat.archive": ["a", "b"],
              "chat.filter": null,
              "chat.save": "",
              "future.thing": "y",
              "chat.first": 3
            }
            """.utf8)
        let result = ShortcutFile.parse(data)
        #expect(result.overrides["chat.new"] == ["x"])
        #expect(result.overrides["chat.archive"] == ["a", "b"])
        #expect(result.overrides["chat.filter"] == [])
        #expect(result.overrides["chat.save"] == [])
        #expect(result.overrides["_note"] == nil)
        #expect(result.overrides["future.thing"] == nil)
        #expect(result.overrides["chat.first"] == nil)
        #expect(result.issues.count == 2)
        #expect(result.issues.contains { $0.contains("future.thing") })
        #expect(result.issues.contains { $0.contains("chat.first") })
    }

    @Test("A key that is not a JSON object parses to nothing with one issue")
    func parseRejectsNonObject() {
        let result = ShortcutFile.parse(Data("[1,2]".utf8))
        #expect(result.overrides.isEmpty)
        #expect(result.issues.count == 1)
    }

    @Test("A key on a single action that is never narrowed is bound as it is typed")
    func fitBareKeyOnNormalOnlyAction() throws {
        let fit = ShortcutEditor.fit(try chords("n"), for: "chat.new")
        #expect(fit == .bound(spec: "n", note: nil))
    }

    @Test("A bare letter on an action that also works in the prompt box is narrowed to normal")
    func fitBareLetterNarrowsToNormal() throws {
        let fit = ShortcutEditor.fit(try chords("n"), for: "composer.modelDial")
        guard case .bound(let spec, let note) = fit else {
            Issue.record("expected a bound key, got \(fit)")
            return
        }
        #expect(spec == "normal:n")
        #expect(note != nil)
    }

    @Test("A Ctrl+Alt chord on the model dial needs no context prefix, since nothing narrows it")
    func fitCtrlAltChordIsNotNarrowed() throws {
        let fit = ShortcutEditor.fit(try chords("ctrl+alt+k"), for: "composer.modelDial")
        #expect(fit == .bound(spec: "ctrl+alt+k", note: nil))
    }

    @Test("A Ctrl+Shift chord on the model dial is bound with no context prefix")
    func fitCtrlShiftChordIsUnrestricted() throws {
        let fit = ShortcutEditor.fit(try chords("ctrl+shift+k"), for: "composer.modelDial")
        #expect(fit == .bound(spec: "ctrl+shift+k", note: nil))
    }

    @Test("A bare letter with nowhere left to work is refused with the reason")
    func fitBareLetterOnInsertOnlyIsRefused() throws {
        let fit = ShortcutEditor.fit(try chords("n"), for: "composer.send")
        #expect(isRefused(fit))
    }

    @Test("Ctrl+C on an action that also works in the prompt box is narrowed to normal")
    func fitCtrlCNarrowsToNormal() throws {
        let fit = ShortcutEditor.fit(try chords("ctrl+c"), for: "composer.effortHotter")
        #expect(
            fit
                == .bound(
                    spec: "normal:ctrl+c",
                    note: "Not everywhere: the prompt box uses this one to edit text"))
    }

    @Test("A two-key sequence on a normal-only action is bound as written")
    func fitSequence() throws {
        let fit = ShortcutEditor.fit(try chords("g x"), for: "chat.new")
        #expect(fit == .bound(spec: "g x", note: nil))
    }

    @Test("Three keys in a row are refused")
    func fitThreeChordsRefused() throws {
        let g = try #require(KeySpec.parse("g")).chords[0]
        #expect(isRefused(ShortcutEditor.fit([g, g, g], for: "chat.new")))
    }

    @Test("An approval key takes one bare key, and a Ctrl chord is refused")
    func fitApprovalKeys() throws {
        #expect(isRefused(ShortcutEditor.fit(try chords("ctrl+y"), for: "approve.once")))
        let bare = ShortcutEditor.fit(try chords("y"), for: "approve.once")
        #expect(bare == .bound(spec: "y", note: nil))
    }

    @Test("Adding a key another action holds reports that action as the same key")
    func conflictSameKey() throws {
        let found = ShortcutEditor.conflicts(
            adding: "e", to: "chat.new", in: ShortcutBindings())
        let conflict = try #require(found.first { $0.id == "chat.archive" })
        #expect(conflict.kind == .sameKey)
    }

    @Test("A bare key that begins a shipped two-key sequence reports that sequence")
    func conflictStartsSequence() throws {
        let found = ShortcutEditor.conflicts(
            adding: "g", to: "chat.new", in: ShortcutBindings())
        let conflict = try #require(found.first { $0.id == "scroll.top" })
        #expect(conflict.kind == .startsSequence)
    }

    @Test("A two-key sequence with no shipped bare key beginning it has no conflict")
    func conflictFreeSequence() {
        #expect(
            ShortcutEditor.conflicts(adding: "g x", to: "chat.new", in: ShortcutBindings())
                .isEmpty)
    }

    @Test("A two-key sequence beginning with a key another action holds alone reports that action")
    func conflictBeginsWithKey() throws {
        let bindings = ShortcutBindings(overrides: ["chat.first": ["g"]])
        let found = ShortcutEditor.conflicts(adding: "g x", to: "chat.new", in: bindings)
        let conflict = try #require(found.first { $0.id == "chat.first" })
        #expect(conflict.kind == .beginsWithKey)
        #expect(!found.contains { $0.id == "scroll.top" && $0.kind == .sameKey })
    }

    @Test("Keys in disjoint contexts do not conflict")
    func conflictAcrossDisjointContexts() {
        let found = ShortcutEditor.conflicts(
            adding: "insert:ctrl+k", to: "composer.send", in: ShortcutBindings())
        #expect(found.isEmpty)
    }

    @Test("An ordinary key never conflicts with an approval key")
    func conflictIgnoresApprovalKeys() {
        let found = ShortcutEditor.conflicts(adding: "y", to: "chat.new", in: ShortcutBindings())
        #expect(!found.contains { $0.id.hasPrefix("approve.") })
    }

    @Test("Adding a key takes it from its holder and writes the action's full new list")
    func addingPlan() throws {
        let plan = ShortcutEditor.adding("e", to: "chat.new", in: ShortcutBindings())
        #expect(plan.changes["chat.new"] == ["n", "e"])
        #expect(plan.changes["chat.archive"] == [])
        #expect(plan.displaced.count == 1)
        #expect(plan.displaced.first?.id == "chat.archive")
        #expect(plan.fileChanges["chat.archive"] == .bind([]))
        #expect(plan.fileChanges["chat.new"] == .bind(["n", "e"]))
    }

    @Test("Adding a key an action already has is an empty plan")
    func addingExistingKeyIsEmpty() {
        let plan = ShortcutEditor.adding("n", to: "chat.new", in: ShortcutBindings())
        #expect(plan.isEmpty)
        #expect(plan.displaced.isEmpty)
    }

    @Test("Removing a key leaves the action with the rest of its keys")
    func removingPlan() {
        let plan = ShortcutEditor.removing("n", from: "chat.new", in: ShortcutBindings())
        #expect(plan.changes["chat.new"] == [])
        #expect(plan.displaced.isEmpty)
    }

    @Test("Restoring an action takes its shipped keys back from whoever holds them")
    func restoringPlan() throws {
        let bindings = ShortcutBindings(overrides: ["chat.new": ["x"], "chat.filter": ["n"]])
        let plan = ShortcutEditor.restoring("chat.new", in: bindings)
        #expect(plan.changes["chat.new"] == ["n"])
        #expect(plan.changes["chat.filter"] == [])
        #expect(plan.displaced.count == 1)
        #expect(plan.fileChanges["chat.new"] == .restoreDefault)
        #expect(plan.fileChanges["chat.filter"] == .bind([]))
    }

    @Test("An action restored to its shipped keys is removed from the file")
    func shippedKeysMapToRestoreDefault() {
        let bindings = ShortcutBindings(overrides: ["chat.archive": ["x"]])
        let plan = ShortcutEditor.restoring("chat.archive", in: bindings)
        #expect(plan.fileChanges["chat.archive"] == .restoreDefault)
    }

    @Test("With no query the sections hold the app category and the Settings shortcut")
    func sectionsWithoutQuery() throws {
        let sections = ShortcutEditor.sections(bindings: ShortcutBindings())
        #expect(sections.contains { $0.category == .app })
        let settings = try #require(
            sections.flatMap(\.entries).first { $0.id == "app.settings" })
        #expect(settings.keys.first?.spec == "ctrl+comma")
    }

    @Test("A query matches the action's title and finds Settings")
    func sectionsQueryByTitle() {
        let sections = ShortcutEditor.sections(bindings: ShortcutBindings(), query: "settings")
        #expect(sections.flatMap(\.entries).contains { $0.id == "app.settings" })
    }

    @Test("A query matching nothing returns no sections")
    func sectionsQueryNothing() {
        let sections = ShortcutEditor.sections(bindings: ShortcutBindings(), query: "zzzzqqq")
        #expect(sections.isEmpty)
    }

    @Test("A query matching a key's display finds the action holding that key")
    func sectionsQueryByDisplay() throws {
        let key = try #require(
            ShortcutEditor.sections(bindings: ShortcutBindings())
                .flatMap(\.entries).first { $0.id == "app.settings" }?.keys.first)
        let sections = ShortcutEditor.sections(bindings: ShortcutBindings(), query: key.display)
        #expect(sections.flatMap(\.entries).contains { $0.id == "app.settings" })
    }

    @Test("Unavailable actions are left off the sections")
    func sectionsOmitUnavailable() {
        let previous = ShortcutSet.unavailable
        ShortcutSet.unavailable = ["app.settings"]
        defer { ShortcutSet.unavailable = previous }
        let sections = ShortcutEditor.sections(bindings: ShortcutBindings())
        #expect(!sections.flatMap(\.entries).contains { $0.id == "app.settings" })
    }

    @Test("Every registry id is unique and the shipped table builds with no issues")
    func registryIsSane() {
        let ids = ShortcutRegistry.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ShortcutSet.build(overrides: [:]).issues.isEmpty)
    }

    @Test("The Settings shortcut and the nine chat-number actions are registered")
    func registryHasAppAndChatActions() {
        #expect(ShortcutRegistry.definition("app.settings") != nil)
        for number in 1...9 {
            #expect(ShortcutRegistry.definition("chat.open\(number)")?.action == .openChat(number))
        }
    }

    @Test("Reset recovers a file that is not JSON, keeping what was there beside it")
    func resetRecoversUnreadableFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcut-reset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let before = ShortcutSet.configDirectoryOverride
        ShortcutSet.configDirectoryOverride = directory
        defer {
            ShortcutSet.configDirectoryOverride = before
            try? FileManager.default.removeItem(at: directory)
        }
        let broken = Data("{ not json".utf8)
        try broken.write(to: ShortcutSet.configURL)

        try ShortcutFile.resetAll()

        let kept = ShortcutSet.configURL.appendingPathExtension("broken")
        #expect(try Data(contentsOf: kept) == broken)
        let fresh = try JSONSerialization.jsonObject(
            with: Data(contentsOf: ShortcutSet.configURL)) as? [String: Any]
        #expect(fresh?["_readme"] != nil)
        #expect(ShortcutBindings.load().customizedCount == 0)
        try ShortcutFile.resetAll()
        #expect(try Data(contentsOf: kept) == broken)
    }

    private func chords(_ spec: String) throws -> [KeyChord] {
        try #require(KeySpec.parse(spec)).chords
    }

    private func isRefused(_ fit: ShortcutEditor.Fit) -> Bool {
        if case .refused = fit { return true }
        return false
    }
}
