import AppKit
import TailscodeCore

/// A section of a master's page: its name over a raised card of rows. Content, so it sits on the
/// window's canvas, never on glass.
@MainActor
final class MasterSection: NSView {
    private let title = NSTextField(labelWithString: "")
    private let trailingTitle = NSStackView()
    let body = FillingStack(topDown: false)
    private let card = NSView()
    private var drawnKey: [AnyHashable]?

    init(title text: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        title.stringValue = text.uppercased(with: .current)
        title.font = MacTheme.Ramp.font(.sectionLabel)
        title.textColor = MacTheme.Color.secondaryLabel
        title.translatesAutoresizingMaskIntoConstraints = false
        trailingTitle.orientation = .horizontal
        trailingTitle.spacing = MacTheme.Spacing.s
        trailingTitle.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = MacTheme.Radius.card
        card.translatesAutoresizingMaskIntoConstraints = false
        body.spacing = 0
        body.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        body.setHuggingPriority(.required, for: .vertical)
        card.addSubview(body)
        addSubview(title)
        addSubview(trailingTitle)
        addSubview(card)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacTheme.Spacing.xs),
            title.topAnchor.constraint(equalTo: topAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingTitle.leadingAnchor, constant: -MacTheme.Spacing.s),
            trailingTitle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacTheme.Spacing.xs),
            trailingTitle.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            card.topAnchor.constraint(equalTo: title.bottomAnchor, constant: MacTheme.Spacing.xs + 2),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            body.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            body.topAnchor.constraint(equalTo: card.topAnchor),
            body.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        paint()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            card.layer?.backgroundColor = MacTheme.Color.canvasRaised.cgColor
            card.layer?.borderColor = MacTheme.Color.separator.withAlphaComponent(0.5).cgColor
        }
        card.layer?.borderWidth = 0.5
    }

    /// Whether what the section would show now differs from what it shows, remembering the new
    /// key when it does: a section is rebuilt only for a change, so a selection, a focused row or a
    /// popover's anchor in it lives through a read that found nothing new.
    func redraws(for key: [AnyHashable]) -> Bool {
        guard key != drawnKey else { return false }
        drawnKey = key
        return true
    }

    /// The controls that ride on the section's title line, at its trailing end.
    func setAccessories(_ views: [NSView]) {
        trailingTitle.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for view in views { trailingTitle.addArrangedSubview(view) }
    }

    /// Replaces the rows, with a hairline between neighbours.
    func setRows(_ rows: [NSView]) {
        body.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, row) in rows.enumerated() {
            if index > 0 { body.addArrangedSubview(MasterHairline()) }
            body.addArrangedSubview(row)
        }
    }

    var sectionTitle: String { title.stringValue }
    var cardFill: CGColor? { card.layer?.backgroundColor }
}

/// The line between two rows of a section, inset from the leading edge like the system's lists.
@MainActor
final class MasterHairline: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        MacTheme.Color.separator.withAlphaComponent(0.6).setFill()
        NSRect(x: MacTheme.Spacing.m, y: 0, width: bounds.width - MacTheme.Spacing.m, height: 0.5).fill()
    }
}

/// One row of a section: what leads it (a lamp, a mark, nothing), its title with an optional tag,
/// the line under it in its tone, the few words at its trailing edge, and — when it does
/// something — a hover plate, a press and a context menu.
@MainActor
final class MasterLineRow: NSControl {
    private let leading: NSView?
    private let title = NSTextField(labelWithString: "")
    private let tagLabel = MasterTagLabel(weight: .semibold)
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let trailing = NSTextField(labelWithString: "")
    private var hovered = false {
        didSet { if hovered != oldValue { needsDisplay = true } }
    }
    private var tracking: NSTrackingArea?
    var onPress: (() -> Void)?
    var contextMenu: (() -> NSMenu?)?

    var titleText: String { title.stringValue }
    var detailText: String { detail.stringValue }
    var tagText: String { tagLabel.isHidden ? "" : tagLabel.stringValue }

    init(_ reading: MasterRowReading, leading: NSView? = nil, detailLines: Int = 2) {
        self.leading = leading
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        title.font = MacTheme.Ramp.font(.rowTitle)
        title.textColor = MacTheme.Color.label
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailing.lineBreakMode = .byTruncatingHead
        tagLabel.setContentCompressionResistancePriority(MacTheme.Layout.belowWindowSize, for: .horizontal)
        tagLabel.lineBreakMode = .byTruncatingTail
        detail.font = MacTheme.Ramp.font(.panelFootnote)
        detail.isSelectable = false
        detail.maximumNumberOfLines = detailLines
        detail.cell?.truncatesLastVisibleLine = true
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailing.font = MacTheme.Ramp.font(.rowStamp)
        trailing.textColor = MacTheme.Color.tertiaryLabel
        trailing.alignment = .right
        trailing.maximumNumberOfLines = 2
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        let spacer = masterSpacer()
        let titleLine = NSStackView(views: [title, tagLabel, spacer, trailing])
        titleLine.orientation = .horizontal
        titleLine.alignment = .firstBaseline
        titleLine.distribution = .fill
        titleLine.spacing = MacTheme.Spacing.s
        titleLine.detachesHiddenViews = true
        let lines = NSStackView(views: [titleLine, detail])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.distribution = .fill
        lines.spacing = 2
        lines.detachesHiddenViews = true
        lines.setHuggingPriority(.required, for: .vertical)
        lines.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lines)
        var constraints = [
            lines.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacTheme.Spacing.m),
            lines.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.s),
            lines.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -MacTheme.Spacing.s),
            titleLine.widthAnchor.constraint(equalTo: lines.widthAnchor),
            detail.widthAnchor.constraint(equalTo: lines.widthAnchor),
        ]
        if let leading {
            leading.translatesAutoresizingMaskIntoConstraints = false
            addSubview(leading)
            constraints += [
                leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacTheme.Spacing.m),
                leading.centerYAnchor.constraint(equalTo: title.centerYAnchor),
                lines.leadingAnchor.constraint(equalTo: leading.trailingAnchor, constant: MacTheme.Spacing.s + 2),
            ]
        } else {
            constraints.append(lines.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacTheme.Spacing.m))
        }
        NSLayoutConstraint.activate(constraints)
        show(reading)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ reading: MasterRowReading) {
        title.stringValue = reading.title
        detail.stringValue = reading.detail.text
        let quiet = reading.detail.tone == .quiet || reading.detail.tone == .good
        detail.textColor = quiet ? MacTheme.Color.secondaryLabel : MasterInk.color(reading.detail.tone)
        detail.isHidden = reading.detail.text.isEmpty
        trailing.stringValue = reading.trailing ?? ""
        trailing.isHidden = reading.trailing == nil
        if let mark = reading.tag {
            tagLabel.stringValue = " \(mark.text) "
            tagLabel.ink = MasterInk.color(mark.tone)
            tagLabel.isHidden = false
        } else {
            tagLabel.isHidden = true
        }
        setAccessibilityElement(true)
        setAccessibilityRole(onPress == nil ? .staticText : .button)
        setAccessibilityLabel(reading.accessibilityLabel)
    }

    /// With Full Keyboard Access on, a row that does something is a stop in the Tab loop and Space
    /// or Return presses it, as the system's own controls are.
    override var acceptsFirstResponder: Bool { onPress != nil && NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 4, dy: 1) }

    override func drawFocusRingMask() {
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: MacTheme.Radius.control, yRadius: MacTheme.Radius.control
        ).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        guard onPress != nil else { return }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = onPress != nil }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { onPress?() }

    override func keyDown(with event: NSEvent) {
        guard onPress != nil, event.characters == " " || event.characters == "\r" else {
            super.keyDown(with: event)
            return
        }
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        MacTheme.Color.label.withAlphaComponent(0.05).setFill()
        bounds.insetBy(dx: 4, dy: 1).fill()
    }
}

/// A capsule of words — a fact about what a task starts with, a skill, a place — tinted by tone.
@MainActor
final class MasterChip: NSView {
    private let label = NSTextField(labelWithString: "")
    private let lamp: LampView?

    init(_ line: MasterLine, lamp showsLamp: Bool = false) {
        lamp = showsLamp && line.tone != .quiet ? LampView(color: MasterInk.color(line.tone), filled: true) : nil
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 11
        label.stringValue = line.text
        label.font = MacTheme.Ramp.font(.panelFootnote)
        label.textColor = MacTheme.Color.label
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        let row = NSStackView(views: [lamp, label].compactMap { $0 })
        row.orientation = .horizontal
        row.spacing = 5
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 3, left: 9, bottom: 3, right: 9)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityLabel(line.text)
        paint()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var text: String { label.stringValue }

    override var intrinsicContentSize: NSSize {
        let inner = label.intrinsicContentSize
        let lampWidth: CGFloat = lamp == nil ? 0 : 14
        return NSSize(width: inner.width + 18 + lampWidth, height: max(22, inner.height + 6))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = MacTheme.Color.label.withAlphaComponent(0.07).cgColor
        }
    }
}

/// A plain link-like button in the accent colour, for the one verb a section offers inline.
@MainActor
func masterLinkButton(_ title: String, target: AnyObject?, action: Selector?) -> NSButton {
    let button = NSButton(title: title, target: target, action: action)
    button.isBordered = false
    button.contentTintColor = MacTheme.Color.accent
    button.attributedTitle = NSAttributedString(
        string: title,
        attributes: [.font: MacTheme.Ramp.font(.rowTitle), .foregroundColor: MacTheme.Color.accent])
    button.setContentHuggingPriority(.required, for: .horizontal)
    return button
}

/// A small button for a section's title line.
@MainActor
func masterSmallButton(_ title: String, target: AnyObject?, action: Selector?) -> NSButton {
    let button = NSButton(title: title, target: target, action: action)
    button.bezelStyle = .accessoryBarAction
    button.controlSize = .small
    button.setContentHuggingPriority(.required, for: .horizontal)
    return button
}

/// The chooser's Masters section: every master as a pressable chip — mark, name, machine — above
/// the model families. A press starts a task with that master rather than choosing a model.
@MainActor
final class MasterChooserStrip: NSView {
    private let flow = ChipFlow()

    init(rows: [MasterRow], onPick: @escaping @MainActor (MasterRow) -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: MasterWords.mastersSection.uppercased(with: .current))
        title.font = MacTheme.Ramp.font(.sectionLabel)
        title.textColor = MacTheme.Color.secondaryLabel
        let machines = Set(rows.map(\.profileID)).count
        flow.setChips(
            rows.map { row in
                let chip = MasterPickChip(row: row, showsMachine: machines > 1)
                chip.onPick = { onPick(row) }
                return chip
            })
        let column = NSStackView(views: [title, flow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            flow.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// One master in the chooser: its mark, its name, and — when masters live on several machines — where.
@MainActor
final class MasterPickChip: NSControl {
    private let label = NSTextField(labelWithString: "")
    private let mark: MasterMarkView
    private var hovered = false {
        didSet { if hovered != oldValue { needsDisplay = true } }
    }
    private var tracking: NSTrackingArea?
    var onPick: (() -> Void)?

    init(row: MasterRow, showsMachine: Bool) {
        mark = MasterMarkView(row: row, side: 18)
        super.init(frame: .zero)
        label.stringValue = showsMachine ? "\(row.master.name) · \(row.machine)" : row.master.name
        label.font = MacTheme.Ramp.font(.rowTitle)
        label.translatesAutoresizingMaskIntoConstraints = false
        let line = NSStackView(views: [mark, label])
        line.orientation = .horizontal
        line.spacing = 6
        line.alignment = .centerY
        line.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 10)
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.topAnchor.constraint(equalTo: topAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        wantsLayer = true
        layer?.cornerRadius = 12
        toolTip = [row.master.purpose, MasterWords.chooserDetail(row.machine)].filter { !$0.isEmpty }.joined(separator: "\n")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(row.master.name)
        paint()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: label.intrinsicContentSize.width + 18 + 6 + 14, height: 26)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = MacTheme.Color.label.withAlphaComponent(hovered ? 0.12 : 0.07).cgColor
        }
    }

    /// With Full Keyboard Access on, each master is a stop in the Tab loop and Space or Return
    /// starts its task, as the chooser's other choices do.
    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
    }

    override func keyDown(with event: NSEvent) {
        guard event.characters == " " || event.characters == "\r" else {
            super.keyDown(with: event)
            return
        }
        onPick?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        paint()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        paint()
    }

    override func mouseDown(with event: NSEvent) { onPick?() }

    override func accessibilityPerformPress() -> Bool {
        onPick?()
        return true
    }
}

/// A few words on a plate of their own colour — a proposal's New or Retire, a row's tag — the
/// plate read again under the label's own appearance whenever light and dark switch.
@MainActor
final class MasterTagLabel: NSTextField {
    var ink: NSColor = MacTheme.Color.secondaryLabel {
        didSet {
            textColor = ink
            paint()
        }
    }

    init(weight: NSFont.Weight) {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        maximumNumberOfLines = 1
        lineBreakMode = .byTruncatingTail
        font = NSFont.systemFont(ofSize: MacTheme.Ramp.font(.panelFootnote).pointSize - 1, weight: weight)
        textColor = ink
        wantsLayer = true
        layer?.cornerRadius = 4
        setContentHuggingPriority(.required, for: .horizontal)
        paint()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = ink.withAlphaComponent(0.16).cgColor
        }
    }
}

/// A rounded plate of one fill, read again under the plate's own appearance whenever light and
/// dark switch.
@MainActor
final class MasterPlate: NSView {
    private let fill: NSColor

    init(fill: NSColor, radius: CGFloat) {
        self.fill = fill
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        paint()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill.cgColor
        }
    }
}

/// A view held at the section's inset, its height exactly its content's and the insets', so a
/// line inside a section never takes room nobody gave it.
@MainActor
func masterInset(_ view: NSView, top: CGFloat, bottom: CGFloat) -> NSView {
    let holder = NSView()
    holder.translatesAutoresizingMaskIntoConstraints = false
    view.translatesAutoresizingMaskIntoConstraints = false
    holder.addSubview(view)
    let hugs = view.contentHuggingPriority(for: .horizontal) >= .required
    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: MacTheme.Spacing.m),
        hugs
            ? view.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor, constant: -MacTheme.Spacing.m)
            : view.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -MacTheme.Spacing.m),
        view.topAnchor.constraint(equalTo: holder.topAnchor, constant: top),
        view.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -bottom),
    ])
    return holder
}

/// A gap that only ever takes width: a view that never asks for height of its own, so a row it
/// pushes apart stays exactly as tall as its words.
@MainActor
func masterSpacer() -> NSView {
    let spacer = NSView()
    spacer.translatesAutoresizingMaskIntoConstraints = false
    spacer.setContentHuggingPriority(.init(1), for: .horizontal)
    spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
    spacer.heightAnchor.constraint(equalToConstant: 0).isActive = true
    return spacer
}

/// A stack that is exactly as tall as what it holds, on either axis, so nothing about its height
/// is left for the layout engine to guess.
@MainActor
func masterHug(_ stacks: NSStackView...) {
    for stack in stacks { stack.setHuggingPriority(.required, for: .vertical) }
}
