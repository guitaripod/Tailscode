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
    /// Whether the catalog behind this list was resolved inside a project. A repository's own
    /// command files are absent from a directory-less catalog *and* unresolvable by the turn it
    /// would start, so a word missing for that reason says which reason it is instead of reading
    /// as a typo.
    var hasProject = true

    private let column = FillingStack()
    private var presentation: SlashPresentation = .hidden
    private var namingMatches: [SlashMatch] = []
    private var cursor = 0

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true

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

    /// The rows are dropped through the stack rather than straight off the view, so the fills a
    /// ``FillingStack`` holds for each one go with them instead of outliving a list that is rebuilt
    /// on every keystroke.
    private func clearRows() {
        for view in column.arrangedSubviews {
            column.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func paintNaming() {
        clearRows()
        let start = max(0, min(cursor - 3, namingMatches.count - 8))
        let end = min(namingMatches.count, start + 8)
        for index in start..<end {
            column.addArrangedSubview(
                commandRow(namingMatches[index], selected: index == cursor))
        }
        if start > 0 || end < namingMatches.count {
            let hidden = namingMatches.count - (end - start)
            let more = RowKit.label(
                Localized.text("… %d more", hidden), font: MacTheme.Ramp.font(.panelFootnote),
                color: MacTheme.Color.onGlassSecondary)
            column.addArrangedSubview(RowKit.inset(more, leading: MacTheme.Spacing.s))
        }
        isHidden = false
    }

    private func paintArguments(_ command: AgentCommand, typed: String) {
        clearRows()
        let title = RowKit.label(
            "/\(command.name)", font: MacTheme.Ramp.font(.cardTitle), color: MacTheme.Color.onGlass)
        let lines = NSStackView(views: [title])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 2
        if let hint = command.argumentHint, !hint.isEmpty {
            lines.addArrangedSubview(
                RowKit.label(
                    hint, font: MacTheme.Ramp.font(.toolOutput), color: MacTheme.Color.accent))
        }
        if !command.details.isEmpty {
            lines.addArrangedSubview(
                RowKit.label(
                    command.details, font: MacTheme.Ramp.font(.panelFootnote),
                    color: MacTheme.Color.onGlassSecondary))
        }
        if !typed.isEmpty {
            lines.addArrangedSubview(
                RowKit.label(
                    Localized.text("Writing: %@", typed), font: MacTheme.Ramp.font(.panelFootnote),
                    color: MacTheme.Color.onGlassSecondary))
        }
        lines.edgeInsets = NSEdgeInsets(
            top: 4, left: MacTheme.Spacing.s, bottom: 4, right: MacTheme.Spacing.s)
        column.addArrangedSubview(lines)
        isHidden = false
    }

    private func paintNoMatch(_ query: String) {
        clearRows()
        let message = RowKit.label(
            SlashPresentation.noMatchWording(query, hasProject: hasProject),
            font: MacTheme.Ramp.font(.panelLabel), color: MacTheme.Color.onGlassSecondary)
        message.lineBreakMode = .byWordWrapping
        message.maximumNumberOfLines = 3
        message.preferredMaxLayoutWidth = 360
        column.addArrangedSubview(RowKit.inset(message, leading: MacTheme.Spacing.s))
        if onBrowse != nil {
            let browse = RowKit.label(
                Localized.text("Browse every command"),
                font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.accent)
            let row = CompletionRowView(index: -1) { [weak self] _ in self?.onBrowse?() }
            row.setAccessibilityLabel(Localized.text("Browse every command"))
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

    /// The letters that put the row in the list are the ones coloured: a scattered match — `/gr`
    /// finding `git:review` — is otherwise a row with nothing on it saying why it is there, or why
    /// it outranks the row under it.
    private func matchedName(_ match: SlashMatch) -> NSAttributedString {
        let name = match.command.name
        let text = NSMutableAttributedString(
            string: "/\(name)",
            attributes: MacTheme.Ramp.attributes(.cardTitle, color: MacTheme.Color.onGlass))
        let letters = Array(name)
        for offset in match.highlight where letters.indices.contains(offset) {
            let location = String(letters[..<offset]).utf16.count + 1
            let length = String(letters[offset]).utf16.count
            text.addAttribute(
                .foregroundColor, value: MacTheme.Color.accent,
                range: NSRange(location: location, length: length))
        }
        return text
    }

    private func commandRow(_ match: SlashMatch, selected: Bool) -> NSView {
        let command = match.command
        let name = RowKit.label(
            "/\(command.name)", font: MacTheme.Ramp.font(.cardTitle), color: MacTheme.Color.onGlass)
        name.attributedStringValue = matchedName(match)
        let lines = NSStackView(views: [name])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 1
        if let hint = command.argumentHint, !hint.isEmpty {
            lines.addArrangedSubview(
                RowKit.label(hint, font: MacTheme.Ramp.font(.rowNote), color: MacTheme.Color.onGlassSecondary))
        }
        if !command.details.isEmpty {
            let detail = RowKit.label(
                command.details, font: MacTheme.Ramp.font(.panelFootnote),
                color: MacTheme.Color.onGlassSecondary)
            lines.addArrangedSubview(detail)
        }
        if let scope = command.scope, !scope.isEmpty {
            lines.addArrangedSubview(
                RowKit.label(scope, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.onGlassSecondary))
        }
        lines.edgeInsets = NSEdgeInsets(
            top: 3, left: MacTheme.Spacing.s, bottom: 3, right: MacTheme.Spacing.s)
        lines.translatesAutoresizingMaskIntoConstraints = false

        let rowView = CompletionRowView(index: 0) { [weak self] _ in
            self?.onPick?(command)
        }
        rowView.setAccessibilityLabel("/\(command.name)")
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
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        pick(index)
    }
}
