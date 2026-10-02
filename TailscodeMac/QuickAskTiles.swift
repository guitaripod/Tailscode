import AppKit
import TailscodeCore

/// The quick ask's empty panel, drawn as things to press rather than as lines of small grey text:
/// each starter a tile with its symbol set in a tinted square, its title over its quieter detail,
/// and the chord that picks it in the corner; each question already asked one line with its age at
/// the far end. Every one of them answers the pointer the way the rest of the window does, through
/// `PressSurface`, so the panel is not a second dialect of hover.
@MainActor
enum QuickAskTiles {
    static let spacing: CGFloat = 8

    static func tile(
        _ starter: QuickAskStarter, shortcut: String?, onPress: @escaping () -> Void
    ) -> NSView {
        let face = QuickAskTileFace(
            symbol: starter.symbol, title: starter.title, detail: starter.detail,
            shortcut: shortcut, onPress: onPress)
        let surface = PressSurface(content: face, outset: NSEdgeInsetsZero, radius: 10)
        surface.onPress = onPress
        return surface
    }

    /// A question already asked, on one line: what it was, and how long ago at the far end.
    static func recent(title: String, age: String, onPress: @escaping () -> Void) -> NSView {
        let mark = NSImageView(
            image: NSImage(
                systemSymbolName: "arrow.counterclockwise", accessibilityDescription: nil)
                ?? NSImage())
        mark.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        mark.contentTintColor = MacTheme.Color.accent
        mark.setContentHuggingPriority(.required, for: .horizontal)
        let name = NSTextField(labelWithString: title)
        name.font = MacTheme.Ramp.font(.rowTitle)
        name.textColor = MacTheme.Color.label
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        name.setContentHuggingPriority(.init(1), for: .horizontal)
        let when = NSTextField(labelWithString: age)
        when.font = MacTheme.Ramp.font(.rowMeta)
        when.textColor = MacTheme.Color.tertiaryLabel
        when.setContentHuggingPriority(.required, for: .horizontal)
        when.setContentCompressionResistancePriority(.required, for: .horizontal)
        let line = NSStackView(views: [mark, name, when])
        line.orientation = .horizontal
        line.spacing = 10
        line.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        line.setAccessibilityElement(true)
        line.setAccessibilityRole(.button)
        line.setAccessibilityLabel(title + ", " + age)
        let surface = PressSurface(content: line, outset: NSEdgeInsetsZero, radius: 7)
        surface.onPress = onPress
        return surface
    }
}

/// One starter's face: a rounded ground a shade off the panel's, the symbol in a tinted square so
/// a column of them reads as a set of things to do, and the chord in the corner. It is the
/// accessibility element, because the press surface around it keeps out of that tree.
@MainActor
final class QuickAskTileFace: NSView {
    private let onPress: () -> Void
    private let badge = NSView()

    init(
        symbol: String, title: String, detail: String, shortcut: String?,
        onPress: @escaping () -> Void
    ) {
        self.onPress = onPress
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        badge.wantsLayer = true
        badge.layer?.cornerRadius = 7
        badge.layer?.cornerCurve = .continuous
        badge.translatesAutoresizingMaskIntoConstraints = false
        let image = NSImageView(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        image.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        image.contentTintColor = MacTheme.Color.accent
        image.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(image)

        let titleField = NSTextField(labelWithString: title)
        titleField.font = MacTheme.Ramp.font(.rowTitleStrong)
        titleField.textColor = MacTheme.Color.label
        titleField.lineBreakMode = .byTruncatingTail
        let detailField = NSTextField(labelWithString: detail)
        detailField.font = MacTheme.Ramp.font(.rowDetail)
        detailField.textColor = MacTheme.Color.secondaryLabel
        detailField.lineBreakMode = .byTruncatingTail
        for field in [titleField, detailField] {
            field.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        }
        let words = NSStackView(views: [titleField, detailField])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 1
        words.translatesAutoresizingMaskIntoConstraints = false

        addSubview(badge)
        addSubview(words)
        var constraints = [
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 30),
            badge.heightAnchor.constraint(equalToConstant: 30),
            image.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            image.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            words.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            words.centerYAnchor.constraint(equalTo: centerYAnchor),
            words.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 9),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
        ]
        if let shortcut {
            let key = NSTextField(labelWithString: shortcut)
            key.font = MacTheme.Ramp.font(.rowMeta)
            key.textColor = MacTheme.Color.tertiaryLabel
            key.setContentCompressionResistancePriority(.required, for: .horizontal)
            key.translatesAutoresizingMaskIntoConstraints = false
            addSubview(key)
            constraints += [
                key.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                key.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                words.trailingAnchor.constraint(equalTo: key.leadingAnchor, constant: -6),
            ]
        } else {
            constraints.append(
                words.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10))
        }
        NSLayoutConstraint.activate(constraints)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityHelp(detail)
        toolTip = detail
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.035).cgColor
        layer?.borderColor = MacTheme.Color.separator.cgColor
        badge.layer?.backgroundColor = MacTheme.Color.accent.withAlphaComponent(0.14).cgColor
    }

    override func accessibilityPerformPress() -> Bool {
        onPress()
        return true
    }
}

/// What was just copied, as one card above the starters: what it is, a glimpse of it where the
/// words were read, and a button per errand. The close button is how a person says the clipboard
/// is not what this question is about, and the panel remembers it, so the same thing is not
/// offered again on the next summon.
@MainActor
final class QuickAskCopiedCard: NSView {
    init(
        copied: QuickAskCopied, shortcuts: [String?],
        onErrand: @escaping (QuickAskClipboardErrand) -> Void,
        onSetAside: @escaping () -> Void
    ) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        let headline = NSTextField(
            labelWithAttributedString: NSAttributedString(
                string: copied.headline,
                attributes: MacTheme.Ramp.attributes(.sectionLabel, color: MacTheme.Color.accent)))
        headline.lineBreakMode = .byTruncatingTail
        headline.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let aside = RowKit.ActionButton(title: "") { onSetAside() }
        aside.image = NSImage(
            systemSymbolName: "xmark", accessibilityDescription: QuickAskWords.setAside)
        aside.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        aside.isBordered = false
        aside.imagePosition = .imageOnly
        aside.contentTintColor = MacTheme.Color.secondaryLabel
        aside.toolTip = QuickAskWords.setAside
        aside.setContentHuggingPriority(.required, for: .horizontal)
        HoverPlate.attach(to: aside)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let head = NSStackView(views: [headline, spacer, aside])
        head.orientation = .horizontal
        head.spacing = 8

        var rows: [NSView] = [head]
        if let preview = copied.preview {
            let glimpse = NSTextField(wrappingLabelWithString: preview)
            glimpse.font = MacTheme.Ramp.font(.rowDetail)
            glimpse.textColor = MacTheme.Color.label
            glimpse.maximumNumberOfLines = 2
            glimpse.lineBreakMode = .byWordWrapping
            glimpse.cell?.truncatesLastVisibleLine = true
            glimpse.isSelectable = false
            glimpse.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            rows.append(glimpse)
        }
        let errands = NSStackView(
            views: copied.errands.enumerated().map { index, errand in
                let button = RowKit.ActionButton(title: errand.title) { onErrand(errand) }
                button.image = NSImage(
                    systemSymbolName: errand.symbol, accessibilityDescription: nil)
                button.imagePosition = .imageLeading
                button.controlSize = .small
                button.font = MacTheme.Ramp.font(.control)
                let shortcut = shortcuts.indices.contains(index) ? shortcuts[index] : nil
                button.toolTip = [errand.prompt, shortcut].compactMap { $0 }.joined(separator: "  ")
                return button
            })
        errands.orientation = .horizontal
        errands.spacing = 6
        rows.append(errands)

        let column = NSStackView(views: rows)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
            head.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        if let glimpse = rows.dropFirst().first, glimpse !== errands {
            glimpse.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -2).isActive = true
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = MacTheme.Color.accent.withAlphaComponent(0.07).cgColor
        layer?.borderColor = MacTheme.Color.accent.withAlphaComponent(0.32).cgColor
    }
}
