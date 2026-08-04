import AppKit
import CodingAgentKit
import TailscodeCore

/// Every model the server offers, from every provider, as one list.
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
    private let onPick: @MainActor (ModelSelection?) -> Void
    private let summary = NSTextField(labelWithString: "")
    private let field = NSSearchField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let empty = NSTextField(labelWithString: "")
    private var entries: [Entry] = []
    private var monitor: Any?

    static func present(
        on host: NSWindow, models: [ModelInfo], selected: ModelSelection?,
        allowsServerDefault: Bool, onPick: @escaping @MainActor (ModelSelection?) -> Void
    ) {
        let controller = ModelChooserSheet(
            models: models, selected: selected, allowsServerDefault: allowsServerDefault,
            onPick: onPick)
        active.append(controller)
        host.beginSheet(controller.sheet) { _ in
            controller.teardown()
            active.removeAll { $0 === controller }
        }
        controller.sheet.makeFirstResponder(controller.field)
        controller.revealCursor()
    }

    private init(
        models: [ModelInfo], selected: ModelSelection?, allowsServerDefault: Bool,
        onPick: @escaping @MainActor (ModelSelection?) -> Void
    ) {
        chooser = ModelChooser(
            models: models, selected: selected, allowsServerDefault: allowsServerDefault)
        self.onPick = onPick
        sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 620),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()

        let content = NSView()
        sheet.contentView = content

        summary.stringValue = chooser.summary
        summary.font = MacTheme.Font.mono(11)
        summary.textColor = MacTheme.Color.secondaryLabel
        summary.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(summary)

        field.placeholderString = Localized.text("Search models, providers, ids")
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(field)

        table.headerView = nil
        table.rowSizeStyle = .custom
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = true
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

        empty.font = MacTheme.Font.body()
        empty.textColor = MacTheme.Color.secondaryLabel
        empty.alignment = .center
        empty.isHidden = true
        empty.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(empty)

        let hint = NSTextField(labelWithString: chooser.hint)
        hint.font = MacTheme.Font.mono(10)
        hint.textColor = MacTheme.Color.tertiaryLabel
        hint.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hint)

        let inset = MacTheme.Spacing.l
        NSLayoutConstraint.activate([
            summary.topAnchor.constraint(equalTo: content.topAnchor, constant: inset),
            summary.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
            summary.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),
            field.topAnchor.constraint(
                equalTo: summary.bottomAnchor, constant: MacTheme.Spacing.s),
            field.leadingAnchor.constraint(equalTo: summary.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: summary.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: MacTheme.Spacing.m),
            scroll.leadingAnchor.constraint(equalTo: summary.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: summary.trailingAnchor),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.topAnchor.constraint(equalTo: scroll.topAnchor, constant: MacTheme.Spacing.xl),
            hint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: MacTheme.Spacing.s),
            hint.leadingAnchor.constraint(equalTo: summary.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: summary.trailingAnchor),
            hint.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -inset),
        ])

        rebuild()
        installMonitor()
    }

    private func teardown() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// ⌃→ / ⌃← open and close a folded row. AppKit hands ⌃N/⌃P to the field as `moveDown:`/
    /// `moveUp:` already, but the arrows with a modifier never reach `doCommandBy`.
    private func installMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.sheet,
                event.modifierFlags.contains(.control)
            else { return event }
            switch event.keyCode {
            case 124: return self.chooser.setExpanded(true) ? self.refreshed() : event
            case 123: return self.chooser.setExpanded(false) ? self.refreshed() : event
            default: return event
            }
        }
    }

    private func refreshed() -> NSEvent? {
        rebuild()
        revealCursor()
        return nil
    }

    private func rebuild() {
        entries = []
        var index = 0
        for section in chooser.sections {
            if !section.title.isEmpty { entries.append(.header(section)) }
            for row in section.rows {
                entries.append(.row(row, index: index))
                index += 1
            }
        }
        summary.stringValue = chooser.summary
        empty.stringValue = chooser.emptyResult ?? ""
        empty.isHidden = chooser.emptyResult == nil
        table.reloadData()
        syncSelection()
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
        guard entries.indices.contains(clicked), case .row(let row, let index) = entries[clicked]
        else { return }
        chooser.focus(index)
        pick(row.selection)
    }

    private func pick(_ selection: ModelSelection?) {
        let handler = onPick
        sheet.sheetParent?.endSheet(sheet)
        handler(selection)
    }

    private func toggle(_ index: Int) {
        chooser.focus(index)
        guard chooser.setExpanded(!(chooser.focused?.isExpanded ?? false), at: index) else {
            return
        }
        rebuild()
        revealCursor()
    }

    fileprivate func expandAction(_ index: Int) -> () -> Void {
        { [weak self] in self?.toggle(index) }
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
            return ModelChooserRowView(row: value, onExpand: expandAction(index))
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
            pick(chooser.focused?.selection ?? nil)
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
        let title = NSTextField(labelWithString: section.title.uppercased())
        title.font = .systemFont(ofSize: 10 * MacTheme.UIScale.factor, weight: .bold)
        title.textColor = MacTheme.Color.secondaryLabel
        let detail = NSTextField(labelWithString: section.detail)
        detail.font = MacTheme.Font.mono(9)
        detail.textColor = MacTheme.Color.tertiaryLabel
        for view in [title, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacTheme.Spacing.s),
            title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacTheme.Spacing.s),
            detail.lastBaselineAnchor.constraint(equalTo: title.lastBaselineAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// One model: the name with the letters the query landed on weighted inside it, who runs it and
/// under what id, and the facts that would change the pick.
@MainActor
private final class ModelChooserRowView: NSTableCellView {
    init(row: ModelChooserRow, onExpand: @escaping () -> Void) {
        super.init(frame: .zero)

        let title = NSTextField(labelWithAttributedString: Self.title(row))
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let check = NSTextField(labelWithString: row.isSelected ? "✓" : "")
        check.font = MacTheme.Font.body()
        check.textColor = MacTheme.Color.accent

        let line = NSStackView(views: [check, title])
        line.spacing = MacTheme.Spacing.xs
        line.alignment = .firstBaseline
        for fact in row.facts { line.addArrangedSubview(Self.pill(fact)) }
        if row.canExpand {
            let chevron = RowKit.ActionButton(title: "", action: onExpand)
            chevron.image = NSImage(
                systemSymbolName: row.isExpanded ? "chevron.down" : "chevron.right",
                accessibilityDescription: Localized.text("The other providers that run it"))
            chevron.isBordered = false
            chevron.bezelStyle = .accessoryBar
            chevron.contentTintColor = MacTheme.Color.secondaryLabel
            chevron.toolTip = Localized.text("The other providers that run it")
            line.addArrangedSubview(chevron)
        }

        let column = NSStackView(views: [line])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 1
        if !row.detail.isEmpty {
            let detail = NSTextField(labelWithString: row.detail)
            detail.font = MacTheme.Font.mono(10)
            detail.textColor = MacTheme.Color.tertiaryLabel
            detail.lineBreakMode = .byTruncatingTail
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            column.addArrangedSubview(detail)
        }
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        let leading = MacTheme.Spacing.s + (row.isNested ? MacTheme.Spacing.xl : 0)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacTheme.Spacing.s),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private static func title(_ row: ModelChooserRow) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: row.title,
            attributes: [
                .font: MacTheme.Font.body(), .foregroundColor: MacTheme.Color.label,
            ])
        let characters = Array(row.title)
        for offset in row.highlight where offset < characters.count {
            let start = String(characters[0..<offset]).utf16.count
            let length = String(characters[offset]).utf16.count
            text.addAttributes(
                [
                    .foregroundColor: MacTheme.Color.accent,
                    .font: MacTheme.Font.emphasis(),
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
        let label = NSTextField(labelWithString: fact.tag)
        label.font = .monospacedSystemFont(ofSize: 9 * MacTheme.UIScale.factor, weight: .medium)
        label.textColor = tint
        label.toolTip = fact.label
        label.translatesAutoresizingMaskIntoConstraints = false
        let wrap = NSView()
        wrap.wantsLayer = true
        wrap.layer?.cornerRadius = 3
        wrap.layer?.borderWidth = 1
        wrap.layer?.borderColor = tint.withAlphaComponent(0.4).cgColor
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -1),
        ])
        wrap.setContentCompressionResistancePriority(.required, for: .horizontal)
        wrap.setContentHuggingPriority(.required, for: .horizontal)
        return wrap
    }
}
