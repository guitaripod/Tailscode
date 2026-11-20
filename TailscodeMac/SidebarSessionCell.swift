import AppKit
import CodingAgentKit
import TailscodeCore

/// One conversation, in the grammar `docs/session-list.md` sets for all three desks: a state
/// column whose mark always means something, the title on a line of its own, a line of news only
/// when there is news, and who, where and with what last. Kept transparent: the system sidebar
/// glass is the only background this row ever has.
final class SidebarSessionCell: NSView {
    private let glyph = NSTextField(labelWithString: "")
    /// The state's own symbol, breathing or knocking, in the column the glyph holds. The text
    /// glyph stays for the one thing that is not a state: the check of a marked row.
    private let badge = ActivityBadgeView(pointSize: 10)
    /// The unread dot, in the state column rather than trailing the title, so it is found by
    /// running an eye down one edge.
    private let dot = NSView()
    private let title = NSTextField(labelWithString: "")
    /// The small marks after the title, set as one run of symbols so a row with none of them
    /// has nothing there to lay out.
    private let marks = NSTextField(labelWithString: "")
    private var markCount = 0
    private let news = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    /// How long ago the conversation moved, in a column of its own down the trailing edge.
    private let age = NSTextField(labelWithString: "")
    private let titleRow = NSView()
    private let column = NSStackView()
    private var glyphWidth: NSLayoutConstraint?
    private var badgeWidth: NSLayoutConstraint?
    private var badgeHeight: NSLayoutConstraint?
    private var dotSide: [NSLayoutConstraint] = []
    /// The verbs a resting pointer is offered, standing where the age was: the one thing on the
    /// row nobody needs while deciding what to do with it.
    private let actions = NSStackView()
    /// The last line gives way to the verbs while they are up, rather than running underneath
    /// them. The title and the news keep their width, so a row never changes height under the
    /// pointer that is resting on it.
    private var actionRoom: [NSLayoutConstraint] = []
    private var quickState: SidebarQuickState?
    private var inked: (model: SessionRowModel, marked: Bool)?
    /// The last line at every length it can be said in, longest first. The one that fits is
    /// drawn, so a narrow sidebar loses a whole fact — the effort, then the model, then the
    /// machine — rather than the end of a word.
    private var detailFits: [NSAttributedString] = []
    var onQuickAction: ((SidebarQuickAction, NSView) -> Void)?

    /// Whether the table's selection is on this row: the conversation open in the window, or the
    /// one the keyboard is passing over. Either way it is the row being looked at, so its title is
    /// never the stepped-back ink of a row at rest.
    var isChosen = false {
        didSet {
            guard isChosen != oldValue, let inked else { return }
            title.textColor = Self.titleColor(inked.model, chosen: isChosen)
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = MacTheme.Radius.control
        glyph.font = MacTheme.Ramp.font(.panelLabel)
        glyph.alignment = .center
        glyph.translatesAutoresizingMaskIntoConstraints = false

        dot.wantsLayer = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.setAccessibilityElement(false)

        title.font = MacTheme.Ramp.font(.rowTitle)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        title.translatesAutoresizingMaskIntoConstraints = false
        marks.translatesAutoresizingMaskIntoConstraints = false
        marks.setContentCompressionResistancePriority(.required, for: .horizontal)
        marks.setContentHuggingPriority(.required, for: .horizontal)
        titleRow.addSubview(title)
        titleRow.addSubview(marks)

        news.isSelectable = false
        news.maximumNumberOfLines = 1
        news.cell?.truncatesLastVisibleLine = true
        news.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        news.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        detail.font = MacTheme.Ramp.font(.panelFootnote)
        detail.textColor = MacTheme.Color.secondaryLabel
        detail.lineBreakMode = .byTruncatingTail
        detail.maximumNumberOfLines = 1
        detail.cell?.usesSingleLineMode = true
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false
        for line in [titleRow, news, detail] { column.addArrangedSubview(line) }

        age.font = .monospacedDigitSystemFont(ofSize: MacTheme.Ramp.font(.panelFootnote).pointSize, weight: .regular)
        age.textColor = MacTheme.Color.tertiaryLabel
        age.alignment = .right
        age.setContentCompressionResistancePriority(.required, for: .horizontal)
        age.setContentHuggingPriority(.required, for: .horizontal)
        age.translatesAutoresizingMaskIntoConstraints = false

        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        addSubview(badge)
        addSubview(dot)
        addSubview(age)
        addSubview(column)
        let stateColumn = Self.stateColumn()
        let glyphWidth = glyph.widthAnchor.constraint(equalToConstant: stateColumn)
        let badgeWidth = badge.widthAnchor.constraint(equalToConstant: stateColumn)
        let badgeHeight = badge.heightAnchor.constraint(equalToConstant: stateColumn)
        self.glyphWidth = glyphWidth
        self.badgeWidth = badgeWidth
        self.badgeHeight = badgeHeight
        dotSide = [
            dot.widthAnchor.constraint(equalToConstant: Self.dotSide()),
            dot.heightAnchor.constraint(equalToConstant: Self.dotSide()),
        ]
        actions.orientation = .horizontal
        actions.spacing = 2
        actions.isHidden = true
        actions.translatesAutoresizingMaskIntoConstraints = false
        addSubview(actions)
        actionRoom = [
            detail.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -4)
        ]
        let newsWidth = news.widthAnchor.constraint(equalTo: column.widthAnchor)
        newsWidth.priority = .init(999)
        NSLayoutConstraint.activate(
            dotSide + [
                badge.centerXAnchor.constraint(equalTo: glyph.centerXAnchor),
                badge.centerYAnchor.constraint(equalTo: title.centerYAnchor),
                badgeWidth,
                badgeHeight,
                dot.centerXAnchor.constraint(equalTo: glyph.centerXAnchor),
                dot.centerYAnchor.constraint(equalTo: title.centerYAnchor),
                glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                glyph.centerYAnchor.constraint(equalTo: title.centerYAnchor),
                glyphWidth,
                column.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 4),
                column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                column.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
                titleRow.widthAnchor.constraint(equalTo: column.widthAnchor),
                title.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
                title.topAnchor.constraint(equalTo: titleRow.topAnchor),
                title.bottomAnchor.constraint(equalTo: titleRow.bottomAnchor),
                marks.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 3),
                marks.centerYAnchor.constraint(equalTo: title.centerYAnchor),
                marks.trailingAnchor.constraint(lessThanOrEqualTo: titleRow.trailingAnchor),
                newsWidth,
                actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
                actions.centerYAnchor.constraint(equalTo: detail.centerYAnchor),
                age.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                age.firstBaselineAnchor.constraint(equalTo: detail.firstBaselineAnchor),
                detail.trailingAnchor.constraint(lessThanOrEqualTo: age.leadingAnchor, constant: -6),
            ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The verbs come up with the pointer and go with it. `state` says which way each would go —
    /// pinned shows the way out of the pin — and nil puts the age back.
    func setHovered(_ state: SidebarQuickState?) {
        guard state != quickState else { return }
        quickState = state
        guard let state else {
            actions.isHidden = true
            age.isHidden = false
            NSLayoutConstraint.deactivate(actionRoom)
            needsLayout = true
            return
        }
        let verbs: [(SidebarQuickAction, String, String)] = [
            (.pin, state.pinned ? "pin.slash" : "pin",
             state.pinned ? Localized.text("Unpin") : Localized.text("Pin")),
            (.save, state.saved ? "bookmark.fill" : "bookmark",
             state.saved ? Localized.text("Unsave") : Localized.text("Save")),
            (.archive, state.archived ? "tray.and.arrow.up" : "archivebox",
             state.archived ? Localized.text("Unarchive") : Localized.text("Archive")),
            (.more, "ellipsis", Localized.text("More")),
        ]
        actions.setViews(verbs.map { Self.quickButton($0.0, symbol: $0.1, tip: $0.2, cell: self) }, in: .leading)
        age.isHidden = true
        actions.isHidden = false
        NSLayoutConstraint.activate(actionRoom)
        needsLayout = true
    }

    /// Whether the verbs are up, for a harness that proves they come and go with the pointer.
    var showsQuickActions: Bool { !actions.isHidden }

    private static func quickButton(
        _ action: SidebarQuickAction, symbol: String, tip: String, cell: SidebarSessionCell
    ) -> NSButton {
        let button = QuickButton { [weak cell] sender in cell?.onQuickAction?(action, sender) }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: (11 * MacTheme.UIScale.factor).rounded(), weight: .medium))
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
        return button
    }

    /// A borderless glyph that does not take the keyboard from the list it sits in.
    private final class QuickButton: NSButton {
        private let handler: (NSView) -> Void

        init(handler: @escaping (NSView) -> Void) {
            self.handler = handler
            super.init(frame: .zero)
            isBordered = false
            imagePosition = .imageOnly
            refusesFirstResponder = true
            contentTintColor = MacTheme.Color.onGlassSecondary
            target = self
            action = #selector(fire)
            translatesAutoresizingMaskIntoConstraints = false
            let side = (18 * MacTheme.UIScale.factor).rounded()
            widthAnchor.constraint(equalToConstant: side).isActive = true
            heightAnchor.constraint(equalToConstant: side).isActive = true
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        @objc private func fire() { handler(self) }
    }

    /// The width of the column the state is read in, held to the type scale: a well nailed to 16pt
    /// clips the very glyphs it exists to show once the ramp is stepped up, and leaves the symbol
    /// badge a speck beside a title twice its size.
    static func stateColumn() -> CGFloat {
        (16 * MacTheme.UIScale.factor).rounded()
    }

    /// What the row is drawing, for a harness that proves the grammar without a screen.
    struct Reading {
        let titleFont: NSFont
        let titleColor: NSColor
        let titleFrame: NSRect
        let showsDot: Bool
        let dotFrame: NSRect
        let showsBadge: Bool
        let marks: Int
        let news: NSAttributedString?
        let newsLines: Int
        let detail: NSAttributedString
        let age: String
    }

    var reading: Reading {
        Reading(
            titleFont: title.font ?? MacTheme.Ramp.font(.rowTitle),
            titleColor: title.textColor ?? MacTheme.Color.label,
            titleFrame: convert(title.bounds, from: title),
            showsDot: !dot.isHidden, dotFrame: dot.frame, showsBadge: badge.activity != nil,
            marks: markCount,
            news: news.isHidden ? nil : news.attributedStringValue,
            newsLines: news.maximumNumberOfLines, detail: detail.attributedStringValue,
            age: age.stringValue)
    }

    /// The side of the unread dot, held to the type scale like the column it sits in.
    static func dotSide() -> CGFloat {
        (7 * MacTheme.UIScale.factor).rounded()
    }

    /// - Parameter marked: a marked row wears the accent wash and lends its state column to the
    ///   check, because the mark is the only thing about the row that a verb is about to act on;
    ///   what the row was doing is still said by its news line, so nothing a marked row says is
    ///   lost.
    /// - Parameter dress: what the list around the row decides for it: which facts the listing
    ///   already says, the heading it sits under, and its news.
    func configure(with model: SessionRowModel, marked: Bool, dress: SidebarRowDress = .plain) {
        inked = (model, marked)
        layer?.backgroundColor =
            marked
            ? MacTheme.Color.accent.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor
        let stateColumn = Self.stateColumn()
        glyphWidth?.constant = stateColumn
        badgeWidth?.constant = stateColumn
        badgeHeight?.constant = stateColumn
        for side in dotSide { side.constant = Self.dotSide() }
        dot.layer?.cornerRadius = Self.dotSide() / 2
        dot.layer?.backgroundColor = MacTheme.Color.accent.cgColor
        badge.pointSize = (10 * MacTheme.UIScale.factor).rounded()

        let mark = marked ? ChatRowInk.ColumnMark.none : model.columnMark
        if case .activity(let activity) = mark { badge.activity = activity } else { badge.activity = nil }
        dot.isHidden = mark != .unread
        glyph.stringValue = marked ? "✓" : ""
        glyph.font = MacTheme.Ramp.font(.panelLabel)
        glyph.textColor = MacTheme.Color.accent

        title.stringValue = model.title
        title.font = MacTheme.Ramp.font(model.emphasis == .strong ? .rowTitleStrong : .rowTitle)
        title.textColor = Self.titleColor(model, chosen: isChosen)

        let titleMarks = model.titleMarks(under: dress.section)
        let expert = model.entry.session.expertID == nil ? nil : ExpertDesk.shared.row(for: model.entry)
        markCount = titleMarks.count + (expert == nil ? 0 : 1)
        marks.attributedStringValue = Self.markText(titleMarks, expert: expert)
        marks.toolTip =
            ([expert.map { Localized.text("A task of %@", $0.expert.name) }].compactMap { $0 }
            + titleMarks.map(\.spoken)).joined(separator: ", ").nilIfBlank
        marks.setAccessibilityElement(false)

        if let said = dress.news {
            let lines = ChatRowInk.newsLines(said.voice, roomy: false)
            news.maximumNumberOfLines = lines
            news.cell?.usesSingleLineMode = lines == 1
            news.cell?.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
            news.attributedStringValue = Self.newsText(said, lines: lines)
            news.toolTip = said.spoken
            news.isHidden = false
        } else {
            news.stringValue = ""
            news.toolTip = nil
            news.isHidden = true
        }

        let facets = model.facets(dress.vocabulary)
        detail.font = MacTheme.Ramp.font(.panelFootnote)
        detailFits = Self.detailFits(
            facets, chip: ModelBadge.chip(for: model.entry),
            strength: ChatRowInk.chipOpacity(model.emphasis))
        detail.attributedStringValue = detailFits.first ?? NSAttributedString()
        needsLayout = true
        age.stringValue = facets.age
        age.font = .monospacedDigitSystemFont(
            ofSize: MacTheme.Ramp.font(.panelFootnote).pointSize, weight: .regular)
        age.textColor = MacTheme.Color.tertiaryLabel
        alphaValue = model.state == .offline ? 0.62 : 1

        setAccessibilityLabel(Self.spoken(model, news: dress.news, marks: titleMarks))
        setAccessibilityValue(marked ? Localized.text("Marked") : "")
    }

    override func layout() {
        super.layout()
        fitDetail()
    }

    /// Draws the longest saying of the last line that fits between the title's edge and the age
    /// or the verbs, whichever is standing there.
    private func fitDetail() {
        guard let longest = detailFits.first, let shortest = detailFits.last else { return }
        let end = actions.isHidden ? age.frame.minX - 6 : actions.frame.minX - 4
        let room = end - column.frame.minX
        guard room > 0 else { return }
        let pick = detailFits.first { ceil($0.size().width) <= room } ?? shortest
        if detail.attributedStringValue != pick {
            detail.attributedStringValue = pick
        }
        detail.toolTip = pick == longest ? nil : longest.string
    }

    /// Every length the last line can be said in, longest first: who, where and with what; then
    /// without the effort; then without the model; then the project alone.
    static func detailFits(
        _ facets: SessionRowFacets, chip: ModelChip?, strength: Double
    ) -> [NSAttributedString] {
        let whole = detailText(facets)
        let gap = NSAttributedString(
            string: "  ", attributes: [.font: MacTheme.Ramp.font(.panelFootnote)])
        func line(_ parts: [NSAttributedString]) -> NSAttributedString {
            let text = NSMutableAttributedString()
            for part in parts where part.length > 0 {
                if text.length > 0 { text.append(gap) }
                text.append(part)
            }
            text.addAttribute(
                .paragraphStyle, value: oneLine, range: NSRange(location: 0, length: text.length))
            return text
        }
        var fits: [NSAttributedString] = []
        if let chip {
            fits.append(line([whole, chipText(chip, strength: strength)]))
            if chip.effort != nil {
                fits.append(line([whole, chipText(chip, strength: strength, effort: false)]))
            }
        }
        if whole.length > 0 { fits.append(line([whole])) }
        if facets.origin != nil, facets.project != nil {
            fits.append(
                line([detailText(SessionRowFacets(project: facets.project, origin: nil, age: facets.age))]))
        }
        if fits.isEmpty { fits.append(line([whole])) }
        return fits
    }

    /// The title's ink on the three rungs: the chosen row and anything waiting, unread or busy at
    /// full strength, a settled row that has been read one step back.
    static func titleColor(_ model: SessionRowModel, chosen: Bool) -> NSColor {
        let strength = chosen ? 1 : ChatRowInk.titleOpacity(model.emphasis)
        return strength == 1
            ? MacTheme.Color.label : MacTheme.Color.label.withAlphaComponent(strength)
    }

    /// What the row is called aloud: its name, what it is doing, what it has to say, and whether
    /// it is unread, in the order a person would say them.
    static func spoken(
        _ model: SessionRowModel, news: ChatRowNews?, marks: [ChatRowInk.TitleMark]
    ) -> String {
        var parts = [model.title]
        if let state = model.state.activity?.spoken { parts.append(state) }
        if let news, news.spoken != model.state.activity?.spoken { parts.append(news.spoken) }
        if model.unread { parts.append(Localized.text("Unread")) }
        parts.append(contentsOf: marks.map(\.spoken))
        return parts.joined(separator: ", ")
    }

    /// The last line never wraps: what does not fit is cut at its end, the model first.
    private static let oneLine: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    /// The marks after a title as one run of symbols. Glyphs rather than words: the heading says
    /// PINNED once, and a row that wears it elsewhere has only to be recognised, not read.
    static func markText(_ marks: [ChatRowInk.TitleMark], expert: ExpertRow? = nil) -> NSAttributedString {
        let text = NSMutableAttributedString()
        if let expert {
            let side = (12 * MacTheme.UIScale.factor).rounded()
            let attachment = NSTextAttachment()
            attachment.image = ExpertMarkView.image(expert, side: side)
            attachment.bounds = NSRect(x: 0, y: -2, width: side, height: side)
            text.append(NSAttributedString(attachment: attachment))
        }
        let face = NSImage.SymbolConfiguration(
            pointSize: (9 * MacTheme.UIScale.factor).rounded(), weight: .semibold
        ).applying(.init(paletteColors: [MacTheme.Color.tertiaryLabel]))
        for mark in marks {
            guard
                let image = NSImage(systemSymbolName: mark.symbol, accessibilityDescription: mark.spoken)?
                    .withSymbolConfiguration(face)
            else { continue }
            let attachment = NSTextAttachment()
            attachment.image = image
            if text.length > 0 { text.append(NSAttributedString(string: "\u{2009}")) }
            text.append(NSAttributedString(attachment: attachment))
        }
        return text
    }

    /// One mark as a view of its own, for a row that is laid out as a stack.
    static func markView(_ mark: ChatRowInk.TitleMark) -> NSView {
        let view = NSImageView(
            image: NSImage(systemSymbolName: mark.symbol, accessibilityDescription: mark.spoken)
                ?? NSImage())
        view.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: (9 * MacTheme.UIScale.factor).rounded(), weight: .semibold)
        view.contentTintColor = MacTheme.Color.tertiaryLabel
        view.toolTip = mark.spoken
        view.setAccessibilityLabel(mark.spoken)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }

    /// The news in the tone of what it is. A failure is said in the failure colour and a quoted
    /// answer in the reader's own ink a step under the title; the thing a waiting turn wants is
    /// set in the machine's face, because it is a command or a path.
    ///
    /// - Parameter lines: how many lines the news may take. One line is cut at its end; two wrap
    ///   by the word and the field cuts the last one, which a truncating paragraph cannot do.
    static func newsText(_ news: ChatRowNews, lines: Int = 1) -> NSAttributedString {
        let color: NSColor
        switch news.voice {
        case .asking: color = MacTheme.Color.label
        case .working: color = MacTheme.Color.accent
        case .failed: color = MacTheme.Color.danger
        case .said: color = MacTheme.Color.label.withAlphaComponent(ChatRowInk.quotedNews)
        case .away, .settled: color = MacTheme.Color.secondaryLabel
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        let text = NSMutableAttributedString(
            string: news.lead,
            attributes: [
                .font: MacTheme.Ramp.font(.panelDetail), .foregroundColor: color,
                .paragraphStyle: style,
            ])
        if let object = news.object, !object.isEmpty {
            text.append(
                NSAttributedString(
                    string: " " + object,
                    attributes: [
                        .font: MacTheme.Ramp.font(.rowDetail),
                        .foregroundColor: MacTheme.Color.label, .paragraphStyle: style,
                    ]))
        }
        return text
    }

    /// The model wearing its family's hue and the effort wearing its heat, leading the detail
    /// line the same way the Linux chips do. Ultracode is not a heat, so its word is set letter
    /// by letter from the shared rainbow, each held to the canvas's own contrast floor.
    ///
    /// - Parameter strength: how much of its own colour the chip keeps. A read row's chip steps
    ///   back with the row, so the hues are still there to recognise and never the brightest
    ///   thing on a line nobody needs to look at.
    /// - Parameter effort: whether the effort is said after the model, which a line short of room
    ///   gives up first.
    static func chipText(
        _ chip: ModelChip, strength: Double = 1, effort saysEffort: Bool = true
    ) -> NSAttributedString {
        let font = MacTheme.Ramp.font(.rowMeta)
        func inked(_ color: NSColor) -> NSColor {
            strength == 1 ? color : color.withAlphaComponent(color.alphaComponent * strength)
        }
        let text = NSMutableAttributedString(
            string: chip.name,
            attributes: [.font: font, .foregroundColor: inked(MacTheme.Color.modelIdentity(chip))])
        guard saysEffort, let effort = chip.effort else { return text }
        text.append(NSAttributedString(string: " ", attributes: [.font: font]))
        if chip.isUltracode {
            for (index, letter) in effort.enumerated() {
                text.append(
                    NSAttributedString(
                        string: String(letter),
                        attributes: [
                            .font: font,
                            .foregroundColor: inked(
                                MacTheme.Color.modelRainbowLetter(index, of: effort.count)),
                        ]))
            }
        } else {
            text.append(
                NSAttributedString(
                    string: effort,
                    attributes: [
                        .font: font,
                        .foregroundColor: inked(
                            MacTheme.Color.modelEffort(effort) ?? MacTheme.Color.secondaryLabel),
                    ]))
        }
        return text
    }

    /// Two weights on one line: the project a person recognises the chat by, then the machine it
    /// lives on a step quieter behind it. One colour for both is a line that has to be read word
    /// by word to find the only part that identifies anything.
    private static func detailText(_ facets: SessionRowFacets) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let font = MacTheme.Ramp.font(.panelFootnote)
        if let project = facets.project {
            text.append(
                NSAttributedString(
                    string: project,
                    attributes: [.font: font, .foregroundColor: MacTheme.Color.secondaryLabel]))
        }
        if let origin = facets.origin {
            text.append(
                NSAttributedString(
                    string: text.length == 0 ? origin : " · \(origin)",
                    attributes: [.font: font, .foregroundColor: MacTheme.Color.tertiaryLabel]))
        }
        return text
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}
