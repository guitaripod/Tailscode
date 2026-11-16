import AppKit
import CodingAgentKit
import TailscodeCore

/// Everything the chat list can say, one value per row: the table is a pure function of this
/// array, which is what makes the ten-second refresh cheap to diff and safe to skip when nothing
/// the list would say has changed.
enum SidebarRow: Equatable {
    case banner(String)
    case backLink
    /// The clearable banner a scoped list wears: the project and its server, worn as a row whose
    /// click restores the whole list.
    case scopeLink(String)
    /// The offer the launch pad owed: a new chat in the scoped project, pre-aimed at its
    /// directory, riding the board's own chrome.
    case scopeNew(String)
    /// The sidebar's answer to an empty list when the cause is that no machine is set up: the
    /// one press that starts setting one up, so the sentence above it is never a dead end.
    case addMachine(String)
    case header(SectionHeading)
    /// - Parameter marked: whether the row is held by the bulk selection. It travels in the row
    ///   value rather than being read from the store at configure time, so the table's diff sees a
    ///   mark land the same way it sees a title change.
    /// - Parameter dress: what the list decides for the row, carried in the value for the same
    ///   reason: news that changed is a row that changed.
    case session(SessionRowModel, marked: Bool, dress: SidebarRowDress)
    /// Several conversations held in one window at once, drawn as the one row they are. Pressing
    /// it puts the whole arrangement back; each member still has a line of its own.
    case tab(SplitTabRow, marked: Bool)
    case more(Int)
    case archived(Int)
    case empty(String)
    /// What happened while nobody was here. The heading carries the whole count and the way to
    /// dismiss the lot; each row is a place to go back to.
    case missedHeader(Int)
    case missed(MissedActivity)
    /// The words that were searched for, how many conversations said them, and whether the fleet
    /// is still answering. Clicking it is the way back to the list.
    case searchHeader(String, Int, Bool)
    case searchResult(TranscriptSearch.Row)

    /// Whether the row stands for a conversation, which is the one kind a range mark can measure
    /// between — a header or an action row is a place in the list, not a chat.
    var isChat: Bool {
        switch self {
        case .session, .tab: return true
        default: return false
        }
    }

    /// Whether a press on the row does something, which is what earns it a ground under the
    /// pointer. A heading, a banner and an empty list's sentence are read, not pressed.
    var isPressable: Bool {
        switch self {
        case .banner, .header, .empty, .missedHeader: return false
        default: return true
        }
    }
}

/// What the list around a chat row decides for it: the facts every row of this listing shares
/// and so none repeats, the heading it sits under, whose mark it need not wear again, and the
/// line of news it has to say.
struct SidebarRowDress: Equatable, Sendable {
    var vocabulary: ChatListVocabulary
    var section: SessionSection?
    var news: ChatRowNews?

    static let plain = SidebarRowDress(vocabulary: .full, section: nil, news: nil)
}

/// The verbs a chat row offers to a pointer resting on it, without a right-click: the ones
/// somebody reaches for most, and the way into the rest.
enum SidebarQuickAction {
    case pin
    case save
    case archive
    case more
}

/// Which way each verb would go if pressed now, read when the pointer arrives rather than kept on
/// the row, because the stores can change under a row that is not being redrawn.
struct SidebarQuickState: Equatable {
    var pinned: Bool
    var saved: Bool
    var archived: Bool
}

/// A row that comes up under the pointer. The ground is the cell's own shape — the same rounded
/// rectangle a marked row is washed in — so a hovered row and a marked one read as the same kind
/// of fact at two strengths, and a selected row keeps the system's selection to itself.
@MainActor
final class SidebarRowView: NSTableRowView {
    var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    override var isSelected: Bool {
        didSet { tellCellItIsChosen() }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        tellCellItIsChosen()
    }

    /// The row the selection is on is the one being looked at — the chat open in the window, or
    /// the one the arrow keys are passing over on the way to another — and its cell inks its
    /// title at full strength.
    private func tellCellItIsChosen() {
        for case let cell as SidebarSessionCell in subviews { cell.isChosen = isSelected }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isHovered, !isSelected else { return }
        let shape = numberOfColumns > 0 ? (view(atColumn: 0) as? NSView)?.frame ?? bounds : bounds
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(
            roundedRect: shape, xRadius: MacTheme.Radius.control, yRadius: MacTheme.Radius.control
        ).fill()
    }
}

/// Builds and recycles the table's cells, so the view controller stays about data and the cells
/// stay about pixels.
@MainActor
enum SidebarCellFactory {
    static func view(
        for row: SidebarRow, in tableView: NSTableView, onClearMissed: (() -> Void)? = nil,
        onOpenMember: ((SplitTab, Int) -> Void)? = nil
    ) -> NSView {
        switch row {
        case .session(let model, let marked, let dress):
            let cell = reuse("session", in: tableView) { SidebarSessionCell() }
            cell.configure(with: model, marked: marked, dress: dress)
            return cell
        case .tab(let model, let marked):
            let cell = reuse("splitTab", in: tableView) { SidebarSplitTabCell() }
            cell.configure(with: model, marked: marked, onOpenMember: onOpenMember)
            return cell
        case .header(let heading):
            let cell = reuse("header", in: tableView) { SidebarHeaderCell() }
            cell.configure(heading: heading)
            return cell
        case .banner(let text):
            let cell = reuse("banner", in: tableView) { SidebarMessageCell() }
            cell.configure(text: text, style: .banner)
            return cell
        case .empty(let text):
            let cell = reuse("empty", in: tableView) { SidebarMessageCell() }
            cell.configure(text: text, style: .empty)
            return cell
        case .more(let count):
            let cell = reuse("action", in: tableView) { SidebarMessageCell() }
            cell.configure(text: Localized.text("%@ more chats", "\(count)"), style: .action)
            return cell
        case .archived(let count):
            let cell = reuse("action", in: tableView) { SidebarMessageCell() }
            cell.configure(text: Localized.text("%@ archived", "\(count)"), style: .action)
            return cell
        case .backLink:
            let cell = reuse("action", in: tableView) { SidebarMessageCell() }
            cell.configure(text: Localized.text("← All chats"), style: .action)
            return cell
        case .scopeLink(let text):
            let cell = reuse("action", in: tableView) { SidebarMessageCell() }
            cell.configure(text: Localized.text("%@ ✕", text), style: .action)
            return cell
        case .scopeNew(let name):
            let cell = reuse("action", in: tableView) { SidebarMessageCell() }
            cell.configure(text: Localized.text("＋ New chat in %@", name), style: .action)
            return cell
        case .addMachine(let title):
            let cell = reuse("action", in: tableView) { SidebarMessageCell() }
            cell.configure(text: title, style: .primary)
            return cell
        case .missedHeader(let count):
            let cell = reuse("missedHeader", in: tableView) { SidebarHeaderCell() }
            cell.configure(
                title: Localized.text("MISSED"), count: count, onClear: onClearMissed)
            return cell
        case .missed(let item):
            let cell = reuse("missed", in: tableView) { SidebarMissedCell() }
            cell.configure(with: item)
            return cell
        case .searchHeader(let query, let count, let running):
            let cell = reuse("searchHeader", in: tableView) { SidebarHeaderCell() }
            headSearchResults(cell, query: query, count: count, running: running)
            return cell
        case .searchResult(let result):
            let cell = reuse("searchResult", in: tableView) { SidebarSearchResultCell() }
            cell.configure(with: result)
            return cell
        }
    }

    /// The heading over what a search found. It has no button: the heading itself is the way back,
    /// because a result list is left by clicking away from it and a second control there is one
    /// more thing to read.
    private static func headSearchResults(
        _ cell: SidebarHeaderCell, query: String, count: Int, running: Bool
    ) {
        cell.configure(
            title: running
                ? Localized.text("SEARCHING “%@” — CLICK TO GO BACK", query)
                : Localized.text("“%@” — CLICK TO GO BACK", query),
            count: running ? nil : count)
    }

    private static func reuse<T: NSView>(
        _ id: String, in tableView: NSTableView, make: () -> T
    ) -> T {
        let identifier = NSUserInterfaceItemIdentifier(id)
        if let recycled = tableView.makeView(withIdentifier: identifier, owner: nil) as? T {
            return recycled
        }
        let made = make()
        made.identifier = identifier
        return made
    }
}

/// One thing that happened out of sight: what it was, in which chat, and how long ago. Same three
/// voices as a conversation row, because it is a way back into one.
final class SidebarMissedCell: NSView {
    private let glyph = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var glyphWidth: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)
        glyph.font = MacTheme.Ramp.font(.panelLabel)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        title.font = MacTheme.Ramp.font(.rowTitle)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        detail.font = MacTheme.Ramp.font(.panelFootnote)
        detail.textColor = MacTheme.Color.secondaryLabel
        detail.lineBreakMode = .byTruncatingTail
        detail.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        addSubview(title)
        addSubview(detail)
        let glyphWidth = glyph.widthAnchor.constraint(
            equalToConstant: SidebarSessionCell.stateColumn())
        self.glyphWidth = glyphWidth
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            glyph.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            glyphWidth,
            title.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 4),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            detail.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(with item: MissedActivity) {
        let face = item.reason.face
        glyph.stringValue = face.glyph
        glyph.font = MacTheme.Ramp.font(.panelLabel)
        glyphWidth?.constant = SidebarSessionCell.stateColumn()
        glyph.textColor =
            item.isBlocking ? face.tone.color : face.tone.color.withAlphaComponent(0.72)
        title.stringValue = item.title
        title.font =
            item.isBlocking ? MacTheme.Ramp.font(.rowTitleStrong) : MacTheme.Ramp.font(.rowTitle)
        detail.font = MacTheme.Ramp.font(.panelFootnote)
        detail.stringValue = Localized.text(
            "%@ · %@ ago", item.kindLabel,
            StatusFacts.age(Date().timeIntervalSince(item.at)))
        setAccessibilityLabel(Localized.text("%@ — %@", item.title, item.kindLabel))
    }
}

/// One conversation the words were found in: what it is, where it lives, and the places it said
/// them — each quoted under the register it was in, so an answer, a thought and a shell command
/// are told apart at a glance rather than read for.
final class SidebarSearchResultCell: NSView {
    private let title = NSTextField(labelWithString: "")
    private let where_ = NSTextField(labelWithString: "")
    private let quotes = FillingStack(views: [])

    init() {
        super.init(frame: .zero)
        title.lineBreakMode = .byTruncatingTail
        where_.textColor = MacTheme.Color.secondaryLabel
        where_.lineBreakMode = .byTruncatingTail
        quotes.spacing = 2
        let column = FillingStack(views: [title, where_, quotes])
        column.spacing = 2
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(with result: TranscriptSearch.Row) {
        title.stringValue = result.title
        title.font =
            result.isTitleOnly
            ? MacTheme.Ramp.font(.rowTitle) : MacTheme.Ramp.font(.rowTitleStrong)
        where_.font = MacTheme.Ramp.font(.panelFootnote)
        where_.stringValue =
            ([result.project, result.profileName].compactMap { $0 }
            + (result.isTitleOnly ? [Localized.text("title only")] : []))
            .joined(separator: " · ")
        for view in quotes.arrangedSubviews {
            quotes.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for match in result.matches.prefix(3) {
            quotes.addArrangedSubview(Self.quote(match))
        }
        if result.total > result.matches.count {
            let more = NSTextField(
                labelWithString: Localized.text(
                    "… %@ more in this chat", "\(result.total - result.matches.count)"))
            more.font = MacTheme.Ramp.font(.panelFootnote)
            more.textColor = MacTheme.Color.tertiaryLabel
            quotes.addArrangedSubview(more)
        }
        setAccessibilityLabel(result.title)
    }

    private static func quote(_ match: TranscriptMatch) -> NSView {
        let kind = NSTextField(labelWithString: TranscriptSearch.label(for: match))
        kind.font = MacTheme.Ramp.font(.panelFootnote)
        kind.textColor = MacTheme.Color.accent
        kind.setContentCompressionResistancePriority(.required, for: .horizontal)
        let text = NSTextField(labelWithString: match.text)
        text.font = MacTheme.Ramp.font(.panelFootnote)
        text.textColor = MacTheme.Color.secondaryLabel
        text.lineBreakMode = .byTruncatingTail
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [kind, text])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .firstBaseline
        return row
    }
}

/// A section heading and the one figure worth putting beside it: how many agents are waiting or
/// working, or how many rows under it are new.
final class SidebarHeaderCell: NSView {
    private let title = NSTextField(labelWithString: "")
    private let fresh = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let clear = NSButton()
    private var onClear: (() -> Void)?

    init() {
        super.init(frame: .zero)
        title.textColor = MacTheme.Color.secondaryLabel
        title.translatesAutoresizingMaskIntoConstraints = false
        count.textColor = MacTheme.Color.tertiaryLabel
        count.translatesAutoresizingMaskIntoConstraints = false
        clear.title = Localized.text("clear")
        clear.bezelStyle = .inline
        clear.isBordered = false
        clear.contentTintColor = MacTheme.Color.secondaryLabel
        clear.target = self
        clear.action = #selector(clearTapped)
        clear.isHidden = true
        clear.translatesAutoresizingMaskIntoConstraints = false
        fresh.textColor = MacTheme.Color.accent
        fresh.isHidden = true
        fresh.translatesAutoresizingMaskIntoConstraints = false
        fresh.setContentCompressionResistancePriority(.required, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)
        addSubview(fresh)
        addSubview(count)
        addSubview(clear)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            fresh.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 7),
            fresh.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            fresh.trailingAnchor.constraint(lessThanOrEqualTo: clear.leadingAnchor, constant: -6),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            count.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            clear.trailingAnchor.constraint(equalTo: count.leadingAnchor, constant: -8),
            clear.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A recycled cell is handed back with the size it was built at, so every font is written here
    /// rather than in `init` — otherwise a step of the type scale grows the conversations and
    /// leaves the headings between them behind.
    ///
    /// - Parameter count: nil for a section that cannot honestly state a number yet. A search still
    ///   being answered has not found nothing, and a hard zero beside it says that it has.
    /// - Parameter onClear: the verb the heading carries, for a section that can be dismissed
    ///   whole. Absent for the ordinary chat-list headings, which name a grouping rather than a
    ///   pile of things to be got through.
    func configure(title: String, count: Int?, onClear: (() -> Void)? = nil) {
        apply(title: title, count: count, fresh: nil, tint: nil, onClear: onClear)
    }

    /// A chat section's heading. The section that waits on the person wears the attention tone,
    /// name and figure both, because it is the one heading that is itself a call to act.
    func configure(heading: SectionHeading) {
        apply(
            title: heading.title, count: heading.total, fresh: heading.freshLabel,
            tint: heading.needsYou ? MacTheme.Color.warning : nil, onClear: nil)
        setAccessibilityLabel(heading.spoken)
    }

    private func apply(
        title: String, count: Int?, fresh: String?, tint: NSColor?, onClear: (() -> Void)?
    ) {
        self.title.textColor = tint ?? MacTheme.Color.secondaryLabel
        self.count.textColor = tint ?? MacTheme.Color.tertiaryLabel
        self.fresh.font = NSFont.systemFont(
            ofSize: MacTheme.Ramp.font(.panelFootnote).pointSize, weight: .semibold)
        self.fresh.textColor = MacTheme.Color.accent
        self.fresh.stringValue = fresh ?? ""
        self.fresh.isHidden = fresh == nil
        self.title.font = MacTheme.Ramp.font(.sectionLabel)
        self.title.stringValue = title
        self.count.font = MacTheme.Ramp.font(.metricLabel)
        self.count.stringValue = count.map { "\($0)" } ?? ""
        self.count.isHidden = count == nil
        clear.font = MacTheme.Ramp.font(.metricLabel)
        self.onClear = onClear
        clear.isHidden = onClear == nil
    }

    /// What the heading is drawing, for a harness: its name, the figure beside it and the words
    /// that say how many rows are new, each nil when it is not shown.
    var reading: (title: String, count: String?, fresh: String?) {
        (
            title.stringValue, count.isHidden ? nil : count.stringValue,
            fresh.isHidden ? nil : fresh.stringValue
        )
    }

    @objc private func clearTapped() { onClear?() }
}

/// The list's non-conversation voices: the unreachable banner, the empty-state line, and the
/// tappable footers — more chats, the archive, and the way back out of it.
final class SidebarMessageCell: NSView {
    enum Style {
        case banner
        case empty
        case action
        case primary
    }

    private let label = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isSelectable = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(text: String, style: Style) {
        label.stringValue = text
        switch style {
        case .banner:
            label.font = MacTheme.Ramp.font(.panelFootnote)
            label.textColor = MacTheme.Color.danger
            label.alignment = .left
        case .empty:
            label.font = MacTheme.Ramp.font(.panelLabel)
            label.textColor = MacTheme.Color.tertiaryLabel
            label.alignment = .center
        case .action:
            label.font = MacTheme.Ramp.font(.panelFootnote)
            label.textColor = MacTheme.Color.secondaryLabel
            label.alignment = .center
        case .primary:
            label.font = MacTheme.Ramp.font(.panelLabel)
            label.textColor = MacTheme.Color.accent
            label.alignment = .center
        }
    }
}

/// One watch over the whole list, per the lesson every Mac app with a long outline learns: a
/// tracking area per row costs the scroll and the redraw, while one area on the table's visible
/// rect costs a lookup per move. It also answers the moves nobody makes — a scroll or a redraw
/// that slides a different row under a pointer standing still.
@MainActor
final class SidebarHoverWatch: NSResponder {
    private let onChange: () -> Void
    private weak var scrollView: NSScrollView?

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func watch(_ tableView: NSTableView, scrolling scrollView: NSScrollView) {
        self.scrollView = scrollView
        tableView.addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self, userInfo: nil))
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)
    }

    /// The row under the pointer, or -1 when the pointer is anywhere but over the list.
    func row(in tableView: NSTableView) -> Int {
        guard let window = tableView.window, let scrollView else { return -1 }
        let location = window.mouseLocationOutsideOfEventStream
        let inClip = scrollView.contentView.convert(location, from: nil)
        guard scrollView.contentView.bounds.contains(inClip) else { return -1 }
        return tableView.row(at: tableView.convert(location, from: nil))
    }

    override func mouseEntered(with event: NSEvent) { onChange() }
    override func mouseMoved(with event: NSEvent) { onChange() }
    override func mouseExited(with event: NSEvent) { onChange() }

    @objc private func scrolled() { onChange() }
}
