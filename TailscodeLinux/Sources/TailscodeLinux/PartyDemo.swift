import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The party against a scripted fleet, for the drive verbs that photograph it and the self-test
/// that measures it: six slots over the demo machines, a chat on Opus at high, and the device's own
/// party put aside while it is on screen and put back when it is gone, so no shot or check ever
/// leaves a demo behind.
enum PartyDemo {
    static let storageKey = "tailscode.modelParty"
    nonisolated(unsafe) private static var saved: String??

    static var slots: [(ModelPreset, String?)?] {
        func preset(_ provider: String, _ id: String, _ effort: PresetEffort) -> ModelPreset {
            ModelPreset(selection: ModelSelection(providerID: provider, modelID: id), effort: effort)
        }
        return [
            (preset("anthropic", "claude-opus-5", .level("high")), "Daily"),
            (preset("anthropic", "claude-sonnet-5", .level("low")), "Sprint"),
            (preset("ollama", "qwen3-coder:30b", .keep), "Local"),
            (preset("opencode-go", "gpt-5.6-luna", .level("high")), "Reviewer"),
            (preset("google", "gemini-3.5-pro-preview-0731", .server), "Big context"),
            nil,
        ]
    }

    static func inputs(onlyOn profiles: Set<String>? = nil) -> PartyInputs {
        PartyInputs(
            sources: ModelChooserDemo.sources().filter { profiles?.contains($0.profileID) ?? true },
            model: ModelChooserDemo.selected, effort: "high",
            agentOptions: [], recent: ModelChooserDemo.recents)
    }

    /// Puts the device's party aside, once, and fills the six places with the demo's.
    static func seed() {
        if saved == nil { saved = .some(UserDefaults.standard.string(forKey: storageKey)) }
        for (index, entry) in slots.enumerated() {
            if let (preset, name) = entry {
                ModelParty.replace(slot: index, with: preset, name: name)
            } else {
                ModelParty.release(slot: index)
            }
        }
    }

    /// Gives the device its own party back, exactly as it was.
    static func restore() {
        guard let held = saved else { return }
        saved = nil
        if let held {
            UserDefaults.standard.set(held, forKey: storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
        NotificationCenter.default.post(name: ModelParty.didChange, object: nil)
    }

    static func hooks(
        onlyOn profiles: Set<String>? = nil, report: @escaping @Sendable (String) -> Void
    ) -> PartyHooks {
        let hooks = PartyHooks()
        hooks.inputs = { inputs(onlyOn: profiles) }
        hooks.take = { card in report("take slot=\(card.slot + 1) title=\(card.title)") }
        hooks.pick = { pick in report("pick \(pick.modelName)") }
        hooks.fill = { slot in report("fill slot=\(slot + 1)") }
        hooks.addRecent = { recent, _ in report("add \(recent.word)") }
        hooks.catalog = { report("catalog") }
        return hooks
    }

    static func summary(_ cards: [PartyCard]) -> String {
        cards.map { card in
            card.isHollow
                ? "-" : "\(card.title)\(card.isInUse ? "*" : "")\(card.machine.map { "@" + $0 } ?? "")"
        }.joined(separator: ",")
    }
}

extension MainWindow {
    func presentPartyDemo(editing: Bool) {
        guard DesktopGuard.isHarnessed else {
            FileHandle.standardOutput.write(
                Data("PARTY refused: the demo rewrites the party, and only the harness may\n".utf8))
            return
        }
        if let old = demoParty {
            gtk_popover_popdown(ptr(old.popover))
            if gtk_widget_get_parent(old.popover) != nil { gtk_widget_unparent(old.popover) }
        }
        PartyDemo.seed()
        let party = PartyPopover(
            hooks: PartyDemo.hooks { line in
                FileHandle.standardOutput.write(Data("PARTY \(line)\n".utf8))
            })
        let anchor = activePane.root
        gtk_widget_set_parent(party.popover, anchor)
        gtk_popover_set_position(ptr(party.popover), GTK_POS_TOP)
        Gtk.connect(UnsafeMutableRawPointer(party.popover), "closed") { [weak self, weak party] in
            Gtk.onMain { [weak self, weak party] in
                FileHandle.standardOutput.write(Data("PARTY closed\n".utf8))
                guard let party, self?.demoParty === party else { return }
                PartyDemo.restore()
            }
        }
        demoParty = party
        gtk_popover_popup(ptr(party.popover))
        Gtk.after(300) { [weak self] in
            if editing { self?.demoParty?.toggleEditing() }
            Gtk.after(300) { [weak self] in
                let cards = self?.demoParty?.currentCards ?? []
                let popover = self?.demoParty?.popover
                let size = popover.map { "\(gtk_widget_get_width($0))x\(gtk_widget_get_height($0))" } ?? "-"
                let widths = (self?.demoParty?.gridView?.views ?? []).map {
                    view in
                    view.anchor.map { widget in
                        var least: Int32 = 0
                        var natural: Int32 = 0
                        var a: Int32 = 0
                        var b: Int32 = 0
                        gtk_widget_measure(widget, GTK_ORIENTATION_HORIZONTAL, -1, &least, &natural, &a, &b)
                        return "\(least)/\(natural)"
                    } ?? "-"
                }.joined(separator: ",")
                let mapped = popover.map { gtk_widget_get_mapped($0) != 0 } ?? false
                FileHandle.standardOutput.write(
                    Data(
                        "PARTY open editing=\(editing) mapped=\(mapped) size=\(size) bodies=\(widths) cards=\(PartyDemo.summary(cards))\n"
                            .utf8))
            }
        }
    }
}

extension MainWindow {
    /// *Which one makes room?* over the demo party, with six held, so the question can be
    /// photographed without a chooser to ask it from.
    func presentPartyRoomDemo() {
        guard DesktopGuard.isHarnessed else { return }
        PartyDemo.seed()
        ModelParty.replace(
            slot: 5, with: ModelPreset(
                selection: ModelSelection(providerID: "anthropic", modelID: "claude-haiku-4-5"),
                effort: .server), name: "Quick")
        let offered = ModelPreset(
            selection: ModelSelection(providerID: "deepseek", modelID: "deepseek-v4-flash"),
            effort: .level("deep"))
        PartyRoom.offer(offered, on: activePane.root, inputs: PartyDemo.inputs()) { words in
            FileHandle.standardOutput.write(Data("PARTY room \(words)\n".utf8))
        }
    }
}
