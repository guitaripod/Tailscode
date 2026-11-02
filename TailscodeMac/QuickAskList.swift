import AppKit
import TailscodeCore

/// The quick ask's list, drawn: every line the same height whatever it holds — the glyph in a
/// tinted square, the title, its quieter words, a pill for where it asks or when, and the chord
/// that picks it — and the line the keyboard stands on wearing the accent. Lines answer the pointer
/// through `PressSurface`, so the panel is not a second dialect of hover.
@MainActor
enum QuickAskList {
    static let rowHeight: CGFloat = 34

    static func row(
        _ item: QuickAskMenuItem, onPress: @escaping () -> Void
    ) -> QuickAskRowView {
        QuickAskRowView(item: item, onPress: onPress)
    }

    /// The name of a group, set in the ramp's own answer for one.
    static func section(_ text: String) -> NSView {
        let label = NSTextField(
            labelWithAttributedString: NSAttributedString(
                string: text,
                attributes: MacTheme.Ramp.attributes(
                    .sectionLabel, color: MacTheme.Color.secondaryLabel)))
        return padded(label, top: 10, left: 10, bottom: 2)
    }

    /// What was copied heads its section: what it is in the accent, a glimpse of it, and the way
    /// to say it is not what this question is about.
    static func copiedHeader(_ section: QuickAskMenuSection, onSetAside: @escaping () -> Void)
        -> NSView
    {
        let headline = NSTextField(
            labelWithAttributedString: NSAttributedString(
                string: section.title,
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
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let head = NSStackView(views: [headline, spacer, aside])
        head.orientation = .horizontal
        var rows: [NSView] = [head]
        if let note = section.note {
            let glimpse = NSTextField(wrappingLabelWithString: note)
            glimpse.font = MacTheme.Ramp.font(.rowDetail)
            glimpse.textColor = MacTheme.Color.secondaryLabel
            glimpse.maximumNumberOfLines = 2
            glimpse.cell?.truncatesLastVisibleLine = true
            glimpse.isSelectable = false
            glimpse.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            rows.append(glimpse)
        }
        let column = NSStackView(views: rows)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 8)
        column.wantsLayer = true
        column.layer?.cornerRadius = 8
        column.layer?.backgroundColor = MacTheme.Color.accent.withAlphaComponent(0.08).cgColor
        head.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -20).isActive = true
        return padded(column, top: 6, left: 0, bottom: 2)
    }

    /// A line of small print in the list: who asks the questions for later, an unreadable entry.
    static func note(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = MacTheme.Ramp.font(.panelFootnote)
        label.textColor = MacTheme.Color.tertiaryLabel
        label.isSelectable = false
        return padded(label, top: 2, left: 44, bottom: 4)
    }

    /// One key and what it does, for the foot of the panel.
    static func key(_ key: QuickAskFooter.Key) -> NSView {
        let cap = NSTextField(labelWithString: key.keys)
        cap.font = MacTheme.Ramp.font(.panelFootnote)
        cap.textColor = MacTheme.Color.label
        cap.alignment = .center
        let capBox = NSView()
        capBox.wantsLayer = true
        capBox.layer?.cornerRadius = 4
        capBox.layer?.borderWidth = 1
        capBox.layer?.borderColor = MacTheme.Color.separator.cgColor
        cap.translatesAutoresizingMaskIntoConstraints = false
        capBox.addSubview(cap)
        NSLayoutConstraint.activate([
            cap.leadingAnchor.constraint(equalTo: capBox.leadingAnchor, constant: 5),
            cap.trailingAnchor.constraint(equalTo: capBox.trailingAnchor, constant: -5),
            cap.topAnchor.constraint(equalTo: capBox.topAnchor, constant: 1),
            cap.bottomAnchor.constraint(equalTo: capBox.bottomAnchor, constant: -1),
        ])
        let word = NSTextField(labelWithString: key.word)
        word.font = MacTheme.Ramp.font(.panelFootnote)
        word.textColor = MacTheme.Color.secondaryLabel
        let pair = NSStackView(views: [capBox, word])
        pair.orientation = .horizontal
        pair.spacing = 5
        return pair
    }

    private static func padded(_ view: NSView, top: CGFloat, left: CGFloat, bottom: CGFloat)
        -> NSView
    {
        let box = NSStackView(views: [view])
        box.orientation = .vertical
        box.alignment = .leading
        box.edgeInsets = NSEdgeInsets(top: top, left: left, bottom: bottom, right: 0)
        view.widthAnchor.constraint(equalTo: box.widthAnchor, constant: -left).isActive = true
        return box
    }
}

/// One line of the list. It is the accessibility element, because the press surface around its
/// face keeps out of that tree.
@MainActor
final class QuickAskRowView: NSView {
    let item: QuickAskMenuItem
    private let onPress: () -> Void
    private let face = NSView()

    init(item: QuickAskMenuItem, onPress: @escaping () -> Void) {
        self.item = item
        self.onPress = onPress
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        face.wantsLayer = true
        face.layer?.cornerRadius = 8
        face.layer?.cornerCurve = .continuous

        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 6
        badge.layer?.cornerCurve = .continuous
        badge.layer?.backgroundColor = MacTheme.Color.accent.withAlphaComponent(0.14).cgColor
        let symbol = NSImageView(
            image: NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil) ?? NSImage())
        symbol.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        symbol.contentTintColor = MacTheme.Color.accent
        symbol.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(symbol)
        badge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 24),
            badge.heightAnchor.constraint(equalToConstant: 24),
            symbol.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
        ])
        if case .newAction = item.kind {
            badge.layer?.backgroundColor = NSColor.clear.cgColor
            badge.layer?.borderWidth = 1
            badge.layer?.borderColor = MacTheme.Color.separator.cgColor
            symbol.contentTintColor = MacTheme.Color.secondaryLabel
        }

        let title = NSTextField(labelWithString: item.title)
        title.font = MacTheme.Ramp.font(.rowTitle)
        title.textColor =
            {
                if case .newAction = item.kind { return MacTheme.Color.secondaryLabel }
                return MacTheme.Color.label
            }()
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        title.setContentHuggingPriority(.required, for: .horizontal)
        let detail = NSTextField(labelWithString: item.detail)
        detail.font = MacTheme.Ramp.font(.rowDetail)
        detail.textColor = MacTheme.Color.tertiaryLabel
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        detail.setContentHuggingPriority(.init(1), for: .horizontal)
        var views: [NSView] = [badge, title, detail]
        if let words = item.badge, !words.isEmpty {
            let pill = NSTextField(labelWithString: words)
            pill.font = MacTheme.Ramp.font(.rowMeta)
            pill.textColor = MacTheme.Color.accent
            pill.setContentCompressionResistancePriority(.required, for: .horizontal)
            views.append(pill)
        }
        if let digit = item.digit {
            let chord = NSTextField(labelWithString: "⌘\(digit)")
            chord.font = MacTheme.Ramp.font(.rowMeta)
            chord.textColor = MacTheme.Color.tertiaryLabel
            chord.setContentCompressionResistancePriority(.required, for: .horizontal)
            views.append(chord)
        }
        let line = NSStackView(views: views)
        line.orientation = .horizontal
        line.spacing = 10
        line.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 10)
        line.translatesAutoresizingMaskIntoConstraints = false
        face.addSubview(line)
        face.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: face.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: face.trailingAnchor),
            line.centerYAnchor.constraint(equalTo: face.centerYAnchor),
            face.heightAnchor.constraint(equalToConstant: QuickAskList.rowHeight),
        ])
        let surface = PressSurface(content: face, outset: NSEdgeInsetsZero, radius: 8)
        surface.onPress = onPress
        addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(
            [item.title, item.detail, item.badge ?? ""].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var isSelected = false {
        didSet {
            face.layer?.backgroundColor =
                isSelected ? MacTheme.Color.accent.withAlphaComponent(0.18).cgColor : nil
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress()
        return true
    }
}
