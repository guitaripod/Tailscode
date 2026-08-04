import AppKit
import CodingAgentKit
import TailscodeCore

/// Typing `/word` offers what it could become, right above the prompt box: filtered as letters
/// arrive, stepped with the arrows or ^N/^P, taken with Tab or a click, dismissed with Escape.
/// Past the name the list gives way to that one command's signature; a word the catalog lacks
/// says so rather than vanishing. The panel never takes focus.
@MainActor
final class CompletionPopover: NSView {
    var onPick: ((AgentCommand) -> Void)?
    var onBrowse: (() -> Void)?

    private let column = NSStackView()
    private var presentation: SlashPresentation = .hidden
    private var namingMatches: [SlashMatch] = []
    private var cursor = 0

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true

        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.s, left: MacTheme.Spacing.s, bottom: MacTheme.Spacing.s,
            right: MacTheme.Spacing.s)
        column.translatesAutoresizingMaskIntoConstraints = false

        let glass = MacTheme.glass(around: column, cornerRadius: MacTheme.Radius.card)
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var isShowing: Bool { !isHidden }

    /// The greppable anchor for the argument stage + hints surface.
    func renderCompletion(_ presentation: SlashPresentation, cursor: Int = 0) {
        self.presentation = presentation
        switch presentation {
        case .hidden:
            hide()
        case .naming(let matches):
            namingMatches = matches
            self.cursor = matches.isEmpty ? 0 : min(max(0, cursor), matches.count - 1)
            paintNaming()
        case .arguments(let command, let typed):
            namingMatches = []
            paintArguments(command, typed: typed)
        case .noMatch(let query):
            namingMatches = []
            paintNoMatch(query)
        }
    }

    /// Legacy path kept for call sites that still pass a bare list; prefer `renderCompletion`.
    func render(matches: [AgentCommand], cursor: Int) {
        let ranked = matches.map { SlashMatch(command: $0, kind: .prefix, highlight: []) }
        renderCompletion(.naming(matches: ranked), cursor: cursor)
    }

    func hide() {
        guard !isHidden else { return }
        isHidden = true
        namingMatches = []
        presentation = .hidden
    }

    var namingCount: Int { namingMatches.count }

    var selectedCommand: AgentCommand? {
        guard namingMatches.indices.contains(cursor) else { return nil }
        return namingMatches[cursor].command
    }

    private func paintNaming() {
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let start = max(0, min(cursor - 3, namingMatches.count - 8))
        let end = min(namingMatches.count, start + 8)
        for index in start..<end {
            let match = namingMatches[index]
            column.addArrangedSubview(
                commandRow(match.command, selected: index == cursor, pick: match.command))
        }
        if start > 0 || end < namingMatches.count {
            let hidden = namingMatches.count - (end - start)
            let more = RowKit.label(
                "… \(hidden) more", font: MacTheme.Font.caption(),
                color: MacTheme.Color.tertiaryLabel)
            column.addArrangedSubview(RowKit.inset(more, leading: MacTheme.Spacing.s))
        }
        isHidden = false
    }

    private func paintArguments(_ command: AgentCommand, typed: String) {
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let title = RowKit.label(
            "/\(command.name)", font: MacTheme.Font.emphasis(), color: MacTheme.Color.label)
        let lines = NSStackView(views: [title])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 2
        if let hint = command.argumentHint, !hint.isEmpty {
            lines.addArrangedSubview(
                RowKit.label(
                    hint, font: MacTheme.Font.mono(11), color: MacTheme.Color.accent))
        }
        if !command.details.isEmpty {
            lines.addArrangedSubview(
                RowKit.label(
                    command.details, font: MacTheme.Font.caption(),
                    color: MacTheme.Color.secondaryLabel))
        }
        if !typed.isEmpty {
            lines.addArrangedSubview(
                RowKit.label(
                    Localized.text("Writing: %@", typed), font: MacTheme.Font.caption(),
                    color: MacTheme.Color.tertiaryLabel))
        }
        lines.edgeInsets = NSEdgeInsets(
            top: 4, left: MacTheme.Spacing.s, bottom: 4, right: MacTheme.Spacing.s)
        column.addArrangedSubview(lines)
        isHidden = false
    }

    private func paintNoMatch(_ query: String) {
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let message = RowKit.label(
            Localized.text("No command named “%@”", query),
            font: MacTheme.Font.body(), color: MacTheme.Color.secondaryLabel)
        message.lineBreakMode = .byWordWrapping
        message.maximumNumberOfLines = 3
        message.preferredMaxLayoutWidth = 360
        column.addArrangedSubview(RowKit.inset(message, leading: MacTheme.Spacing.s))
        if onBrowse != nil {
            let browse = RowKit.label(
                Localized.text("Browse every command"),
                font: MacTheme.Font.caption(), color: MacTheme.Color.accent)
            let row = CompletionRowView(index: -1) { [weak self] _ in self?.onBrowse?() }
            row.translatesAutoresizingMaskIntoConstraints = false
            browse.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(browse)
            NSLayoutConstraint.activate([
                browse.leadingAnchor.constraint(
                    equalTo: row.leadingAnchor, constant: MacTheme.Spacing.s),
                browse.trailingAnchor.constraint(
                    equalTo: row.trailingAnchor, constant: -MacTheme.Spacing.s),
                browse.topAnchor.constraint(equalTo: row.topAnchor, constant: 4),
                browse.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -4),
            ])
            column.addArrangedSubview(row)
        }
        isHidden = false
    }

    private func commandRow(
        _ command: AgentCommand, selected: Bool, pick: AgentCommand
    ) -> NSView {
        let name = RowKit.label(
            "/\(command.name)", font: MacTheme.Font.emphasis(), color: MacTheme.Color.label)
        let lines = NSStackView(views: [name])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 1
        if let hint = command.argumentHint, !hint.isEmpty {
            lines.addArrangedSubview(
                RowKit.label(hint, font: MacTheme.Font.mono(10), color: MacTheme.Color.tertiaryLabel))
        }
        if !command.details.isEmpty {
            let detail = RowKit.label(
                command.details, font: MacTheme.Font.caption(),
                color: MacTheme.Color.secondaryLabel)
            lines.addArrangedSubview(detail)
        }
        if let scope = command.scope, !scope.isEmpty {
            lines.addArrangedSubview(
                RowKit.label(scope, font: MacTheme.Font.caption(), color: MacTheme.Color.tertiaryLabel))
        }
        lines.edgeInsets = NSEdgeInsets(
            top: 3, left: MacTheme.Spacing.s, bottom: 3, right: MacTheme.Spacing.s)
        lines.translatesAutoresizingMaskIntoConstraints = false

        let rowView = CompletionRowView(index: 0) { [weak self] _ in
            self?.onPick?(pick)
        }
        rowView.translatesAutoresizingMaskIntoConstraints = false
        rowView.wantsLayer = true
        if selected {
            rowView.layer?.backgroundColor =
                MacTheme.Color.accent.withAlphaComponent(0.22).cgColor
            rowView.layer?.cornerRadius = 6
        }
        rowView.addSubview(lines)
        NSLayoutConstraint.activate([
            lines.leadingAnchor.constraint(equalTo: rowView.leadingAnchor),
            lines.trailingAnchor.constraint(equalTo: rowView.trailingAnchor),
            lines.topAnchor.constraint(equalTo: rowView.topAnchor),
            lines.bottomAnchor.constraint(equalTo: rowView.bottomAnchor),
            rowView.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])
        return rowView
    }
}

@MainActor
private final class CompletionRowView: NSView {
    private let index: Int
    private let pick: (Int) -> Void

    init(index: Int, pick: @escaping (Int) -> Void) {
        self.index = index
        self.pick = pick
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        pick(index)
    }
}
