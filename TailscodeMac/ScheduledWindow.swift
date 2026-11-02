import AppKit
import CodingAgentKit
import TailscodeCore

/// Every machine's schedules in one window: the list on the left, soonest first with paused and
/// finished ones after (`ScheduleBoard`), each row its words, when and where, and the mark its last
/// run left; the chosen schedule on the right, its words and time editable, its switches, Run now,
/// Pause and Delete, and its history with each run's conversation one press away. The machine keeps
/// the clock, so nothing here asks anything itself: every press goes to the machine, and the window
/// redraws from what the machine answers next.
@MainActor
final class ScheduledWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let listScroll = NSScrollView()
    private let detail = ScheduleDetailView()
    private let empty = NSStackView()
    private let emptyTitle = NSTextField(labelWithString: ScheduleWords.empty)
    private let emptyDetail = NSTextField(wrappingLabelWithString: ScheduleWords.emptyDetail)
    private var rows: [ScheduleRow] = []
    private var selectedID: String?
    var onOpenChat: ((String, String) -> Void)?
    var onAskLater: (() -> Void)?
    var onToast: ((String) -> Void)?

    /// The rows on screen, for a harness.
    var shownRows: [ScheduleRow] { rows }
    var detailView: ScheduleDetailView { detail }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 580),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = ScheduleWords.title
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 640, height: 420)
        super.init(window: window)
        window.contentView = makeContent()
        window.center()
        window.setFrameAutosaveName("TailscodeScheduled")
        NotificationCenter.default.addObserver(
            forName: MachineDesk.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        detail.onOpenChat = { [weak self] profileID, sessionID in self?.onOpenChat?(profileID, sessionID) }
        detail.onToast = { [weak self] text in self?.onToast?(text) }
        detail.onDeleted = { [weak self] in
            self?.selectedID = nil
            self?.reload()
        }
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present(selecting id: String? = nil) {
        if let id { selectedID = MachineDesk.shared.row(id: id)?.id ?? id }
        reload()
        window?.makeKeyAndOrderFront(nil)
        Task { await MachineDesk.shared.refreshSchedules() }
    }

    private func makeContent() -> NSView {
        table.headerView = nil
        table.style = .sourceList
        table.backgroundColor = .clear
        table.usesAutomaticRowHeights = true
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("schedule"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        listScroll.translatesAutoresizingMaskIntoConstraints = false

        let newButton = NSButton(
            title: ScheduleWords.askLaterMenu, target: self, action: #selector(askLaterTapped))
        newButton.bezelStyle = .push
        newButton.controlSize = .small
        newButton.translatesAutoresizingMaskIntoConstraints = false

        let side = NSVisualEffectView()
        side.material = .sidebar
        side.blendingMode = .behindWindow
        side.translatesAutoresizingMaskIntoConstraints = false
        side.addSubview(listScroll)
        side.addSubview(newButton)

        emptyTitle.font = MacTheme.Ramp.font(.cardTitle)
        emptyDetail.font = MacTheme.Ramp.font(.panelDetail)
        emptyDetail.textColor = MacTheme.Color.secondaryLabel
        emptyDetail.preferredMaxLayoutWidth = 360
        empty.orientation = .vertical
        empty.alignment = .centerX
        empty.spacing = MacTheme.Spacing.s
        empty.addArrangedSubview(emptyTitle)
        empty.addArrangedSubview(emptyDetail)
        empty.translatesAutoresizingMaskIntoConstraints = false

        detail.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(side)
        root.addSubview(detail)
        root.addSubview(empty)
        NSLayoutConstraint.activate([
            side.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            side.topAnchor.constraint(equalTo: root.topAnchor),
            side.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            side.widthAnchor.constraint(equalToConstant: 300),
            listScroll.leadingAnchor.constraint(equalTo: side.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: side.trailingAnchor),
            listScroll.topAnchor.constraint(equalTo: side.topAnchor, constant: MacTheme.Spacing.s),
            listScroll.bottomAnchor.constraint(equalTo: newButton.topAnchor, constant: -MacTheme.Spacing.s),
            newButton.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: MacTheme.Spacing.m),
            newButton.bottomAnchor.constraint(equalTo: side.bottomAnchor, constant: -MacTheme.Spacing.m),
            detail.leadingAnchor.constraint(equalTo: side.trailingAnchor),
            detail.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            detail.topAnchor.constraint(equalTo: root.topAnchor),
            detail.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: detail.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: detail.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: detail.widthAnchor, constant: -48),
        ])
        return root
    }

    @objc private func askLaterTapped() { onAskLater?() }

    func reload() {
        rows = MachineDesk.shared.board.rows
        table.reloadData()
        if selectedID == nil || !rows.contains(where: { $0.id == selectedID }) {
            selectedID = rows.first?.id
        }
        if let selectedID, let index = rows.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        let row = rows.first { $0.id == selectedID }
        detail.isHidden = row == nil
        empty.isHidden = row != nil
        if let row { detail.show(row) }
    }

    func select(id: String) {
        selectedID = MachineDesk.shared.row(id: id)?.id ?? id
        reload()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = ScheduleRowCell()
        cell.configure(rows[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let index = table.selectedRow
        guard rows.indices.contains(index) else { return }
        guard rows[index].id != selectedID else { return }
        selectedID = rows[index].id
        detail.show(rows[index])
        detail.isHidden = false
        empty.isHidden = true
    }

    /// The colour a schedule's mark wears, one meaning to one colour wherever a mark is drawn.
    static func color(_ mark: ScheduleMark) -> NSColor {
        switch mark {
        case .answered, .done: return MacTheme.Color.success
        case .failed: return MacTheme.Color.danger
        case .caughtUp: return MacTheme.Color.warning
        case .running: return MacTheme.Color.accent
        case .quiet, .paused: return MacTheme.Color.tertiaryLabel
        case .missed, .waiting: return MacTheme.Color.secondaryLabel
        }
    }
}

/// One schedule as the list draws it: its words, when and where, and its last run's mark.
@MainActor
final class ScheduleRowCell: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let mark = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = MacTheme.Ramp.font(.rowTitleStrong)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.font = MacTheme.Ramp.font(.panelFootnote)
        subtitle.textColor = MacTheme.Color.secondaryLabel
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        mark.font = MacTheme.Ramp.font(.rowMeta)
        mark.alignment = .right
        mark.setContentCompressionResistancePriority(.required, for: .horizontal)
        mark.setContentHuggingPriority(.required, for: .horizontal)
        let lines = NSStackView(views: [title, subtitle])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 1
        lines.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [lines, spacer, mark])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MacTheme.Spacing.s
        row.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.xs + 2, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.xs + 2,
            right: MacTheme.Spacing.m)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ row: ScheduleRow) {
        title.stringValue = row.title
        title.textColor =
            row.schedule.paused || row.schedule.isFinished ? MacTheme.Color.secondaryLabel : MacTheme.Color.label
        subtitle.stringValue = row.subtitle
        let words = row.markWords.map { "\(row.mark.glyph) \($0)" } ?? row.mark.glyph
        mark.stringValue = words
        mark.textColor = ScheduledWindow.color(row.mark)
        setAccessibilityLabel([row.title, row.subtitle, row.markWords ?? ""].joined(separator: ", "))
    }
}
