import AppKit
import TailscodeCore

/// The window's one quiet word about density: how many chats are whole out of how many are open
/// — `Live 2 of 5` — and, when the Mac is shedding, why (`· busy`, `· memory`, `· warm`). It lives
/// in the toolbar, where the glass comes free, and only once there are two chats to count.
///
/// Pressed, it explains itself and offers `Keep all live`, which asks every open chat to stay
/// whole. At strained and above safety outranks that preference: the switch keeps its setting, the
/// governor ignores it, and the popover says so rather than leaving a switch that silently does
/// nothing.
@MainActor
final class LiveChip: NSObject {
    let button = NSButton(title: "", target: nil, action: nil)
    /// Asked whether every chat should be kept whole, and told when the person changes it.
    var keepAllLive: () -> Bool = { false }
    var setKeepAllLive: ((Bool) -> Void)?

    private var popover: NSPopover?
    private var decision: GovernorDecision?
    private var counts = (live: 0, chats: 0)

    override init() {
        super.init()
        button.bezelStyle = .toolbar
        button.target = self
        button.action = #selector(pressed)
        button.setAccessibilityRole(.button)
        restyle()
    }

    private func restyle() {
        button.font = MacTheme.Ramp.font(.chip)
    }

    /// Whether the chip has anything to count: two chats or more.
    var isShown: Bool { counts.chats > 1 }

    func update(decision: GovernorDecision?, live: Int, chats: Int) {
        self.decision = decision
        counts = (live, chats)
        let title = Self.title(live: live, chats: chats, decision: decision)
        if button.title != title { button.title = title }
        button.toolTip = Self.explanation(decision: decision)
        button.setAccessibilityLabel(title)
        restyle()
    }

    static func title(live: Int, chats: Int, decision: GovernorDecision?) -> String {
        let count = Localized.text("Live %@ of %@", "\(live)", "\(chats)")
        guard let decision, decision.level > .calm, let reason = decision.reasons.first else {
            return count
        }
        return "\(count) · \(reason.chipWord)"
    }

    static func explanation(decision: GovernorDecision?) -> String {
        var lines = [
            Localized.text(
                "The focused chat and a few others stay whole; the rest show as glance tiles, so many panes never slow the Mac down.")
        ]
        if let decision, decision.level > .calm, let reason = decision.reasons.first {
            lines.append(Localized.text("Fewer chats stay whole while the Mac is %@.", reason.chipWord))
        }
        return lines.joined(separator: " ")
    }

    @objc private func pressed() {
        if let popover, popover.isShown {
            popover.close()
            return
        }
        let controller = NSViewController()
        controller.view = content()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.ground(controller)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        self.popover = popover
    }

    private func content() -> NSView {
        let heading = NSTextField(labelWithString: button.title)
        heading.font = MacTheme.Ramp.font(.panelTitle)
        heading.textColor = MacTheme.Color.label
        let body = NSTextField(wrappingLabelWithString: Self.explanation(decision: decision))
        body.font = MacTheme.Ramp.font(.panelDetail)
        body.textColor = MacTheme.Color.secondaryLabel
        let toggle = NSButton(
            checkboxWithTitle: Localized.text("Keep all live"), target: self,
            action: #selector(toggled(_:)))
        toggle.state = keepAllLive() ? .on : .off
        toggle.font = MacTheme.Ramp.font(.control)
        var views: [NSView] = [heading, body, toggle]
        if decision?.level.overridesPreference == true {
            let note = NSTextField(
                wrappingLabelWithString: Localized.text(
                    "Ignored while the Mac is strained: keeping it responsive comes first."))
            note.font = MacTheme.Ramp.font(.panelFootnote)
            note.textColor = MacTheme.Color.warning
            views.append(note)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = MacTheme.Spacing.s
        stack.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.m, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.m,
            right: MacTheme.Spacing.m)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: 300).isActive = true
        for view in views where view is NSTextField {
            view.widthAnchor.constraint(lessThanOrEqualToConstant: 276).isActive = true
        }
        return stack
    }

    @objc private func toggled(_ sender: NSButton) {
        setKeepAllLive?(sender.state == .on)
    }
}
