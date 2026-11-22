import AppKit
import TailscodeCore

/// The sidebar's way into the board: the Agents tile with a count that is amber when somebody is
/// waiting on the person and the number of agents working otherwise. The count is a number and a
/// word in the accessibility label as well as a colour.
@MainActor
final class AgentsSidebarEntry: SidebarPlaceTile {
    private(set) var needsYou = 0
    private(set) var working = 0
    var onOpen: (() -> Void)?

    init() {
        super.init(symbol: "square.stack.3d.up", caption: Localized.text("Agents"))
        onPress = { [weak self] in self?.onOpen?() }
        render(needsYou: 0, working: 0)
    }

    func render(needsYou: Int, working: Int) {
        self.needsYou = needsYou
        self.working = working
        let amber = needsYou > 0
        show(
            badge: amber ? needsYou : working,
            text: amber ? MacTheme.Color.onAccent : MacTheme.Color.success,
            fill: amber ? MacTheme.Color.warning : MacTheme.Color.success.withAlphaComponent(0.22))
        let phrase =
            amber
            ? Localized.text("%d needs you", needsYou)
            : (working > 0 ? Localized.text("%d working", working) : "")
        let label = phrase.isEmpty ? Localized.text("Agents") : Localized.text("Agents") + ", " + phrase
        setAccessibilityLabel(label)
        toolTip = label
    }
}
