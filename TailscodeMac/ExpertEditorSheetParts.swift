import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// The expert's mark as the press that changes it: its colour and its two letters open beside it.
@MainActor
final class ExpertMarkButton: NSControl {
    let mark: ExpertMarkView
    private let side: CGFloat

    init(glyph: String, hue: ExpertHue, side: CGFloat) {
        mark = ExpertMarkView(glyph: glyph, hue: hue, side: side)
        self.side = side
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(mark)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side), heightAnchor.constraint(equalToConstant: side),
            mark.centerXAnchor.constraint(equalTo: centerXAnchor), mark.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }
    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: side * 0.24, yRadius: side * 0.24).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) { sendAction(action, to: target) }

    override func keyDown(with event: NSEvent) {
        guard event.characters == " " || event.characters == "\r" else {
            super.keyDown(with: event)
            return
        }
        sendAction(action, to: target)
    }

    override func accessibilityPerformPress() -> Bool {
        sendAction(action, to: target)
    }
}

/// One part of an expert in the editor's list: its name over the line that says what it holds,
/// quieter while it holds nothing of the person's own.
@MainActor
final class ExpertOutlineCell: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        title.font = MacTheme.Ramp.font(.rowTitle)
        title.textColor = .labelColor
        value.font = MacTheme.Ramp.font(.panelFootnote)
        value.lineBreakMode = .byTruncatingMiddle
        let chevron = NSImageView()
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        chevron.contentTintColor = .tertiaryLabelColor
        for view in [title, value, chevron] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            title.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -6),
            title.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            value.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            value.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -6),
            value.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = title
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ row: ExpertOutline.Row) {
        title.stringValue = row.title
        value.stringValue = row.value
        value.textColor = row.isSet ? .secondaryLabelColor : .tertiaryLabelColor
        setAccessibilityLabel("\(row.title), \(row.value)")
    }
}

/// One hue to choose: a dot of the colour, ringed while chosen.
@MainActor
final class ExpertSwatch: NSControl {
    let hue: ExpertHue
    var chosen = false {
        didSet {
            needsDisplay = true
            setAccessibilityValue(NSNumber(value: chosen))
        }
    }

    init(hue: ExpertHue) {
        self.hue = hue
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 20), heightAnchor.constraint(equalToConstant: 20),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(hue.name)
        setAccessibilityValue(NSNumber(value: false))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 20, height: 20) }

    override func mouseDown(with event: NSEvent) { sendAction(action, to: target) }

    /// With Full Keyboard Access on, each colour is a stop in the Tab loop and Space or Return
    /// chooses it, as the system's own radio buttons are.
    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(ovalIn: bounds).fill()
    }

    override func keyDown(with event: NSEvent) {
        guard event.characters == " " || event.characters == "\r" else {
            super.keyDown(with: event)
            return
        }
        sendAction(action, to: target)
    }

    override func accessibilityPerformPress() -> Bool {
        sendAction(action, to: target)
    }

    override func draw(_ dirtyRect: NSRect) {
        ExpertInk.hue(hue).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3)).fill()
        guard chosen else { return }
        MacTheme.Color.label.setStroke()
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75))
        ring.lineWidth = 1.5
        ring.stroke()
    }
}

/// One device or service on the bench, as the form edits it: what kind, its name, how the machine
/// finds it, the lock held around it, and a press that takes it off. Placed by constraints, one line.
@MainActor
final class ExpertBenchEditorRow: NSView, NSTextFieldDelegate {
    private let id: String
    let nameField = NSTextField()
    private let kind = NSPopUpButton()
    private let target = NSTextField()
    private let lock = NSTextField()
    private let remove = NSButton()
    private let machine: String
    var onRemove: (() -> Void)?
    var onChange: (() -> Void)?

    func controlTextDidChange(_ obj: Notification) { onChange?() }

    init(item: ExpertBenchItem, machine: String) {
        id = item.id
        self.machine = machine
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        kind.addItems(withTitles: [Localized.text("Apple device"), Localized.text("Command"), Localized.text("Port")])
        kind.selectItem(at: ExpertBenchItem.Kind.allCases.firstIndex(of: item.kind) ?? 0)
        kind.target = self
        kind.action = #selector(kindChanged)
        nameField.placeholderString = ExpertWords.name
        nameField.stringValue = item.name
        switch item.kind {
        case .appleDevice: target.stringValue = item.identifier ?? ""
        case .command: target.stringValue = item.command ?? ""
        case .port: target.stringValue = [item.host, item.port.map(String.init)].compactMap { $0 }.joined(separator: ":")
        }
        lock.placeholderString = Localized.text("Lock file (optional)")
        lock.stringValue = item.lock ?? ""
        remove.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: Localized.text("Remove"))
        remove.isBordered = false
        remove.target = self
        remove.action = #selector(removeTapped)
        nameField.setAccessibilityLabel(ExpertWords.name)
        lock.setAccessibilityLabel(Localized.text("Lock file (optional)"))
        nameField.delegate = self
        target.delegate = self
        for view in [kind, nameField, target, lock, remove] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let gap = MacTheme.Spacing.s
        NSLayoutConstraint.activate([
            kind.leadingAnchor.constraint(equalTo: leadingAnchor),
            kind.widthAnchor.constraint(equalToConstant: 118),
            kind.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            nameField.leadingAnchor.constraint(equalTo: kind.trailingAnchor, constant: gap),
            nameField.widthAnchor.constraint(equalToConstant: 112),
            nameField.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            nameField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            target.leadingAnchor.constraint(equalTo: nameField.trailingAnchor, constant: gap),
            target.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            target.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            lock.leadingAnchor.constraint(equalTo: target.trailingAnchor, constant: gap),
            lock.widthAnchor.constraint(equalToConstant: 128),
            lock.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            remove.leadingAnchor.constraint(equalTo: lock.trailingAnchor, constant: gap),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor),
            remove.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            remove.widthAnchor.constraint(equalToConstant: 20),
        ])
        kindChanged()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func kindChanged() {
        switch kind.indexOfSelectedItem {
        case 1: target.placeholderString = Localized.text("A command that exits 0 when it is there")
        case 2: target.placeholderString = "host:port"
        default: target.placeholderString = Localized.text("UDID or device name on %@", machine)
        }
        target.setAccessibilityLabel(target.placeholderString)
        onChange?()
    }

    @objc private func removeTapped() { onRemove?() }

    /// The item as the form says it, or nil for a row left empty.
    var item: ExpertBenchItem? {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let value = target.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty || !value.isEmpty else { return nil }
        let kinds = ExpertBenchItem.Kind.allCases
        let chosen = kinds.indices.contains(kind.indexOfSelectedItem) ? kinds[kind.indexOfSelectedItem] : .appleDevice
        let lockPath = lock.stringValue.trimmingCharacters(in: .whitespaces)
        var item = ExpertBenchItem(
            id: id, name: name.isEmpty ? value : name, kind: chosen, lock: lockPath.isEmpty ? nil : lockPath)
        switch chosen {
        case .appleDevice: item.identifier = value.isEmpty ? nil : value
        case .command: item.command = value
        case .port:
            let parts = value.split(separator: ":")
            if parts.count == 2 {
                item.host = String(parts[0])
                item.port = Int(parts[1])
            } else {
                item.port = Int(value)
            }
        }
        return item
    }
}

/// One guard, as the form edits it: its name and command, and — when it measures a number — the
/// pattern that finds the number and the line it is held to. Placed by constraints; the metric
/// line folds away when the guard measures nothing.
@MainActor
final class ExpertGuardEditorRow: NSView, NSTextFieldDelegate {
    private let id: String
    let nameField = NSTextField()
    private let command = NSTextField()
    private let measures = NSButton(checkboxWithTitle: Localized.text("Measures a number"), target: nil, action: nil)
    private let pattern = NSTextField()
    private let bound = NSPopUpButton()
    private let limit = NSTextField()
    private let unit = NSTextField()
    private let remove = NSButton()
    private var withMetric: NSLayoutConstraint!
    private var withoutMetric: NSLayoutConstraint!
    var onRemove: (() -> Void)?
    var onChange: (() -> Void)?

    func controlTextDidChange(_ obj: Notification) { onChange?() }

    init(item: ExpertGuard) {
        id = item.id
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        nameField.placeholderString = ExpertWords.name
        nameField.stringValue = item.name
        command.placeholderString = Localized.text("The command, run in the expert's folder")
        command.stringValue = item.command
        command.font = MacTheme.Ramp.font(.code)
        remove.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: Localized.text("Remove"))
        remove.isBordered = false
        remove.target = self
        remove.action = #selector(removeTapped)
        measures.target = self
        measures.action = #selector(measuresChanged)
        measures.state = item.metric == nil ? .off : .on
        pattern.placeholderString = "first frame ([0-9.]+) ms"
        pattern.stringValue = item.metric?.pattern ?? ""
        pattern.font = MacTheme.Ramp.font(.code)
        bound.addItems(withTitles: [Localized.text("at most"), Localized.text("at least")])
        bound.selectItem(at: item.metric?.atLeast != nil && item.metric?.atMost == nil ? 1 : 0)
        limit.placeholderString = "100"
        limit.stringValue = (item.metric?.atMost ?? item.metric?.atLeast).map { String(format: "%g", $0) } ?? ""
        unit.placeholderString = "ms"
        unit.stringValue = item.metric?.unit ?? ""
        nameField.setAccessibilityLabel(ExpertWords.name)
        command.setAccessibilityLabel(Localized.text("Command"))
        pattern.setAccessibilityLabel(Localized.text("Pattern"))
        limit.setAccessibilityLabel(Localized.text("At most"))
        unit.setAccessibilityLabel(Localized.text("Unit"))
        nameField.delegate = self
        command.delegate = self
        for view in [nameField, command, remove, measures, pattern, bound, limit, unit] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let gap = MacTheme.Spacing.s
        withMetric = bottomAnchor.constraint(equalTo: pattern.bottomAnchor, constant: 2)
        withoutMetric = bottomAnchor.constraint(equalTo: measures.bottomAnchor, constant: 2)
        NSLayoutConstraint.activate([
            nameField.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameField.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            nameField.widthAnchor.constraint(equalToConstant: 150),
            command.leadingAnchor.constraint(equalTo: nameField.trailingAnchor, constant: gap),
            command.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            command.trailingAnchor.constraint(equalTo: remove.leadingAnchor, constant: -gap),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor),
            remove.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            remove.widthAnchor.constraint(equalToConstant: 20),
            measures.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            measures.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 6),
            pattern.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            pattern.topAnchor.constraint(equalTo: measures.bottomAnchor, constant: 6),
            pattern.widthAnchor.constraint(equalToConstant: 220),
            bound.leadingAnchor.constraint(equalTo: pattern.trailingAnchor, constant: gap),
            bound.centerYAnchor.constraint(equalTo: pattern.centerYAnchor),
            limit.leadingAnchor.constraint(equalTo: bound.trailingAnchor, constant: gap),
            limit.centerYAnchor.constraint(equalTo: pattern.centerYAnchor),
            limit.widthAnchor.constraint(equalToConstant: 64),
            unit.leadingAnchor.constraint(equalTo: limit.trailingAnchor, constant: gap),
            unit.centerYAnchor.constraint(equalTo: pattern.centerYAnchor),
            unit.widthAnchor.constraint(equalToConstant: 48),
            unit.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        measuresChanged()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func measuresChanged() {
        let shows = measures.state == .on
        for view in [pattern, bound, limit, unit] as [NSView] { view.isHidden = !shows }
        withMetric.isActive = shows
        withoutMetric.isActive = !shows
    }

    @objc private func removeTapped() { onRemove?() }

    var item: ExpertGuard? {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let line = command.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty || !line.isEmpty else { return nil }
        var metric: ExpertGuardMetric?
        if measures.state == .on, !pattern.stringValue.isEmpty {
            let value = Double(limit.stringValue.replacingOccurrences(of: ",", with: "."))
            metric = ExpertGuardMetric(
                pattern: pattern.stringValue, atMost: bound.indexOfSelectedItem == 0 ? value : nil,
                atLeast: bound.indexOfSelectedItem == 1 ? value : nil, unit: unit.stringValue.isEmpty ? nil : unit.stringValue)
        }
        return ExpertGuard(id: id, name: name.isEmpty ? line : name, command: line, metric: metric)
    }
}
