import AppKit
import TailscodeCore

/// The line under the prompt box that says where the next prompt goes and how: vim mode,
/// destination, model, effort, the command palette, attachments, and stop. The CLI's status
/// line, made clickable — every pill pops the menu that changes what it names.
@MainActor
final class PillsRow: NSView {
    struct MenuRow {
        let title: String
        let subtitle: String?
        let checked: Bool
        let handler: @MainActor () -> Void

        init(
            _ title: String, subtitle: String? = nil, checked: Bool = false,
            handler: @escaping @MainActor () -> Void = {}
        ) {
            self.title = title
            self.subtitle = subtitle
            self.checked = checked
            self.handler = handler
        }
    }

    /// A lane was pressed. Chat is the pane this row already sits in, so only the other two leave.
    var onLane: ((QuickAskLane) -> Void)?

    var modelRows: (() -> [MenuRow])?
    var effortRows: (() -> [MenuRow])?
    var commandRows: (() -> [MenuRow])?
    var attachRows: (() -> [MenuRow])?
    var onStop: (() -> Void)?

    /// The composer's three lanes, worn as the segmented control a Mac walks modes with. On a
    /// desk each lane is a surface — chat is this pane, ask is the summoned question window,
    /// video is the forge sheet — so a press is a door, and the selection springs back to chat
    /// because this row never stops being a conversation's.
    private let laneControl = NSSegmentedControl(
        labels: QuickAskLane.order.map(\.word), trackingMode: .momentary, target: nil,
        action: nil)
    private let vimBadge = NSTextField(labelWithString: "")
    private let vimBadgeWrap = NSView()
    private let destinationLabel = NSTextField(labelWithString: "")
    private let modelPill: MenuPill
    private let effortPill: MenuPill
    private let commandPill: MenuPill
    private let attachButton: MenuPill
    private let stopButton: RowKit.ActionButton

    init() {
        modelPill = MenuPill(title: Localized.text("model"))
        effortPill = MenuPill(title: Localized.text("effort"))
        commandPill = MenuPill(title: "/")
        attachButton = MenuPill(title: "")
        stopButton = RowKit.ActionButton(title: "") {}
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        vimBadge.textColor = MacTheme.Color.onGlass
        vimBadge.translatesAutoresizingMaskIntoConstraints = false
        vimBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        vimBadgeWrap.wantsLayer = true
        vimBadgeWrap.layer?.cornerRadius = 5
        vimBadgeWrap.translatesAutoresizingMaskIntoConstraints = false
        vimBadgeWrap.addSubview(vimBadge)
        NSLayoutConstraint.activate([
            vimBadge.leadingAnchor.constraint(equalTo: vimBadgeWrap.leadingAnchor, constant: 6),
            vimBadge.trailingAnchor.constraint(
                equalTo: vimBadgeWrap.trailingAnchor, constant: -6),
            vimBadge.topAnchor.constraint(equalTo: vimBadgeWrap.topAnchor, constant: 2),
            vimBadge.bottomAnchor.constraint(equalTo: vimBadgeWrap.bottomAnchor, constant: -2),
        ])
        vimBadgeWrap.isHidden = true

        destinationLabel.textColor = MacTheme.Color.onGlassSecondary
        destinationLabel.lineBreakMode = .byTruncatingMiddle
        destinationLabel.translatesAutoresizingMaskIntoConstraints = false
        destinationLabel.setContentCompressionResistancePriority(
            .defaultLow, for: .horizontal)

        modelPill.rows = { [weak self] in self?.modelRows?() ?? [] }
        modelPill.toolTip = Localized.text("The model the next prompt runs on")
        effortPill.rows = { [weak self] in self?.effortRows?() ?? [] }
        effortPill.toolTip = Localized.text("How hard the model thinks")
        commandPill.rows = { [weak self] in self?.commandRows?() ?? [] }
        commandPill.toolTip = Localized.text("Slash commands")

        attachButton.rows = { [weak self] in self?.attachRows?() ?? [] }
        attachButton.image = NSImage(
            systemSymbolName: "paperclip",
            accessibilityDescription: Localized.text("Attach files"))
        attachButton.toolTip = Localized.text("Attach files or a pasted image, up to 8 MB each")

        stopButton.bezelStyle = .rounded
        stopButton.controlSize = .small
        stopButton.image = NSImage(
            systemSymbolName: "stop.fill",
            accessibilityDescription: Localized.text("Stop the running turn"))
        stopButton.toolTip = Localized.text("Stop the running turn")
        stopButton.isHidden = true
        stopButton.target = self
        stopButton.action = #selector(stopTapped)
        stopButton.translatesAutoresizingMaskIntoConstraints = false

        for pill in [modelPill, effortPill, commandPill] {
            pill.setContentCompressionResistancePriority(.init(251), for: .horizontal)
            pill.cell?.lineBreakMode = .byTruncatingTail
        }
        attachButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        stopButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        laneControl.controlSize = .small
        laneControl.target = self
        laneControl.action = #selector(laneTapped)
        laneControl.setContentCompressionResistancePriority(.required, for: .horizontal)
        laneControl.translatesAutoresizingMaskIntoConstraints = false
        for (index, lane) in QuickAskLane.order.enumerated() {
            laneControl.setToolTip(lane.spoken, forSegment: index)
        }

        let row = NSStackView(views: [
            laneControl, vimBadgeWrap, destinationLabel, modelPill, effortPill, commandPill,
            RowKit.spacer(),
            attachButton, stopButton,
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MacTheme.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged), name: MacTheme.Chrome.didRepaint, object: nil)
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Every font and every palette colour in this row is asked for again rather than remembered:
    /// a type-scale step changes what a role is worth, and a colour built under one theme answers
    /// that theme forever — a Stop button made before a theme change would keep the old red.
    func restyle() {
        vimBadge.font = MacTheme.Ramp.font(.badge)
        destinationLabel.font = MacTheme.Ramp.font(.panelFootnote)
        for pill in [modelPill, effortPill, commandPill, attachButton] {
            pill.font = MacTheme.Ramp.font(.panelFootnote)
        }
        stopButton.contentTintColor = MacTheme.Color.danger
    }

    @objc private func themeChanged() {
        restyle()
    }

    @objc private func laneTapped() {
        let lanes = QuickAskLane.order
        guard lanes.indices.contains(laneControl.selectedSegment) else { return }
        onLane?(lanes[laneControl.selectedSegment])
    }

    /// Alongside the badge the caret itself says which mode this is, so the badge carries the
    /// mode's color too: quiet in normal, accent in insert, warning in the visual modes.
    func setVim(_ mode: VimMode?) {
        guard let mode else {
            vimBadgeWrap.isHidden = true
            return
        }
        vimBadgeWrap.isHidden = false
        vimBadge.stringValue = mode.label
        let background: NSColor =
            switch mode {
            case .insert: MacTheme.Color.accent.withAlphaComponent(0.25)
            case .normal: MacTheme.Color.tertiaryLabel.withAlphaComponent(0.25)
            case .visual, .visualLine: MacTheme.Color.warning.withAlphaComponent(0.3)
            }
        vimBadgeWrap.layer?.backgroundColor = background.cgColor
    }

    func setDestination(_ text: String) {
        destinationLabel.stringValue = text
    }

    func setModelTitle(_ text: String) {
        modelPill.title = text
    }

    /// Nil hides the pill outright: a model with no effort levels has no effort control, and a
    /// pill reading "no effort control" spent a permanent slot in the chrome explaining the
    /// absence of something nobody asked for.
    func setEffortTitle(_ text: String?) {
        effortPill.isHidden = text == nil
        effortPill.title = text ?? ""
    }

    /// The pills wear the same colours the list chips do — the family's hue on the model, the
    /// tier's heat on the effort — and nil hands the pill back to the toolkit's own tint.
    func setModelTint(_ color: NSColor?) {
        modelPill.contentTintColor = color
    }

    func setEffortTint(_ color: NSColor?) {
        effortPill.contentTintColor = color
    }

    /// Ultracode is a power, not a level, so its pill does not take a heat: the word itself is
    /// set letter by letter from the shared rainbow, the same stops the aura travels.
    func setEffortRainbow(_ word: String) {
        let font = effortPill.font ?? MacTheme.Ramp.font(.panelFootnote)
        let text = NSMutableAttributedString()
        for (index, letter) in word.enumerated() {
            text.append(
                NSAttributedString(
                    string: String(letter),
                    attributes: [
                        .font: font,
                        .foregroundColor: MacTheme.Color.modelRainbowLetter(
                            index, of: word.count),
                    ]))
        }
        effortPill.attributedTitle = text
    }

    func setAttachShown(_ shown: Bool) {
        attachButton.isHidden = !shown
    }

    func setStopShown(_ shown: Bool) {
        stopButton.isHidden = !shown
    }

    func popUpCommandMenu() {
        commandPill.popUpMenu()
    }

    @objc private func stopTapped() {
        onStop?()
    }
}

/// A pill that pops a menu built fresh on every click, so the rows always describe the session
/// as it is now rather than as it was when the pill was made.
@MainActor
final class MenuPill: NSButton {
    var rows: (() -> [PillsRow.MenuRow])?

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        controlSize = .small
        font = MacTheme.Ramp.font(.panelFootnote)
        target = self
        action = #selector(popUp)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func popUpMenu() {
        popUp()
    }

    @objc private func popUp() {
        let rows = rows?() ?? []
        guard !rows.isEmpty else { return }
        let menu = NSMenu()
        for row in rows {
            let item = ClosureMenuItem(title: row.title, handler: row.handler)
            if let subtitle = row.subtitle { item.subtitle = subtitle }
            item.state = row.checked ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }
}

/// A target-action shim so a menu built from data can hand a closure to AppKit.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() {
        handler()
    }
}
