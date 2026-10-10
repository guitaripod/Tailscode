import AppKit
import TailscodeCore

/// The pane verbs in the menu bar, built from Core's groups so this desktop names the same verbs
/// in the same order under the same headings as the Linux one, and a person who never learns the
/// chords still reaches every one. The registry's sequences (`^w a`) have no key-equivalent
/// spelling, so each item wears the keys it is on right now, rebinding included, in its title.
@MainActor
enum PaneMenu {
    /// The submenus a menu lists after the split verbs: one per Core group, the first led by the
    /// named arrangements so a shape can be chosen as well as cycled to.
    static func items(
        keys: (String) -> String?, verb: Selector, arrangement: Selector, target: AnyObject
    ) -> [NSMenuItem] {
        SplitMenu.groups.enumerated().map { index, group in
            let menu = NSMenu(title: group.title)
            menu.autoenablesItems = true
            if index == 0 {
                for shape in SplitMenu.arrangements {
                    menu.addItem(arrangementItem(shape, action: arrangement, target: target))
                }
                menu.addItem(.separator())
            }
            for id in group.shortcutIDs {
                guard let definition = SplitMenu.definition(id) else { continue }
                menu.addItem(
                    verbItem(definition, keys: keys(id), action: verb, target: target))
            }
            let holder = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            return holder
        }
    }

    /// An item for one registered verb, wearing its keys in a column at the trailing edge.
    static func verbItem(
        _ definition: ShortcutDefinition, keys: String?, action: Selector, target: AnyObject
    ) -> NSMenuItem {
        let item = NSMenuItem(title: definition.title, action: action, keyEquivalent: "")
        item.target = target
        item.representedObject = definition.action
        if let keys, !keys.isEmpty {
            item.attributedTitle = titled(definition.title, keys: keys)
            item.toolTip = keys
        }
        return item
    }

    static func arrangementItem(
        _ shape: SplitArrangement, action: Selector, target: AnyObject
    ) -> NSMenuItem {
        let item = NSMenuItem(title: shape.title, action: action, keyEquivalent: "")
        item.target = target
        item.representedObject = shape
        item.image = NSImage(systemSymbolName: shape.symbolName, accessibilityDescription: nil)
        return item
    }

    /// The title and its keys on one line, the keys right-aligned in the secondary ink a menu uses
    /// for its own key equivalents.
    static func titled(_ title: String, keys: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: keyColumn)]
        let line = NSMutableAttributedString(
            string: title,
            attributes: [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: style])
        line.append(
            NSAttributedString(
                string: "\t\(keys)",
                attributes: [
                    .font: NSFont.menuFont(ofSize: 0),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: style,
                ]))
        return line
    }

    /// Where the right-aligned keys end, wide enough for the longest verb title beside them.
    private static let keyColumn: CGFloat = 300
}
