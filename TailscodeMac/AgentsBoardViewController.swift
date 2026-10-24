import AppKit
import CodingAgentKit
import TailscodeCore

/// The Now face of the board: Core's sentence on top, then Needs you, Working, In the background
/// and Finished, each item a view that is changed in place when only its words changed.
@MainActor
final class AgentsBoardViewController: NSViewController {
    let table = AgentsTableView()
    private let scroll = NSScrollView()
    private let context: AgentsContext
    private(set) var items: [AgentsItem] = []
    private var board: AgentBoard = .empty
    var onSelect: ((String?) -> Void)?
    var onOpenChat: ((String) -> Void)?
    var onPeek: ((String) -> Void)?
    var onStop: ((String) -> Void)?
    var onToggleInspector: (() -> Void)?
    private var suppressSelection = false

    init(context: AgentsContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var selectedKey: String? {
        let row = table.selectedRow
        return items.indices.contains(row) ? items[row].sessionKey : nil
    }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("agents"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.usesAutomaticRowHeights = true
        table.intercellSpacing = .zero
        table.backgroundColor = MacTheme.Color.canvas
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.doubleAction = #selector(doubleClicked)
        table.onOpenChat = { [weak self] in self?.openSelected() }
        table.onToggleInspector = { [weak self] in self?.onToggleInspector?() }
        table.menuProvider = { [weak self] row in self?.menu(forRow: row) }
        table.setAccessibilityLabel(Localized.text("Agents"))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = MacTheme.Color.canvas
        scroll.automaticallyAdjustsContentInsets = true
        view = scroll
    }

    func refresh() { apply(board) }

    func apply(_ next: AgentBoard) {
        board = next
        context.showsMachines = next.showsMachines
        let fresh = Self.items(for: next, actions: context.actions)
        let previous = items
        items = fresh
        context.actions.forget(
            keepingOnly: Set(next.needsYou.map(\.id) + next.working.map(\.id) + next.background.map(\.id)))
        guard isViewLoaded else { return }
        if previous.map(\.id) == fresh.map(\.id) {
            var heights = IndexSet()
            for index in fresh.indices where previous[index] != fresh[index] {
                reconfigure(row: index)
                heights.insert(index)
            }
            if !heights.isEmpty { table.noteHeightOfRows(withIndexesChanged: heights) }
            return
        }
        let keep = selectedKey
        suppressSelection = true
        table.reloadData()
        if let keep, let row = fresh.firstIndex(where: { $0.sessionKey == keep && $0.isSelectable }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        suppressSelection = false
        if keep != nil, selectedKey == nil { onSelect?(nil) }
    }

    static func items(for board: AgentBoard, actions: AgentsActions) -> [AgentsItem] {
        var items: [AgentsItem] = [
            .summary(
                [board.sentence, board.watchLine, board.machines.map { "\($0.name)\($0.running)\(String(describing: $0.reachable))" }.joined()]
                    .joined(separator: "|"))
        ]
        if board.isEmpty, board.finished.isEmpty {
            items.append(.empty)
            return items
        }
        if !board.needsYou.isEmpty {
            items.append(.header(.needsYou, count: board.needsYou.count, unread: 0))
            items += board.needsYou.map { .ask($0, actions.phase(for: $0.id, askID: $0.ask.id)) }
        }
        if !board.working.isEmpty {
            items.append(.header(.working, count: board.working.count, unread: 0))
            items += board.working.map { .row($0, .working) }
        }
        if !board.background.isEmpty {
            items.append(.header(.background, count: board.background.count, unread: 0))
            items += board.background.map { .row($0, .background) }
        }
        if !board.finished.isEmpty {
            items.append(
                .header(
                    .finished, count: board.finished.count,
                    unread: board.finished.filter(\.unread).count))
            items += board.finished.map { .finish($0) }
        }
        return items
    }

    func select(key: String?) {
        suppressSelection = true
        defer { suppressSelection = false }
        guard let key, let row = items.firstIndex(where: { $0.sessionKey == key && $0.isSelectable })
        else {
            table.deselectAll(nil)
            return
        }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    func tick() {
        let now = context.now()
        table.enumerateAvailableRowViews { rowView, _ in
            switch rowView.view(atColumn: 0) {
            case let card as AgentsAskCardView: card.tick(now: now)
            case let row as AgentsRowView: row.tick(now: now)
            case let finish as AgentsFinishRowView: finish.tick(now: now)
            default: break
            }
        }
    }

    private func reconfigure(row index: Int) {
        guard let rowView = table.rowView(atRow: index, makeIfNecessary: false),
            let cell = rowView.view(atColumn: 0) as? NSView
        else { return }
        configure(cell, for: items[index])
    }

    private func configure(_ cell: NSView, for item: AgentsItem) {
        let now = context.now()
        switch (cell, item) {
        case (let view as AgentsSummaryView, .summary):
            view.configure(board)
        case (let view as AgentsSectionHeaderView, .header(let section, let count, let unread)):
            view.configure(section, count: count, unread: unread)
        case (let view as AgentsAskCardView, .ask(let card, let phase)):
            view.configure(card, phase: phase, showsMachine: context.showsMachines, context: context)
            wire(view.block, card: card)
        case (let view as AgentsRowView, .row(let row, let section)):
            view.configure(row, section: section, showsMachine: context.showsMachines, context: context)
        case (let view as AgentsFinishRowView, .finish(let finish)):
            view.configure(finish, showsMachine: context.showsMachines, now: now)
        default:
            break
        }
    }

    private func wire(_ block: AgentsAskBlockView, card: AgentAskCard) {
        block.onDecide = { [weak self] allow in
            self?.context.actions.decide(card.id, ask: card.ask, allow: allow)
        }
        block.onOption = { [weak self] option in
            self?.context.actions.choose(card.id, ask: card.ask, option: option)
        }
    }

    private func openSelected() {
        guard let key = selectedKey else { return }
        onOpenChat?(key)
    }

    @objc private func clicked() {
        let row = table.clickedRow
        guard items.indices.contains(row), case .finish(let finish) = items[row] else { return }
        onOpenChat?(finish.id)
    }

    @objc private func doubleClicked() {
        let row = table.clickedRow
        guard items.indices.contains(row), let key = items[row].sessionKey,
            items[row].isSelectable
        else { return }
        onOpenChat?(key)
    }

    private func menu(forRow row: Int) -> NSMenu? {
        guard items.indices.contains(row), let key = items[row].sessionKey else { return nil }
        let menu = NSMenu()
        let open = NSMenuItem(
            title: Localized.text("Open Chat"), action: #selector(menuOpen(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = key
        menu.addItem(open)
        guard items[row].isSelectable else { return menu }
        let peek = NSMenuItem(
            title: Localized.text("Peek"), action: #selector(menuPeek(_:)), keyEquivalent: "")
        peek.target = self
        peek.representedObject = key
        menu.addItem(peek)
        menu.addItem(.separator())
        let stop = NSMenuItem(
            title: Localized.text("Stop…"), action: #selector(menuStop(_:)), keyEquivalent: "")
        stop.target = self
        stop.representedObject = key
        menu.addItem(stop)
        return menu
    }

    @objc private func menuOpen(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String { onOpenChat?(key) }
    }

    @objc private func menuPeek(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String { onPeek?(key) }
    }

    @objc private func menuStop(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String { onStop?(key) }
    }
}

extension AgentsBoardViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
}

extension AgentsBoardViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let cell: NSView
        switch item {
        case .summary: cell = reuse("summary", in: tableView) { AgentsSummaryView() }
        case .empty: cell = reuse("empty", in: tableView) { AgentsEmptyView() }
        case .header: cell = reuse("header", in: tableView) { AgentsSectionHeaderView() }
        case .ask: cell = reuse("ask", in: tableView) { AgentsAskCardView() }
        case .row: cell = reuse("row", in: tableView) { AgentsRowView() }
        case .finish: cell = reuse("finish", in: tableView) { AgentsFinishRowView() }
        }
        configure(cell, for: item)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = AgentsTableRowView()
        switch items[row] {
        case .ask: view.kind = .card
        case .row: view.kind = .row
        default: view.kind = .plain
        }
        return view
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        items.indices.contains(row) && items[row].isSelectable
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        onSelect?(selectedKey)
    }

    private func reuse<T: NSView>(
        _ identifier: String, in tableView: NSTableView, make: () -> T
    ) -> T {
        let id = NSUserInterfaceItemIdentifier(identifier)
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? T { return reused }
        let made = make()
        made.identifier = id
        return made
    }
}
