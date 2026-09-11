import AppKit
import CodingAgentKit
import TailscodeCore

/// The dial opened: the models a person actually reaches for beside the effort ladder, over one
/// `ModelDialState` so the Mac draws the same columns in the same order as the Linux desk. The
/// axes split the keys — ↑↓ and ⏎ are the model's, ←→ and the digits the effort's — and a mouse
/// does the same by clicking a row or a rung. Effort changes are live and keep the popover open;
/// a model is committed by a press and closes it.
@MainActor
final class ModelDialPopover: NSObject {
    private let popover = NSPopover()
    private let panel: ModelDialPanel
    private var state: ModelDialState
    private var monitor: Any?
    private let onEffort: @MainActor (String?) -> Void
    private let onPick: @MainActor (ModelPick) -> Void
    private let onOpenCatalog: @MainActor () -> Void
    private let onStarred: @MainActor (ModelSelection) -> Void
    private let onClosed: @MainActor () -> Void

    static func present(
        from anchor: NSView, state: ModelDialState,
        onEffort: @escaping @MainActor (String?) -> Void,
        onPick: @escaping @MainActor (ModelPick) -> Void,
        onOpenCatalog: @escaping @MainActor () -> Void,
        onStarred: @escaping @MainActor (ModelSelection) -> Void,
        onClosed: @escaping @MainActor () -> Void
    ) -> ModelDialPopover {
        let controller = ModelDialPopover(
            state: state, onEffort: onEffort, onPick: onPick, onOpenCatalog: onOpenCatalog,
            onStarred: onStarred, onClosed: onClosed)
        controller.show(from: anchor)
        return controller
    }

    private init(
        state: ModelDialState,
        onEffort: @escaping @MainActor (String?) -> Void,
        onPick: @escaping @MainActor (ModelPick) -> Void,
        onOpenCatalog: @escaping @MainActor () -> Void,
        onStarred: @escaping @MainActor (ModelSelection) -> Void,
        onClosed: @escaping @MainActor () -> Void
    ) {
        self.state = state
        self.onEffort = onEffort
        self.onPick = onPick
        self.onOpenCatalog = onOpenCatalog
        self.onStarred = onStarred
        self.onClosed = onClosed
        panel = ModelDialPanel()
        super.init()
        panel.onRowHover = { [weak self] index in self?.hover(index) }
        panel.onRowPress = { [weak self] index in self?.press(index) }
        panel.onRungPress = { [weak self] rung in self?.select(rung) }
        panel.searchField.delegate = self
    }

    var isShown: Bool { popover.isShown }

    /// The composer heard something new — a catalog refresh, a level stepped from the wheel —
    /// and hands over a fresh state. The query and the row under the cursor survive the swap.
    func update(state fresh: ModelDialState) {
        let query = state.query
        let focusedID = state.focused?.id
        state = fresh
        if !query.isEmpty { state.search(query) }
        if let focusedID, let index = state.rows.firstIndex(where: { $0.id == focusedID }) {
            state.move(to: index)
        }
        render()
    }

    func close() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    private func show(from anchor: NSView) {
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = panel
        render()
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        panel.view.window?.makeFirstResponder(panel.searchField)
        installMonitor()
    }

    private func render() {
        panel.render(state)
        popover.contentSize = panel.view.fittingSize
        panel.reveal(state.cursor)
    }

    /// The field editor owns the arrows, Enter and Escape through `doCommandBy`, but a chord with
    /// control and a bare digit never reach it as commands — ⌃S stars, ⌃⏎ opens the catalog,
    /// ⌃↑/⌃↓ jump the list, and a digit picks a rung while the search is empty, because a
    /// person typing "gpt-5" is naming a model rather than asking for five bars.
    private func installMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown, event.window === self.panel.view.window,
                let chord = MacKeys.chord(for: event)
            else { return event }
            let isDigit = Keymap.digit(chord.keyval) != nil && !chord.control && !chord.alt
            guard chord.control || (isDigit && self.state.digitsPickEffort) else { return event }
            guard
                let command = ModelDialState.command(
                    for: chord, digitsLive: self.state.digitsPickEffort)
            else { return event }
            return self.handle(command) ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    @discardableResult
    private func handle(_ command: ModelDialCommand) -> Bool {
        apply(state.handle(command))
    }

    private func apply(_ outcome: ModelDialOutcome) -> Bool {
        switch outcome {
        case .unhandled:
            return false
        case .moved:
            panel.highlight(state.cursor)
            panel.reveal(state.cursor)
        case .effort(let level):
            onEffort(level)
            panel.render(state)
        case .pick(let pick):
            close()
            onPick(pick)
        case .openCatalog:
            close()
            onOpenCatalog()
        case .starred(let selection):
            onStarred(selection)
            render()
        case .dismiss:
            close()
        }
        return true
    }

    private func hover(_ index: Int) {
        guard index != state.cursor else { return }
        state.move(to: index)
        panel.highlight(state.cursor)
    }

    private func press(_ index: Int) {
        state.move(to: index)
        handle(.activate)
    }

    private func select(_ rung: EffortRung) {
        state.setEffort(rung.level)
        _ = apply(.effort(state.effort))
    }
}

extension ModelDialPopover: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        removeMonitor()
        onClosed()
    }
}

extension ModelDialPopover: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        state.search(panel.searchField.stringValue)
        render()
    }

    /// A bare arrow steps the ladder only while the field is empty: with words in it the caret
    /// owns ←→, the same rule `ModelDialState.command` applies, and ⌃←/⌃→ reach the ladder
    /// through the chord monitor regardless.
    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): return handle(.down)
        case #selector(NSResponder.moveUp(_:)): return handle(.up)
        case #selector(NSResponder.moveLeft(_:)):
            return state.digitsPickEffort ? handle(.colder) : false
        case #selector(NSResponder.moveRight(_:)):
            return state.digitsPickEffort ? handle(.hotter) : false
        case #selector(NSResponder.insertNewline(_:)): return handle(.activate)
        case #selector(NSResponder.cancelOperation(_:)): return handle(.dismiss)
        default: return false
        }
    }
}

/// The popover's body: the model column with its search on the left, the ladder on the right,
/// the key hint along the foot. It draws a state and forwards presses; every decision is the
/// controller's.
@MainActor
final class ModelDialPanel: NSViewController {
    let searchField = NSSearchField()
    var onRowHover: ((Int) -> Void)?
    var onRowPress: ((Int) -> Void)?
    var onRungPress: ((EffortRung) -> Void)?

    private let modelList = FlippedStackView()
    private let listScroll = NSScrollView()
    private var listHeight: NSLayoutConstraint?
    private let headline = NSTextField(labelWithString: "")
    private let ladder = NSStackView()
    private let hint = NSTextField(labelWithString: "")
    private var rowViews: [DialModelRowView] = []
    private static let listCap: CGFloat = 400

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = Localized.text("Search every model")
        searchField.controlSize = .regular
        searchField.font = MacTheme.Ramp.font(.control)
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.translatesAutoresizingMaskIntoConstraints = false

        modelList.orientation = .vertical
        modelList.alignment = .leading
        modelList.spacing = 1
        modelList.translatesAutoresizingMaskIntoConstraints = false
        listScroll.documentView = modelList
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.drawsBackground = false
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        let listHeight = listScroll.heightAnchor.constraint(equalToConstant: 200)
        self.listHeight = listHeight

        let left = NSStackView(views: [searchField, listScroll])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = MacTheme.Spacing.s
        left.translatesAutoresizingMaskIntoConstraints = false

        let effortLabel = NSTextField(labelWithString: "")
        effortLabel.attributedStringValue = NSAttributedString(
            string: Localized.text("EFFORT"),
            attributes: MacTheme.Ramp.attributes(
                .sectionLabel, color: MacTheme.Color.tertiaryLabel))
        headline.font = MacTheme.Ramp.font(.rowDetail)
        headline.textColor = MacTheme.Color.secondaryLabel
        headline.lineBreakMode = .byTruncatingTail
        headline.alignment = .right
        effortLabel.setContentHuggingPriority(.required, for: .horizontal)
        effortLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        headline.setContentHuggingPriority(.init(1), for: .horizontal)
        headline.setContentCompressionResistancePriority(.init(240), for: .horizontal)
        let head = NSStackView(views: [effortLabel, headline])
        head.orientation = .horizontal
        head.alignment = .firstBaseline
        head.distribution = .fill
        head.translatesAutoresizingMaskIntoConstraints = false

        ladder.orientation = .vertical
        ladder.alignment = .leading
        ladder.spacing = 5
        ladder.translatesAutoresizingMaskIntoConstraints = false

        let right = NSStackView(views: [head, ladder])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = MacTheme.Spacing.s
        right.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let columns = NSView()
        columns.translatesAutoresizingMaskIntoConstraints = false
        columns.addSubview(left)
        columns.addSubview(divider)
        columns.addSubview(right)
        let leftFloor = columns.bottomAnchor.constraint(equalTo: left.bottomAnchor)
        leftFloor.priority = .defaultLow
        let rightFloor = columns.bottomAnchor.constraint(equalTo: right.bottomAnchor)
        rightFloor.priority = .defaultLow

        hint.font = MacTheme.Ramp.font(.hint)
        hint.textColor = MacTheme.Color.tertiaryLabel
        hint.stringValue = ModelDial.hint
        hint.lineBreakMode = .byTruncatingTail
        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false

        let body = NSStackView(views: [columns, rule, hint])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = MacTheme.Spacing.s
        body.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(body)

        let inset = MacTheme.Spacing.m
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            body.topAnchor.constraint(equalTo: root.topAnchor, constant: inset),
            body.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -inset),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 620),
            left.widthAnchor.constraint(equalToConstant: 340),
            right.widthAnchor.constraint(equalToConstant: 260),
            left.leadingAnchor.constraint(equalTo: columns.leadingAnchor),
            left.topAnchor.constraint(equalTo: columns.topAnchor),
            divider.leadingAnchor.constraint(
                equalTo: left.trailingAnchor, constant: MacTheme.Spacing.m),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: columns.topAnchor),
            divider.bottomAnchor.constraint(equalTo: columns.bottomAnchor),
            right.leadingAnchor.constraint(
                equalTo: divider.trailingAnchor, constant: MacTheme.Spacing.m),
            right.topAnchor.constraint(equalTo: columns.topAnchor),
            right.trailingAnchor.constraint(equalTo: columns.trailingAnchor),
            columns.bottomAnchor.constraint(greaterThanOrEqualTo: left.bottomAnchor),
            columns.bottomAnchor.constraint(greaterThanOrEqualTo: right.bottomAnchor),
            leftFloor, rightFloor,
            searchField.widthAnchor.constraint(equalTo: left.widthAnchor),
            listScroll.widthAnchor.constraint(equalTo: left.widthAnchor),
            listHeight,
            modelList.widthAnchor.constraint(equalTo: listScroll.contentView.widthAnchor),
            modelList.topAnchor.constraint(equalTo: listScroll.contentView.topAnchor),
            modelList.leadingAnchor.constraint(equalTo: listScroll.contentView.leadingAnchor),
            head.widthAnchor.constraint(equalTo: right.widthAnchor),
            ladder.widthAnchor.constraint(equalTo: right.widthAnchor),
            columns.widthAnchor.constraint(equalTo: body.widthAnchor),
            rule.widthAnchor.constraint(equalTo: body.widthAnchor),
            hint.widthAnchor.constraint(equalTo: body.widthAnchor),
        ])
        view = root
    }

    func render(_ state: ModelDialState) {
        if searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) != state.query {
            searchField.stringValue = state.query
        }
        for view in modelList.arrangedSubviews {
            modelList.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rowViews = []
        for (index, row) in state.rows.enumerated() {
            if let section = row.section {
                let label = NSTextField(labelWithString: "")
                label.attributedStringValue = NSAttributedString(
                    string: section.uppercased(),
                    attributes: MacTheme.Ramp.attributes(
                        .sectionLabel, color: MacTheme.Color.tertiaryLabel))
                let wrap = NSView()
                wrap.translatesAutoresizingMaskIntoConstraints = false
                label.translatesAutoresizingMaskIntoConstraints = false
                wrap.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 10),
                    label.trailingAnchor.constraint(lessThanOrEqualTo: wrap.trailingAnchor),
                    label.topAnchor.constraint(
                        equalTo: wrap.topAnchor, constant: index == 0 ? 2 : MacTheme.Spacing.s),
                    label.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -3),
                ])
                modelList.addArrangedSubview(wrap)
                wrap.widthAnchor.constraint(equalTo: modelList.widthAnchor).isActive = true
            }
            let view = DialModelRowView(row: row)
            view.onHover = { [weak self] in self?.onRowHover?(index) }
            view.onPress = { [weak self] in self?.onRowPress?(index) }
            modelList.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: modelList.widthAnchor).isActive = true
            rowViews.append(view)
        }
        highlight(state.cursor)
        modelList.layoutSubtreeIfNeeded()
        listHeight?.constant = min(modelList.fittingSize.height, Self.listCap)

        headline.stringValue = state.headline
        for view in ladder.arrangedSubviews {
            ladder.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for rung in state.rungs {
            let view = DialRungView(rung: rung, isCurrent: rung.id == state.currentRung?.id)
            view.onPress = { [weak self] in self?.onRungPress?(rung) }
            ladder.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: ladder.widthAnchor).isActive = true
        }
        view.layoutSubtreeIfNeeded()
    }

    func highlight(_ cursor: Int) {
        for (index, view) in rowViews.enumerated() { view.isFocused = index == cursor }
    }

    func reveal(_ cursor: Int) {
        guard rowViews.indices.contains(cursor) else { return }
        let row = rowViews[cursor]
        row.scrollToVisible(row.bounds)
    }
}

/// One model row: the star, the name, its capabilities in the quieter register, the door or the
/// machine, and the wall in front of it. The row under the cursor wears a wash and an accent
/// edge; hovering moves the cursor, so the mouse and the arrows are one cursor.
@MainActor
private final class DialModelRowView: NSView {
    var onHover: (() -> Void)?
    var onPress: (() -> Void)?
    var isFocused = false {
        didSet { if isFocused != oldValue { needsDisplay = true } }
    }
    private let row: ModelDialRow
    private var tracking: NSTrackingArea?

    init(row: ModelDialRow) {
        self.row = row
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel([row.title, row.detail].filter { !$0.isEmpty }.joined(separator: ", "))

        let star = NSTextField(labelWithString: row.candidate == nil ? "" : (row.isStarred ? "★" : "☆"))
        star.font = MacTheme.Ramp.font(.rowMeta)
        star.textColor = row.isStarred ? MacTheme.Color.warning : MacTheme.Color.tertiaryLabel
        star.alignment = .center

        let title = NSTextField(labelWithString: row.title)
        title.font = MacTheme.Ramp.font(row.isCurrent ? .rowTitleStrong : .rowTitle)
        title.textColor =
            row.kind == .serverDefault || row.opensCatalog
            ? MacTheme.Color.secondaryLabel : MacTheme.Color.label
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.init(260), for: .horizontal)

        let line = NSStackView(views: [star, title])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.distribution = .fill
        line.spacing = MacTheme.Spacing.s
        line.translatesAutoresizingMaskIntoConstraints = false

        let chips = row.facts.filter(\.isCapability)
        if !chips.isEmpty {
            let strip = NSStackView(views: chips.map(Self.chip))
            strip.orientation = .horizontal
            strip.spacing = 3
            strip.setContentCompressionResistancePriority(.required, for: .horizontal)
            line.addArrangedSubview(strip)
        }
        line.addArrangedSubview(Self.spacer())
        if let wall = row.wall {
            let note = NSTextField(labelWithString: QuotaSurface.rowNote(wall))
            note.font = MacTheme.Ramp.font(.rowNote)
            note.textColor = MacTheme.Color.danger
            note.toolTip = QuotaSurface.bannerBody(wall)
            note.setContentCompressionResistancePriority(.required, for: .horizontal)
            line.addArrangedSubview(note)
        }
        if !row.detail.isEmpty {
            let detail = NSTextField(labelWithString: row.detail)
            detail.font = MacTheme.Ramp.font(.rowNote)
            detail.textColor = MacTheme.Color.tertiaryLabel
            detail.lineBreakMode = .byTruncatingTail
            detail.setContentCompressionResistancePriority(.init(240), for: .horizontal)
            line.addArrangedSubview(detail)
        }

        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            line.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            line.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            star.widthAnchor.constraint(equalToConstant: 14 * MacTheme.UIScale.factor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
    }

    /// A capability is worth a word in a thin frame and nothing louder.
    private static func chip(_ fact: ModelFact) -> NSView {
        let label = NSTextField(labelWithString: fact.tag)
        label.font = MacTheme.Ramp.font(.chip)
        label.textColor = MacTheme.Color.tertiaryLabel
        label.toolTip = fact.label
        label.translatesAutoresizingMaskIntoConstraints = false
        let frame = NSView()
        frame.wantsLayer = true
        frame.layer?.cornerRadius = 4
        frame.layer?.borderWidth = 1
        frame.layer?.borderColor = MacTheme.Color.separator.cgColor
        frame.translatesAutoresizingMaskIntoConstraints = false
        frame.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: frame.topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: frame.bottomAnchor, constant: -1),
        ])
        return frame
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?()
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isFocused else { return }
        let wash = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
        MacTheme.Color.accent.withAlphaComponent(0.12).setFill()
        wash.fill()
        let edge = NSBezierPath(
            roundedRect: NSRect(x: 0, y: 4, width: 3, height: bounds.height - 8), xRadius: 1.5,
            yRadius: 1.5)
        MacTheme.Color.accent.setFill()
        edge.fill()
    }
}

/// One rung of the ladder: its digit, its word in the tier's colour over what it means, and
/// its bars. The rung in force wears the tier's wash and border; the power wears the rainbow.
@MainActor
private final class DialRungView: NSView {
    var onPress: (() -> Void)?
    private let rung: EffortRung
    private let isCurrent: Bool
    private let tint: NSColor
    private var hovered = false {
        didSet { if hovered != oldValue { needsDisplay = true } }
    }
    private var tracking: NSTrackingArea?

    init(rung: EffortRung, isCurrent: Bool) {
        self.rung = rung
        self.isCurrent = isCurrent
        tint =
            rung.isServer
            ? MacTheme.Color.secondaryLabel
            : rung.isPower
                ? MacTheme.Color.danger
                : (rung.level.flatMap(MacTheme.Color.modelEffort) ?? MacTheme.Color.secondaryLabel)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(rung.title), \(rung.caption)")

        let key = NSTextField(labelWithString: String(rung.key))
        key.font = MacTheme.Ramp.font(.rowMeta)
        key.textColor = MacTheme.Color.tertiaryLabel
        key.alignment = .right

        let title = NSTextField(labelWithString: "")
        if rung.isPower {
            title.attributedStringValue = DialPill.rainbow(
                rung.title, pointSize: MacTheme.Ramp.font(.rowTitleStrong).pointSize)
        } else {
            title.stringValue = rung.title
            title.font = MacTheme.Ramp.font(rung.isServer ? .rowTitle : .rowTitleStrong)
            title.textColor = tint
        }
        title.lineBreakMode = .byTruncatingTail
        let caption = NSTextField(labelWithString: rung.caption)
        caption.font = MacTheme.Ramp.font(.rowNote)
        caption.textColor = MacTheme.Color.tertiaryLabel
        caption.lineBreakMode = .byTruncatingTail
        caption.maximumNumberOfLines = 1
        let words = NSStackView(views: [title, caption])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 0
        words.setContentCompressionResistancePriority(.init(240), for: .horizontal)
        words.setContentHuggingPriority(.init(1), for: .horizontal)

        let meter = EffortMeterView()
        meter.set(
            lit: rung.heat, tint: rung.isServer ? nil : tint, rainbow: rung.isPower,
            cold: rung.isServer, glow: rung.level.map { EffortHeat.style($0).glow } ?? 0,
            ember: rung.isEmber)

        let line = NSStackView(views: [key, words, meter])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.distribution = .fill
        line.spacing = MacTheme.Spacing.s
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            line.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            line.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            key.widthAnchor.constraint(equalToConstant: 14 * MacTheme.UIScale.factor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: inset, xRadius: 8, yRadius: 8)
        if rung.isPower {
            let stops = (0..<7).map {
                MacTheme.Color.modelRainbowLetter($0, of: 7).withAlphaComponent(
                    isCurrent ? 0.22 : 0.12)
            }
            NSGradient(colors: stops)?.draw(in: shape, angle: 0)
        } else if isCurrent {
            tint.withAlphaComponent(0.14).setFill()
            shape.fill()
        }
        if isCurrent {
            tint.withAlphaComponent(0.55).setStroke()
            shape.lineWidth = 1
            shape.stroke()
        } else if hovered {
            MacTheme.Color.separator.setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
    }
}

/// A list read top-down: the scroll view's document starts at the top of its clip rather than at
/// AppKit's bottom-left origin, so a short list sits under the search field and a long one
/// opens on its first row.
@MainActor
private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}
