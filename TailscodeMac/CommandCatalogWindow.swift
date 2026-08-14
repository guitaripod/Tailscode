import AppKit
import CodingAgentKit
import TailscodeCore

/// Every command this server offers, on one browsable surface. The completion popover is for
/// speed; this is for discovery — grouped by source, searchable through the shared ranking.
@MainActor
final class CommandCatalogWindow: NSWindowController, NSSearchFieldDelegate, NSTableViewDataSource,
    NSTableViewDelegate
{
    private static var open: CommandCatalogWindow?

    private let commands: [AgentCommand]
    private let onPick: (AgentCommand) -> Void
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private var sections: [(id: String, title: String, commands: [AgentCommand])] = []
    private var rows: [CatalogRow] = []

    private enum CatalogRow {
        case header(String, Int)
        case command(AgentCommand)
    }

    static func present(commands: [AgentCommand], onPick: @escaping (AgentCommand) -> Void) {
        open?.window?.close()
        let catalog = CommandCatalogWindow(commands: commands, onPick: onPick)
        open = catalog
        catalog.showWindow(nil)
        catalog.window?.makeKeyAndOrderFront(nil)
    }

    private init(commands: [AgentCommand], onPick: @escaping (AgentCommand) -> Void) {
        self.commands = commands
        self.onPick = onPick
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = Localized.text("Commands")
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 420, height: 320)
        super.init(window: window)
        window.contentView = makeContent()
        window.initialFirstResponder = searchField
        window.center()
        rebuild()
        NotificationCenter.default.addObserver(
            self, selector: #selector(closed), name: NSWindow.willCloseNotification, object: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func makeContent() -> NSView {
        let column = FillingStack()
        column.spacing = MacTheme.Spacing.s
        column.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.m, left: MacTheme.Spacing.l, bottom: MacTheme.Spacing.m,
            right: MacTheme.Spacing.l)

        searchField.placeholderString = Localized.text(
            "Search %@ commands", "\(commands.count)")
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setContentHuggingPriority(.required, for: .vertical)
        column.addArrangedSubview(searchField)

        tableView.headerView = nil
        tableView.style = .plain
        tableView.usesAutomaticRowHeights = true
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(activate)
        tableView.target = self
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        tableView.addTableColumn(col)
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = MacTheme.Ramp.font(.panelLabel)
        emptyLabel.textColor = MacTheme.Color.secondaryLabel
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let field = NSView()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.addSubview(scroll)
        field.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: field.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: field.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: field.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            emptyLabel.widthAnchor.constraint(
                lessThanOrEqualTo: field.widthAnchor, constant: -2 * MacTheme.Spacing.xl),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        column.addArrangedSubview(field)
        return column
    }

    private func rebuild() {
        sections = CommandCatalogGrouping.sections(
            commands: commands, query: searchField.stringValue.trimmingCharacters(in: .whitespaces))
        rows = []
        for section in sections {
            rows.append(.header(section.title, section.commands.count))
            for command in section.commands { rows.append(.command(command)) }
        }
        tableView.reloadData()
        renderEmptiness()
    }

    /// A search that matched nothing and a server that offered nothing are two different silences,
    /// and neither may be drawn as a blank slab: a word the catalog lacks says so rather than
    /// vanishing.
    private func renderEmptiness() {
        emptyLabel.isHidden = !rows.isEmpty
        guard rows.isEmpty else { return }
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        emptyLabel.stringValue =
            query.isEmpty
            ? Localized.text(
                "This server didn't offer a command catalog. Typed slashes still go through as messages."
            )
            : Localized.text("No command matches “%@”", query)
    }

    func controlTextDidChange(_ obj: Notification) { rebuild() }

    /// The catalog is where a keyboard grammar is discovered, so it is answered from the keyboard:
    /// the caret stays in the field while ↑↓ walk the list under it, and Return takes what the walk
    /// landed on — or the first command, when the search has just been narrowed to it.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool
    {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            move(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            move(by: -1)
        case #selector(NSResponder.insertNewline(_:)):
            if tableView.selectedRow < 0 { move(by: 1) }
            activate()
        default:
            return false
        }
        return true
    }

    /// Headers are rows too, so a step is a walk past them to the next command in that direction.
    private func move(by delta: Int) {
        var index = tableView.selectedRow
        if index < 0 { index = delta > 0 ? -1 : rows.count }
        index += delta
        while index >= 0, index < rows.count {
            if case .command = rows[index] {
                tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                tableView.scrollRowToVisible(index)
                return
            }
            index += delta
        }
    }

    override func cancelOperation(_ sender: Any?) {
        window?.close()
    }

    @objc private func activate() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0, row < rows.count, case .command(let command) = rows[row] else { return }
        onPick(command)
        window?.close()
    }

    @objc private func closed() { Self.open = nil }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        switch rows[row] {
        case .header(let title, let count):
            let label = RowKit.attributedLabel(
                NSAttributedString(
                    string: "\(title.uppercased())  ·  \(count)",
                    attributes: MacTheme.Ramp.attributes(
                        .sectionLabel, color: MacTheme.Color.secondaryLabel)))
            return RowKit.inset(label, leading: MacTheme.Spacing.xs, top: MacTheme.Spacing.s)
        case .command(let command):
            let hint = command.argumentHint.map { " \($0)" } ?? ""
            let detail = [command.details, command.scope]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
                .joined(separator: " · ").nilIfEmpty
            return CommandCell(name: "/\(command.name)" + hint, detail: detail)
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .command = rows[row] { return true }
        return false
    }
}

/// The catalog's own cell view, because selection is a colour the table hands down rather than one
/// a row can read: `NSTableRowView` tells an `NSTableCellView` that its ink is now standing on the
/// emphasized accent, and a bare stack of labels never hears it — it keeps the near-black it was
/// built with and disappears into the fill under the first click.
@MainActor
private final class CommandCell: NSTableCellView {
    private let name: NSTextField
    private let detail: NSTextField?

    init(name: String, detail: String?) {
        self.name = RowKit.label(
            name, font: MacTheme.Ramp.font(.panelLabel), color: MacTheme.Color.label)
        self.detail = detail.map {
            RowKit.label(
                $0, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.secondaryLabel)
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let lines = NSStackView(views: [self.name])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 1
        if let field = self.detail { lines.addArrangedSubview(field) }
        lines.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lines)
        NSLayoutConstraint.activate([
            lines.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacTheme.Spacing.xs),
            lines.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -MacTheme.Spacing.xs),
            lines.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.xs),
            lines.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -MacTheme.Spacing.xs),
        ])
        textField = self.name
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let emphasized = backgroundStyle == .emphasized
            name.textColor = emphasized ? .alternateSelectedControlTextColor : MacTheme.Color.label
            detail?.textColor =
                emphasized
                ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.75)
                : MacTheme.Color.secondaryLabel
        }
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
