import AppKit
import TailscodeCore

/// One answer to a question, as wide as the card and as tall as its words: a button whose label
/// wraps, because an option a person has to choose between is never shortened to fit a title bar.
@MainActor
final class AgentsOptionButton: NSControl {
    private let ground = RowKit.Ground(frame: .zero)
    private let label = NSTextField(wrappingLabelWithString: "")
    private var hovered = false {
        didSet { if hovered != oldValue { paint() } }
    }
    private var pressed = false {
        didSet { if pressed != oldValue { paint() } }
    }
    private var tracking: NSTrackingArea?

    var chosen = false {
        didSet { if chosen != oldValue { paint() } }
    }

    var title: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            setAccessibilityLabel(newValue)
        }
    }

    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            paint()
            if !isEnabled, window?.firstResponder === self { window?.makeFirstResponder(nil) }
        }
    }

    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.font = MacTheme.Ramp.font(.option)
        label.isSelectable = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ground.radius = MacTheme.Radius.control
        addSubview(ground)
        addSubview(label)
        let inset = MacTheme.Spacing.m
        NSLayoutConstraint.activate([
            ground.leadingAnchor.constraint(equalTo: leadingAnchor),
            ground.trailingAnchor.constraint(equalTo: trailingAnchor),
            ground.topAnchor.constraint(equalTo: topAnchor),
            ground.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            label.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.s),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -MacTheme.Spacing.s),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        self.title = title
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { isEnabled }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(
            roundedRect: bounds, xRadius: MacTheme.Radius.control, yRadius: MacTheme.Radius.control
        ).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = isEnabled }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            let inside = bounds.contains(convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp {
                pressed = false
                if inside { _ = sendAction(action, to: target) }
                return
            }
            pressed = inside
        }
        pressed = false
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled, event.characters == " " || event.characters == "\r" else {
            super.keyDown(with: event)
            return
        }
        _ = sendAction(action, to: target)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        let ink = MacTheme.Color.label
        let fill: NSColor
        if chosen {
            fill = MacTheme.Color.accent.withAlphaComponent(0.22)
        } else if pressed {
            fill = ink.withAlphaComponent(0.16)
        } else if hovered {
            fill = ink.withAlphaComponent(0.11)
        } else {
            fill = ink.withAlphaComponent(0.07)
        }
        ground.fill = fill
        ground.stroke = chosen ? MacTheme.Color.accent : MacTheme.Color.separator
        ground.needsDisplay = true
        label.textColor = isEnabled || chosen ? MacTheme.Color.label : MacTheme.Color.tertiaryLabel
        alphaValue = isEnabled || chosen ? 1 : 0.7
    }
}
