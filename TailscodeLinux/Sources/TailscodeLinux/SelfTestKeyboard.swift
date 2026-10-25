import Foundation
import TailscodeCore

extension SelfTest {
    /// The Keyboard page's round trip with no widgets: the calls the capture dialog makes, against
    /// a scratch config directory so the person's `keybindings.json` is never the file under test.
    /// A key added to an action must resolve on the very next load, give itself back on restore,
    /// take a key from its owner when asked, and never be written over a file that is not JSON.
    static func checkKeyboardRebind() throws -> Int {
        var claims = 0
        func expect(_ condition: Bool, _ words: String) throws {
            guard condition else { throw SelfTestFailure(words) }
            claims += 1
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("tailscode-keyboard-\(UUID().uuidString)", isDirectory: true)
        let before = ShortcutSet.configDirectoryOverride
        ShortcutSet.configDirectoryOverride = scratch
        defer {
            ShortcutSet.configDirectoryOverride = before
            try? FileManager.default.removeItem(at: scratch)
        }

        func resolves(_ chord: KeyChord) -> KeyAction? {
            let set = ShortcutSet.load()
            if case .run(let action) = set.resolve(
                chord, context: .normal, pending: [], awaitingApproval: false)
            {
                return action
            }
            return nil
        }
        func pinned() throws -> [String: Any] {
            let data = try Data(contentsOf: ShortcutSet.configURL)
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }

        let extra = KeyChord.canonical(
            keyval: 0x79, state: KeyChord.controlMask | KeyChord.altMask)
        let chord = try needed(extra, "Ctrl+Alt+Y reads as a chord")
        try expect(resolves(chord) == nil, "the key is free before anything is bound")
        try expect(
            ShortcutBindings.load().keys(for: "chat.new") == ["n"], "a new file means shipped keys")

        let fitted = ShortcutEditor.fit([chord], for: "chat.new")
        guard case .bound(let spec, let note) = fitted else {
            throw SelfTestFailure("Ctrl+Alt+Y may be given to New conversation")
        }
        try expect(spec == "ctrl+alt+y" && note == nil, "the recorded chord is spelled as the grammar does")
        let bindings = ShortcutBindings.load()
        try expect(
            ShortcutEditor.conflicts(adding: spec, to: "chat.new", in: bindings).isEmpty,
            "a free key has no owner to take it from")

        let added = try ShortcutEditor.apply(
            ShortcutEditor.adding(spec, to: "chat.new", in: bindings))
        try expect(added.keys(for: "chat.new") == ["n", "ctrl+alt+y"], "the key is added beside the old one")
        try expect(resolves(chord) == .newChat, "the next load resolves the new key to New conversation")
        try expect(
            (try pinned())["chat.new"] as? [String] == ["n", "ctrl+alt+y"],
            "the file pins both keys")

        let again = ShortcutEditor.adding(spec, to: "chat.new", in: added)
        try expect(again.isEmpty, "adding a key an action already has is no change")

        let restored = try ShortcutEditor.apply(ShortcutEditor.restoring("chat.new", in: added))
        try expect(restored.keys(for: "chat.new") == ["n"], "restoring brings back the shipped keys")
        try expect((try pinned())["chat.new"] == nil, "the file no longer pins the action")
        try expect(resolves(chord) == nil, "the added key stops resolving")
        try expect((try pinned())["_readme"] != nil, "the file's notes survive an edit")

        let taken = KeyChord.canonical(keyval: 0x6E, state: KeyChord.controlMask)
        let ctrlN = try needed(taken, "Ctrl+N reads as a chord")
        let plan = ShortcutEditor.adding("ctrl+n", to: "chat.new", in: restored)
        try expect(
            plan.displaced.map(\.id) == ["chat.next"], "Ctrl+N is named as Next chat's key")
        try ShortcutEditor.apply(plan)
        try expect(resolves(ctrlN) == .newChat, "the taken key now belongs to New conversation")
        try expect(
            ShortcutBindings.load().keys(for: "chat.next") == ["J"], "its old owner kept its other key")

        try ShortcutFile.resetAll()
        try expect(ShortcutBindings.load().customizedCount == 0, "reset puts every action back")
        try expect(resolves(ctrlN) == .selectNext, "the taken key goes home on reset")

        let garbage = Data("{ nope".utf8)
        try garbage.write(to: ShortcutSet.configURL)
        var refused = false
        do {
            try ShortcutEditor.apply(
                ShortcutEditor.adding(spec, to: "chat.new", in: ShortcutBindings()))
        } catch ShortcutFile.Failure.unreadable {
            refused = true
        }
        try expect(refused, "a file that is not JSON refuses the edit")
        try expect(
            (try Data(contentsOf: ShortcutSet.configURL)) == garbage,
            "and is left exactly as it was")
        return claims
    }

    private static func needed<T>(_ value: T?, _ words: String) throws -> T {
        guard let value else { throw SelfTestFailure(words) }
        return value
    }
}
