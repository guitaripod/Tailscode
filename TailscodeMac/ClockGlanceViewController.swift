import AppKit
import TailscodeCore

/// What the chip shows when the pointer rests on it: the date, a strip of daylight for every place
/// the person watches, the machines and how far their clocks are from this one, and the quota window
/// that reopens next. Every word is Core's reading; this arranges them. A view at the root says when
/// the pointer is on the card so the popover is not pulled away while it is read.
@MainActor
final class ClockGlanceViewController: NSViewController {
    static let width: CGFloat = 380

    var onHover: ((Bool) -> Void)?

    private var reading: WorldClockReading
    private let column = NSStackView()

    init(reading: WorldClockReading) {
        self.reading = reading
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var contentWidth: CGFloat { Self.width * MacTheme.UIScale.factor }

    private var inset: CGFloat { MacTheme.Spacing.l }

    override func loadView() {
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.edgeInsets = NSEdgeInsets(
            top: inset, left: inset, bottom: MacTheme.Spacing.m, right: inset)
        column.translatesAutoresizingMaskIntoConstraints = false
        build()
        let host = HoverHost()
        host.onHover = { [weak self] inside in self?.onHover?(inside) }
        host.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: host.topAnchor),
            column.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            column.widthAnchor.constraint(equalToConstant: contentWidth),
        ])
        view = host
    }

    func apply(_ next: WorldClockReading) {
        guard next != reading else { return }
        reading = next
        guard isViewLoaded else { return }
        build()
    }

    private var rowWidth: CGFloat { contentWidth - 2 * inset }

    private func build() {
        column.arrangedSubviews.forEach {
            column.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        add(header())
        add(
            RowKit.label(
                reading.zoneLine, font: MacTheme.Ramp.font(.panelDetail),
                color: MacTheme.Color.secondaryLabel),
            before: 2)
        add(sectionLabel(Localized.text("AROUND THE WORLD")), before: MacTheme.Spacing.m + 2)
        for (index, zone) in reading.zones.enumerated() {
            add(zoneRow(zone), before: index == 0 ? MacTheme.Spacing.xs : 2)
        }
        if !reading.suggestions.isEmpty { add(suggestions(), before: MacTheme.Spacing.s) }
        if !reading.machines.isEmpty {
            add(rule(), before: MacTheme.Spacing.m)
            add(sectionLabel(Localized.text("MACHINES")), before: MacTheme.Spacing.m)
            for (index, machine) in reading.machines.enumerated() {
                add(machineRow(machine), before: index == 0 ? MacTheme.Spacing.xs : 2)
            }
            if let warning = reading.skewWarning {
                add(warningCard(warning), before: MacTheme.Spacing.xs + 2)
            }
        }
        if !reading.resets.isEmpty {
            add(rule(), before: MacTheme.Spacing.m)
            for (index, reset) in reading.resets.enumerated() {
                add(resetRow(reset), before: index == 0 ? MacTheme.Spacing.m : MacTheme.Spacing.s)
            }
        }
        add(rule(), before: MacTheme.Spacing.m)
        add(
            RowKit.label(
                reading.hint, font: MacTheme.Ramp.font(.panelFootnote),
                color: MacTheme.Color.secondaryLabel),
            before: MacTheme.Spacing.s)
        let flexible = NSView()
        flexible.translatesAutoresizingMaskIntoConstraints = false
        flexible.setContentHuggingPriority(.init(1), for: .vertical)
        flexible.setContentCompressionResistancePriority(.init(1), for: .vertical)
        add(flexible)
    }

    private func add(_ view: NSView, before gap: CGFloat = 0) {
        if let last = column.arrangedSubviews.last { column.setCustomSpacing(gap, after: last) }
        column.addArrangedSubview(view)
        view.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
    }

    private func header() -> NSView {
        let date = RowKit.label(
            reading.dateLine, font: MacTheme.Ramp.font(.panelTitle), color: MacTheme.Color.label)
        let week = RowKit.label(
            reading.weekLine, font: MacTheme.Ramp.font(.panelDetail),
            color: MacTheme.Color.secondaryLabel)
        week.setContentHuggingPriority(.required, for: .horizontal)
        week.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [date, RowKit.spacer(), week])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = MacTheme.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func sectionLabel(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = NSAttributedString(
            string: text,
            attributes: MacTheme.Ramp.attributes(.sectionLabel, color: MacTheme.Color.secondaryLabel))
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityRole(.staticText)
        return label
    }

    private func rule() -> NSView {
        let rule = TintView(fill: { MacTheme.Color.separator })
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return rule
    }

    private func zoneRow(_ zone: WorldClockReading.Zone) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let name = RowKit.label(
            zone.name, font: MacTheme.Ramp.font(.rowTitleStrong), color: MacTheme.Color.label)
        let detail = RowKit.label(
            zone.detail, font: MacTheme.Ramp.font(.panelFootnote),
            color: MacTheme.Color.secondaryLabel)
        let names = FillingStack(topDown: true, stretches: false)
        names.addArrangedSubview(name)
        names.addArrangedSubview(detail)
        names.spacing = 0
        let strip = DaylightStripView()
        strip.apply(bar: zone.bar, marker: zone.marker, isUp: zone.isUp)
        let time = RowKit.label(
            zone.time, font: MacTheme.Ramp.font(.statusLine), color: MacTheme.Color.label)
        time.alignment = .right
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        time.setContentHuggingPriority(.required, for: .horizontal)
        for view in [names, strip, time] { row.addSubview(view) }
        let nameWidth = names.widthAnchor.constraint(equalToConstant: 112 * MacTheme.UIScale.factor)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 38),
            names.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            names.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            nameWidth,
            strip.leadingAnchor.constraint(equalTo: names.trailingAnchor, constant: MacTheme.Spacing.m),
            strip.trailingAnchor.constraint(equalTo: time.leadingAnchor, constant: -MacTheme.Spacing.m),
            strip.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            time.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            time.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            time.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
        ])
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.group)
        row.setAccessibilityLabel("\(zone.name), \(zone.detail), \(zone.time)")
        return row
    }

    private func suggestions() -> NSView {
        let label = RowKit.label(
            Localized.text("Add a city"), font: MacTheme.Ramp.font(.panelDetail),
            color: MacTheme.Color.secondaryLabel)
        var chips: [NSView] = []
        for city in reading.suggestions {
            let chip = SymbolChip()
            chip.text = city.name
            chip.onTap = { WorldClockStore.update { $0.pin(city.id) } }
            chip.setAccessibilityLabel(Localized.text("Add %@", city.name))
            chips.append(chip)
        }
        chips.append(RowKit.spacer())
        let row = NSStackView(views: chips)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MacTheme.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        let column = FillingStack(topDown: true)
        column.addArrangedSubview(label)
        column.addArrangedSubview(row)
        column.spacing = MacTheme.Spacing.xs + 2
        return column
    }

    private func machineRow(_ machine: MachineClockReading) -> NSView {
        let tone = Self.color(machine.tone)
        let dot = TintView(fill: { tone }, radius: 3.5)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
        ])
        let name = RowKit.label(
            machine.name, font: MacTheme.Ramp.font(.rowTitleStrong), color: MacTheme.Color.label)
        let status = RowKit.label(
            machine.status, font: MacTheme.Ramp.font(.panelDetail), color: tone)
        status.setContentCompressionResistancePriority(.required, for: .horizontal)
        status.setContentHuggingPriority(.required, for: .horizontal)
        let time = RowKit.label(
            machine.time ?? "", font: MacTheme.Ramp.font(.statusLine), color: MacTheme.Color.label)
        time.alignment = .right
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        time.setContentHuggingPriority(.required, for: .horizontal)
        time.widthAnchor.constraint(greaterThanOrEqualToConstant: 62).isActive = true
        let row = NSStackView(views: [dot, name, RowKit.spacer(), status, time])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MacTheme.Spacing.s + 2
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 30).isActive = true
        row.setAccessibilityElement(true)
        row.setAccessibilityLabel("\(machine.name), \(machine.status)")
        return row
    }

    private func warningCard(_ text: String) -> NSView {
        let card = TintView(
            fill: { MacTheme.Color.warning.withAlphaComponent(0.1) }, radius: 10)
        let label = RowKit.wrapping(
            text, font: MacTheme.Ramp.font(.panelDetail), color: MacTheme.Color.warning)
        label.preferredMaxLayoutWidth = rowWidth - 20
        card.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
        ])
        return card
    }

    private func resetRow(_ reset: ClockReset) -> NSView {
        let tile = TintView(fill: { MacTheme.Color.info.withAlphaComponent(0.16) }, radius: 8)
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        icon.contentTintColor = MacTheme.Color.info
        icon.imageScaling = .scaleNone
        icon.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(icon)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 28),
            tile.heightAnchor.constraint(equalToConstant: 28),
            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])
        let title = RowKit.label(
            reset.title(viewer: MeridianFeed.shared.viewer, style: MeridianFeed.shared.preferences.style),
            font: MacTheme.Ramp.font(.rowTitleStrong), color: MacTheme.Color.label)
        let note = RowKit.label(
            reset.note, font: MacTheme.Ramp.font(.panelFootnote),
            color: MacTheme.Color.secondaryLabel)
        let text = FillingStack(topDown: true, stretches: false)
        [title, note].forEach { text.addArrangedSubview($0) }
        text.spacing = 0
        let countdown = RowKit.label(
            reset.countdown(now: MeridianFeed.shared.now), font: MacTheme.Ramp.font(.metricValue),
            color: MacTheme.Color.accent)
        countdown.setContentCompressionResistancePriority(.required, for: .horizontal)
        countdown.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [tile, text, RowKit.spacer(), countdown])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MacTheme.Spacing.m
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setAccessibilityElement(true)
        row.setAccessibilityLabel("\(title.stringValue), \(countdown.stringValue)")
        return row
    }

    static func color(_ tone: ClockTone) -> NSColor {
        switch tone {
        case .ok: return MacTheme.Color.accent
        case .warn: return MacTheme.Color.warning
        case .quiet: return MacTheme.Color.secondaryLabel
        }
    }

    private final class HoverHost: NSView {
        var onHover: ((Bool) -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(
                NSTrackingArea(
                    rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                    owner: self))
        }

        override func mouseEntered(with event: NSEvent) { onHover?(true) }

        override func mouseExited(with event: NSEvent) { onHover?(false) }
    }
}
