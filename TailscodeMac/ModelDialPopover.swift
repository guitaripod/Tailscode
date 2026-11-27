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
    /// the arrows survive the swap; a state that would draw exactly what is on screen — the same
    /// rows, at the same level — is not drawn at all, because a streaming turn hands one over
    /// with each frame.
    func update(state fresh: ModelDialState) {
        guard !drawsSame(fresh) else { return }
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

    /// Whether the fresh state's rows say what the drawn ones say: the ids in order, the words on
    /// every row, the level the ladder shows and the catalog the list is a window on.
    private func drawsSame(_ fresh: ModelDialState) -> Bool {
        guard fresh.rows.map(\.id) == state.rows.map(\.id), fresh.rows == state.rows,
            fresh.effort == state.effort, fresh.headline == state.headline,
            fresh.catalogSummary == state.catalogSummary,
            fresh.catalogCount == state.catalogCount
        else { return false }
        return fresh.rungs == state.rungs && fresh.ladderEffort == state.ladderEffort
            && fresh.ladderIsPreview == state.ladderIsPreview
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
    private var rowViews: [String: DialModelRowView] = [:]
    private var sectionViews: [String: DialSectionHeader] = [:]
    /// The row ids the list was arranged for, and the height it was last measured to at the
    /// column's width: a list that says the same thing again is neither re-arranged nor probed.
    private var rowOrder: [String] = []
    private var rowSections: [Bool] = []
    private var listHeightCache: (keys: [String], height: CGFloat)?
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
        arrange(state.rows)
        highlight(state.cursor)
        listHeight?.constant = measuredListHeight(state.rows)
        ladderKey = []
        renderLadder(state)
    }

    /// The list's rows, kept as views keyed by their id: a model that is still listed keeps the
    /// view it had — its name, its level and its check written in place — and only the rows that
    /// came or went cost anything, because building one is a dozen views and constraints.
    private func arrange(_ rows: [ModelDialRow]) {
        let keys = Self.keys(for: rows)
        let sections = rows.map { $0.section != nil }
        if keys == rowOrder, sections == rowSections {
            for (index, row) in rows.enumerated() {
                guard let view = rowViews[keys[index]] else { continue }
                view.update(row)
                if let section = row.section {
                    sectionViews[keys[index]]?.show(section.uppercased(), first: index == 0)
                }
            }
            return
        }
        for view in modelList.arrangedSubviews {
            modelList.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        var shown: [String: DialModelRowView] = [:]
        var headers: [String: DialSectionHeader] = [:]
        for (index, row) in rows.enumerated() {
            let key = keys[index]
            if let section = row.section {
                let header = sectionViews[key] ?? DialSectionHeader()
                header.show(section.uppercased(), first: index == 0)
                headers[key] = header
                modelList.addArrangedSubview(header)
                header.widthAnchor.constraint(equalTo: modelList.widthAnchor).isActive = true
            }
            let view = rowViews[key] ?? DialModelRowView(row: row)
            view.update(row)
            if !row.isMessage {
                view.onHover = { [weak self] in self?.onRowHover?(index) }
                view.onPress = { [weak self] in self?.onRowPress?(index) }
            }
            modelList.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: modelList.widthAnchor).isActive = true
            shown[key] = view
        }
        rowViews = shown
        sectionViews = headers
        rowOrder = keys
        rowSections = sections
    }

    /// A key per row that is unique even where two rows would share an id, so a repeated pair can
    /// never stand as one view twice.
    private static func keys(for rows: [ModelDialRow]) -> [String] {
        var seen: [String: Int] = [:]
        return rows.map { row in
            let count = seen[row.id, default: 0]
            seen[row.id] = count + 1
            return count == 0 ? row.id : row.id + "#\(count)"
        }
    }

    /// The list's own height at the column's width, measured once per sequence of rows: it is read
    /// row by row, and the same models under the same headings are the same height. A message row
    /// re-measures with its words, since a search that finds nothing changes only those.
    private func measuredListHeight(_ rows: [ModelDialRow]) -> CGFloat {
        let keys = rows.map { row -> String in
            let base =
                row.isMessage
                ? row.id + "\u{1}" + row.title + "\u{1}" + row.detail : row.id
            return row.section == nil ? base : base + "\u{2}"
        }
        if let cache = listHeightCache, cache.keys == keys { return cache.height }
        let height = min(listContentHeight(), Self.listCap)
        listHeightCache = (keys, height)
        return height
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
        for (index, key) in rowOrder.enumerated() {
            rowViews[key]?.isFocused = index == cursor
        }
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
        guard !view.isHidden else { return 0 }
        return (view is EffortMeterView ? 1 : 0) + view.subviews.reduce(0) { $0 + meters(in: $1) }
    }

    func reveal(_ cursor: Int) {
        guard rowOrder.indices.contains(cursor), let row = rowViews[rowOrder[cursor]] else { return }
        row.scrollToVisible(row.bounds)
    }
}

/// The ladder column's frame: drawn only while the arrows are the ladder's, so a person who
/// pressed ⇥ can see where ↑↓ now land without reading the hint.
