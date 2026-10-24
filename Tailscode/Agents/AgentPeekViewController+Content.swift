import MidgarCore
import TailscodeCore
import UIKit

extension AgentPeekViewController {
    struct Signature: Equatable {
        var facts: AgentFacts?
        var row: AgentRow?
        var watchRequested: Bool
        var busy: Bool
        var large: Bool
    }

    func buildSkeleton() {
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        content.axis = .vertical
        content.spacing = Theme.Spacing.xl - 4
        content.isLayoutMarginsRelativeArrangement = true
        content.layoutMargins = UIEdgeInsets(
            top: Theme.Spacing.l, left: Theme.Spacing.l + 4, bottom: Theme.Spacing.xl,
            right: Theme.Spacing.l + 4)
        content.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(content)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            content.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
        buildHeader()
        buildButtons()
        buildNudgeBar()
    }

    private func buildHeader() {
        badge.translatesAutoresizingMaskIntoConstraints = false
        badgeBox.addSubview(badge)
        NSLayoutConstraint.activate([
            badgeBox.widthAnchor.constraint(equalToConstant: 26),
            badge.centerXAnchor.constraint(equalTo: badgeBox.centerXAnchor),
            badge.topAnchor.constraint(equalTo: badgeBox.topAnchor, constant: 3),
        ])
        titleLabel.font = Theme.Ramp.font(.paneHeadline)
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 0
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.text = target.title
        elapsedLabel.font = Theme.Ramp.font(.rowStamp)
        elapsedLabel.textColor = Theme.Color.secondaryLabel
        elapsedLabel.adjustsFontForContentSizeCategory = true
        elapsedLabel.setContentHuggingPriority(.required, for: .horizontal)
        elapsedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        metaLabel.numberOfLines = 0
        metaLabel.adjustsFontForContentSizeCategory = true
    }

    private func buildButtons() {
        statusLabel.font = Theme.Ramp.font(.panelDetail)
        statusLabel.numberOfLines = 0
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.isHidden = true

        openButton.addAction(UIAction { [weak self] _ in self?.openChat() }, for: .touchUpInside)
        watchButton.addAction(
            UIAction { [weak self] _ in self?.requestWatch() }, for: .touchUpInside)
        stopButton.configuration?.baseForegroundColor = Theme.Color.danger
        stopButton.addAction(UIAction { [weak self] _ in self?.confirmStop() }, for: .touchUpInside)
        nudgeButton.addAction(UIAction { [weak self] _ in self?.showNudge() }, for: .touchUpInside)
        secondaryRow.axis = .horizontal
        secondaryRow.distribution = .fillEqually
        secondaryRow.spacing = Theme.Spacing.m
        [stopButton, nudgeButton].forEach(secondaryRow.addArrangedSubview)
    }

    func render() {
        guard isViewLoaded else { return }
        let signature = Signature(
            facts: facts, row: row, watchRequested: watchRequested, busy: isBusy,
            large: AgentsLayout.isLarge(traitCollection))
        guard signature != lastSignature else { return }
        lastSignature = signature
        timed.removeAll()
        renderHeader()

        var parts: [UIView] = [headerView()]
        if row?.isAway == true { parts.append(awayLine()) }
        if let ask = facts?.ask { parts.append(askSection(ask)) }
        if let doing = doingSection() { parts.append(doing) }
        if facts == nil { parts.append(listedSection()) }
        if let facts {
            if !facts.steps.isEmpty { parts.append(stepsSection(facts.steps)) }
            if !facts.children.isEmpty { parts.append(agentsSection(facts.children)) }
            if !facts.touched.isEmpty {
                let flow = AgentsFlowView()
                flow.setChips(facts.touched)
                parts.append(AgentsPeekStyle.section(String(localized: "Files touched"), [flow]))
            }
            if let meters = metersRow(facts) { parts.append(meters) }
            if facts.isRunning { parts.append(pulseSection(facts.beat)) }
        }
        parts.append(statusLabel)
        parts.append(openButton)
        parts.append(secondaryRow)

        content.arrangedSubviews.forEach {
            content.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        parts.forEach(content.addArrangedSubview)
        content.setCustomSpacing(Theme.Spacing.m, after: statusLabel)
        content.setCustomSpacing(Theme.Spacing.s, after: openButton)
        updateButtons()
    }

    private func headerView() -> UIView {
        let titleRow = UIStackView(arrangedSubviews: [badgeBox, titleLabel, elapsedLabel])
        titleRow.axis = AgentsLayout.isLarge(traitCollection) ? .vertical : .horizontal
        titleRow.alignment = AgentsLayout.isLarge(traitCollection) ? .leading : .firstBaseline
        titleRow.spacing = Theme.Spacing.s
        let spacer = UIView()
        spacer.widthAnchor.constraint(equalToConstant: 26 + Theme.Spacing.s).isActive = true
        let metaRow = UIStackView(arrangedSubviews: [spacer, metaLabel])
        metaRow.axis = .horizontal
        let column = UIStackView(arrangedSubviews: [titleRow, metaRow])
        column.axis = .vertical
        column.spacing = Theme.Spacing.xs
        return column
    }

    private func renderHeader() {
        let icon = headerIcon()
        badge.show(icon, spoken: AgentGlyph.spoken(tone: icon.tone, motion: icon.motion, background: isBackground))
        let chip = ModelBadge.chip(
            selection: facts?.model, effort: facts?.effort,
            catalog: ModelCatalogStore.cached(target.profileID)) ?? target.chip
        let pieces: [(text: String, color: UIColor)] = [(target.machine, Theme.Color.secondaryLabel)]
        metaLabel.attributedText = ModelChipText.line(
            chip: chip, pieces: pieces, size: Theme.Ramp.font(.panelFootnote).pointSize)
        let started = facts?.startedAt ?? row?.startedAt
        let setElapsed: (Date) -> Void = { [weak self] now in
            self?.elapsedLabel.text = AgentsWords.elapsed(since: started, now: now)
            self?.elapsedLabel.isHidden = started == nil
        }
        setElapsed(Date())
        timed.append(setElapsed)
    }

    private var isBackground: Bool {
        if case .background? = facts?.phase { return true }
        return false
    }

    private func headerIcon() -> ActivityIcon {
        guard let facts else {
            guard let row else { return AgentGlyph.icon(tone: .quiet, motion: .still) }
            return AgentGlyph.icon(tone: row.tone, motion: row.motion)
        }
        switch facts.phase {
        case .working: return AgentGlyph.icon(tone: .live, motion: .working)
        case .needsYou: return AgentGlyph.icon(tone: .attention, motion: .attention)
        case .retrying: return AgentGlyph.icon(tone: .live, motion: .turning)
        case .background(_, let stalled):
            return AgentGlyph.icon(
                tone: stalled ? .attention : .live, motion: stalled ? .still : .working, background: true)
        case .idle: return AgentGlyph.icon(tone: .quiet, motion: .still)
        }
    }

    private func awayLine() -> UIView {
        let label = UILabel()
        label.font = Theme.Ramp.font(.panelDetail)
        label.textColor = Theme.Color.warning
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        let heard = hub.lastHeard(target.profileID)
        label.text = AgentsWords.lastSeen(heard, now: Date())
        timed.append { [weak label] now in label?.text = AgentsWords.lastSeen(heard, now: now) }
        return label
    }

    private func askSection(_ ask: AgentAsk) -> UIView {
        let lead = UILabel()
        lead.font = Theme.Ramp.font(.panelDetail)
        lead.textColor = Theme.Color.label
        lead.numberOfLines = 0
        lead.adjustsFontForContentSizeCategory = true
        lead.text = ask.lead
        var body: [UIView] = [lead]
        if let object = ask.object, !object.isEmpty {
            let block = AgentsCommandView()
            block.show(object)
            body.append(block)
        }
        return AgentsPeekStyle.section(String(localized: "Waiting on you"), body)
    }

    private func doingSection() -> UIView? {
        let words = facts == nil ? row?.line : facts?.doing
        guard let words, !words.isEmpty else { return nil }
        let doing = UILabel()
        doing.font = Theme.Font.display(.title2, weight: .bold)
        doing.textColor = Theme.Color.label
        doing.numberOfLines = 0
        doing.adjustsFontForContentSizeCategory = true
        doing.text = words
        var body: [UIView] = [doing]
        if let object = facts?.object { body.append(objectView(object)) }
        return AgentsPeekStyle.section(String(localized: "Doing now"), body)
    }

    private func objectView(_ object: AgentObject) -> UIView {
        switch object.kind {
        case .command:
            let block = AgentsCommandView()
            block.show(object.text)
            return block
        case .path:
            return pathView(object)
        }
    }

    private func pathView(_ object: AgentObject) -> UIView {
        let label = UILabel()
        label.font = Theme.Ramp.font(.code)
        label.textColor = Theme.Color.label
        label.numberOfLines = 0
        label.lineBreakMode = .byCharWrapping
        label.adjustsFontForContentSizeCategory = true
        label.text = object.text.replacingOccurrences(of: "/", with: "/\u{200B}")
        label.accessibilityLabel = object.text
        var row: [UIView] = [label]
        if object.added != nil || object.removed != nil {
            row.append(diffChip(added: object.added, removed: object.removed))
        }
        let stack = UIStackView(arrangedSubviews: row)
        stack.axis = AgentsLayout.isLarge(traitCollection) ? .vertical : .horizontal
        stack.alignment = AgentsLayout.isLarge(traitCollection) ? .leading : .firstBaseline
        stack.spacing = Theme.Spacing.s
        stack.translatesAutoresizingMaskIntoConstraints = false
        let box = UIView()
        box.backgroundColor = Theme.Color.codeBackground
        box.layer.cornerRadius = Theme.Radius.control
        box.layer.cornerCurve = .continuous
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: Theme.Spacing.s + 2),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -(Theme.Spacing.s + 2)),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: Theme.Spacing.m),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -Theme.Spacing.m),
        ])
        return box
    }

    private func diffChip(added: Int?, removed: Int?) -> UILabel {
        let font = Theme.Ramp.font(.code)
        let text = NSMutableAttributedString()
        var spoken: [String] = []
        if let added {
            text.append(
                NSAttributedString(
                    string: "+\(added)", attributes: [.font: font, .foregroundColor: Theme.Color.success]))
            spoken.append(String(localized: "\(added) lines added"))
        }
        if let removed {
            if text.length > 0 { text.append(NSAttributedString(string: " ", attributes: [.font: font])) }
            text.append(
                NSAttributedString(
                    string: "\u{2212}\(removed)",
                    attributes: [.font: font, .foregroundColor: Theme.Color.danger]))
            spoken.append(String(localized: "\(removed) lines removed"))
        }
        let label = UILabel()
        label.attributedText = text
        label.adjustsFontForContentSizeCategory = true
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.accessibilityLabel = spoken.joined(separator: ", ")
        return label
    }

    private func listedSection() -> UIView {
        var body: [UIView] = []
        let note = UILabel()
        note.font = Theme.Ramp.font(.panelDetail)
        note.textColor = Theme.Color.secondaryLabel
        note.numberOfLines = 0
        note.adjustsFontForContentSizeCategory = true
        note.text = watchRequested
            ? String(localized: "Starting to watch this one…") : String(localized: "Listed only, not watched")
        body.append(note)
        if let row, row.listedAgents > row.children.count {
            let agents = UILabel()
            agents.font = Theme.Ramp.font(.rowDetail)
            agents.textColor = Theme.Color.label
            agents.numberOfLines = 0
            agents.adjustsFontForContentSizeCategory = true
            agents.text = AgentsWords.agents(row.listedAgents)
            body.append(agents)
        }
        if row != nil, row?.isAway != true {
            watchButton.isEnabled = !watchRequested
            body.append(watchButton)
        }
        let stack = UIStackView(arrangedSubviews: body)
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.s
        stack.alignment = .fill
        return stack
    }

    private func stepsSection(_ steps: [AgentStep]) -> UIView {
        let rows = steps.enumerated().map { index, step in AgentsStepRow(step, isNewest: index == 0) }
        let list = UIStackView(arrangedSubviews: rows)
        list.axis = .vertical
        list.spacing = Theme.Spacing.m - 2
        timed.append { now in rows.forEach { $0.tick(now: now) } }
        let caption = AgentsPeekStyle.caption(String(localized: "When this device first saw each step"))
        return AgentsPeekStyle.section(String(localized: "Last steps"), [caption, list])
    }

    private func agentsSection(_ children: [AgentChild]) -> UIView {
        let lines = children.map { child -> AgentChildLineView in
            let line = AgentChildLineView()
            line.configure(child, now: Date())
            return line
        }
        timed.append { now in lines.forEach { $0.tick(now: now) } }
        let list = UIStackView(arrangedSubviews: lines)
        list.axis = .vertical
        list.spacing = Theme.Spacing.m
        return AgentsPeekStyle.section(String(localized: "Agents in this chat"), [list])
    }

    private func pulseSection(_ beat: [Int]) -> UIView {
        let strip = AgentBeatStripView()
        strip.beat = beat
        strip.isAccessibilityElement = true
        strip.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [strip, UIView()])
        row.axis = .horizontal
        return AgentsPeekStyle.section(String(localized: "Last minute"), [row])
    }

    private func metersRow(_ facts: AgentFacts) -> UIView? {
        var tiles: [UIView] = []
        if let fill = facts.fill {
            let percent = fill.percent
            let value =
                percent.map { "\($0)%" } ?? ((fill.isEstimate ? "~" : "") + StatusFacts.tokens(fill.used))
            let caption =
                percent == nil
                ? String(localized: "tokens in context") : String(localized: "of context")
            let spoken =
                percent.map { String(localized: "\($0) percent of the context window is used") }
                ?? String(localized: "\(StatusFacts.tokens(fill.used)) tokens in context")
            let tint: UIColor
            switch fill.tone {
            case .quiet: tint = Theme.Color.success
            case .attention: tint = Theme.Color.warning
            case .danger: tint = Theme.Color.danger
            }
            tiles.append(
                AgentsMeterTile(
                    value: value, caption: caption, ring: fill.fraction.map { ($0, tint) },
                    spoken: spoken))
        }
        if let tokens = facts.tokens {
            tiles.append(
                AgentsMeterTile(
                    value: StatusFacts.tokens(tokens), caption: String(localized: "tokens this turn"),
                    spoken: String(localized: "\(StatusFacts.tokens(tokens)) tokens this turn")))
        }
        if let cost = facts.cost {
            tiles.append(
                AgentsMeterTile(
                    value: AgentsWords.cost(cost), caption: String(localized: "API estimate"),
                    spoken: String(localized: "About \(cost.formatted(.currency(code: "USD"))), an API estimate, not a bill")))
        }
        guard !tiles.isEmpty else { return nil }
        let row = UIStackView(arrangedSubviews: tiles)
        row.axis = AgentsLayout.isLarge(traitCollection) ? .vertical : .horizontal
        row.distribution = .fillEqually
        row.spacing = Theme.Spacing.s
        return row
    }
}
