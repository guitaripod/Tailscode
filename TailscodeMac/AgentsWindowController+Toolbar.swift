import AppKit
import TailscodeCore

extension AgentsWindowController: NSToolbarDelegate {
    func configureToolbar(for window: NSWindow) {
        let toolbar = NSToolbar(identifier: Self.toolbarID)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.modeItem, .flexibleSpace, Self.inspectorItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.modeItem:
            let titles = [Localized.text("Now"), Localized.text("Hour")]
            let group = NSToolbarItemGroup(
                itemIdentifier: itemIdentifier, titles: titles, selectionMode: .selectOne,
                labels: titles, target: self, action: #selector(modeChanged(_:)))
            group.selectedIndex = mode.rawValue
            group.label = Localized.text("View")
            group.paletteLabel = Localized.text("View")
            modeGroup = group
            return group
        case Self.inspectorItem:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(
                systemSymbolName: "sidebar.trailing",
                accessibilityDescription: Localized.text("Show or hide the peek"))
            item.label = Localized.text("Peek")
            item.toolTip = Localized.text("Show or hide the peek")
            item.target = self
            item.action = #selector(inspectorPressed)
            return item
        default:
            return nil
        }
    }

    @objc private func modeChanged(_ sender: NSToolbarItemGroup) {
        guard let next = Mode(rawValue: sender.selectedIndex) else { return }
        setMode(next)
    }

    @objc private func inspectorPressed() {
        toggleInspector()
    }
}
