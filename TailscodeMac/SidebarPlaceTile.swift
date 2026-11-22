import AppKit

/// One of the sidebar's places (Agents, Scheduled, Masters) drawn as a compact tile: a symbol with
/// its count riding on its corner and a short caption under it. Three sit side by side in one row,
/// so the places cost the chat list a single line; what a place has to say beyond its count is its
/// tooltip and its accessibility label.
@MainActor
class SidebarPlaceTile: NSControl {
    private let icon = NSImageView()
    private let caption: NSTextField
    private let badge = NSTextField(labelWithString: "")
    private let badgeGround = RowKit.Ground(frame: .zero)
    private var hovered = false {
        didSet { if hovered != oldValue { needsDisplay = true } }
    }
    private var tracking: NSTrackingArea?
    private var badgeTint: (text: NSColor, fill: NSColor) = (MacTheme.Color.onAccent, MacTheme.Color.accent)
    var onPress: (() -> Void)?

    var badgeText: String { badge.isHidden ? "" : badge.stringValue }
    var captionText: String { caption.stringValue }

    init(symbol: String, caption text: String) {
        caption = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        icon.contentTintColor = MacTheme.Color.secondaryLabel
        icon.translatesAutoresizingMaskIntoConstraints = false
        caption.font = MacTheme.Ramp.font(.panelFootnote)
        caption.textColor = MacTheme.Color.secondaryLabel
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingTail
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        caption.translatesAutoresizingMaskIntoConstraints = false
        badge.font = .monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        badge.alignment = .center
        badge.translatesAutoresizingMaskIntoConstraints = false
        badgeGround.radius = 7
        badgeGround.translatesAutoresizingMaskIntoConstraints = false
        for view in [icon, caption, badgeGround, badge] { addSubview(view) }
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            icon.heightAnchor.constraint(equalToConstant: 18),
            caption.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 2),
            caption.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 2),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            caption.centerXAnchor.constraint(equalTo: centerXAnchor),
            badge.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: -3),
            badge.centerYAnchor.constraint(equalTo: icon.topAnchor, constant: 2),
            badgeGround.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -4),
            badgeGround.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 4),
            badgeGround.heightAnchor.constraint(equalToConstant: 14),
            badgeGround.widthAnchor.constraint(greaterThanOrEqualToConstant: 14),
            badgeGround.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
        ])
        setContentHuggingPriority(.required, for: .vertical)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        show(badge: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    /// The tile's own height, so the list below it gets the rest of the sidebar.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 6 + 18 + 2 + caption.intrinsicContentSize.height + 5)
    }

    func show(badge count: Int?, text: NSColor = MacTheme.Color.onAccent, fill: NSColor = MacTheme.Color.accent) {
        let shown = (count ?? 0) > 0
        badge.stringValue = shown ? "\(count ?? 0)" : ""
        badge.isHidden = !shown
        badgeGround.isHidden = !shown
        badgeTint = (text, fill)
        paint()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { onPress?() }

    override func keyDown(with event: NSEvent) {
        guard event.characters == " " || event.characters == "\r" else {
            super.keyDown(with: event)
            return
        }
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        MacTheme.Color.label.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: MacTheme.Radius.control, yRadius: MacTheme.Radius.control).fill()
    }

    private func paint() {
        badge.textColor = badgeTint.text
        badgeGround.fill = badgeTint.fill
        badgeGround.needsDisplay = true
    }
}
