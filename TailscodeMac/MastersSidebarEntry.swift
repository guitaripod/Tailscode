import AppKit
import CodingAgentKit
import TailscodeCore

/// The sidebar's place for masters: "Masters" under Scheduled, then one line per master — its mark,
/// its name, the one state line the shelf says (working on a task, notes to review, a guard
/// failing, at rest) and the count of notes waiting. It is there only while some machine keeps
/// masters. A press on the title opens the Masters window; a press on a master opens it on that
/// master; a master's context menu starts a task or opens its notebook.
@MainActor
final class MastersSidebarEntry: NSView {
    private let header = MastersSidebarHeader()
    private let list = NSStackView()
    private let more = NSTextField(labelWithString: "")
    private var rowViews: [MasterSidebarRow] = []
    var onOpen: ((MasterRow?) -> Void)?
    var onNewTask: ((MasterRow) -> Void)?

    /// The most masters the sidebar lists before it says how many more there are.
    static let shown = 6

    /// What the place lists, for a harness.
    var shownNames: [String] { rowViews.filter { !$0.isHidden }.map(\.nameText) }
    var shownStates: [String] { rowViews.filter { !$0.isHidden }.map(\.stateText) }
    var headerBadge: String? { header.badgeText }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        header.onOpen = { [weak self] in self?.onOpen?(nil) }
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.detachesHiddenViews = true
        list.translatesAutoresizingMaskIntoConstraints = false
        more.font = MacTheme.Ramp.font(.panelFootnote)
        more.textColor = MacTheme.Color.tertiaryLabel
        more.translatesAutoresizingMaskIntoConstraints = false
        let column = NSStackView(views: [header, list, more])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.detachesHiddenViews = true
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: column.widthAnchor),
            list.widthAnchor.constraint(equalTo: column.widthAnchor),
            more.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 38),
        ])
        render()
        NotificationCenter.default.addObserver(
            forName: MasterDesk.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        NotificationCenter.default.addObserver(
            forName: MachineDesk.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Shown while any machine keeps masters; at rest with none made, the title says so.
    func render(now: Date = Date()) {
        let desk = MasterDesk.shared
        isHidden = !desk.anyKeepsMasters
        guard !isHidden else { return }
        let rows = desk.board.rows
        header.render(pending: desk.board.pending, empty: rows.isEmpty, silent: rows.isEmpty ? desk.silentLine : nil)
        while rowViews.count < min(rows.count, Self.shown) {
            let view = MasterSidebarRow()
            view.onOpen = { [weak self] row in self?.onOpen?(row) }
            view.onNewTask = { [weak self] row in self?.onNewTask?(row) }
            rowViews.append(view)
            list.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        for (index, view) in rowViews.enumerated() {
            guard index < rows.count, index < Self.shown else {
                view.isHidden = true
                continue
            }
            view.isHidden = false
            view.show(rows[index], now: now)
        }
        let hidden = rows.count - min(rows.count, Self.shown)
        more.isHidden = hidden <= 0
        more.stringValue = Localized.text("%d more in Masters", hidden)
    }
}

/// The place's title: the symbol, "Masters", and how many notes wait across every master.
@MainActor
private final class MastersSidebarHeader: NSControl {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: MasterWords.title)
    private let line = NSTextField(labelWithString: "")
    private let badge = MasterBadgeView()
    private var hovered = false {
        didSet { if hovered != oldValue { needsDisplay = true } }
    }
    private var tracking: NSTrackingArea?
    var onOpen: (() -> Void)?
    var badgeText: String? { badge.isHidden ? nil : badge.stringValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "person.crop.rectangle.stack", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        icon.contentTintColor = MacTheme.Color.secondaryLabel
        icon.translatesAutoresizingMaskIntoConstraints = false
        title.font = MacTheme.Ramp.font(.rowTitleStrong)
        title.textColor = MacTheme.Color.label
        title.translatesAutoresizingMaskIntoConstraints = false
        line.font = MacTheme.Ramp.font(.panelFootnote)
        line.textColor = MacTheme.Color.secondaryLabel
        line.lineBreakMode = .byTruncatingTail
        line.translatesAutoresizingMaskIntoConstraints = false
        line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [icon, title, line, badge] { addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacTheme.Spacing.m),
            icon.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: MacTheme.Spacing.s),
            title.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.xs + 2),
            title.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -MacTheme.Spacing.s),
            line.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            line.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -MacTheme.Spacing.m),
            line.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacTheme.Spacing.m),
            badge.centerYAnchor.constraint(equalTo: title.centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize {
        let lineHeight = line.isHidden ? 0 : line.intrinsicContentSize.height + 1
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: max(30, title.intrinsicContentSize.height + lineHeight + 2 * (MacTheme.Spacing.xs + 2)))
    }

    func render(pending: Int, empty: Bool, silent: String? = nil) {
        badge.show(pending > 0 ? pending : nil)
        line.isHidden = !empty
        line.stringValue = silent ?? MasterWords.empty
        setAccessibilityLabel(
            [MasterWords.title, empty ? MasterWords.empty : nil, pending > 0 ? MasterWords.toReview(pending) : nil]
                .compactMap { $0 }.joined(separator: ", "))
        invalidateIntrinsicContentSize()
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

    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        MacTheme.Color.label.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: MacTheme.Radius.control, yRadius: MacTheme.Radius.control).fill()
    }
}

/// One master in the sidebar: mark, name, its state line in its tone, and the notes waiting.
@MainActor
final class MasterSidebarRow: NSControl {
    private let mark = MasterMarkView(glyph: "", hue: .blue, side: 18)
    private let name = NSTextField(labelWithString: "")
    private let state = NSTextField(labelWithString: "")
    private let badge = MasterBadgeView()
    private var row: MasterRow?
    private var hovered = false {
        didSet { if hovered != oldValue { needsDisplay = true } }
    }
    private var tracking: NSTrackingArea?
    var onOpen: ((MasterRow) -> Void)?
    var onNewTask: ((MasterRow) -> Void)?

    var nameText: String { name.stringValue }
    var stateText: String { state.stringValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        name.font = MacTheme.Ramp.font(.rowTitle)
        name.textColor = MacTheme.Color.label
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.translatesAutoresizingMaskIntoConstraints = false
        state.font = MacTheme.Ramp.font(.panelFootnote)
        state.lineBreakMode = .byTruncatingTail
        state.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        state.translatesAutoresizingMaskIntoConstraints = false
        for view in [mark, name, state, badge] { addSubview(view) }
        NSLayoutConstraint.activate([
            mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacTheme.Spacing.m),
            mark.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            name.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: MacTheme.Spacing.s),
            name.centerYAnchor.constraint(equalTo: mark.centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -MacTheme.Spacing.xs),
            state.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            state.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 0),
            state.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -MacTheme.Spacing.m),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacTheme.Spacing.m),
            badge.centerYAnchor.constraint(equalTo: mark.centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        menu = NSMenu()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: 5 + max(18, name.intrinsicContentSize.height) + state.intrinsicContentSize.height + 5)
    }

    func show(_ row: MasterRow, now: Date = Date()) {
        self.row = row
        mark.show(row)
        name.stringValue = row.master.name
        let line = row.state(now: now)
        state.stringValue = line.text
        state.textColor = MasterInk.color(line.tone)
        badge.show(MasterReading.badge(row.master))
        toolTip = [row.master.purpose, row.machine].filter { !$0.isEmpty }.joined(separator: " · ")
        setAccessibilityLabel(
            [row.master.name, line.text, MasterReading.badge(row.master).map(MasterWords.toReview)]
                .compactMap { $0 }.joined(separator: ", "))
        invalidateIntrinsicContentSize()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let row else { return nil }
        let menu = NSMenu()
        let task = NSMenuItem(title: MasterWords.newTask + "…", action: #selector(newTaskChosen), keyEquivalent: "")
        task.target = self
        menu.addItem(task)
        let open = NSMenuItem(
            title: Localized.text("Open %@", row.master.name), action: #selector(openChosen), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        return menu
    }

    @objc private func newTaskChosen() { if let row { onNewTask?(row) } }
    @objc private func openChosen() { if let row { onOpen?(row) } }

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

    override func mouseDown(with event: NSEvent) {
        guard let row else { return }
        onOpen?(row)
    }

    override func keyDown(with event: NSEvent) {
        guard let row, event.characters == " " || event.characters == "\r" else {
            super.keyDown(with: event)
            return
        }
        onOpen?(row)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let row else { return false }
        onOpen?(row)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        MacTheme.Color.label.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: MacTheme.Radius.control, yRadius: MacTheme.Radius.control).fill()
    }
}
