import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension BrainView {
    /// The drive verbs that browse: `key=<name or character>`, `click=row:<n>|node:<n>[,double]`,
    /// `rowhover=<n>`, `filter=<zone>|failed|clear`, `search=<text>`, `menu=<n>` (opens the row's
    /// menu), `menuitem=<k>` (performs the k-th item on the cursor's row), `legend`, `scroll=<px>`
    /// and `expand` (folds or unfolds the readout's long output). Numbers are one-based steps.
    func driveBrowse(verb: String, value: String) {
        func id(_ text: String) -> String? {
            guard let number = Int(text), number >= 1, number <= model.steps.count else { return nil }
            return model.steps[number - 1].id
        }
        switch verb {
        case "key":
            driveKey(value)
        case "click":
            let words = value.split(separator: ",").map(String.init)
            let double = words.contains("double")
            let target = (words.first ?? "").split(separator: ":", maxSplits: 1).map(String.init)
            guard target.count == 2, let step = id(target[1]) else { return }
            if target[0] == "node" {
                browse(.clickNode(model.browseState.list.nodeID(of: step), double: double))
            } else {
                browse(.click(step, double: double))
            }
        case "rowhover":
            if let step = id(value) { hoverStep(step) } else { hoverLeftStep() }
        case "filter":
            switch value {
            case "failed": browse(.failedToggle, grabFocus: false)
            case "clear": clearAllFilters()
            default:
                if let zone = NeuralZone.allCases.first(where: { String(describing: $0) == value }) {
                    browse(.zoneChip(zone, solo: false), grabFocus: false)
                }
            }
        case "search":
            openSearch()
            browse(.searchText(value), grabFocus: false)
        case "menu":
            if let step = id(value.replacingOccurrences(of: ",hold", with: "")),
                let row = model.browseState.list.row(id: step)
            {
                presentMenu(
                    for: step, items: NeuralBrowse.menuItems(for: row), at: (160, 60),
                    holding: value.hasSuffix(",hold"))
            }
        case "menuitem":
            guard let cursor = model.pinnedStep, let row = model.browseState.list.row(id: cursor),
                let index = Int(value)
            else { return }
            let items = NeuralBrowse.menuItems(for: row)
            guard index >= 1, index <= items.count else { return }
            browse(.menu(items[index - 1], cursor))
        case "legend":
            toggleLegend()
            Gtk.after(400) { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self, !self.disposed else { return }
                    let popover = self.legendPopover?.widget
                    let line = "legend state=\(self.model.browseState.legend) popover=\(popover != nil) mapped=\(popover.map { gtk_widget_get_mapped($0) } ?? -1)\n"
                    FileHandle.standardOutput.write(Data(line.utf8))
                }
            }
        case "scroll":
            list?.driveScroll(Double(value) ?? 0)
        case "expand":
            readout?.toggleOutput()
        default:
            break
        }
    }

    private func driveKey(_ name: String) {
        let table: [String: Int32] = [
            "up": GDK_KEY_Up, "down": GDK_KEY_Down, "pgup": GDK_KEY_Page_Up, "pgdn": GDK_KEY_Page_Down,
            "home": GDK_KEY_Home, "end": GDK_KEY_End, "left": GDK_KEY_Left, "right": GDK_KEY_Right,
            "enter": GDK_KEY_Return, "space": GDK_KEY_space, "esc": GDK_KEY_Escape, "tab": GDK_KEY_Tab,
        ]
        if let code = table[name] {
            _ = brainKey(keyval: UInt32(code), state: 0)
            return
        }
        guard let scalar = name.unicodeScalars.first, name.count == 1 else { return }
        let shift: UInt32 = scalar.properties.isUppercase ? GDK_SHIFT_MASK.rawValue : 0
        _ = brainKey(keyval: gdk_unicode_to_keyval(scalar.value), state: shift)
    }
}
