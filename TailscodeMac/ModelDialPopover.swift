import AppKit
import CodingAgentKit
import TailscodeCore

/// The dial opened: the models and pinned pairs a person actually reaches for beside the effort
/// ladder, over one `ModelDialState` so the Mac draws the same columns in the same order as the
/// Linux desk. The axes split the keys — ↑↓ and ⏎ are the model's, ←→ and the digits the effort's,
/// ⇥ hands the arrows to the ladder — and a mouse does the same by clicking a row or a rung. The
/// ladder follows the cursor: on this chat's model a level is live and keeps the popover open, on
/// any other row it is a preview that rides with the pick, and a pick closes it.
@MainActor
final class ModelDialPopover: NSObject {
    private let popover = NSPopover()
    private let panel: ModelDialPanel
    private var state: ModelDialState
    private var monitor: Any?
    private let onEffort: @MainActor (String?) -> Void
    private let onPick: @MainActor (ModelPick, EffortAsk, String?) -> Void
    private let onOpenCatalog: @MainActor () -> Void
    private let onPinned: @MainActor (ModelPreset) -> Void
    private let onClosed: @MainActor () -> Void

    /// `onPick` hands over the pick, what it does to the level, and the sentence to say when the
    /// level moved on its own (`ModelDialState.pickNotice`), read before the popover forgets the
    /// state it was taken in.
    static func present(
        from anchor: NSView, state: ModelDialState,
        onEffort: @escaping @MainActor (String?) -> Void,
        onPick: @escaping @MainActor (ModelPick, EffortAsk, String?) -> Void,
        onOpenCatalog: @escaping @MainActor () -> Void,
        onPinned: @escaping @MainActor (ModelPreset) -> Void,
        onClosed: @escaping @MainActor () -> Void
    ) -> ModelDialPopover {
        let controller = ModelDialPopover(
            state: state, onEffort: onEffort, onPick: onPick, onOpenCatalog: onOpenCatalog,
            onPinned: onPinned, onClosed: onClosed)
        controller.show(from: anchor)
        return controller
    }

    private init(
        state: ModelDialState,
        onEffort: @escaping @MainActor (String?) -> Void,
        onPick: @escaping @MainActor (ModelPick, EffortAsk, String?) -> Void,
        onOpenCatalog: @escaping @MainActor () -> Void,
        onPinned: @escaping @MainActor (ModelPreset) -> Void,
        onClosed: @escaping @MainActor () -> Void
    ) {
        self.state = state
        self.onEffort = onEffort
        self.onPick = onPick
        self.onOpenCatalog = onOpenCatalog
        self.onPinned = onPinned
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
    /// and hands over a fresh state. The query, the row under the cursor and the column that owns
    /// the arrows survive the swap.
    func update(state fresh: ModelDialState) {
        let query = state.query
        let focusedID = state.focused?.id
        let column = state.column
        state = fresh
        if !query.isEmpty { state.search(query) }
        if let focusedID, let index = state.rows.firstIndex(where: { $0.id == focusedID }) {
            state.move(to: index)
        }
        if column != state.column { _ = state.handle(.switchColumn) }
        render()
    }

    func close() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    private func show(from anchor: NSView) {
        popover.behavior = .transient
        popover.delegate = self
        popover.ground(panel)
        render()
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        panel.view.window?.makeFirstResponder(panel.searchField)
        installMonitor()
    }

    private func render() {
        panel.render(state)
        fit()
        panel.reveal(state.cursor)
    }

    private func fit() {
        let size = panel.view.fittingSize
        if popover.contentSize != size { popover.contentSize = size }
    }

    /// The field editor owns the arrows, Enter, Escape and Tab through `doCommandBy`, but a chord
    /// with control and a bare digit never reach it as commands — ⌃S pins, ⌃⏎ opens the catalog,
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

    /// A move redraws the ladder as well as the cursor, because the ladder is the cursor's: the
    /// row under it decides whose levels are shown and whether a step is live or a preview.
    private func apply(_ outcome: ModelDialOutcome) -> Bool {
        switch outcome {
        case .unhandled:
            return false
        case .moved:
            panel.highlight(state.cursor)
            panel.renderLadder(state)
            fit()
            panel.reveal(state.cursor)
        case .effort(let level):
            onEffort(level)
            panel.renderLadder(state)
            fit()
        case .previewed:
            panel.renderLadder(state)
            fit()
        case .pick(let pick, let effort):
            let notice = state.pickNotice
            close()
            onPick(pick, effort, notice)
        case .openCatalog:
            close()
            onOpenCatalog()
        case .pinned(let preset):
            onPinned(preset)
            render()
        case .dismiss:
            close()
        }
        return true
    }

    private func hover(_ index: Int) {
        guard index != state.cursor, state.rows.indices.contains(index),
            !state.rows[index].isMessage
        else { return }
        state.move(to: index)
        panel.highlight(state.cursor)
        panel.renderLadder(state)
        fit()
    }

    private func press(_ index: Int) {
        guard state.rows.indices.contains(index), !state.rows[index].isMessage else { return }
        state.move(to: index)
        handle(.activate)
    }

    private func select(_ rung: EffortRung) {
        _ = apply(state.setEffort(rung.level))
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
    /// through the chord monitor regardless. Tab and Shift-Tab hand the arrows between the
    /// columns, and are taken here so AppKit's key-view loop never walks focus out of the field.
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
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            handle(.switchColumn)
            return true
        case #selector(NSResponder.insertNewline(_:)): return handle(.activate)
        case #selector(NSResponder.cancelOperation(_:)): return handle(.dismiss)
        default: return false
        }
    }
}

/// The popover's body: the model column with its search on the left, the ladder on the right,
/// the key hint along the foot. It draws a state and forwards presses; every decision is the
/// controller's. The column that owns the arrows wears a quiet accent frame, and a ladder drawn
/// for a row other than this chat's model is marked a preview and set a little quieter.
@MainActor
final class ModelDialPanel: NSViewController {
    let searchField = NSSearchField()
    var onRowHover: ((Int) -> Void)?
    var onRowPress: ((Int) -> Void)?
    var onRungPress: ((EffortRung) -> Void)?

    private let modelList = FlippedStackView()
    private let listScroll = NSScrollView()
    private var listHeight: NSLayoutConstraint?
    private let effortLabel = NSTextField(labelWithString: "")
    private let previewTag = NSTextField(labelWithString: "")
    private let headline = NSTextField(wrappingLabelWithString: "")
    private let ladder = NSStackView()
    private let carryNotice = NSTextField(wrappingLabelWithString: "")
    private let ladderFrame = ColumnFrameView()
    private let hint = FittedWrapLabel()
    private var rowViews: [Int: DialModelRowView] = [:]
    private var ladderKey: [String] = []
    /// The columns grow with the type: a width fixed in points while the words in it are scaled
    /// is a column that cuts the words it was sized for. The list is wide enough for a pinned
    /// pair that stands behind a wall — name, wall with its reset, level and check on one line.
    private static var listCap: CGFloat { 400 * MacTheme.UIScale.factor }
    static var ladderWidth: CGFloat { 280 * MacTheme.UIScale.factor }
    static var listWidth: CGFloat { 392 * MacTheme.UIScale.factor }

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

        effortLabel.setContentHuggingPriority(.required, for: .horizontal)
        effortLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        previewTag.attributedStringValue = NSAttributedString(
            string: Localized.text("preview").uppercased(),
            attributes: MacTheme.Ramp.attributes(.chip, color: MacTheme.Color.secondaryLabel))
        previewTag.wantsLayer = true
        previewTag.toolTip = Localized.text(
            "The levels of the row under the cursor. A level set here goes with the pick.")
        previewTag.setContentHuggingPriority(.required, for: .horizontal)
        previewTag.setContentCompressionResistancePriority(.required, for: .horizontal)
        let tagSpacer = NSView()
        tagSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let head = NSStackView(views: [effortLabel, previewTag, tagSpacer])
        head.orientation = .horizontal
        head.alignment = .firstBaseline
        head.spacing = MacTheme.Spacing.s
        head.translatesAutoresizingMaskIntoConstraints = false

        headline.font = MacTheme.Ramp.font(.rowDetail)
        headline.textColor = MacTheme.Color.secondaryLabel
        headline.maximumNumberOfLines = 2
        headline.preferredMaxLayoutWidth = Self.ladderWidth - 20

        ladder.orientation = .vertical
        ladder.alignment = .leading
        ladder.spacing = 5
        ladder.translatesAutoresizingMaskIntoConstraints = false

        carryNotice.font = MacTheme.Ramp.font(.rowNote)
        carryNotice.textColor = MacTheme.Color.secondaryLabel
        carryNotice.maximumNumberOfLines = 3
        carryNotice.preferredMaxLayoutWidth = Self.ladderWidth - 20

        let right = NSStackView(views: [head, headline, ladder, carryNotice])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = MacTheme.Spacing.s
        right.setCustomSpacing(2, after: head)
        right.translatesAutoresizingMaskIntoConstraints = false
        ladderFrame.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let columns = NSView()
        columns.translatesAutoresizingMaskIntoConstraints = false
        columns.addSubview(left)
        columns.addSubview(divider)
        columns.addSubview(ladderFrame)
        columns.addSubview(right)
        let leftFloor = columns.bottomAnchor.constraint(equalTo: left.bottomAnchor)
        leftFloor.priority = .defaultLow

        hint.font = MacTheme.Ramp.font(.hint)
        hint.textColor = MacTheme.Color.secondaryLabel
        hint.stringValue = ModelDial.hint
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
        let halo: CGFloat = 6
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            body.topAnchor.constraint(equalTo: root.topAnchor, constant: inset),
            body.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -inset),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 640 * MacTheme.UIScale.factor),
            left.widthAnchor.constraint(equalToConstant: Self.listWidth),
            right.widthAnchor.constraint(equalToConstant: Self.ladderWidth),
            left.leadingAnchor.constraint(equalTo: columns.leadingAnchor),
            left.topAnchor.constraint(equalTo: columns.topAnchor),
            divider.leadingAnchor.constraint(
                equalTo: left.trailingAnchor, constant: MacTheme.Spacing.m),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: columns.topAnchor),
            divider.bottomAnchor.constraint(equalTo: columns.bottomAnchor),
            right.leadingAnchor.constraint(
                equalTo: divider.trailingAnchor, constant: MacTheme.Spacing.m),
            right.topAnchor.constraint(equalTo: columns.topAnchor, constant: halo),
            right.trailingAnchor.constraint(equalTo: columns.trailingAnchor),
            ladderFrame.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: -halo),
            ladderFrame.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: halo),
            ladderFrame.topAnchor.constraint(equalTo: right.topAnchor, constant: -halo),
            ladderFrame.bottomAnchor.constraint(equalTo: right.bottomAnchor, constant: halo),
            columns.bottomAnchor.constraint(greaterThanOrEqualTo: left.bottomAnchor),
            columns.bottomAnchor.constraint(
                greaterThanOrEqualTo: right.bottomAnchor, constant: halo),
            leftFloor,
            searchField.widthAnchor.constraint(equalTo: left.widthAnchor),
            listScroll.widthAnchor.constraint(equalTo: left.widthAnchor),
            listHeight,
            modelList.widthAnchor.constraint(equalTo: listScroll.contentView.widthAnchor),
            modelList.topAnchor.constraint(equalTo: listScroll.contentView.topAnchor),
            modelList.leadingAnchor.constraint(equalTo: listScroll.contentView.leadingAnchor),
            head.widthAnchor.constraint(equalTo: right.widthAnchor),
            headline.widthAnchor.constraint(equalTo: right.widthAnchor),
            ladder.widthAnchor.constraint(equalTo: right.widthAnchor),
            carryNotice.widthAnchor.constraint(equalTo: right.widthAnchor),
            columns.widthAnchor.constraint(equalTo: body.widthAnchor),
            rule.widthAnchor.constraint(equalTo: body.widthAnchor),
            hint.widthAnchor.constraint(equalTo: body.widthAnchor),
        ])
        view = root
    }

    /// The view is loaded first: the popover asks for the panel's size before AppKit has asked for
    /// its view, and a list measured into a constraint that does not exist yet stays at its
    /// placeholder height.
    func render(_ state: ModelDialState) {
        loadViewIfNeeded()
        if searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) != state.query {
            searchField.stringValue = state.query
        }
        for view in modelList.arrangedSubviews {
            modelList.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rowViews = [:]
        for (index, row) in state.rows.enumerated() {
            if let section = row.section {
                let label = NSTextField(labelWithString: "")
                label.attributedStringValue = NSAttributedString(
                    string: section.uppercased(),
                    attributes: MacTheme.Ramp.attributes(
                        .sectionLabel, color: MacTheme.Color.secondaryLabel))
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
            if !row.isMessage {
                view.onHover = { [weak self] in self?.onRowHover?(index) }
                view.onPress = { [weak self] in self?.onRowPress?(index) }
            }
            modelList.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: modelList.widthAnchor).isActive = true
            rowViews[index] = view
        }
        highlight(state.cursor)
        listHeight?.constant = min(listContentHeight(), Self.listCap)
        ladderKey = []
        renderLadder(state)
    }

    /// The list's own height, measured row by row at the column's width: the stack's fitting size
    /// is read while it is still pinned to a clip of the old height, and answered with that.
    private func listContentHeight() -> CGFloat {
        let views = modelList.arrangedSubviews
        let width = Self.listWidth
        let rows = views.reduce(CGFloat(0)) { total, row in
            let probe = row.widthAnchor.constraint(equalToConstant: width)
            probe.priority = .required
            row.addConstraint(probe)
            defer { row.removeConstraint(probe) }
            return total + row.fittingSize.height
        }
        return rows + modelList.spacing * CGFloat(max(0, views.count - 1))
    }

    /// The right column alone, which follows the cursor: the ladder of the row under it, the
    /// headline naming whose levels these are, the preview mark, the sentence about what will
    /// become of the level, and which column owns the arrows. Rungs are rebuilt only when the
    /// ladder itself changed, so a hover across rows of one model does not churn views.
    func renderLadder(_ state: ModelDialState) {
        let live = !state.ladderIsPreview
        let owns = state.column == .ladder
        effortLabel.attributedStringValue = NSAttributedString(
            string: Localized.text("EFFORT"),
            attributes: MacTheme.Ramp.attributes(
                .sectionLabel, color: owns ? MacTheme.Color.accent : MacTheme.Color.secondaryLabel))
        previewTag.isHidden = live
        ladderFrame.owns = owns
        headline.stringValue = state.headline
        let current = state.currentRung?.id
        let key = state.rungs.map { $0.id + ($0.id == current ? "·on" : "") } + [live ? "live" : "preview"]
        if key != ladderKey {
            ladderKey = key
            for view in ladder.arrangedSubviews {
                ladder.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            for rung in state.rungs {
                let view = DialRungView(rung: rung, isCurrent: rung.id == current)
                view.onPress = { [weak self] in self?.onRungPress?(rung) }
                ladder.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: ladder.widthAnchor).isActive = true
            }
        }
        ladder.alphaValue = live ? 1 : 0.78
        if let notice = state.carryNotice, !Self.repeats(notice, state.headline) {
            carryNotice.stringValue = notice
            carryNotice.isHidden = false
        } else {
            carryNotice.stringValue = ""
            carryNotice.isHidden = true
        }
        view.layoutSubtreeIfNeeded()
    }

    /// A carry notice that only says again what the headline above it already says — a model with
    /// no levels is both — is drawn once.
    static func repeats(_ notice: String, _ headline: String) -> Bool {
        let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))
        return notice.trimmingCharacters(in: trim) == headline.trimmingCharacters(in: trim)
    }

    func highlight(_ cursor: Int) {
        for (index, view) in rowViews { view.isFocused = index == cursor }
    }

    /// What the panel drew, for the self-test to read back without a screen.
    var drawn: (preview: Bool, carry: String?, ladderOwnsArrows: Bool, rungs: Int, rowMeters: Int) {
        let meters = rowViews.values.reduce(0) { count, row in
            count + Self.meters(in: row)
        }
        return (
            !previewTag.isHidden, carryNotice.isHidden ? nil : carryNotice.stringValue,
            ladderFrame.owns, ladder.arrangedSubviews.count, meters
        )
    }

    private static func meters(in view: NSView) -> Int {
        (view is EffortMeterView ? 1 : 0) + view.subviews.reduce(0) { $0 + meters(in: $1) }
    }

    func reveal(_ cursor: Int) {
        guard let row = rowViews[cursor] else { return }
        row.scrollToVisible(row.bounds)
    }
}

/// The ladder column's frame: drawn only while the arrows are the ladder's, so a person who
/// pressed ⇥ can see where ↑↓ now land without reading the hint.
@MainActor
private final class ColumnFrameView: NSView {
    var owns = false {
        didSet { if owns != oldValue { needsDisplay = true } }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard owns else { return }
        let shape = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        MacTheme.Color.accent.withAlphaComponent(0.06).setFill()
        shape.fill()
        MacTheme.Color.accent.withAlphaComponent(0.45).setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
}

/// One model row: the star, the family's dot, the name, its capabilities in the quieter register,
/// the pinned pair's level as the pill's own word and meter, the door or the machine, the wall in
/// front of it, and a check on the row this chat runs. The row under the cursor wears a wash and
/// an accent edge; hovering moves the cursor, so the mouse and the arrows are one cursor. A row
/// that is a message — a search that found nothing — is two quiet lines and answers nothing.
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
        guard !row.isMessage else {
            buildMessage()
            return
        }
        setAccessibilityRole(.button)
        let levelWords = row.level.map { Localized.text("%@ effort", $0.word) }
        setAccessibilityLabel(
            [row.title, levelWords, row.detail, row.isStarred ? Localized.text("pinned") : nil]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
        setAccessibilityValue(row.isCurrent ? Localized.text("current") : nil)

        let star = NSTextField(labelWithString: row.candidate == nil ? "" : (row.isStarred ? "★" : "☆"))
        star.font = MacTheme.Ramp.font(.rowMeta)
        star.textColor = row.isStarred ? MacTheme.Color.mark : MacTheme.Color.tertiaryLabel
        star.alignment = .center

        let dot = NSTextField(labelWithString: row.candidate == nil ? "" : "●")
        dot.font = MacTheme.Ramp.font(.chip)
        dot.textColor =
            row.candidate.flatMap { ModelBadge.chip(model: $0.selection.modelID, effort: nil) }
            .map(MacTheme.Color.modelIdentity) ?? MacTheme.Color.tertiaryLabel
        dot.setContentHuggingPriority(.required, for: .horizontal)
        dot.isHidden = row.candidate == nil

        let title = NSTextField(labelWithString: row.title)
        title.font = MacTheme.Ramp.font(row.isCurrent ? .rowTitleStrong : .rowTitle)
        title.textColor =
            row.kind == .serverDefault || row.opensCatalog
            ? MacTheme.Color.secondaryLabel : MacTheme.Color.label
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.init(260), for: .horizontal)

        let line = NSStackView(views: [star, dot, title])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.distribution = .fill
        line.spacing = MacTheme.Spacing.s
        line.setCustomSpacing(5, after: dot)
        line.translatesAutoresizingMaskIntoConstraints = false

        title.toolTip = row.title
        let chips = row.wall == nil ? row.facts.filter(\.isCapability) : []
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
            note.lineBreakMode = .byTruncatingTail
            note.setContentCompressionResistancePriority(.init(250), for: .horizontal)
            line.addArrangedSubview(note)
        }
        let showsDetail = row.level == nil || row.candidate?.isElsewhere == true
        if showsDetail, !row.detail.isEmpty {
            let detail = NSTextField(labelWithString: row.detail)
            detail.font = MacTheme.Ramp.font(.rowNote)
            detail.textColor = MacTheme.Color.secondaryLabel
            detail.lineBreakMode = .byTruncatingTail
            detail.toolTip = row.detail
            detail.setContentCompressionResistancePriority(.init(240), for: .horizontal)
            line.addArrangedSubview(detail)
        }
        toolTip = [row.title, row.detail].filter { !$0.isEmpty }.joined(separator: " — ")
        if let level = row.level {
            line.addArrangedSubview(Self.levelView(level))
        }
        let check = NSTextField(labelWithString: row.isCurrent ? "✓" : "")
        check.font = MacTheme.Ramp.font(.rowMeta)
        check.textColor = MacTheme.Color.accent
        check.alignment = .center
        line.addArrangedSubview(check)

        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            line.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            line.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            star.widthAnchor.constraint(equalToConstant: 14 * MacTheme.UIScale.factor),
            check.widthAnchor.constraint(equalToConstant: 12 * MacTheme.UIScale.factor),
        ])
    }

    /// The list's width less the row's insets, so the message wraps where it will be drawn and the
    /// list is measured tall enough to hold it.
    private static var messageWidth: CGFloat { ModelDialPanel.listWidth - 20 }

    /// The search that found nothing says so in two lines — what was asked and where it looked —
    /// in the quiet ink of a caption, because it is an answer and not a row to take.
    private func buildMessage() {
        setAccessibilityRole(.staticText)
        setAccessibilityLabel([row.title, row.detail].filter { !$0.isEmpty }.joined(separator: ". "))
        let title = NSTextField(wrappingLabelWithString: row.title)
        title.font = MacTheme.Ramp.font(.rowTitle)
        title.textColor = MacTheme.Color.secondaryLabel
        title.isSelectable = false
        let detail = NSTextField(wrappingLabelWithString: row.detail)
        detail.font = MacTheme.Ramp.font(.rowNote)
        detail.textColor = MacTheme.Color.tertiaryLabel
        detail.isSelectable = false
        detail.isHidden = row.detail.isEmpty
        title.preferredMaxLayoutWidth = Self.messageWidth
        detail.preferredMaxLayoutWidth = Self.messageWidth
        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    /// A pinned pair's level, drawn the way the pill draws it: the word in quiet ink and the five
    /// bars carrying the heat, so a pair reads the same in the list as it will on the pill.
    private static func levelView(_ level: ModelDialRow.Level) -> NSView {
        let size = MacTheme.Ramp.font(.rowNote).pointSize
        let word = NSTextField(labelWithString: "")
        let meter = EffortMeterView()
        if level.isPower {
            word.attributedStringValue = DialPill.rainbow(level.word, pointSize: size)
            meter.set(lit: level.heat, tint: nil, rainbow: true, cold: false, glow: 6)
        } else if level.isServer {
            word.attributedStringValue = NSAttributedString(
                string: level.word,
                attributes: EffortHeat.attributes(
                    EffortHeat.Style(weight: .regular, glow: 0), pointSize: size,
                    colour: MacTheme.Color.tertiaryLabel))
            meter.set(lit: 0, tint: nil, rainbow: false, cold: true, glow: 0)
        } else {
            word.attributedStringValue = NSAttributedString(
                string: level.word,
                attributes: EffortHeat.attributes(
                    level.word, pointSize: size, colour: MacTheme.Color.secondaryLabel))
            meter.set(
                lit: level.heat,
                tint: MacTheme.Color.modelEffort(level.word) ?? MacTheme.Color.secondaryLabel,
                rainbow: false, cold: false, glow: EffortHeat.style(level.word).glow,
                ember: level.isEmber)
        }
        word.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = NSStackView(views: [word, meter])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.setContentHuggingPriority(.required, for: .horizontal)
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)
        return stack
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
        label.textColor = MacTheme.Color.secondaryLabel
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

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return onPress != nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isFocused, !row.isMessage else { return }
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

/// One rung of the ladder: its digit, its word in ink over what it means, and its bars in the
/// tier's heat — hue is who answers and heat is how hard, so colour lives on the bars and the
/// frame, never on the word. The rung in force wears the tier's wash and border; the power wears
/// the rainbow.
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
        toolTip = "\(rung.title) — \(rung.caption)"

        let key = NSTextField(labelWithString: String(rung.key))
        key.font = MacTheme.Ramp.font(.rowMeta)
        key.textColor = MacTheme.Color.secondaryLabel
        key.alignment = .right

        let title = NSTextField(labelWithString: "")
        if rung.isPower {
            title.attributedStringValue = DialPill.rainbow(
                rung.title, pointSize: MacTheme.Ramp.font(.rowTitleStrong).pointSize)
        } else {
            title.stringValue = rung.title
            title.font = MacTheme.Ramp.font(rung.isServer ? .rowTitle : .rowTitleStrong)
            title.textColor = rung.isServer ? MacTheme.Color.secondaryLabel : MacTheme.Color.label
        }
        title.lineBreakMode = .byTruncatingTail
        let caption = FittedWrapLabel()
        caption.stringValue = rung.caption
        caption.font = MacTheme.Ramp.font(.rowNote)
        caption.textColor = MacTheme.Color.secondaryLabel
        caption.maximumNumberOfLines = 2
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

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return onPress != nil
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
    nonisolated override var isFlipped: Bool { true }
}

/// Pinned pairs over the chooser's fixture fleet, so the dial's pairs, previews and carry notices
/// can be drawn on a desk with no servers and no pins of its own: one pair this chat runs, one
/// whose level the model lacks, one on another machine kept as a bare star.
enum ModelDialDemo {
    static var presets: [ModelPreset] {
        [
            ModelPreset(selection: ModelChooserDemo.selected, effort: .level("high")),
            ModelPreset(
                selection: ModelSelection(providerID: "anthropic", modelID: "claude-sonnet-5"),
                effort: .level("max")),
            ModelPreset(
                selection: ModelSelection(providerID: "opencode-go", modelID: "gpt-5.6-luna"),
                effort: .server),
            ModelPreset(
                selection: ModelSelection(providerID: "ollama", modelID: "qwen3-coder:30b"),
                effort: .keep),
        ]
    }
}
