import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// A family heading with what it holds, counted — the one place the provider count still belongs,
/// because a section is the only thing a count can be about once the rows are models.
@MainActor
final class ModelChooserHeaderView: NSTableCellView {
    init(section: ModelChooserSection) {
        super.init(frame: .zero)
        let title = NSTextField(
            labelWithAttributedString: NSAttributedString(
                string: section.title.uppercased(),
                attributes: MacTheme.Ramp.attributes(
                    .metricLabel, color: MacTheme.Color.secondaryLabel)))
        let detail = NSTextField(labelWithString: section.detail)
        detail.font = MacTheme.Ramp.font(.gaugeCaption)
        detail.textColor = MacTheme.Color.secondaryLabel
        detail.lineBreakMode = .byTruncatingTail
        detail.toolTip = section.detail
        detail.setContentCompressionResistancePriority(.init(240), for: .horizontal)
        title.lineBreakMode = .byTruncatingTail
        title.toolTip = section.title
        title.setContentCompressionResistancePriority(.init(245), for: .horizontal)
        for view in [title, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let leading: CGFloat = section.canCollapse ? MacTheme.Spacing.l : MacTheme.Spacing.s
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            detail.leadingAnchor.constraint(
                greaterThanOrEqualTo: title.trailingAnchor, constant: MacTheme.Spacing.s),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacTheme.Spacing.s),
            detail.lastBaselineAnchor.constraint(equalTo: title.lastBaselineAnchor),
        ])
        guard section.canCollapse else { return }
        let fold = NSImageView(
            image: NSImage(
                systemSymbolName: section.isCollapsed ? "chevron.right" : "chevron.down",
                accessibilityDescription: section.title) ?? NSImage())
        fold.contentTintColor = MacTheme.Color.tertiaryLabel
        fold.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        fold.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fold)
        toolTip = Localized.text("Open or fold this family")
        NSLayoutConstraint.activate([
            fold.trailingAnchor.constraint(equalTo: title.leadingAnchor, constant: -4),
            fold.centerYAnchor.constraint(equalTo: title.centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// One model in three columns that hold their places down the whole list: the tick, the name over
/// what settles which model it is, and — flush to the right edge — only what the row wears: the
/// wall in front of it or the capability marks as a column of glyph slots, then where it runs,
/// the star, and the chevron onto its other doors.
@MainActor
final class ModelChooserRowView: NSTableCellView {
    private static let slotWidth: CGFloat = 16

    init(
        row: ModelChooserRow, slots: [ModelFact],
        onExpand: @escaping () -> Void, onTogglePin: @escaping () -> Void
    ) {
        super.init(frame: .zero)

        let title = NSTextField(labelWithAttributedString: Self.title(row))
        title.lineBreakMode = .byTruncatingTail
        title.toolTip = row.title
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.init(260), for: .horizontal)

        let column = NSStackView(views: [title])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 1
        if !row.detail.isEmpty {
            let detail = NSTextField(labelWithString: row.detail)
            detail.font = MacTheme.Ramp.font(.rowNote)
            detail.textColor = MacTheme.Color.tertiaryLabel
            detail.lineBreakMode = .byTruncatingTail
            detail.toolTip = row.detail
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            column.addArrangedSubview(detail)
        }
        column.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        column.setContentHuggingPriority(.init(700), for: .horizontal)

        let check = NSTextField(labelWithString: row.isSelected ? "✓" : "")
        check.font = MacTheme.Ramp.font(.panelLabel)
        check.textColor = MacTheme.Color.accent
        check.alignment = .center

        let line = NSStackView(views: [check, row.detail.isEmpty ? title : column, Self.spacer()])
        line.spacing = MacTheme.Spacing.xs
        line.alignment = .centerY
        line.orientation = .horizontal
        line.distribution = .fill

        if let wall = row.wall {
            let note = NSTextField(labelWithString: QuotaSurface.rowNote(wall))
            note.font = MacTheme.Ramp.font(.gaugeCaption)
            note.textColor = MacTheme.Color.danger
            note.toolTip = QuotaSurface.bannerBody(wall)
            note.setContentCompressionResistancePriority(.required, for: .horizontal)
            line.addArrangedSubview(note)
        } else if !slots.isEmpty {
            line.addArrangedSubview(Self.marks(row, slots: slots))
        }
        for fact in row.facts where !fact.isCapability { line.addArrangedSubview(Self.pill(fact)) }

        let star = RowKit.ActionButton(title: "", action: onTogglePin)
        star.isBordered = false
        star.bezelStyle = .accessoryBar
        star.contentTintColor = row.isPinned ? MacTheme.Color.accent : MacTheme.Color.tertiaryLabel
        if row.selection != nil {
            star.image = NSImage(
                systemSymbolName: row.isPinned ? "star.fill" : "star",
                accessibilityDescription: Localized.text(
                    row.isPinned ? "Unpin this model" : "Pin this model"))
            star.toolTip = Localized.text(
                row.isPinned ? "Unpin this model" : "Pin this model")
        } else {
            star.isEnabled = false
            star.image = NSImage(
                systemSymbolName: "star",
                accessibilityDescription: Localized.text("Pin this model"))
        }
        line.addArrangedSubview(star)

        let chevron = RowKit.ActionButton(title: "", action: onExpand)
        chevron.isBordered = false
        chevron.bezelStyle = .accessoryBar
        chevron.contentTintColor = MacTheme.Color.secondaryLabel
        chevron.isEnabled = row.canExpand
        if row.canExpand {
            chevron.image = NSImage(
                systemSymbolName: row.isExpanded ? "chevron.down" : "chevron.right",
                accessibilityDescription: Localized.text("The other providers that run it"))
            chevron.toolTip = Localized.text("The other providers that run it")
        }
        line.addArrangedSubview(chevron)

        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        let leading = MacTheme.Spacing.s + (row.isNested ? MacTheme.Spacing.xl : 0)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacTheme.Spacing.s),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 14 * MacTheme.UIScale.factor),
            star.widthAnchor.constraint(equalToConstant: 16 * MacTheme.UIScale.factor),
            star.heightAnchor.constraint(equalToConstant: 16 * MacTheme.UIScale.factor),
            chevron.widthAnchor.constraint(equalToConstant: 18 * MacTheme.UIScale.factor),
            chevron.heightAnchor.constraint(equalToConstant: 16 * MacTheme.UIScale.factor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// What takes the row's slack, so the name keeps its own width and everything after it sits
    /// flush right — a stack with no lowest hugger handed the slack to whichever view it liked,
    /// and the marks floated after each name instead of standing in a column.
    private static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
    }

    /// The capability column: one slot per mark the catalog can wear, in the catalog's order, a
    /// slot left empty where this model lacks the capability so the glyphs line up down the list.
    private static func marks(_ row: ModelChooserRow, slots: [ModelFact]) -> NSView {
        let strip = NSStackView()
        strip.orientation = .horizontal
        strip.spacing = 0
        strip.alignment = .centerY
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.widthAnchor.constraint(
            equalToConstant: CGFloat(slots.count) * slotWidth * MacTheme.UIScale.factor
        ).isActive = true
        let worn = row.facts.filter(\.isCapability)
        for slot in slots {
            let cell = NSImageView()
            cell.imageScaling = .scaleProportionallyDown
            if worn.contains(slot) {
                cell.image = NSImage(systemSymbolName: slot.symbol, accessibilityDescription: slot.label)
                cell.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
                cell.contentTintColor = MacTheme.Color.tertiaryLabel
                cell.toolTip = slot.label
            }
            cell.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                cell.widthAnchor.constraint(equalToConstant: slotWidth * MacTheme.UIScale.factor),
                cell.heightAnchor.constraint(equalToConstant: slotWidth * MacTheme.UIScale.factor),
            ])
            strip.addArrangedSubview(cell)
        }
        strip.setContentCompressionResistancePriority(.required, for: .horizontal)
        strip.setContentHuggingPriority(.required, for: .horizontal)
        strip.setAccessibilityLabel(worn.map(\.label).joined(separator: ", "))
        return strip
    }

    /// The name, with the letters the query matched picked out. A match changes weight and colour
    /// and never size: a taller glyph inside a word lifts the line's ascent, so the row would jump
    /// as the query changed and the name would read as misspelt rather than as found.
    private static func title(_ row: ModelChooserRow) -> NSAttributedString {
        let base = MacTheme.Ramp.font(.panelLabel)
        let face = row.isSelected ? base.bold : base
        let text = NSMutableAttributedString(
            string: row.title,
            attributes: [
                .font: face,
                .foregroundColor: row.wall == nil
                    ? MacTheme.Color.label : MacTheme.Color.tertiaryLabel,
            ])
        let characters = Array(row.title)
        for offset in row.highlight where offset < characters.count {
            let start = String(characters[0..<offset]).utf16.count
            let length = String(characters[offset]).utf16.count
            text.addAttributes(
                [
                    .foregroundColor: MacTheme.Color.accent,
                    .font: base.bold,
                ], range: NSRange(location: start, length: length))
        }
        return text
    }

    private static func pill(_ fact: ModelFact) -> NSView {
        let tint: NSColor = {
            switch fact {
            case .local: return MacTheme.Color.accent
            case .server: return MacTheme.Color.info
            default: return MacTheme.Color.secondaryLabel
            }
        }()
        return pill(text: fact.tag, tint: tint, tooltip: fact.label)
    }

    private static func pill(text: String, tint: NSColor, tooltip: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = MacTheme.Ramp.font(.gaugeCaption)
        label.textColor = tint
        label.toolTip = tooltip
        label.translatesAutoresizingMaskIntoConstraints = false
        let wrap = NSView()
        wrap.wantsLayer = true
        wrap.layer?.cornerRadius = 7
        wrap.layer?.backgroundColor = tint.withAlphaComponent(0.16).cgColor
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -1),
        ])
        wrap.setContentCompressionResistancePriority(.required, for: .horizontal)
        wrap.setContentHuggingPriority(.required, for: .horizontal)
        return wrap
    }
}
