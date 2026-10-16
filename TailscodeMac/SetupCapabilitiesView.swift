import AppKit
import CodingAgentKit
import TailscodeCore

/// A server's Capabilities section in the servers window: a row for each capability the machine
/// reports as available, with its state and one line, and a click that opens the checklist behind it;
/// one quiet invitation for a machine whose gateway does not answer; nothing for a capability the
/// machine can never do. The rows are Core's `SetupCapabilityRow`, built from the same snapshots the
/// checklist reads, and the desk polls for them only between `start()` and `stop()`, which the window
/// brackets with its own being on screen.
@MainActor
final class SetupCapabilitiesView: NSStackView {
    var openChecklist: ((SetupTarget) -> Void)?

    private let targets: [SetupTarget]
    private let lifetime = PaneLifetime()
    private var snapshots: [SetupTarget: SetupSnapshot] = [:]
    private var rows: [SetupCapabilityRow] = []
    private var following = false
    private let header = MacDialogs.sectionHeader(SetupCapabilityRow.sectionTitle)

    init(profileURL: URL) {
        targets = SetupTargets.targets(forProfileURL: profileURL)
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = MacTheme.Spacing.xs
        isHidden = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func start() {
        guard !following else { return }
        following = true
        for target in targets {
            MacSetupGate.desk.follow(target, lifetime: lifetime) { [weak self] snapshot in
                Task { @MainActor in self?.receive(snapshot) }
            }
        }
    }

    func stop() {
        guard following else { return }
        following = false
        lifetime.cancelAll()
    }

    private func receive(_ snapshot: SetupSnapshot) {
        guard following else { return }
        snapshots[snapshot.target] = snapshot
        let next = targets.compactMap { target in snapshots[target].flatMap { SetupCapabilityRow.row(for: $0) } }
        guard next != rows else { return }
        rows = next
        render()
    }

    private func render() {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        isHidden = rows.isEmpty
        guard !rows.isEmpty else { return }
        header.font = MacTheme.Ramp.font(.sectionLabel)
        addArrangedSubview(header)
        for row in rows {
            guard case .checklist(let target) = row.opens else { continue }
            addArrangedSubview(rowView(row, target: target))
        }
    }

    private func rowView(_ row: SetupCapabilityRow, target: SetupTarget) -> NSView {
        let badge = ActivityBadgeView(pointSize: 14)
        badge.show(row.icon, spoken: row.chip)
        let title = NSTextField(labelWithString: row.title)
        title.font = MacTheme.Ramp.font(.panelLabel)
        title.textColor = MacTheme.Color.label
        let detail = MacDialogs.detailLabel(row.line, wraps: true)
        let words = NSStackView(views: [title, detail])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 1
        let chip = NSTextField(labelWithString: row.chip)
        chip.font = MacTheme.Ramp.font(.panelFootnote)
        chip.textColor = row.quiet ? MacTheme.Color.secondaryLabel : row.tone.color
        let line = NSStackView(views: [badge, words, NSView(), chip])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = MacTheme.Spacing.s
        let button = CapabilityRowButton { [weak self] in self?.openChecklist?(target) }
        button.setAccessibilityLabel(row.spoken)
        button.translatesAutoresizingMaskIntoConstraints = false
        line.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 6),
            line.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -6),
            line.topAnchor.constraint(equalTo: button.topAnchor, constant: 4),
            line.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -4),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])
        return button
    }
}

/// A row that is one big button: the whole line is the target, because the chip and the sentence
/// beside the title are part of what is being opened.
@MainActor
private final class CapabilityRowButton: NSButton {
    private let onClick: @MainActor () -> Void

    init(onClick: @escaping @MainActor () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        action = #selector(fire)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { onClick() }
}
