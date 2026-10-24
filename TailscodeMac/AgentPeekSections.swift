import AppKit
import CodingAgentKit
import TailscodeCore

extension AgentPeekViewController {
    func addFacts(_ facts: AgentFacts, subject: AgentsSubject, now: Date) {
        if let doing = facts.doing, !doing.isEmpty {
            column.addArrangedSubview(sectionLabel(Localized.text("Doing now")))
            column.addArrangedSubview(doingBlock(doing, object: facts.object))
        }
        if !facts.steps.isEmpty {
            column.addArrangedSubview(sectionLabel(Localized.text("Last steps")))
            for step in facts.steps {
                let row = AgentsStepRow()
                row.configure(step, now: now)
                stepRows.append(row)
                column.addArrangedSubview(row)
            }
        }
        if !facts.children.isEmpty {
            column.addArrangedSubview(sectionLabel(Localized.text("Agents in this chat")))
            for child in facts.children {
                let line = AgentsChildLineView()
                line.configure(child, now: now)
                childRows.append(line)
                column.addArrangedSubview(line)
            }
        }
        if !facts.touched.isEmpty {
            column.addArrangedSubview(sectionLabel(Localized.text("Files touched")))
            let flow = AgentsChipFlow()
            flow.titles = facts.touched
            column.addArrangedSubview(flow)
        }
        addMeters(facts)
    }

    private func addMeters(_ facts: AgentFacts) {
        var rows: [NSView] = []
        if let fill = facts.fill {
            let bar = AgentsMeterBar()
            bar.fraction = fill.fraction ?? 0
            bar.tint =
                switch fill.tone {
                case .quiet: MacTheme.Color.success
                case .attention: MacTheme.Color.warning
                case .danger: MacTheme.Color.danger
                }
            rows.append(meter(Localized.text("Context"), value: fill.badge, bar: bar))
        }
        if let tokens = facts.tokens {
            rows.append(meter(Localized.text("Tokens this turn"), value: StatusFacts.tokens(tokens), bar: nil))
        }
        if let cost = facts.cost {
            rows.append(
                meter(
                    Localized.text("API estimate"),
                    value: Localized.text("≈ %@", SessionSpend.money(cost)), bar: nil))
        }
        if let strip = pulse(facts) { rows.append(strip) }
        guard !rows.isEmpty else { return }
        column.addArrangedSubview(sectionLabel(Localized.text("Meters")))
        for row in rows { column.addArrangedSubview(row) }
    }

    private func pulse(_ facts: AgentFacts) -> NSView? {
        guard facts.isRunning else { return nil }
        let strip = AgentBeatStripView()
        strip.beat = facts.beat
        strip.tone = .live
        let title = caption(Localized.text("Pulse"))
        let row = NSStackView(views: [title, strip])
        row.orientation = .horizontal
        row.distribution = .fill
        row.alignment = .centerY
        row.spacing = MacTheme.Spacing.m
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func meter(_ name: String, value: String, bar: AgentsMeterBar?) -> NSView {
        let title = caption(name)
        let figure = NSTextField(labelWithString: value)
        figure.font = .monospacedDigitSystemFont(
            ofSize: MacTheme.Ramp.font(.rowDetail).pointSize, weight: .regular)
        figure.textColor = MacTheme.Color.label
        figure.alignment = .right
        figure.translatesAutoresizingMaskIntoConstraints = false
        figure.setContentHuggingPriority(.required, for: .horizontal)
        figure.setContentCompressionResistancePriority(.required, for: .horizontal)
        var views: [NSView] = [title]
        if let bar {
            bar.setContentHuggingPriority(.defaultLow, for: .horizontal)
            bar.widthAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
            views.append(bar)
        } else {
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            views.append(spacer)
        }
        views.append(figure)
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.distribution = .fill
        row.alignment = .centerY
        row.spacing = MacTheme.Spacing.m
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setAccessibilityElement(true)
        row.setAccessibilityLabel("\(name), \(value)")
        return row
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = MacTheme.Ramp.font(.rowDetail)
        label.textColor = MacTheme.Color.secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    func sectionLabel(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = MacTheme.Ramp.font(.sectionLabel)
        label.textColor = MacTheme.Color.secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor),
            label.topAnchor.constraint(equalTo: holder.topAnchor, constant: MacTheme.Spacing.m),
            label.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
        ])
        holder.setAccessibilityElement(true)
        holder.setAccessibilityRole(.staticText)
        holder.setAccessibilityLabel(text)
        return holder
    }

    private func doingBlock(_ doing: String, object: AgentObject?) -> NSView {
        let large = NSTextField(wrappingLabelWithString: doing)
        large.font = MacTheme.Ramp.font(.headline)
        large.maximumNumberOfLines = 0
        large.isSelectable = true
        large.translatesAutoresizingMaskIntoConstraints = false
        large.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = FillingStack(topDown: false, stretches: true)
        stack.spacing = MacTheme.Spacing.xs
        stack.addArrangedSubview(large)
        guard let object, !object.text.isEmpty else { return stack }
        let mono = NSTextField(wrappingLabelWithString: object.text)
        mono.font = MacTheme.Ramp.font(.code)
        mono.textColor = MacTheme.Color.secondaryLabel
        mono.maximumNumberOfLines = 0
        mono.lineBreakMode = object.kind == .path ? .byCharWrapping : .byWordWrapping
        mono.isSelectable = true
        mono.translatesAutoresizingMaskIntoConstraints = false
        mono.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if object.kind == .command {
            let box = NSView()
            box.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(mono)
            RowKit.ground(behind: box, fill: MacTheme.Color.codeBackground, stroke: nil, radius: MacTheme.Radius.control)
            let inset = MacTheme.Spacing.s
            NSLayoutConstraint.activate([
                mono.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: inset),
                mono.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -inset),
                mono.topAnchor.constraint(equalTo: box.topAnchor, constant: inset),
                mono.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -inset),
            ])
            mono.textColor = MacTheme.Color.label
            stack.addArrangedSubview(box)
        } else {
            stack.addArrangedSubview(mono)
        }
        if object.added != nil || object.removed != nil {
            stack.addArrangedSubview(changeChips(added: object.added, removed: object.removed))
        }
        return stack
    }

    private func changeChips(added: Int?, removed: Int?) -> NSView {
        func chip(_ text: String, ink: NSColor, ground: NSColor) -> NSView {
            let label = NSTextField(labelWithString: text)
            label.font = .monospacedDigitSystemFont(
                ofSize: MacTheme.Ramp.font(.rowMeta).pointSize, weight: .medium)
            label.textColor = ink
            label.translatesAutoresizingMaskIntoConstraints = false
            let box = CapsuleView()
            box.translatesAutoresizingMaskIntoConstraints = false
            box.wantsLayer = true
            box.layer?.backgroundColor = ground.cgColor
            box.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
                label.topAnchor.constraint(equalTo: box.topAnchor, constant: 2),
                label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2),
            ])
            box.setAccessibilityElement(true)
            box.setAccessibilityLabel(text)
            return box
        }
        var chips: [NSView] = []
        if let added {
            chips.append(chip("+\(added)", ink: MacTheme.Color.success, ground: MacTheme.Color.diffBackground(.added)))
        }
        if let removed {
            chips.append(chip("−\(removed)", ink: MacTheme.Color.danger, ground: MacTheme.Color.diffBackground(.removed)))
        }
        let row = NSStackView(views: chips)
        row.orientation = .horizontal
        row.spacing = MacTheme.Spacing.xs
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    func note(_ text: String, tint: NSColor) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = MacTheme.Ramp.font(.rowDetail)
        label.textColor = tint
        label.maximumNumberOfLines = 0
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func watchButton(_ subject: AgentsSubject) -> NSView {
        let button = RowKit.ActionButton(title: Localized.text("Watch this one")) { [weak self] in
            self?.onWatch?(subject.key)
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }
}
