import AppKit
import CodingAgentKit
import TailscodeCore

/// Several conversations held in one window, drawn as the one row they are: the names in the
/// order the panes read, the shape and the count leading the detail line, and the loudest pane's
/// state in the glyph column — the same row the Linux list draws, in AppKit's voice.
///
/// Each member keeps a line of its own under the row, because merging the rows must not take away
/// the ability to open one chat. Those lines are buttons; the row itself is opened by the table's
/// own selection, so pressing a member never reads as pressing the split.
final class SidebarSplitTabCell: NSView {
    private let glyph = NSTextField(labelWithString: "")
    private let badge = ActivityBadgeView(pointSize: 10)
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let age = NSTextField(labelWithString: "")
    private let titleRow = NSStackView()
    private let memberRows = NSStackView()
    private var glyphWidth: NSLayoutConstraint?
    private var badgeWidth: NSLayoutConstraint?
    private var badgeHeight: NSLayoutConstraint?
    private var tab: SplitTab?
    private var onOpenMember: ((SplitTab, Int) -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = MacTheme.Radius.control
        glyph.translatesAutoresizingMaskIntoConstraints = false
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleRow.orientation = .horizontal
        titleRow.spacing = 6
        titleRow.alignment = .centerY
        titleRow.addArrangedSubview(title)
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        detail.textColor = MacTheme.Color.secondaryLabel
        detail.lineBreakMode = .byTruncatingTail
        detail.translatesAutoresizingMaskIntoConstraints = false
        age.alignment = .right
        age.textColor = MacTheme.Color.tertiaryLabel
        age.setContentCompressionResistancePriority(.required, for: .horizontal)
        age.setContentHuggingPriority(.required, for: .horizontal)
        age.translatesAutoresizingMaskIntoConstraints = false
        memberRows.orientation = .vertical
        memberRows.alignment = .leading
        memberRows.spacing = 1
        memberRows.translatesAutoresizingMaskIntoConstraints = false
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        addSubview(badge)
        addSubview(age)
        addSubview(titleRow)
        addSubview(detail)
        addSubview(memberRows)
        let column = SidebarSessionCell.stateColumn()
        let glyphWidth = glyph.widthAnchor.constraint(equalToConstant: column)
        let badgeWidth = badge.widthAnchor.constraint(equalToConstant: column)
        let badgeHeight = badge.heightAnchor.constraint(equalToConstant: column)
        self.glyphWidth = glyphWidth
        self.badgeWidth = badgeWidth
        self.badgeHeight = badgeHeight
        NSLayoutConstraint.activate([
            badge.centerXAnchor.constraint(equalTo: glyph.centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: glyph.centerYAnchor, constant: 1),
            badgeWidth,
            badgeHeight,
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            glyph.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            glyphWidth,
            titleRow.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 4),
            titleRow.trailingAnchor.constraint(equalTo: age.leadingAnchor, constant: -6),
            titleRow.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            age.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            age.firstBaselineAnchor.constraint(equalTo: detail.firstBaselineAnchor),
            detail.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: age.leadingAnchor, constant: -6),
            detail.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 2),
            memberRows.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
            memberRows.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            memberRows.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 3),
            memberRows.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(
        with model: SplitTabRow, marked: Bool, onOpenMember: ((SplitTab, Int) -> Void)?
    ) {
        self.tab = model.tab
        self.onOpenMember = onOpenMember
        layer?.backgroundColor =
            marked
            ? MacTheme.Color.accent.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor
        setAccessibilityLabel(model.accessibleLabel)
        setAccessibilityValue(marked ? Localized.text("Marked") : "")
        let column = SidebarSessionCell.stateColumn()
        glyphWidth?.constant = column
        badgeWidth?.constant = column
        badgeHeight?.constant = column
        badge.pointSize = (10 * MacTheme.UIScale.factor).rounded()
        let state = model.state
        let activity = marked ? nil : state.activity
        badge.activity = activity
        glyph.stringValue = activity == nil ? (marked ? "✓" : state.glyph.text) : ""
        glyph.font = MacTheme.Ramp.font(.panelLabel)
        glyph.textColor = marked ? MacTheme.Color.accent : SidebarSessionCell.glyphColor(state)
        title.stringValue = model.title
        title.font =
            model.unread ? MacTheme.Ramp.font(.rowTitleStrong) : MacTheme.Ramp.font(.rowTitle)
        let facets = model.facets()
        detail.font = MacTheme.Ramp.font(.panelFootnote)
        detail.stringValue = [facets.project, facets.origin].compactMap { $0 }
            .joined(separator: " · ")
        age.stringValue = facets.age
        age.font = .monospacedDigitSystemFont(
            ofSize: MacTheme.Ramp.font(.panelFootnote).pointSize, weight: .regular)
        for view in titleRow.arrangedSubviews.dropFirst() {
            titleRow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if let pill = state.pill {
            titleRow.addArrangedSubview(
                SidebarSessionCell.pill(pill.text, tint: SidebarSessionCell.pillTint(state)))
        }
        if model.pinned {
            titleRow.addArrangedSubview(
                SidebarSessionCell.pill(
                    Localized.text("PINNED"), tint: MacTheme.Color.accent))
        }
        for view in memberRows.arrangedSubviews {
            memberRows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, member) in model.members.enumerated() {
            memberRows.addArrangedSubview(memberButton(member, index: index))
        }
    }

    private func memberButton(_ model: SessionRowModel, index: Int) -> NSButton {
        let button = NSButton(
            title: "\(model.state.glyph.text) \(model.title)", target: self,
            action: #selector(memberPressed))
        button.isBordered = false
        button.tag = index
        button.font = MacTheme.Ramp.font(.panelFootnote)
        button.contentTintColor =
            model.unread ? MacTheme.Color.label : MacTheme.Color.secondaryLabel
        button.alignment = .left
        button.toolTip = Localized.text("Open just this chat")
        button.setAccessibilityLabel(Localized.text("Open just %@", model.title))
        return button
    }

    @objc private func memberPressed(_ sender: NSButton) {
        guard let tab else { return }
        onOpenMember?(tab, sender.tag)
    }
}
