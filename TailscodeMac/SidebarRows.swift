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
    case header(String, Int)
    /// - Parameter marked: whether the row is held by the bulk selection. It travels in the row
    ///   value rather than being read from the store at configure time, so the table's diff sees a
    ///   mark land the same way it sees a title change.
    case session(SessionRowModel, marked: Bool, vocabulary: ChatListVocabulary)
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
}

/// Builds and recycles the table's cells, so the view controller stays about data and the cells
/// stay about pixels.
@MainActor
enum SidebarCellFactory {
    static func view(
        for row: SidebarRow, in tableView: NSTableView, onClearMissed: (() -> Void)? = nil
    ) -> NSView {
        switch row {
        case .session(let model, let marked, let vocabulary):
            let cell = reuse("session", in: tableView) { SidebarSessionCell() }
            cell.configure(with: model, marked: marked, vocabulary: vocabulary)
            return cell
        case .header(let title, let count):
            let cell = reuse("header", in: tableView) { SidebarHeaderCell() }
            cell.configure(title: title, count: count)
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
            // No button: the heading itself is the way back, because a result list is left by
            // clicking away from it and a second control there is one more thing to read.
            cell.configure(
                title: running
                    ? Localized.text("SEARCHING “%@” — CLICK TO GO BACK", query)
                    : Localized.text("“%@” — CLICK TO GO BACK", query),
                count: running ? nil : count)
            return cell
        case .searchResult(let result):
            let cell = reuse("searchResult", in: tableView) { SidebarSearchResultCell() }
            cell.configure(with: result)
            return cell
        }
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

/// One conversation: state glyph, title with its pills, and the two-register detail line — the
/// same three voices the Linux row speaks, so the lists read identically across desks. Kept
/// transparent: the system sidebar glass is the only background this row ever has.
final class SidebarSessionCell: NSView {
    private let glyph = NSTextField(labelWithString: "")
    /// The state's own symbol, breathing or knocking, in the column the glyph holds. The text
    /// glyph stays for what is not a state — the mark, and the quiet dot of an idle row.
    private let badge = ActivityBadgeView(pointSize: 10)
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    /// How long ago the conversation moved, in a column of its own down the trailing edge.
    private let age = NSTextField(labelWithString: "")
    private let titleRow = NSStackView()
    private var glyphWidth: NSLayoutConstraint?
    private var badgeWidth: NSLayoutConstraint?
    private var badgeHeight: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = MacTheme.Radius.control
        glyph.font = MacTheme.Ramp.font(.panelLabel)
        glyph.translatesAutoresizingMaskIntoConstraints = false

        title.font = MacTheme.Ramp.font(.rowTitle)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        titleRow.orientation = .horizontal
        titleRow.spacing = 6
        titleRow.alignment = .centerY
        titleRow.addArrangedSubview(title)
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        detail.font = MacTheme.Ramp.font(.panelFootnote)
        detail.textColor = MacTheme.Color.secondaryLabel
        detail.lineBreakMode = .byTruncatingTail
        detail.translatesAutoresizingMaskIntoConstraints = false

        age.font = .monospacedDigitSystemFont(ofSize: MacTheme.Ramp.font(.panelFootnote).pointSize, weight: .regular)
        age.textColor = MacTheme.Color.tertiaryLabel
        age.alignment = .right
        age.setContentCompressionResistancePriority(.required, for: .horizontal)
        age.setContentHuggingPriority(.required, for: .horizontal)
        age.translatesAutoresizingMaskIntoConstraints = false

        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        addSubview(badge)
        addSubview(age)
        addSubview(titleRow)
        addSubview(detail)
        let column = Self.stateColumn()
        let glyphWidth = glyph.widthAnchor.constraint(equalToConstant: column)
        let badgeWidth = badge.widthAnchor.constraint(equalToConstant: column)
        let badgeHeight = badge.heightAnchor.constraint(equalToConstant: column)
        self.glyphWidth = glyphWidth
        self.badgeWidth = badgeWidth
        self.badgeHeight = badgeHeight
        let titleFloor = title.widthAnchor.constraint(greaterThanOrEqualToConstant: 72)
        titleFloor.priority = .defaultHigh
        NSLayoutConstraint.activate([
            badge.centerXAnchor.constraint(equalTo: glyph.centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: glyph.centerYAnchor, constant: 1),
            badgeWidth,
            badgeHeight,
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            glyph.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            glyphWidth,
            titleFloor,
            titleRow.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 4),
            titleRow.trailingAnchor.constraint(lessThanOrEqualTo: age.leadingAnchor, constant: -6),
            titleRow.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            age.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            age.firstBaselineAnchor.constraint(equalTo: detail.firstBaselineAnchor),
            detail.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: age.leadingAnchor, constant: -6),
            detail.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 2),
            detail.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The width of the column the state is read in, held to the type scale: a well nailed to 16pt
    /// clips the very glyphs it exists to show once the ramp is stepped up, and leaves the symbol
    /// badge a speck beside a title twice its size.
    fileprivate static func stateColumn() -> CGFloat {
        (16 * MacTheme.UIScale.factor).rounded()
    }

    /// - Parameter marked: a marked row wears the accent wash and lends its glyph column to the
    ///   check, because the mark is the only thing about the row that a verb is about to act on;
    ///   the state it was in is still spoken by its pill, so nothing a marked row says is lost.
    func configure(
        with model: SessionRowModel, marked: Bool, vocabulary: ChatListVocabulary = .full
    ) {
        layer?.backgroundColor =
            marked
            ? MacTheme.Color.accent.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor
        setAccessibilityLabel(model.title)
        setAccessibilityValue(marked ? Localized.text("Marked") : "")
        let column = Self.stateColumn()
        glyphWidth?.constant = column
        badgeWidth?.constant = column
        badgeHeight?.constant = column
        badge.pointSize = (10 * MacTheme.UIScale.factor).rounded()
        let activity = marked ? nil : model.state.activity
        badge.activity = activity
        glyph.stringValue = activity == nil ? (marked ? "✓" : model.state.glyph.text) : ""
        glyph.font = MacTheme.Ramp.font(.panelLabel)
        glyph.textColor = marked ? MacTheme.Color.accent : Self.glyphColor(model.state)
        title.stringValue = model.title
        title.font =
            model.unread ? MacTheme.Ramp.font(.rowTitleStrong) : MacTheme.Ramp.font(.rowTitle)
        let facets = model.facets(vocabulary)
        detail.font = MacTheme.Ramp.font(.panelFootnote)
        let line = NSMutableAttributedString()
        if let chip = ModelBadge.chip(for: model.entry) {
            line.append(Self.chipText(chip))
            line.append(
                NSAttributedString(
                    string: "  ",
                    attributes: [.font: MacTheme.Ramp.font(.panelFootnote)]))
        }
        if let snippet = model.snippet {
            line.append(
                NSAttributedString(
                    string: snippet,
                    attributes: [
                        .font: MacTheme.Ramp.font(.panelFootnote),
                        .foregroundColor: MacTheme.Color.accent,
                    ]))
        } else {
            line.append(Self.detailText(facets))
        }
        detail.attributedStringValue = line
        age.stringValue = facets.age
        age.font = .monospacedDigitSystemFont(
            ofSize: MacTheme.Ramp.font(.panelFootnote).pointSize, weight: .regular)
        age.textColor = MacTheme.Color.tertiaryLabel
        for view in titleRow.arrangedSubviews.dropFirst() {
            titleRow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if let pill = model.state.pill {
            titleRow.addArrangedSubview(Self.pill(pill.text, tint: Self.pillTint(model.state)))
        }
        if model.pinned {
            titleRow.addArrangedSubview(
                Self.pill(Localized.text("PINNED"), tint: MacTheme.Color.accent))
        }
        if model.saved {
            titleRow.addArrangedSubview(
                Self.pill(Localized.text("SAVED"), tint: MacTheme.Color.mark))
        }
        if model.unread, model.state.pill == nil {
            let dot = NSTextField(labelWithString: "●")
            dot.font = MacTheme.Ramp.font(.badge)
            dot.textColor = MacTheme.Color.accent
            dot.setAccessibilityLabel(Localized.text("Unread"))
            titleRow.addArrangedSubview(dot)
        }
    }

    /// The model wearing its family's hue and the effort wearing its heat, leading the detail
    /// line the same way the Linux chips do. Ultracode is not a heat, so its word is set letter
    /// by letter from the shared rainbow, each held to the canvas's own contrast floor.
    static func chipText(_ chip: ModelChip) -> NSAttributedString {
        let font = MacTheme.Ramp.font(.rowMeta)
        let text = NSMutableAttributedString(
            string: chip.name,
            attributes: [.font: font, .foregroundColor: MacTheme.Color.modelIdentity(chip)])
        guard let effort = chip.effort else { return text }
        text.append(NSAttributedString(string: " ", attributes: [.font: font]))
        if chip.isUltracode {
            for (index, letter) in effort.enumerated() {
                text.append(
                    NSAttributedString(
                        string: String(letter),
                        attributes: [
                            .font: font,
                            .foregroundColor: MacTheme.Color.modelRainbowLetter(
                                index, of: effort.count),
                        ]))
            }
        } else {
            text.append(
                NSAttributedString(
                    string: effort,
                    attributes: [
                        .font: font,
                        .foregroundColor: MacTheme.Color.modelEffort(effort)
                            ?? MacTheme.Color.secondaryLabel,
                    ]))
        }
        return text
    }

    /// Two weights on one line: the project a person recognises the chat by, then the machine it
    /// lives on a step quieter behind it. One colour for both is a line that has to be read word
    /// by word to find the only part that identifies anything.
    private static func detailText(_ facets: SessionRowFacets) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let font = MacTheme.Ramp.font(.panelFootnote)
        if let project = facets.project {
            text.append(
                NSAttributedString(
                    string: project,
                    attributes: [.font: font, .foregroundColor: MacTheme.Color.secondaryLabel]))
        }
        if let origin = facets.origin {
            text.append(
                NSAttributedString(
                    string: text.length == 0 ? origin : " · \(origin)",
                    attributes: [.font: font, .foregroundColor: MacTheme.Color.tertiaryLabel]))
        }
        return text
    }

    /// The glyph column carries the same tones the Linux CSS classes do, and draws the same line
    /// between them: a turn that is running is alive, a turn that is waiting on the reader is
    /// amber, and the two never share a colour.
    private static func glyphColor(_ state: SessionRowState) -> NSColor {
        state.icon.tone.color
    }

    private static func pillTint(_ state: SessionRowState) -> NSColor {
        state.icon.tone.color
    }

    private static func pill(_ text: String, tint: NSColor) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = MacTheme.Ramp.font(.pill)
        label.textColor = tint
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        let capsule = NSView()
        capsule.wantsLayer = true
        capsule.layer?.backgroundColor = tint.withAlphaComponent(0.16).cgColor
        capsule.layer?.cornerRadius = 7
        capsule.translatesAutoresizingMaskIntoConstraints = false
        capsule.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: capsule.topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: capsule.bottomAnchor, constant: -1),
        ])
        return capsule
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
        setAccessibilityLabel("\(item.title) — \(item.kindLabel)")
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

/// A section heading with its count — LIVE NOW, SAVED, RECENT, ARCHIVED.
final class SidebarHeaderCell: NSView {
    private let title = NSTextField(labelWithString: "")
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
        addSubview(title)
        addSubview(count)
        addSubview(clear)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
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
        self.title.font = MacTheme.Ramp.font(.sectionLabel)
        self.title.stringValue = title
        self.count.font = MacTheme.Ramp.font(.metricLabel)
        self.count.stringValue = count.map { "\($0)" } ?? ""
        self.count.isHidden = count == nil
        clear.font = MacTheme.Ramp.font(.metricLabel)
        self.onClear = onClear
        clear.isHidden = onClear == nil
    }

    @objc private func clearTapped() { onClear?() }
}

/// What is held, and the verbs that act on all of it.
///
/// It appears only while chats are marked, and every word on it comes from `BulkChatCopy` so this
/// Mac names a count exactly the way the phone and the Linux desktop do. Content rather than
/// chrome: the sidebar is already the system's own glass and glass never stacks on glass, so this
/// is a tinted strip inside the list, never a second material floating over it.
@MainActor
final class SidebarBulkBar: NSView {
    var onAction: ((BulkChatAction) -> Void)?
    var onClear: (() -> Void)?
    var onSplit: ((SplitArrangement) -> Void)?

    private let badge = NSTextField(labelWithString: "")
    private let verbs = NSStackView()
    private let secondary = NSStackView()
    private let splitHeader = NSTextField(labelWithString: "")
    private let splitRow = NSStackView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = MacTheme.Radius.control
        applyWash()

        badge.textColor = MacTheme.Color.accent
        badge.setContentHuggingPriority(.required, for: .horizontal)

        let clear = NSButton(title: "✕", target: self, action: #selector(clearMarks))
        clear.isBordered = false
        clear.bezelStyle = .accessoryBar
        clear.font = MacTheme.Ramp.font(.panelFootnote)
        clear.contentTintColor = MacTheme.Color.secondaryLabel
        clear.toolTip = Localized.text("Clear the marks")
        clear.setAccessibilityLabel(Localized.text("Clear the marks"))
        clear.setContentHuggingPriority(.required, for: .horizontal)

        verbs.orientation = .horizontal
        verbs.spacing = MacTheme.Spacing.xs
        verbs.alignment = .centerY
        secondary.orientation = .horizontal
        secondary.spacing = MacTheme.Spacing.xs
        secondary.alignment = .centerY
        secondary.distribution = .fillProportionally
        splitHeader.textColor = MacTheme.Color.secondaryLabel
        splitRow.orientation = .horizontal
        splitRow.spacing = MacTheme.Spacing.xs
        splitRow.alignment = .centerY
        splitRow.distribution = .fillProportionally

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let top = NSStackView(views: [badge, verbs, spacer, clear])
        top.orientation = .horizontal
        top.spacing = MacTheme.Spacing.xs
        top.alignment = .centerY

        let column = FillingStack(views: [top, secondary, splitHeader, splitRow])
        column.spacing = MacTheme.Spacing.xs
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacTheme.Spacing.s),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacTheme.Spacing.s),
            column.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.xs),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -MacTheme.Spacing.xs),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The wash is a `CGColor`, which keeps the appearance it was resolved in — so it is written
    /// again wherever the light behind it could have changed, rather than once at construction.
    private func applyWash() {
        layer?.backgroundColor = MacTheme.Color.accent.withAlphaComponent(0.12).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyWash()
    }

    /// - Parameter actions: the destructive verb first, then the three that flip with what is
    ///   held, so a button never offers the opposite of what its own word says.
    func render(count: Int, actions: [BulkChatAction]) {
        applyWash()
        badge.font = MacTheme.Ramp.font(.badge)
        badge.stringValue = "\(count)"
        badge.setAccessibilityLabel("\(count)")
        splitHeader.font = MacTheme.Ramp.font(.panelFootnote)
        for stack in [verbs, secondary, splitRow] {
            for view in stack.arrangedSubviews {
                stack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
        }
        for action in actions {
            let button = self.button(action, count: count)
            if action.isDestructive {
                verbs.addArrangedSubview(button)
            } else {
                secondary.addArrangedSubview(button)
            }
        }
        let arrangements = SplitEven.offers(count: count)
        splitHeader.isHidden = arrangements.isEmpty
        splitRow.isHidden = arrangements.isEmpty
        splitHeader.stringValue = SplitEven.header(count: count)
        for arrangement in arrangements {
            splitRow.addArrangedSubview(splitButton(arrangement, count: count))
        }
    }

    private func splitButton(_ arrangement: SplitArrangement, count: Int) -> NSButton {
        let button = NSButton(
            title: arrangement.title, target: self, action: #selector(splitPicked))
        button.isBordered = false
        button.bezelStyle = .accessoryBar
        button.font = MacTheme.Ramp.font(.panelFootnote)
        button.contentTintColor = MacTheme.Color.accent
        button.image = NSImage(
            systemSymbolName: arrangement.symbolName,
            accessibilityDescription: arrangement.title)
        button.imagePosition = .imageLeading
        button.lineBreakMode = .byTruncatingTail
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.toolTip = arrangement.caption(count: count)
        button.setAccessibilityLabel(arrangement.accessibleLabel(count: count))
        button.identifier = NSUserInterfaceItemIdentifier("split." + arrangement.rawValue)
        return button
    }

    @objc private func splitPicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue.split(separator: ".").last,
            let arrangement = SplitArrangement(rawValue: String(raw))
        else { return }
        onSplit?(arrangement)
    }

    private func button(_ action: BulkChatAction, count: Int) -> NSButton {
        let title = BulkChatCopy.button(action, count: count)
        let button = NSButton(title: title, target: self, action: #selector(verbPicked))
        button.isBordered = false
        button.bezelStyle = .accessoryBar
        button.font = MacTheme.Ramp.font(.panelFootnote)
        button.contentTintColor =
            action.isDestructive ? MacTheme.Color.danger : MacTheme.Color.accent
        button.lineBreakMode = .byTruncatingTail
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.toolTip = title
        button.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
        return button
    }

    @objc private func verbPicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let action = BulkChatAction(rawValue: raw)
        else { return }
        onAction?(action)
    }

    @objc private func clearMarks() {
        onClear?()
    }
}

/// The list's non-conversation voices: the unreachable banner, the empty-state line, and the
/// tappable footers — more chats, the archive, and the way back out of it.
final class SidebarMessageCell: NSView {
    enum Style {
        case banner
        case empty
        case action
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
        }
    }
}
