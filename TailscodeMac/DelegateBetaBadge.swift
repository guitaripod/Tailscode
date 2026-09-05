import AppKit
import TailscodeCore

/// The mark Delegate wears while it is new, on the Mac: a capsule beside the board's title. Resting
/// the pointer on it is enough to read why — the popover stays while the pointer is on it and
/// leaves when the pointer does — and a click does the same for a trackpad or a screen reader.
/// Every word is `DelegateBeta`'s.
@MainActor
final class DelegateBetaBadge: NSView, NSPopoverDelegate {
    private let label = NSTextField(labelWithString: DelegateBeta.badge)
    private var popover: NSPopover?
    private var closing: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        label.font = Self.font
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(DelegateBeta.spoken)
        toolTip = nil
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self))
        paint()
        NotificationCenter.default.addObserver(
            self, selector: #selector(repaint), name: MacTheme.Chrome.didRepaint, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        closing?.cancel()
        show()
    }

    override func mouseExited(with event: NSEvent) {
        scheduleClose()
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if popover == nil { show() } else { close() }
    }

    override func accessibilityPerformPress() -> Bool {
        if popover == nil { show() } else { close() }
        return true
    }

    /// The card, opened the way a press opens it — the road `--open delegate-beta` takes so the
    /// popover can be dumped and checked without a pointer.
    func reveal() { _ = accessibilityPerformPress() }

    private static var font: NSFont {
        let base = MacTheme.Ramp.font(.panelFootnote)
        let bold = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        let rounded = bold.fontDescriptor.withDesign(.rounded).map { NSFont(descriptor: $0, size: bold.pointSize) } ?? nil
        return rounded ?? bold
    }

    @objc private func repaint() { paint() }

    private func paint() {
        let tint = MacTheme.Color.mark
        layer?.backgroundColor = tint.withAlphaComponent(0.14).cgColor
        layer?.borderColor = tint.withAlphaComponent(0.45).cgColor
        label.textColor = tint
        label.attributedStringValue = NSAttributedString(
            string: DelegateBeta.badge, attributes: [.font: Self.font, .kern: 1.1, .foregroundColor: tint])
    }

    private func show() {
        guard popover == nil, window != nil else { return }
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.delegate = self
        let panel = DelegateBetaPanel()
        panel.onHover = { [weak self] inside in
            if inside { self?.closing?.cancel() } else { self?.scheduleClose() }
        }
        popover.contentViewController = panel
        popover.show(relativeTo: bounds, of: self, preferredEdge: .minY)
        self.popover = popover
    }

    private func scheduleClose() {
        closing?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.close() }
        closing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func close() {
        closing?.cancel()
        popover?.close()
        popover = nil
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
    }
}

/// Why Delegate is in beta, as the popover's card: the title and Core's paragraphs in one column,
/// and a view that says when the pointer is on it so the card is not pulled away while it is read.
@MainActor
final class DelegateBetaPanel: NSViewController {
    var onHover: ((Bool) -> Void)?

    override func loadView() {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = MacTheme.Spacing.m
        column.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.l, left: MacTheme.Spacing.l, bottom: MacTheme.Spacing.l,
            right: MacTheme.Spacing.l)
        column.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(wrappingLabelWithString: DelegateBeta.title)
        title.font = MacTheme.Ramp.font(.panelTitle)
        title.textColor = MacTheme.Color.label
        column.addArrangedSubview(title)
        for paragraph in DelegateBeta.paragraphs {
            let body = NSTextField(wrappingLabelWithString: paragraph)
            body.font = MacTheme.Ramp.font(.cardBody)
            body.textColor = MacTheme.Color.secondaryLabel
            body.preferredMaxLayoutWidth = 340 * MacTheme.UIScale.factor
            column.addArrangedSubview(body)
        }
        let host = HoverView()
        host.onHover = { [weak self] inside in self?.onHover?(inside) }
        host.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: host.topAnchor),
            column.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            column.widthAnchor.constraint(equalToConstant: 380 * MacTheme.UIScale.factor),
        ])
        view = host
    }

    private final class HoverView: NSView {
        var onHover: ((Bool) -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(
                NSTrackingArea(
                    rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                    owner: self))
        }

        override func mouseEntered(with event: NSEvent) { onHover?(true) }

        override func mouseExited(with event: NSEvent) { onHover?(false) }
    }
}
