import AppKit
import TailscodeCore

/// The sidebar's way into the board: "Agents" at the top of the list with a count that is amber
/// when somebody is waiting on the person and the number of agents working otherwise. The count is
/// a number and a word in the accessibility label as well as a colour.
@MainActor
final class AgentsSidebarEntry: NSControl {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: Localized.text("Agents"))
    private let badge = NSTextField(labelWithString: "")
    private let badgeGround = RowKit.Ground(frame: .zero)
    private var hovered = false {
        didSet { if hovered != oldValue { needsDisplay = true } }
    }
    private var tracking: NSTrackingArea?
    private(set) var needsYou = 0
    private(set) var working = 0
    var onOpen: (() -> Void)?

    var badgeText: String { badge.isHidden ? "" : badge.stringValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        icon.contentTintColor = MacTheme.Color.secondaryLabel
        icon.translatesAutoresizingMaskIntoConstraints = false
        title.font = MacTheme.Ramp.font(.rowTitleStrong)
        title.textColor = MacTheme.Color.label
        title.translatesAutoresizingMaskIntoConstraints = false
        badge.font = .monospacedDigitSystemFont(
            ofSize: MacTheme.Ramp.font(.rowMeta).pointSize, weight: .semibold)
        badge.alignment = .center
        badge.translatesAutoresizingMaskIntoConstraints = false
        badgeGround.radius = 9
        badgeGround.isHidden = true
        for view in [badgeGround, icon, title, badge] { addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacTheme.Spacing.m),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: MacTheme.Spacing.s),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacTheme.Spacing.m - 6),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: MacTheme.Spacing.m),
            badgeGround.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -6),
            badgeGround.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 6),
            badgeGround.topAnchor.constraint(equalTo: badge.topAnchor, constant: -1),
            badgeGround.bottomAnchor.constraint(equalTo: badge.bottomAnchor, constant: 1),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        render(needsYou: 0, working: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseDown(with event: NSEvent) { onOpen?() }

    override func keyDown(with event: NSEvent) {
        guard event.characters == " " || event.characters == "\r" else {
            super.keyDown(with: event)
            return
        }
        onOpen?()
    }

    override func accessibilityPerformPress() -> Bool {
        onOpen?()
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        MacTheme.Color.label.withAlphaComponent(0.06).setFill()
        NSBezierPath(
            roundedRect: bounds, xRadius: MacTheme.Radius.control, yRadius: MacTheme.Radius.control
        ).fill()
    }

    func render(needsYou: Int, working: Int) {
        self.needsYou = needsYou
        self.working = working
        let count = needsYou > 0 ? needsYou : working
        badge.stringValue = "\(count)"
        badge.isHidden = count == 0
        badgeGround.isHidden = count == 0
        let phrase =
            needsYou > 0
            ? Localized.text("%d needs you", needsYou)
            : (working > 0 ? Localized.text("%d working", working) : "")
        setAccessibilityLabel(
            phrase.isEmpty ? Localized.text("Agents") : Localized.text("Agents") + ", " + phrase)
        paint()
    }

    private func paint() {
        let amber = needsYou > 0
        badge.textColor = amber ? MacTheme.Color.onAccent : MacTheme.Color.success
        badgeGround.fill = amber ? MacTheme.Color.warning : MacTheme.Color.success.withAlphaComponent(0.18)
        badgeGround.needsDisplay = true
    }
}
