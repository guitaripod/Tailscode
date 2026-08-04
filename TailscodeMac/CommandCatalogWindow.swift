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
        super.init(window: window)
        window.contentView = makeContent()
        window.center()
        rebuild()
        NotificationCenter.default.addObserver(
            self, selector: #selector(closed), name: NSWindow.willCloseNotification, object: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func makeContent() -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.spacing = MacTheme.Spacing.s
        column.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        column.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = Localized.text(
            "Search %@ commands", "\(commands.count)")
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(searchField)
        searchField.widthAnchor.constraint(equalToConstant: 480).isActive = true

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
        scroll.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(scroll)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 480).isActive = true
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
    }

    func controlTextDidChange(_ obj: Notification) { rebuild() }

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
            return RowKit.label(
                "\(title.uppercased())  ·  \(count)",
                font: MacTheme.Font.caption(), color: MacTheme.Color.tertiaryLabel)
        case .command(let command):
            let name = "/\(command.name)"
            let hint = command.argumentHint.map { " \($0)" } ?? ""
            let title = RowKit.label(
                name + hint, font: MacTheme.Font.body(), color: MacTheme.Color.label)
            let detailParts = [command.details, command.scope]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
            let lines = NSStackView(views: [title])
            lines.orientation = .vertical
            lines.alignment = .leading
            lines.spacing = 1
            if let detail = detailParts.joined(separator: " · ").nilIfEmpty {
                lines.addArrangedSubview(
                    RowKit.label(
                        detail, font: MacTheme.Font.caption(),
                        color: MacTheme.Color.secondaryLabel))
            }
            lines.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
            return lines
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .command = rows[row] { return true }
        return false
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
