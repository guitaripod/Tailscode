import AppKit
import CodingAgentKit
import TailscodeCore

/// One conversation: state glyph, title with its pills, and the two-register detail line — the
/// same three voices the Linux row speaks, so the lists read identically across desks. Kept
/// transparent: the system sidebar glass is the only background this row ever has.
final class SidebarSessionCell: NSView {
    private let glyph = NSTextField(labelWithString: "")
    /// The state's own symbol, breathing or knocking, in the column the glyph holds. The text
    /// glyph stays for what is not a state — the mark, and the quiet dot of an idle row.
    private let badge = ActivityBadgeView(pointSize: 10)
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    /// How long ago the conversation moved, in a column of its own down the trailing edge.
    private let age = NSTextField(labelWithString: "")
    private let titleRow = NSStackView()
    private var glyphWidth: NSLayoutConstraint?
    private var badgeWidth: NSLayoutConstraint?
    private var badgeHeight: NSLayoutConstraint?
    /// The verbs a resting pointer is offered, standing where the age was: the one thing on the
    /// row nobody needs while deciding what to do with it.
    private let actions = NSStackView()
    /// The title and the detail give way to the verbs while they are up, rather than running
    /// underneath them.
    private var actionRoom: [NSLayoutConstraint] = []
    private var quickState: SidebarQuickState?
    var onQuickAction: ((SidebarQuickAction, NSView) -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = MacTheme.Radius.control
        glyph.font = MacTheme.Ramp.font(.panelLabel)
        glyph.translatesAutoresizingMaskIntoConstraints = false

        title.font = MacTheme.Ramp.font(.rowTitle)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        titleRow.orientation = .horizontal
        titleRow.spacing = 6
        titleRow.alignment = .centerY
        titleRow.addArrangedSubview(title)
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        detail.font = MacTheme.Ramp.font(.panelFootnote)
        detail.textColor = MacTheme.Color.secondaryLabel
        detail.lineBreakMode = .byTruncatingTail
        detail.translatesAutoresizingMaskIntoConstraints = false

        age.font = .monospacedDigitSystemFont(ofSize: MacTheme.Ramp.font(.panelFootnote).pointSize, weight: .regular)
        age.textColor = MacTheme.Color.tertiaryLabel
        age.alignment = .right
        age.setContentCompressionResistancePriority(.required, for: .horizontal)
        age.setContentHuggingPriority(.required, for: .horizontal)
        age.translatesAutoresizingMaskIntoConstraints = false

        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        addSubview(badge)
        addSubview(age)
        addSubview(titleRow)
        addSubview(detail)
        let column = Self.stateColumn()
        let glyphWidth = glyph.widthAnchor.constraint(equalToConstant: column)
        let badgeWidth = badge.widthAnchor.constraint(equalToConstant: column)
        let badgeHeight = badge.heightAnchor.constraint(equalToConstant: column)
        self.glyphWidth = glyphWidth
        self.badgeWidth = badgeWidth
        self.badgeHeight = badgeHeight
        let titleFloor = title.widthAnchor.constraint(greaterThanOrEqualToConstant: 72)
        titleFloor.priority = .defaultHigh
        let titleEnd = titleRow.trailingAnchor.constraint(equalTo: age.leadingAnchor, constant: -6)
        titleEnd.priority = .init(999)
        actions.orientation = .horizontal
        actions.spacing = 2
        actions.isHidden = true
        actions.translatesAutoresizingMaskIntoConstraints = false
        addSubview(actions)
        actionRoom = [
            titleRow.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -4),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -4),
        ]
        NSLayoutConstraint.activate([
            badge.centerXAnchor.constraint(equalTo: glyph.centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: glyph.centerYAnchor, constant: 1),
            badgeWidth,
            badgeHeight,
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            glyph.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            glyphWidth,
            titleFloor,
            titleRow.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 4),
            titleEnd,
            titleRow.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor),
            age.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            age.firstBaselineAnchor.constraint(equalTo: detail.firstBaselineAnchor),
            detail.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: age.leadingAnchor, constant: -6),
            detail.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 2),
            detail.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
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

    /// - Parameter marked: a marked row wears the accent wash and lends its glyph column to the
    ///   check, because the mark is the only thing about the row that a verb is about to act on;
    ///   the state it was in is still spoken by its pill, so nothing a marked row says is lost.
    func configure(
        with model: SessionRowModel, marked: Bool, vocabulary: ChatListVocabulary = .full
    ) {
        layer?.backgroundColor =
            marked
            ? MacTheme.Color.accent.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor
        setAccessibilityLabel(model.title)
        setAccessibilityValue(marked ? Localized.text("Marked") : "")
        let column = Self.stateColumn()
        glyphWidth?.constant = column
        badgeWidth?.constant = column
        badgeHeight?.constant = column
        badge.pointSize = (10 * MacTheme.UIScale.factor).rounded()
        let activity = marked ? nil : model.state.activity
        badge.activity = activity
        glyph.stringValue = activity == nil ? (marked ? "✓" : model.state.glyph.text) : ""
        glyph.font = MacTheme.Ramp.font(.panelLabel)
        glyph.textColor = marked ? MacTheme.Color.accent : Self.glyphColor(model.state)
        title.stringValue = model.title
        title.font =
            model.unread ? MacTheme.Ramp.font(.rowTitleStrong) : MacTheme.Ramp.font(.rowTitle)
        let facets = model.facets(vocabulary)
        detail.font = MacTheme.Ramp.font(.panelFootnote)
        let line = NSMutableAttributedString()
        if let chip = ModelBadge.chip(for: model.entry) {
            line.append(Self.chipText(chip))
            line.append(
                NSAttributedString(
                    string: "  ",
                    attributes: [.font: MacTheme.Ramp.font(.panelFootnote)]))
        }
        if let snippet = model.snippet {
            line.append(
                NSAttributedString(
                    string: snippet,
                    attributes: [
                        .font: MacTheme.Ramp.font(.panelFootnote),
                        .foregroundColor: MacTheme.Color.accent,
                    ]))
        } else {
            line.append(Self.detailText(facets))
        }
        detail.attributedStringValue = line
        age.stringValue = facets.age
        age.font = .monospacedDigitSystemFont(
            ofSize: MacTheme.Ramp.font(.panelFootnote).pointSize, weight: .regular)
        age.textColor = MacTheme.Color.tertiaryLabel
        for view in titleRow.arrangedSubviews.dropFirst() {
            titleRow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if let pill = model.state.pill {
            titleRow.addArrangedSubview(Self.pill(pill.text, tint: Self.pillTint(model.state)))
        }
        if model.pinned {
            titleRow.addArrangedSubview(
                Self.pill(Localized.text("PINNED"), tint: MacTheme.Color.accent))
        }
        if model.saved {
            titleRow.addArrangedSubview(
                Self.pill(Localized.text("SAVED"), tint: MacTheme.Color.mark))
        }
        if model.unread, model.state.pill == nil {
            let dot = NSTextField(labelWithString: "●")
            dot.font = MacTheme.Ramp.font(.badge)
            dot.textColor = MacTheme.Color.accent
            dot.setAccessibilityLabel(Localized.text("Unread"))
            titleRow.addArrangedSubview(dot)
        }
    }

    /// The model wearing its family's hue and the effort wearing its heat, leading the detail
    /// line the same way the Linux chips do. Ultracode is not a heat, so its word is set letter
    /// by letter from the shared rainbow, each held to the canvas's own contrast floor.
    static func chipText(_ chip: ModelChip) -> NSAttributedString {
        let font = MacTheme.Ramp.font(.rowMeta)
        let text = NSMutableAttributedString(
            string: chip.name,
            attributes: [.font: font, .foregroundColor: MacTheme.Color.modelIdentity(chip)])
        guard let effort = chip.effort else { return text }
        text.append(NSAttributedString(string: " ", attributes: [.font: font]))
        if chip.isUltracode {
            for (index, letter) in effort.enumerated() {
                text.append(
                    NSAttributedString(
                        string: String(letter),
                        attributes: [
                            .font: font,
                            .foregroundColor: MacTheme.Color.modelRainbowLetter(
                                index, of: effort.count),
                        ]))
            }
        } else {
            text.append(
                NSAttributedString(
                    string: effort,
                    attributes: [
                        .font: font,
                        .foregroundColor: MacTheme.Color.modelEffort(effort)
                            ?? MacTheme.Color.secondaryLabel,
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

    /// The glyph column carries the same tones the Linux CSS classes do, and draws the same line
    /// between them: a turn that is running is alive, a turn that is waiting on the reader is
    /// amber, and the two never share a colour.
    static func glyphColor(_ state: SessionRowState) -> NSColor {
        state.icon.tone.color
    }

    static func pillTint(_ state: SessionRowState) -> NSColor {
        state.icon.tone.color
    }

    static func pill(_ text: String, tint: NSColor) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = MacTheme.Ramp.font(.pill)
        label.textColor = tint
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
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
