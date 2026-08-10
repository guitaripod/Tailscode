import AppKit
import TailscodeCore

/// The empty pane's chooser, drawn: the question, the hint, and the rows `PaneChooser` decided —
/// numbered, because 1–9 pick them outright. Content, not chrome, so it sits on the opaque canvas
/// and never on glass; the focused row wears the accent the same way the split's focused pane does.
@MainActor
final class ChooserView: NSView {
    private let heading = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private let rows = NSStackView()
    private var onActivate: ((Int) -> Void)?

    init() {
        super.init(frame: .zero)
        heading.font = MacTheme.Ramp.font(.sectionLabel)
        heading.textColor = MacTheme.Color.secondaryLabel
        hint.font = MacTheme.Ramp.font(.panelFootnote)
        hint.textColor = MacTheme.Color.tertiaryLabel

        rows.orientation = .vertical
        rows.alignment = .width
        rows.spacing = 2

        let column = NSStackView(views: [heading, hint, rows])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = MacTheme.Spacing.xs
        column.setCustomSpacing(MacTheme.Spacing.m, after: hint)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func render(_ model: PaneChooser, onActivate: @escaping (Int) -> Void) {
        self.onActivate = onActivate
        heading.stringValue = model.heading
        hint.stringValue = model.hint
        for view in rows.arrangedSubviews {
            rows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, row) in model.rows.enumerated() {
            let view = ChooserRowView()
            view.configure(row, number: index + 1, focused: index == model.cursor)
            view.onClick = { [weak self] in self?.onActivate?(index) }
            rows.addArrangedSubview(view)
        }
    }
}

@MainActor
final class ChooserRowView: NSView {
    private let number = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let note = NSTextField(labelWithString: "")
    private let titleRow = NSStackView()
    private let lines = NSStackView()
    var onClick: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = MacTheme.Radius.control

        number.font = MacTheme.Ramp.font(.rowNote)
        number.textColor = MacTheme.Color.tertiaryLabel
        number.translatesAutoresizingMaskIntoConstraints = false

        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleRow.orientation = .horizontal
        titleRow.spacing = 6
        titleRow.alignment = .centerY
        titleRow.addArrangedSubview(title)

        detail.font = MacTheme.Ramp.font(.panelFootnote)
        detail.textColor = MacTheme.Color.secondaryLabel
        detail.lineBreakMode = .byTruncatingTail

        note.font = MacTheme.Ramp.font(.panelFootnote)
        note.textColor = MacTheme.Color.accent.withAlphaComponent(0.75)
        note.lineBreakMode = .byTruncatingTail

        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 1
        lines.setViews([titleRow, detail, note], in: .leading)
        lines.translatesAutoresizingMaskIntoConstraints = false

        addSubview(number)
        addSubview(lines)
        NSLayoutConstraint.activate([
            number.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacTheme.Spacing.s),
            number.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            number.widthAnchor.constraint(equalToConstant: 14),
            lines.leadingAnchor.constraint(equalTo: number.trailingAnchor, constant: 6),
            lines.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -MacTheme.Spacing.s),
            lines.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            lines.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ row: PaneChooserRow, number index: Int, focused: Bool) {
        number.stringValue = index <= 9 ? "\(index)" : " "
        title.stringValue = row.title
        title.font = row.isPrimary ? MacTheme.Ramp.font(.cardTitle) : MacTheme.Ramp.font(.panelLabel)
        detail.stringValue = row.detail
        note.stringValue = row.note ?? ""
        note.isHidden = row.note == nil
        layer?.backgroundColor =
            focused
            ? MacTheme.Color.accent.withAlphaComponent(0.18).cgColor : NSColor.clear.cgColor
        for view in titleRow.arrangedSubviews.dropFirst() {
            titleRow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if let badge = row.badge {
            let tint: NSColor
            switch badge {
            case .live: tint = MacTheme.Color.success
            case .offline: tint = MacTheme.Color.secondaryLabel
            }
            titleRow.addArrangedSubview(Self.pill(badge.text, tint: tint))
        }
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    private static func pill(_ text: String, tint: NSColor) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = MacTheme.Ramp.font(.metricLabel)
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
