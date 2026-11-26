import AppKit
import TailscodeCore

/// The panes a window cannot show right now, named along the bottom of the canvas: zoomed away, or
/// stepped aside because the window is too small for every pane at its minimum.
///
/// Each is a chip — the activity face, the title cut to eighteen characters, a dot when the turn is
/// waiting on the person — and pressing one goes to that pane: out of the zoom, or swapped in for
/// the pane focused longest ago. Chips that do not fit become a count. The chips are glass
/// capsules in one container, the floating-control layer; the strip under them is canvas.
@MainActor
final class OverflowStripView: NSView {
    struct Chip: Equatable {
        let id: PaneID
        let title: String
        let activity: ActivityKind?
        let needsYou: Bool
    }

    var onPress: ((PaneID) -> Void)?

    private let group = MacTheme.glassGroup(spacing: MacTheme.Spacing.s)
    private let row = NSStackView()
    private let more = NSTextField(labelWithString: "")
    private(set) var chips: [Chip] = []
    private var built: [PaneID: NSView] = [:]
    /// The chips in the order they were built, what each measured, and the "%@ more" line for the
    /// count it says: laying the strip out again sizes nothing it has already sized and builds no
    /// string it has already built.
    private var builtOrder: [PaneID] = []
    private var measuredWidths: [PaneID: CGFloat] = [:]
    private var moreLine: (count: Int, text: String)?
    private var spokenCount: Int?

    static let titleLimit = 18

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MacTheme.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        group.contentView = row
        addSubview(group)
        more.translatesAutoresizingMaskIntoConstraints = false
        addSubview(more)
        NSLayoutConstraint.activate([
            group.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacTheme.Spacing.s),
            group.centerYAnchor.constraint(equalTo: centerYAnchor),
            group.trailingAnchor.constraint(
                lessThanOrEqualTo: more.leadingAnchor, constant: -MacTheme.Spacing.s),
            more.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacTheme.Spacing.m),
            more.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = MacTheme.Color.canvas.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        more.font = MacTheme.Ramp.font(.chip)
        more.textColor = MacTheme.Color.secondaryLabel
        let chips = self.chips
        self.chips = []
        show(chips)
    }

    /// Shows these chips, building only the ones that changed, and as many as the width holds.
    func show(_ next: [Chip]) {
        guard next != chips else {
            fit()
            return
        }
        chips = next
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        built = [:]
        builtOrder = []
        measuredWidths = [:]
        for chip in next {
            let view = makeChip(chip)
            built[chip.id] = view
            builtOrder.append(chip.id)
            row.addArrangedSubview(view)
        }
        if spokenCount != next.count {
            spokenCount = next.count
            setAccessibilityLabel(Localized.text("%@ more", "\(next.count)"))
        }
        fit()
    }

    override func layout() {
        super.layout()
        fit()
    }

    /// Hides the chips past the strip's width and says how many.
    private func fit() {
        let room = bounds.width - MacTheme.Spacing.s - MacTheme.Spacing.m - 60
        var used: CGFloat = 0
        var hidden = 0
        for (index, view) in row.arrangedSubviews.enumerated() {
            let width = measuredWidth(view, at: index) + row.spacing
            if used + width > room {
                if !view.isHidden { view.isHidden = true }
                hidden += 1
            } else {
                if view.isHidden { view.isHidden = false }
                used += width
            }
        }
        more.isHidden = hidden == 0
        if moreLine?.count != hidden {
            moreLine = (hidden, Localized.text("%@ more", "\(hidden)"))
            more.stringValue = moreLine?.text ?? ""
        }
    }

    /// One chip's width, measured for the chip it was built for and kept until the chips are
    /// rebuilt: a stack of glass capsules sizes itself the same way however often it is laid out.
    private func measuredWidth(_ view: NSView, at index: Int) -> CGFloat {
        guard builtOrder.indices.contains(index) else { return view.fittingSize.width }
        let id = builtOrder[index]
        if let width = measuredWidths[id] { return width }
        let width = view.fittingSize.width
        measuredWidths[id] = width
        return width
    }

    private func makeChip(_ chip: Chip) -> NSView {
        let badge = ActivityBadgeView(pointSize: 10)
        badge.activity = chip.activity
        badge.isHidden = chip.activity == nil
        let label = NSTextField(labelWithString: Self.cut(chip.title))
        label.font = MacTheme.Ramp.font(.chip)
        label.textColor = MacTheme.Color.onGlass
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = MacTheme.Color.warning.cgColor
        dot.isHidden = !chip.needsYou
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6), dot.heightAnchor.constraint(equalToConstant: 6),
        ])
        let content = NSStackView(views: [badge, label, dot])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = MacTheme.Spacing.xs
        content.detachesHiddenViews = true
        content.edgeInsets = NSEdgeInsets(
            top: 2, left: MacTheme.Spacing.s, bottom: 2, right: MacTheme.Spacing.s)
        let id = chip.id
        let surface = StripChip(content: content) { [weak self] in self?.onPress?(id) }
        surface.toolTip = chip.title
        surface.setAccessibilityLabel(
            [chip.title, chip.activity?.spoken].compactMap { $0 }.joined(separator: ", "))
        return MacTheme.glass(around: surface, cornerRadius: 10)
    }

    static func cut(_ title: String) -> String {
        title.count > titleLimit ? String(title.prefix(titleLimit - 1)) + "…" : title
    }

    /// The press a screen reader makes on a chip, and the selftest's way of pressing one.
    func press(_ id: PaneID) {
        onPress?(id)
    }
}

/// One chip's press: the whole capsule acts when the button comes up over it, and an assistive
/// app presses it as the button it is.
@MainActor
private final class StripChip: NSView {
    private let action: () -> Void

    init(content: NSView, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action()
    }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }

    override func accessibilityChildren() -> [Any]? { [] }
}
