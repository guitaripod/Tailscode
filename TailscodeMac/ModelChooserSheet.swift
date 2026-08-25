import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// Every model the fleet offers, from every provider, as one list.
///
/// The pill's menu holds what this person actually works with; a catalog of two hundred entries
/// needs a surface you can search, and one that is organised by something a reader recognises. The
/// shared `ModelChooser` decides all of it — the folding of the same model offered by two
/// providers, the family sections, the ranking, the cursor and the keys — and this sheet draws its
/// answer, so the Mac and the phone are the same list rendered twice.
@MainActor
final class ModelChooserSheet: NSObject {
    private enum Entry {
        case header(ModelChooserSection)
        case row(ModelChooserRow, index: Int)
    }

    private static var active: [ModelChooserSheet] = []

    private let sheet: NSWindow
    private var chooser: ModelChooser
    private let onPick: @MainActor (ModelPick) -> Void
    private var quotas: [UsageQuota]
    private let summary = NSTextField(labelWithString: "")
    private let field = NSSearchField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let clear = NSButton()
    private let fold = NSButton()
    private let filters = NSSegmentedControl()
    private var entries: [Entry] = []
    private var monitor: Any?
    /// One width for the capability marks on every row, so what a model reads is a column instead
    /// of an edge that moves with the name beside it.
    private var markWidth: CGFloat = 0

    /// Every server the app knows, as the one list a chooser is built from — this conversation's
    /// own machine first. The pattern is Linux's chat pane's: catalogs come from the fleet's own
    /// memory, so the list can name what another server runs without this chat ever having talked
    /// to it, and a machine that did not answer reads as a state rather than as no models.
    static func fleetSources(
        profiles: [ConnectionProfile], current: String?, currentModels: [ModelInfo],
        backend: AgentType?, allowsServerDefault: Bool, reachable: Bool?
    ) -> [ModelSource] {
        var reachability: [String: Bool] = [:]
        if let current, let reachable { reachability[current] = reachable }
        let sources = ModelFleet.sources(
            profiles: profiles, current: current, currentModels: currentModels,
            allowsServerDefault: allowsServerDefault, reachability: reachability)
        guard sources.isEmpty else { return sources }
        let agent = backend ?? .openCode
        return [
            ModelSource(
                profileID: current ?? "", name: "", backend: agent, models: currentModels,
                isCurrent: true, allowsServerDefault: allowsServerDefault,
                acceptsAnyModelID: agent == .claudeCode, isReachable: reachable)
        ]
    }

    @discardableResult
    static func present(
        on host: NSWindow, sources: [ModelSource], selected: ModelSelection?,
        quotas: [UsageQuota] = [],
        onPick: @escaping @MainActor (ModelPick) -> Void
    ) -> ModelChooserSheet {
        let controller = ModelChooserSheet(
            sources: sources, selected: selected, quotas: quotas, onPick: onPick)
        active.append(controller)
        host.beginSheet(controller.sheet) { _ in
            controller.teardown()
            active.removeAll { $0 === controller }
        }
        controller.sheet.makeFirstResponder(controller.field)
        controller.revealCursor()
        return controller
    }

    private init(
        sources: [ModelSource], selected: ModelSelection?, quotas: [UsageQuota],
        onPick: @escaping @MainActor (ModelPick) -> Void
    ) {
        self.quotas = quotas
        chooser = ModelChooser(sources: sources, selected: selected, quotas: quotas)
        self.onPick = onPick
        sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 620),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()

        let content = NSView()
        sheet.contentView = content

        summary.stringValue = chooser.summary
        summary.font = MacTheme.Ramp.font(.toolOutput)
        summary.textColor = MacTheme.Color.secondaryLabel
        summary.alignment = .right
        summary.setContentHuggingPriority(.defaultLow, for: .horizontal)

        field.placeholderString = Localized.text("Search models, providers, ids")
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(field)

        filters.segmentStyle = .rounded
        filters.trackingMode = .selectOne
        filters.segmentCount = chooser.scopes.count
        for (index, scope) in chooser.scopes.enumerated() {
            filters.setLabel(scope.title, forSegment: index)
            filters.setToolTip(scope.detail, forSegment: index)
        }
        filters.selectedSegment = chooser.scopes.isEmpty ? -1 : 0
        filters.target = self
        filters.action = #selector(filterChanged)
        filters.isHidden = chooser.scopes.isEmpty
        filters.setContentHuggingPriority(.required, for: .horizontal)

        fold.bezelStyle = .accessoryBarAction
        fold.controlSize = .small
        fold.target = self
        fold.action = #selector(foldAll)
        fold.setContentHuggingPriority(.required, for: .horizontal)

        let band = NSStackView(views: [filters, summary, fold])
        band.orientation = .horizontal
        band.alignment = .centerY
        band.spacing = MacTheme.Spacing.s
        band.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(band)

        table.headerView = nil
        table.rowSizeStyle = .custom
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = true
        table.refusesFirstResponder = true
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("model")))
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)

        empty.font = MacTheme.Ramp.font(.panelLabel)
        empty.textColor = MacTheme.Color.secondaryLabel
        empty.alignment = .center
        empty.isSelectable = false
        empty.maximumNumberOfLines = 0
        empty.isHidden = true
        empty.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(empty)

        clear.title = Localized.text("Clear the filter")
        clear.bezelStyle = .rounded
        clear.target = self
        clear.action = #selector(clearFilter)
        clear.isHidden = true
        clear.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(clear)

        let hint = NSTextField(labelWithString: chooser.hint)
        hint.font = MacTheme.Ramp.font(.rowNote)
        hint.textColor = MacTheme.Color.tertiaryLabel
        hint.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hint)

        let inset = MacTheme.Spacing.l
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: inset),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),
            band.topAnchor.constraint(equalTo: field.bottomAnchor, constant: MacTheme.Spacing.s),
            band.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: band.bottomAnchor, constant: MacTheme.Spacing.s),
            scroll.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            empty.leadingAnchor.constraint(
                equalTo: scroll.leadingAnchor, constant: MacTheme.Spacing.l),
            empty.trailingAnchor.constraint(
                equalTo: scroll.trailingAnchor, constant: -MacTheme.Spacing.l),
            empty.topAnchor.constraint(equalTo: scroll.topAnchor, constant: MacTheme.Spacing.xl),
            clear.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            clear.topAnchor.constraint(equalTo: empty.bottomAnchor, constant: MacTheme.Spacing.s),
            hint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: MacTheme.Spacing.s),
            hint.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            hint.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -inset),
        ])

        rebuild()
        installMonitor()
    }

    private func teardown() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// A catalog that arrived while the sheet is open: the list, the summary and the filters are
    /// re-answered from it, and what the reader was doing — the query, the filter — survives the
    /// answer. A server that comes back from a restart reaches the open sheet this way.
    func update(sources: [ModelSource]) {
        let query = chooser.query
        let scope = chooser.scope
        chooser = ModelChooser(sources: sources, selected: chooser.selected, quotas: quotas)
        chooser.search(query)
        if chooser.scopes.contains(scope) || scope == .all { _ = chooser.setScope(scope) }
        filters.segmentCount = chooser.scopes.count
        for (index, offered) in chooser.scopes.enumerated() {
            filters.setLabel(offered.title, forSegment: index)
            filters.setToolTip(offered.detail, forSegment: index)
        }
        filters.isHidden = chooser.scopes.isEmpty
        rebuild()
        revealCursor()
    }

    /// ⌃→ / ⌃← open and close a folded row, and ⌃1–9 take a filter. AppKit hands ⌃N/⌃P to the field
    /// as `moveDown:`/`moveUp:` already, but the arrows and the digits with a modifier never reach
    /// `doCommandBy`. ⌘S stars whatever row the cursor is on — a chord, because a star is a
    /// decision made from the keyboard while the hand is already there.
    private func installMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.sheet else { return event }
            if event.modifierFlags.contains(.command),
                event.charactersIgnoringModifiers?.lowercased() == "s"
            {
                guard let selection = self.chooser.focused?.selection else { return event }
                self.chooser.togglePin(selection)
                return self.refreshed()
            }
            guard event.modifierFlags.contains(.control) else { return event }
            let all = event.modifierFlags.contains(.shift)
            switch (event.keyCode, all) {
            case (124, true): return self.chooser.setAllCollapsed(false) ? self.refreshed() : event
            case (123, true): return self.chooser.setAllCollapsed(true) ? self.refreshed() : event
            case (124, false): return self.handled(.expand) ? self.refreshed() : event
            case (123, false): return self.handled(.collapse) ? self.refreshed() : event
            default: break
            }
            guard let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }), digit > 0,
                self.chooser.scopes.indices.contains(digit - 1),
                self.chooser.setScope(self.chooser.scopes[digit - 1])
            else { return event }
            return self.refreshed()
        }
    }

    private func handled(_ command: ModelChooserCommand) -> Bool {
        chooser.handle(command).handled
    }

    private func refreshed() -> NSEvent? {
        rebuildKeepingScroll()
        revealCursor()
        return nil
    }

    /// Reloading a table whose row count just changed clamps the clip view, and the reveal that
    /// follows then aims at a cursor that was never on screen — which is how opening one family
    /// threw the whole catalog past the place it was being read. Opening or shutting a fold is
    /// still the same list, so it is rebuilt around the position rather than over it.
    private func rebuildKeepingScroll() {
        let held = scroll.contentView.bounds.origin
        rebuild()
        scroll.contentView.scroll(to: held)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func rebuild() {
        entries = []
        var index = 0
        var marks: CGFloat = 0
        let font = MacTheme.Ramp.font(.gaugeCaption)
        for section in chooser.sections {
            if !section.title.isEmpty { entries.append(.header(section)) }
            for row in section.rows {
                entries.append(.row(row, index: index))
                marks = max(marks, ModelChooserRowView.marksText(row).size(withAttributes: [.font: font]).width)
                index += 1
            }
        }
        markWidth = ceil(marks)
        summary.stringValue = chooser.summary
        empty.stringValue = chooser.emptyResult ?? ""
        empty.isHidden = chooser.emptyResult == nil
        clear.isHidden = chooser.emptyEscape == nil
        if let action = chooser.foldAction {
            fold.title = action.title
            fold.isHidden = false
        } else {
            fold.isHidden = true
        }
        if let index = chooser.scopes.firstIndex(of: chooser.scope) {
            filters.selectedSegment = index
        }
        table.reloadData()
        syncSelection()
    }

    @objc private func filterChanged() {
        let index = filters.selectedSegment
        guard chooser.scopes.indices.contains(index) else { return }
        guard chooser.setScope(chooser.scopes[index]) else { return }
        rebuild()
        revealCursor()
    }

    @objc private func clearFilter() {
        guard let escape = chooser.emptyEscape, chooser.setScope(escape) else { return }
        rebuild()
        revealCursor()
    }

    private func syncSelection() {
        guard
            let target = entries.firstIndex(where: {
                if case .row(_, let index) = $0 { return index == chooser.cursor }
                return false
            })
        else {
            table.deselectAll(nil)
            return
        }
        table.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
    }

    private func revealCursor() {
        guard table.selectedRow >= 0 else { return }
        table.scrollRowToVisible(table.selectedRow)
    }

    private func move(by delta: Int) {
        chooser.move(by: delta)
        syncSelection()
        revealCursor()
    }

    @objc private func clicked() {
        let clicked = table.clickedRow
        guard entries.indices.contains(clicked) else { return }
        switch entries[clicked] {
        case .header(let section):
            guard chooser.toggleSection(section.id) else { return }
            rebuildKeepingScroll()
        case .row(let row, let index):
            chooser.focus(index)
            pick(row)
        }
    }

    @objc private func foldAll() {
        guard let action = chooser.foldAction, chooser.setAllCollapsed(action.collapses) else {
            return
        }
        rebuildKeepingScroll()
        revealCursor()
    }

    private func pick(_ row: ModelChooserRow) {
        let handler = onPick
        sheet.sheetParent?.endSheet(sheet)
        handler(row.pick)
    }

    private func toggle(_ index: Int) {
        chooser.focus(index)
        guard chooser.setExpanded(!(chooser.focused?.isExpanded ?? false), at: index) else {
            return
        }
        rebuildKeepingScroll()
    }

    fileprivate func expandAction(_ index: Int) -> () -> Void {
        { [weak self] in self?.toggle(index) }
    }

    fileprivate func togglePinAction(_ index: Int) -> () -> Void {
        { [weak self] in self?.togglePin(at: index) }
    }

    private func togglePin(at index: Int) {
        guard entries.indices.contains(index), case .row(let row, _) = entries[index] else {
            return
        }
        chooser.focus(index)
        guard let selection = row.selection else { return }
        chooser.togglePin(selection)
        rebuildKeepingScroll()
    }
}

extension ModelChooserSheet: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard entries.indices.contains(row) else { return 24 }
        switch entries[row] {
        case .header: return 26 * MacTheme.UIScale.factor
        case .row(let value, _): return (value.detail.isEmpty ? 26 : 40) * MacTheme.UIScale.factor
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard entries.indices.contains(row) else { return false }
        if case .header = entries[row] { return false }
        return true
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        switch entries[row] {
        case .header(let section):
            return ModelChooserHeaderView(section: section)
        case .row(let value, let index):
            return ModelChooserRowView(
                row: value, marks: markWidth, onExpand: expandAction(index),
                onTogglePin: togglePinAction(index))
        }
    }
}

extension ModelChooserSheet: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        chooser.search(field.stringValue)
        rebuild()
        revealCursor()
    }

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            move(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            move(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            guard let focused = chooser.focused else { return true }
            pick(focused)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            sheet.sheetParent?.endSheet(sheet)
            return true
        default:
            return false
        }
    }
}

/// A family heading with what it holds, counted — the one place the provider count still belongs,
/// because a section is the only thing a count can be about once the rows are models.
@MainActor
private final class ModelChooserHeaderView: NSTableCellView {
    init(section: ModelChooserSection) {
        super.init(frame: .zero)
        let title = NSTextField(
            labelWithAttributedString: NSAttributedString(
                string: section.title.uppercased(),
                attributes: MacTheme.Ramp.attributes(
                    .metricLabel, color: MacTheme.Color.secondaryLabel)))
        let detail = NSTextField(labelWithString: section.detail)
        detail.font = MacTheme.Ramp.font(.gaugeCaption)
        detail.textColor = MacTheme.Color.tertiaryLabel
        for view in [title, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let leading: CGFloat = section.canCollapse ? MacTheme.Spacing.l : MacTheme.Spacing.s
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacTheme.Spacing.s),
            detail.lastBaselineAnchor.constraint(equalTo: title.lastBaselineAnchor),
        ])
        guard section.canCollapse else { return }
        let fold = NSImageView(
            image: NSImage(
                systemSymbolName: section.isCollapsed ? "chevron.right" : "chevron.down",
                accessibilityDescription: section.title) ?? NSImage())
        fold.contentTintColor = MacTheme.Color.tertiaryLabel
        fold.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        fold.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fold)
        toolTip = Localized.text("Open or fold this family")
        NSLayoutConstraint.activate([
            fold.trailingAnchor.constraint(equalTo: title.leadingAnchor, constant: -4),
            fold.centerYAnchor.constraint(equalTo: title.centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// One model in three columns that hold their places down the whole list: the tick, the name over
/// what it is, and — flush to the right edge — everything the row wears. The facts used to follow
/// the name, so their left edge moved with every name's length and the eye had to find them again
/// on each line; against the right edge they read as a column.
@MainActor
private final class ModelChooserRowView: NSTableCellView {
    /// The capabilities a row wears, as the one string that goes in the marks column.
    static func marksText(_ row: ModelChooserRow) -> String {
        row.facts.filter(\.isCapability).map(\.tag).joined(separator: " ")
    }

    init(
        row: ModelChooserRow, marks width: CGFloat,
        onExpand: @escaping () -> Void, onTogglePin: @escaping () -> Void
    ) {
        super.init(frame: .zero)

        let title = NSTextField(labelWithAttributedString: Self.title(row))
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let column = NSStackView(views: [title])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 1
        if !row.detail.isEmpty {
            let detail = NSTextField(labelWithString: row.detail)
            detail.font = MacTheme.Ramp.font(.rowNote)
            detail.textColor = MacTheme.Color.tertiaryLabel
            detail.lineBreakMode = .byTruncatingTail
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            column.addArrangedSubview(detail)
        }
        column.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        column.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let check = NSTextField(labelWithString: row.isSelected ? "✓" : "")
        check.font = MacTheme.Ramp.font(.panelLabel)
        check.textColor = MacTheme.Color.accent
        check.alignment = .center

        let line = NSStackView(views: [check, column])
        line.spacing = MacTheme.Spacing.xs
        line.alignment = .centerY
        line.orientation = .horizontal
        if let wall = row.wall {
            line.addArrangedSubview(
                Self.pill(
                    text: QuotaSurface.rowMark(wall), tint: MacTheme.Color.danger,
                    tooltip: QuotaSurface.bannerBody(wall)))
        }
        for fact in row.facts where !fact.isCapability { line.addArrangedSubview(Self.pill(fact)) }

        let star = RowKit.ActionButton(title: "", action: onTogglePin)
        star.isBordered = false
        star.bezelStyle = .accessoryBar
        star.contentTintColor = MacTheme.Color.accent
        if row.selection != nil {
            star.image = NSImage(
                systemSymbolName: row.isPinned ? "star.fill" : "star",
                accessibilityDescription: Localized.text(
                    row.isPinned ? "Unpin this model" : "Pin this model"))
            star.toolTip = Localized.text(
                row.isPinned ? "Unpin this model" : "Pin this model")
        } else {
            star.isEnabled = false
            star.image = NSImage(
                systemSymbolName: "star",
                accessibilityDescription: Localized.text("Pin this model"))
        }
        line.addArrangedSubview(star)

        let capabilities = row.facts.filter(\.isCapability)
        let marks = NSTextField(labelWithString: Self.marksText(row))
        marks.font = MacTheme.Ramp.font(.gaugeCaption)
        marks.textColor = MacTheme.Color.tertiaryLabel
        marks.toolTip = capabilities.map(\.label).joined(separator: " · ")
        marks.setContentCompressionResistancePriority(.required, for: .horizontal)
        line.addArrangedSubview(marks)

        let chevron = RowKit.ActionButton(title: "", action: onExpand)
        chevron.isBordered = false
        chevron.bezelStyle = .accessoryBar
        chevron.contentTintColor = MacTheme.Color.secondaryLabel
        chevron.isEnabled = row.canExpand
        if row.canExpand {
            chevron.image = NSImage(
                systemSymbolName: row.isExpanded ? "chevron.down" : "chevron.right",
                accessibilityDescription: Localized.text("The other providers that run it"))
            chevron.toolTip = Localized.text("The other providers that run it")
        }
        line.addArrangedSubview(chevron)

        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        let leading = MacTheme.Spacing.s + (row.isNested ? MacTheme.Spacing.xl : 0)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacTheme.Spacing.s),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 14 * MacTheme.UIScale.factor),
            star.widthAnchor.constraint(equalToConstant: 16 * MacTheme.UIScale.factor),
            marks.widthAnchor.constraint(equalToConstant: width),
            chevron.widthAnchor.constraint(equalToConstant: 18 * MacTheme.UIScale.factor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The name, with the letters the query matched picked out. A match changes weight and colour
    /// and never size: a taller glyph inside a word lifts the line's ascent, so the row would jump
    /// as the query changed and the name would read as misspelt rather than as found.
    private static func title(_ row: ModelChooserRow) -> NSAttributedString {
        let face = MacTheme.Ramp.font(.panelLabel)
        let text = NSMutableAttributedString(
            string: row.title,
            attributes: [
                .font: face,
                .foregroundColor: row.wall == nil
                    ? MacTheme.Color.label : MacTheme.Color.tertiaryLabel,
            ])
        let characters = Array(row.title)
        for offset in row.highlight where offset < characters.count {
            let start = String(characters[0..<offset]).utf16.count
            let length = String(characters[offset]).utf16.count
            text.addAttributes(
                [
                    .foregroundColor: MacTheme.Color.accent,
                    .font: face.bold,
                ], range: NSRange(location: start, length: length))
        }
        return text
    }

    private static func pill(_ fact: ModelFact) -> NSView {
        let tint: NSColor = {
            switch fact {
            case .local: return MacTheme.Color.accent
            case .providers: return MacTheme.Color.info
            default: return MacTheme.Color.secondaryLabel
            }
        }()
        return pill(text: fact.tag, tint: tint, tooltip: fact.label)
    }

    private static func pill(text: String, tint: NSColor, tooltip: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = MacTheme.Ramp.font(.gaugeCaption)
        label.textColor = tint
        label.toolTip = tooltip
        label.translatesAutoresizingMaskIntoConstraints = false
        let wrap = NSView()
        wrap.wantsLayer = true
        wrap.layer?.cornerRadius = 7
        wrap.layer?.backgroundColor = tint.withAlphaComponent(0.16).cgColor
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -1),
        ])
        wrap.setContentCompressionResistancePriority(.required, for: .horizontal)
        wrap.setContentHuggingPriority(.required, for: .horizontal)
        return wrap
    }
}
