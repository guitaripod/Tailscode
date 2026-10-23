import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// The card behind a tab or a door — Core's `ChooserBriefing` drawn as headings, lines and
/// footnotes in one column, the state line in the state's own tone.
@MainActor
final class BriefingPanelViewController: NSViewController {
    private let briefing: ChooserBriefing

    init(briefing: ChooserBriefing) {
        self.briefing = briefing
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    static func colour(_ tone: ModelMachineState.Tone) -> NSColor {
        switch tone {
        case .live: return MacTheme.Color.success
        case .quiet: return MacTheme.Color.secondaryLabel
        case .danger: return MacTheme.Color.danger
        case .attention: return MacTheme.Color.warning
        }
    }

    override func loadView() {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = MacTheme.Spacing.s
        column.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.l, left: MacTheme.Spacing.l, bottom: MacTheme.Spacing.l,
            right: MacTheme.Spacing.l)
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(label(briefing.title, .panelTitle, MacTheme.Color.label))
        column.addArrangedSubview(label(briefing.subtitle, .panelLabel, MacTheme.Color.secondaryLabel))
        column.addArrangedSubview(wrapped(briefing.lead, MacTheme.Color.secondaryLabel))
        for (index, section) in briefing.sections.enumerated() {
            column.setCustomSpacing(MacTheme.Spacing.l, after: column.arrangedSubviews.last!)
            column.addArrangedSubview(
                label(section.heading.uppercased(), .metricLabel, MacTheme.Color.secondaryLabel))
            for (row, line) in section.lines.enumerated() {
                let tint =
                    index == 0 && row == 0 && briefing.tone != nil
                    ? Self.colour(briefing.tone!) : MacTheme.Color.secondaryLabel
                column.addArrangedSubview(self.line(line, tint: tint))
            }
            if let footnote = section.footnote {
                column.addArrangedSubview(wrapped(footnote, MacTheme.Color.secondaryLabel))
            }
        }
        let host = NSView()
        host.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: host.topAnchor),
            column.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            column.widthAnchor.constraint(equalToConstant: 380 * MacTheme.UIScale.factor),
        ])
        view = host
    }

    private func label(_ text: String, _ role: TypeRole, _ colour: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = MacTheme.Ramp.font(role)
        field.textColor = colour
        return field
    }

    private func wrapped(_ text: String, _ colour: NSColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = MacTheme.Ramp.font(.cardBody)
        field.textColor = colour
        field.preferredMaxLayoutWidth = 340 * MacTheme.UIScale.factor
        return field
    }

    private func line(_ line: ChooserBriefing.Line, tint: NSColor) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = MacTheme.Spacing.s
        if let symbol = line.symbol,
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: line.label)
        {
            let glyph = NSImageView(image: image)
            glyph.contentTintColor = tint
            glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            glyph.widthAnchor.constraint(equalToConstant: 18).isActive = true
            row.addArrangedSubview(glyph)
        }
        let name = label(line.label, .rowTitle, MacTheme.Color.label)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(name)
        let value = label(line.value, .rowDetail, MacTheme.Color.secondaryLabel)
        value.alignment = .right
        value.lineBreakMode = .byWordWrapping
        value.maximumNumberOfLines = 2
        value.preferredMaxLayoutWidth = 220 * MacTheme.UIScale.factor
        row.addArrangedSubview(value)
        row.widthAnchor.constraint(equalToConstant: 340 * MacTheme.UIScale.factor).isActive = true
        return row
    }
}
