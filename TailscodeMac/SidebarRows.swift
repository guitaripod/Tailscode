import AppKit
import CodingAgentKit
import TailscodeCore

/// Everything the chat list can say, one value per row: the table is a pure function of this
/// array, which is what makes the ten-second refresh cheap to diff and safe to skip when nothing
/// the list would say has changed.
enum SidebarRow: Equatable {
    case banner(String)
    case backLink
    case header(String, Int)
    /// - Parameter marked: whether the row is held by the bulk selection. It travels in the row
    ///   value rather than being read from the store at configure time, so the table's diff sees a
    ///   mark land the same way it sees a title change.
    case session(SessionRowModel, marked: Bool)
    case more(Int)
    case archived(Int)
    case empty(String)
}

/// Builds and recycles the table's cells, so the view controller stays about data and the cells
/// stay about pixels.
@MainActor
enum SidebarCellFactory {
    static func view(for row: SidebarRow, in tableView: NSTableView) -> NSView {
        switch row {
        case .session(let model, let marked):
            let cell = reuse("session", in: tableView) { SidebarSessionCell() }
            cell.configure(with: model, marked: marked)
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
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let titleRow = NSStackView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = MacTheme.Radius.control
        glyph.font = MacTheme.Font.body()
        glyph.translatesAutoresizingMaskIntoConstraints = false

        title.font = MacTheme.Font.body()
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        titleRow.orientation = .horizontal
        titleRow.spacing = 6
        titleRow.alignment = .centerY
        titleRow.addArrangedSubview(title)
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        detail.font = MacTheme.Font.caption()
        detail.textColor = MacTheme.Color.secondaryLabel
        detail.lineBreakMode = .byTruncatingTail
        detail.translatesAutoresizingMaskIntoConstraints = false

        addSubview(glyph)
        addSubview(titleRow)
        addSubview(detail)
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            glyph.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            glyph.widthAnchor.constraint(equalToConstant: 16),
            titleRow.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 4),
            titleRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            titleRow.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            detail.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            detail.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 2),
            detail.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// - Parameter marked: a marked row wears the accent wash and lends its glyph column to the
    ///   check, because the mark is the only thing about the row that a verb is about to act on;
    ///   the state it was in is still spoken by its pill, so nothing a marked row says is lost.
    func configure(with model: SessionRowModel, marked: Bool) {
        layer?.backgroundColor =
            marked
            ? MacTheme.Color.accent.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor
        setAccessibilityLabel(model.title)
        setAccessibilityValue(marked ? Localized.text("Marked") : "")
        glyph.stringValue = marked ? "✓" : model.state.glyph.text
        glyph.font = MacTheme.Font.body()
        glyph.textColor = marked ? MacTheme.Color.accent : Self.glyphColor(model.state)
        title.stringValue = model.title
        title.font = model.unread ? MacTheme.Font.emphasis() : MacTheme.Font.body()
        detail.stringValue = model.snippet ?? model.detail
        detail.font = MacTheme.Font.caption()
        detail.textColor =
            model.snippet != nil ? MacTheme.Color.accent : MacTheme.Color.secondaryLabel
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
        if model.unread {
            let dot = NSTextField(labelWithString: "●")
            dot.font = .systemFont(ofSize: 8)
            dot.textColor = MacTheme.Color.accent
            titleRow.addArrangedSubview(dot)
        }
    }

    /// The glyph column carries the same tones the Linux CSS classes do, and draws the same line
    /// between them: a turn that is running is alive, a turn that is waiting on the reader is
    /// amber, and the two never share a colour.
    private static func glyphColor(_ state: SessionRowState) -> NSColor {
        switch state {
        case .awaitingApproval: return MacTheme.Color.warning
        case .live: return MacTheme.Color.success
        case .idle, .offline: return MacTheme.Color.tertiaryLabel
        case .failed: return MacTheme.Color.danger
        }
    }

    private static func pillTint(_ state: SessionRowState) -> NSColor {
        switch state {
        case .awaitingApproval: return MacTheme.Color.warning
        case .live: return MacTheme.Color.success
        case .failed: return MacTheme.Color.danger
        case .offline: return MacTheme.Color.secondaryLabel
        case .idle: return MacTheme.Color.tertiaryLabel
        }
    }

    private static func pill(_ text: String, tint: NSColor) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 9, weight: .semibold)
        label.textColor = tint
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

/// A section heading with its count — LIVE NOW, SAVED, RECENT, ARCHIVED.
final class SidebarHeaderCell: NSView {
    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: 10, weight: .semibold)
        title.textColor = MacTheme.Color.secondaryLabel
        title.translatesAutoresizingMaskIntoConstraints = false
        count.font = .systemFont(ofSize: 10, weight: .semibold)
        count.textColor = MacTheme.Color.tertiaryLabel
        count.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        addSubview(count)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            count.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, count: Int) {
        self.title.stringValue = title
        self.count.stringValue = "\(count)"
    }
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

    private let badge = NSTextField(labelWithString: "")
    private let verbs = NSStackView()
    private let secondary = NSStackView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = MacTheme.Radius.control
        layer?.backgroundColor = MacTheme.Color.accent.withAlphaComponent(0.12).cgColor

        badge.font = MacTheme.Font.mono(11)
        badge.textColor = MacTheme.Color.accent
        badge.setContentHuggingPriority(.required, for: .horizontal)

        let clear = NSButton(title: "✕", target: self, action: #selector(clearMarks))
        clear.isBordered = false
        clear.bezelStyle = .accessoryBar
        clear.font = MacTheme.Font.caption()
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

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let top = NSStackView(views: [badge, verbs, spacer, clear])
        top.orientation = .horizontal
        top.spacing = MacTheme.Spacing.xs
        top.alignment = .centerY

        let column = NSStackView(views: [top, secondary])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = MacTheme.Spacing.xs
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacTheme.Spacing.s),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacTheme.Spacing.s),
            column.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.xs),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -MacTheme.Spacing.xs),
            top.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// - Parameter actions: the destructive verb first, then the three that flip with what is
    ///   held, so a button never offers the opposite of what its own word says.
    func render(count: Int, actions: [BulkChatAction]) {
        badge.stringValue = "\(count)"
        badge.setAccessibilityLabel("\(count)")
        for stack in [verbs, secondary] {
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
    }

    private func button(_ action: BulkChatAction, count: Int) -> NSButton {
        let title = BulkChatCopy.button(action, count: count)
        let button = NSButton(title: title, target: self, action: #selector(verbPicked))
        button.isBordered = false
        button.bezelStyle = .accessoryBar
        button.font = MacTheme.Font.caption()
        button.contentTintColor =
            action.isDestructive ? MacTheme.Color.danger : MacTheme.Color.accent
        button.lineBreakMode = .byTruncatingTail
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
            label.font = MacTheme.Font.caption()
            label.textColor = MacTheme.Color.danger
            label.alignment = .left
        case .empty:
            label.font = MacTheme.Font.body()
            label.textColor = MacTheme.Color.tertiaryLabel
            label.alignment = .center
        case .action:
            label.font = MacTheme.Font.caption()
            label.textColor = MacTheme.Color.secondaryLabel
            label.alignment = .center
        }
    }
}
