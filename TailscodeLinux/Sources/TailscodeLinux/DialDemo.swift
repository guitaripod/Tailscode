import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The dial against a scripted fleet, for the drive verbs that photograph it: the demo machines,
/// a chat on Opus at high, and pinned pairs passed in rather than read from the device, so every
/// shot shows the same pairs whatever the harness's settings hold.
enum DialDemo {
    static let presets: [ModelPreset] = [
        ModelPreset(selection: ModelChooserDemo.selected, effort: .level("high")),
        ModelPreset(
            selection: ModelSelection(providerID: "anthropic", modelID: "claude-sonnet-5"),
            effort: .level("low")),
        ModelPreset(selection: ModelChooserDemo.selected, effort: .server),
        ModelPreset(
            selection: ModelSelection(providerID: "deepseek", modelID: "deepseek-v4-flash"),
            effort: .level("deep")),
    ]

    static func state() -> ModelDialState {
        ModelDialState(
            sources: ModelChooserDemo.sources(), selected: ModelChooserDemo.selected,
            effort: "high", options: ["low", "medium", "high"], modelWord: "Opus",
            quotas: ModelChooserDemo.quotas(), recents: ModelChooserDemo.recents,
            presets: presets, agentOptions: [])
    }

    static func keyval(_ name: String) -> (UInt32, UInt32)? {
        switch name {
        case "up": return (Keymap.up, 0)
        case "down": return (Keymap.down, 0)
        case "left": return (0xFF51, 0)
        case "right": return (0xFF53, 0)
        case "tab": return (Keymap.tab, 0)
        case "stab": return (Keymap.shiftTab, KeyChord.shiftMask)
        case "enter": return (Keymap.enter, 0)
        case "esc": return (Keymap.escape, 0)
        case "pin": return (0x73, KeyChord.controlMask)
        default:
            guard let digit = UInt32(name), digit < 10 else { return nil }
            return (0x30 + digit, 0)
        }
    }

    static func summary(_ dial: ModelDialState) -> String {
        let row = dial.focused
        return [
            "row=\(row?.title ?? "-")", "preset=\(row?.preset.map { "\($0.effort)" } ?? "-")",
            "live=\(dial.effortIsLive)", "column=\(dial.column)",
            "lit=\(dial.ladderEffort ?? "server")", "carry=\(dial.carryNotice ?? "-")",
        ].joined(separator: " ")
    }
}

extension MainWindow {
    func presentDialDemo() {
        if let demoDial { gtk_popover_popdown(ptr(demoDial.popover)) }
        let popover = ModelDialPopover(
            makeState: { DialDemo.state() },
            onPick: { pick, effort, notice in
                FileHandle.standardOutput.write(
                    Data("DIAL pick=\(pick.modelName) effort=\(effort) notice=\(notice ?? "-")\n".utf8))
            },
            onEffort: { level in
                FileHandle.standardOutput.write(Data("DIAL effort=\(level ?? "server")\n".utf8))
            },
            onOpenCatalog: {})
        gtk_widget_set_parent(popover.popover, activePane.root)
        gtk_popover_set_position(ptr(popover.popover), GTK_POS_TOP)
        demoDial = popover
        gtk_popover_popup(ptr(popover.popover))
        Gtk.after(300) { [weak self] in self?.reportDialDemo("DIAL open") }
    }

    func pressDialDemo(_ name: String) {
        guard let demoDial, let (keyval, state) = DialDemo.keyval(name) else { return }
        let handled = demoDial.press(keyval: keyval, state: state)
        reportDialDemo("DKEY \(name) handled=\(handled)")
    }

    func reportDialDemo(_ label: String) {
        guard let dial = demoDial?.current else { return }
        FileHandle.standardOutput.write(
            Data(
                "\(label) \(DialDemo.summary(dial)) preview=\(demoDial?.drawsPreview ?? false) rows=\(demoDial?.drawnRows ?? 0)\n"
                    .utf8))
    }
}
