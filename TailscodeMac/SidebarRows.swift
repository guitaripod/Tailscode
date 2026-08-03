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
    case session(SessionRowModel)
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
        case .session(let model):
            let cell = reuse("session", in: tableView) { SidebarSessionCell() }
            cell.configure(with: model)
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

    func configure(with model: SessionRowModel) {
        glyph.stringValue = model.state.glyph.text
        glyph.textColor = Self.glyphColor(model.state)
        title.stringValue = model.title
        title.font = model.unread ? MacTheme.Font.emphasis() : MacTheme.Font.body()
        detail.stringValue = model.detail
        for view in titleRow.arrangedSubviews.dropFirst() {
            titleRow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if let pill = model.state.pill {
            titleRow.addArrangedSubview(Self.pill(pill.text, tint: Self.pillTint(model.state)))
        }
        if model.saved {
            titleRow.addArrangedSubview(
                Self.pill(Localized.text("SAVED"), tint: MacTheme.Color.accent))
        }
        if model.unread {
            let dot = NSTextField(labelWithString: "●")
            dot.font = .systemFont(ofSize: 8)
            dot.textColor = MacTheme.Color.accent
            titleRow.addArrangedSubview(dot)
        }
    }

    /// The glyph column carries the same three tones the Linux CSS classes do: running is alive,
    /// pending is quiet, error is red.
    private static func glyphColor(_ state: SessionRowState) -> NSColor {
        switch state {
        case .awaitingApproval, .live: return MacTheme.Color.success
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
