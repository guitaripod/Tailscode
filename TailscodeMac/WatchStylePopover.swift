import AppKit
import TailscodeCore

/// Where the wall's style lives on this Mac: one JSON text under one key in this machine's
/// preferences, never in iCloud, so each screen keeps the wall the way it is watched. A change is
/// posted for the walls that are open.
@MainActor
enum MacWatchStyleStore {
    static let key = "agentsWatchStyle"
    static let didChange = Notification.Name("tailscode.mac.agentsWatchStyle.didChange")

    nonisolated(unsafe) private static let defaults = UserDefaults.standard

    static var current: WallStyle { WallStyle.decoded(defaults.string(forKey: key)) }

    static func save(_ style: WallStyle) {
        guard style != current else { return }
        defaults.set(style.encoded(), forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func forget() {
        defaults.removeObject(forKey: key)
    }
}

/// The wall's Style control: every setting the wall has, in the places the person reads them, changed
/// live. It holds no copy of the style that outlives a press: each control writes the whole new style
/// through `onChange` and the wall redraws underneath.
@MainActor
final class WatchStylePopover: NSViewController {
    private struct Switch {
        let title: String
        let path: WritableKeyPath<WallStyle, Bool>
    }

    private let preset = NSSegmentedControl()
    private let customNote = NSTextField(labelWithString: "")
    private let effects = NSSegmentedControl()
    private let field = NSPopUpButton(frame: .zero, pullsDown: false)
    private let dim = NSPopUpButton(frame: .zero, pullsDown: false)
    private let night = NSPopUpButton(frame: .zero, pullsDown: false)
    private let keepAwake = NSPopUpButton(frame: .zero, pullsDown: false)
    private let approvals = NSPopUpButton(frame: .zero, pullsDown: false)
    private var switches: [(NSSwitch, WritableKeyPath<WallStyle, Bool>)] = []
    private(set) var style: WallStyle
    var onChange: ((WallStyle) -> Void)?

    init(style: WallStyle) {
        self.style = style
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static var moves: [Switch] {
        [
            Switch(title: Localized.text("A step lands"), path: \.moves.steps),
            Switch(title: Localized.text("A sub-agent starts or ends"), path: \.moves.agents),
            Switch(title: Localized.text("A turn ends"), path: \.moves.endings),
            Switch(title: Localized.text("It needs you"), path: \.moves.asks),
            Switch(title: Localized.text("Something fails"), path: \.moves.failures),
            Switch(title: Localized.text("It retries or goes quiet"), path: \.moves.retries),
            Switch(title: Localized.text("Context is compacted"), path: \.moves.compaction),
            Switch(title: Localized.text("A session arrives or leaves"), path: \.moves.arrivals),
        ]
    }

    private static var wallParts: [Switch] {
        [
            Switch(title: Localized.text("Clock"), path: \.showsClock),
            Switch(title: Localized.text("Last hour"), path: \.showsHour),
            Switch(title: Localized.text("Recent and also running"), path: \.showsRails),
            Switch(title: Localized.text("Sub-agent tiles"), path: \.showsSquads),
        ]
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

        configureSegments(
            preset, [Localized.text("Studio"), Localized.text("Night desk"), Localized.text("Showcase")],
            action: #selector(presetChosen))
        configureSegments(
            effects, [Localized.text("Off"), Localized.text("Subtle"), Localized.text("Lively")],
            action: #selector(effectsChosen))
        customNote.font = MacTheme.Ramp.font(.panelFootnote)
        customNote.textColor = MacTheme.Color.secondaryLabel
        fill(
            field, [Localized.text("Motes"), Localized.text("Currents"), Localized.text("Aurora"), Localized.text("None")],
            action: #selector(fieldChosen))
        fill(
            dim, WallStyle.dimChoices.map(Self.dimTitle), action: #selector(dimChosen))
        fill(
            night, [Localized.text("Off"), Localized.text("22:00–07:00"), Localized.text("Always")],
            action: #selector(nightChosen))
        fill(
            keepAwake,
            [Localized.text("While charging"), Localized.text("Always"), Localized.text("Never")],
            action: #selector(keepAwakeChosen))
        fill(
            approvals, [Localized.text("Hold to approve"), Localized.text("Open the chat")],
            action: #selector(approvalsChosen))

        column.addArrangedSubview(row(Localized.text("Preset"), preset))
        column.addArrangedSubview(customNote)
        column.addArrangedSubview(row(Localized.text("Effects"), effects))
        column.addArrangedSubview(row(Localized.text("Field"), field))
        column.addArrangedSubview(toggle(Localized.text("Light from tiles"), \.light))
        column.addArrangedSubview(heading(Localized.text("Events that move")))
        for item in Self.moves { column.addArrangedSubview(toggle(item.title, item.path)) }
        column.addArrangedSubview(heading(Localized.text("Screen")))
        column.addArrangedSubview(row(Localized.text("Dim when calm for"), dim))
        column.addArrangedSubview(row(Localized.text("Night"), night))
        column.addArrangedSubview(row(Localized.text("Keep the screen on"), keepAwake))
        column.addArrangedSubview(toggle(Localized.text("Still"), \.still))
        column.addArrangedSubview(heading(Localized.text("On the wall")))
        for item in Self.wallParts { column.addArrangedSubview(toggle(item.title, item.path)) }
        column.addArrangedSubview(heading(Localized.text("Approve from the wall")))
        column.addArrangedSubview(row(Localized.text("Approve from the wall"), approvals))

        let root = NSView()
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.topAnchor.constraint(equalTo: root.topAnchor),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            column.widthAnchor.constraint(equalToConstant: 340),
        ])
        view = root
        sync()
    }

    static func dimTitle(_ interval: TimeInterval?) -> String {
        guard let interval else { return Localized.text("Never") }
        return Localized.text("%d min", Int((interval / 60).rounded()))
    }

    private func configureSegments(_ control: NSSegmentedControl, _ titles: [String], action: Selector) {
        control.segmentCount = titles.count
        for (index, title) in titles.enumerated() { control.setLabel(title, forSegment: index) }
        control.trackingMode = .selectOne
        control.segmentStyle = .rounded
        control.target = self
        control.action = action
        control.translatesAutoresizingMaskIntoConstraints = false
    }

    private func fill(_ popup: NSPopUpButton, _ titles: [String], action: Selector) {
        popup.removeAllItems()
        popup.addItems(withTitles: titles)
        popup.target = self
        popup.action = action
        popup.translatesAutoresizingMaskIntoConstraints = false
    }

    private func heading(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = MacTheme.Ramp.font(.panelFootnote)
        label.textColor = MacTheme.Color.secondaryLabel
        return label
    }

    private func row(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = MacTheme.Ramp.font(.control)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [label, control])
        stack.orientation = .horizontal
        stack.distribution = .fill
        stack.spacing = MacTheme.Spacing.s
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: 340 - 2 * MacTheme.Spacing.l).isActive = true
        return stack
    }

    private func toggle(_ title: String, _ path: WritableKeyPath<WallStyle, Bool>) -> NSView {
        let control = NSSwitch()
        control.controlSize = .small
        control.target = self
        control.action = #selector(switched(_:))
        control.setAccessibilityLabel(title)
        switches.append((control, path))
        return row(title, control)
    }

    func refresh(_ next: WallStyle) {
        style = next
        sync()
    }

    private func sync() {
        guard isViewLoaded else { return }
        let presets: [WallStyle.Preset] = [.studio, .nightDesk, .showcase]
        preset.selectedSegment = presets.firstIndex(of: style.preset) ?? -1
        customNote.stringValue = style.preset == .custom ? Localized.text("Custom") : ""
        customNote.isHidden = style.preset != .custom
        effects.selectedSegment = WallStyle.Effects.allCases.firstIndex(of: style.effects) ?? 1
        field.selectItem(at: WallStyle.Field.allCases.firstIndex(of: style.field) ?? 0)
        dim.selectItem(at: WallStyle.dimChoices.firstIndex { $0 == style.dimAfter } ?? 1)
        night.selectItem(at: WallStyle.Night.allCases.firstIndex(of: style.night) ?? 0)
        keepAwake.selectItem(at: WallStyle.KeepAwake.allCases.firstIndex(of: style.keepAwake) ?? 0)
        approvals.selectItem(at: WallStyle.Approvals.allCases.firstIndex(of: style.approvals) ?? 0)
        for (control, path) in switches { control.state = style[keyPath: path] ? .on : .off }
    }

    private func apply(_ next: WallStyle) {
        guard next != style else { return }
        style = next
        sync()
        onChange?(next)
    }

    @objc private func presetChosen() {
        let presets: [WallStyle.Preset] = [.studio, .nightDesk, .showcase]
        guard presets.indices.contains(preset.selectedSegment) else { return }
        apply(WallStyle.preset(presets[preset.selectedSegment]))
    }

    @objc private func effectsChosen() {
        let all = WallStyle.Effects.allCases
        guard all.indices.contains(effects.selectedSegment) else { return }
        apply(style.with { $0.effects = all[effects.selectedSegment] })
    }

    @objc private func fieldChosen() {
        let all = WallStyle.Field.allCases
        guard all.indices.contains(field.indexOfSelectedItem) else { return }
        apply(style.with { $0.field = all[field.indexOfSelectedItem] })
    }

    @objc private func dimChosen() {
        let all = WallStyle.dimChoices
        guard all.indices.contains(dim.indexOfSelectedItem) else { return }
        apply(style.with { $0.dimAfter = all[dim.indexOfSelectedItem] })
    }

    @objc private func nightChosen() {
        let all = WallStyle.Night.allCases
        guard all.indices.contains(night.indexOfSelectedItem) else { return }
        apply(style.with { $0.night = all[night.indexOfSelectedItem] })
    }

    @objc private func keepAwakeChosen() {
        let all = WallStyle.KeepAwake.allCases
        guard all.indices.contains(keepAwake.indexOfSelectedItem) else { return }
        apply(style.with { $0.keepAwake = all[keepAwake.indexOfSelectedItem] })
    }

    @objc private func approvalsChosen() {
        let all = WallStyle.Approvals.allCases
        guard all.indices.contains(approvals.indexOfSelectedItem) else { return }
        apply(style.with { $0.approvals = all[approvals.indexOfSelectedItem] })
    }

    @objc private func switched(_ sender: NSSwitch) {
        guard let path = switches.first(where: { $0.0 === sender })?.1 else { return }
        apply(style.with { $0[keyPath: path] = sender.state == .on })
    }
}
