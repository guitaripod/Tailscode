import AppKit
import CodingAgentKit
import TailscodeCore

/// Typing `/word` offers what it could become, right above the prompt box: filtered as letters
/// arrive, stepped with the arrows or ^N/^P, taken with Tab or a click, dismissed with Escape.
/// The panel never takes focus — it is a suggestion, not a dialog — so typing simply continues
/// underneath it. At most eight rows, windowed around the selection so the highlight can never
/// scroll off, with a count for what the window hides.
@MainActor
final class CompletionPopover: NSView {
    var onPick: ((Int) -> Void)?

    private let column = NSStackView()

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

    func render(matches: [AgentCommand], cursor: Int) {
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let start = max(0, min(cursor - 3, matches.count - 8))
        let end = min(matches.count, start + 8)
        for index in start..<end {
            column.addArrangedSubview(
                row(for: matches[index], selected: index == cursor, index: index))
        }
        if start > 0 || end < matches.count {
            let hidden = matches.count - (end - start)
            let more = RowKit.label(
                "… \(hidden) more", font: MacTheme.Font.caption(),
                color: MacTheme.Color.tertiaryLabel)
            column.addArrangedSubview(RowKit.inset(more, leading: MacTheme.Spacing.s))
        }
        isHidden = false
    }

    func hide() {
        guard !isHidden else { return }
        isHidden = true
    }

    private func row(for command: AgentCommand, selected: Bool, index: Int) -> NSView {
        let name = RowKit.label(
            "/\(command.name)", font: MacTheme.Font.emphasis(), color: MacTheme.Color.label)
        let lines = NSStackView(views: [name])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 1
        if !command.details.isEmpty {
            let detail = RowKit.label(
                command.details, font: MacTheme.Font.caption(),
                color: MacTheme.Color.secondaryLabel)
            lines.addArrangedSubview(detail)
        }
        lines.edgeInsets = NSEdgeInsets(
            top: 3, left: MacTheme.Spacing.s, bottom: 3, right: MacTheme.Spacing.s)
        lines.translatesAutoresizingMaskIntoConstraints = false

        let rowView = CompletionRowView(index: index) { [weak self] picked in
            self?.onPick?(picked)
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

/// A row that answers a click with its index without ever becoming first responder — focus stays
/// in the composer, where the letters are still landing.
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
