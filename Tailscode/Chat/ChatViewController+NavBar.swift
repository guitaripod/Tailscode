import TailscodeCore
import CodingAgentKit
import UIKit

extension ChatViewController {
    func configureFAB() {
        fab.configuration = fabConfiguration(reading: JumpReading.read(
            rowsNow: 0, rowsAtDeparture: nil, needsYou: false))
        fab.accessibilityLabel = JumpReading.read(
            rowsNow: 0, rowsAtDeparture: nil, needsYou: false).spoken
        fab.translatesAutoresizingMaskIntoConstraints = false
        fab.isHidden = true
        fab.addTarget(self, action: #selector(fabTapped), for: .touchUpInside)
        view.addSubview(fab)
        NSLayoutConstraint.activate([
            fab.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
            fab.bottomAnchor.constraint(
                equalTo: composerAccessories.topAnchor, constant: -Self.fabClearance),
            fab.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            fab.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    /// How far the jump control stands above the facts row, or the composer when the row has
    /// nothing to say, so it never covers a chip.
    private static let fabClearance: CGFloat = 10

    private func fabConfiguration(reading: JumpReading) -> UIButton.Configuration {
        var config = Theme.Glass.buttonConfiguration()
        config.cornerStyle = .capsule
        let glyph = UIImage(
            systemName: "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold))
        config.image = reading.tone == .quiet
            ? glyph : glyph?.withTintColor(reading.tone.color, renderingMode: .alwaysOriginal)
        config.baseForegroundColor = Theme.Color.label
        if let label = reading.label {
            var title = AttributedString(label)
            title.font = Theme.Ramp.font(ChatChrome.chipRole)
            config.attributedTitle = title
            config.imagePadding = CGFloat(ChatChrome.chip(on: .touch).iconGap)
            config.contentInsets = NSDirectionalEdgeInsets(
                top: 0, leading: Theme.Spacing.m, bottom: 0, trailing: Theme.Spacing.m)
        }
        return config
    }

    /// What the jump control says: a bare arrow when the reader is simply up the page, and a
    /// capsule with words when something waits at the end or rows arrived while they were away.
    private func refreshJumpReading() {
        let reading = JumpReading.read(
            rowsNow: orderedIDs.count, rowsAtDeparture: rowsAtDeparture,
            needsYou: pendingPermission != nil || pendingQuestion != nil)
        guard reading != shownJump else { return }
        shownJump = reading
        fab.configuration = fabConfiguration(reading: reading)
        fab.accessibilityLabel = reading.spoken
    }

    /// The header holds the conversation's name for the whole of a turn, with the one status line
    /// under it: what is happening is a second line, never a replacement for the name.
    func configureNavTitleView() {
        navTitleLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(
            for: .systemFont(ofSize: 17, weight: .semibold))
        navTitleLabel.adjustsFontForContentSizeCategory = true
        navTitleLabel.textColor = Theme.Color.label
        navTitleLabel.textAlignment = .center
        navTitleLabel.lineBreakMode = .byTruncatingTail
        navTitleLabel.text = title
        navTitleLabel.isAccessibilityElement = false
        navStatusLabel.font = Theme.Ramp.font(.panelDetail)
        navStatusLabel.adjustsFontForContentSizeCategory = true
        navStatusLabel.textColor = Theme.Color.secondaryLabel
        navStatusLabel.lineBreakMode = .byTruncatingTail
        navStatusRow.addArrangedSubview(navBadge)
        navStatusRow.addArrangedSubview(navStatusLabel)
        navStatusRow.axis = .horizontal
        navStatusRow.spacing = Theme.Spacing.xs
        navStatusRow.alignment = .center
        navStatusRow.isHidden = true
        navTitleStack.addArrangedSubview(navTitleLabel)
        navTitleStack.addArrangedSubview(navStatusRow)
        navTitleStack.axis = .vertical
        navTitleStack.alignment = .center
        navTitleStack.spacing = 0
        navTitleStack.isAccessibilityElement = true
        navTitleStack.accessibilityTraits = .header
        navigationItem.titleView = navTitleStack
        refreshNavAccessibility()
    }

    func refreshNavAccessibility() {
        navTitleStack.accessibilityLabel = navTitleLabel.text
        navTitleStack.accessibilityValue = navStatusRow.isHidden ? nil : navStatusLabel.text
    }
}

extension ChatViewController {
    @objc private func fabTapped() {
        userScrolledUp = false
        scrollToBottom(animated: true)
        Theme.Haptics.tap()
    }

    func syncFAB() {
        let show = !isNearBottom() && orderedIDs.count > 1
        if show {
            if rowsAtDeparture == nil { rowsAtDeparture = orderedIDs.count }
        } else {
            rowsAtDeparture = nil
        }
        refreshJumpReading()
        guard fab.isHidden == show else { return }
        if UIAccessibility.isReduceMotionEnabled {
            fab.isHidden = !show
            fab.alpha = 1
            fab.transform = .identity
            return
        }
        if show {
            fab.isHidden = false
            fab.alpha = 0
            fab.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
            UIView.animate(
                withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.5
            ) {
                self.fab.alpha = 1
                self.fab.transform = .identity
            }
        } else {
            UIView.animate(
                withDuration: 0.15,
                animations: {
                    self.fab.alpha = 0
                    self.fab.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
                },
                completion: { _ in
                    self.fab.isHidden = true
                    self.fab.transform = .identity
                    self.fab.alpha = 1
                })
        }
    }
}

extension ChatViewController {
    /// The nav status states the same facts as the desktop status bands — phase, running tool,
    /// clock — derived through the shared `StatusFacts` rather than a private phase guess. The
    /// richer iOS wording for the busy line still comes from `liveLine`, but the phase and
    /// color are the facts'.
    /// - Parameter messagesMoved: whether the transcript itself changed. When it did not — a
    ///   redraw of what this device is holding — the two readings that walk every message in the
    ///   conversation would return exactly what they returned last time, at the same cost.
    func updateNavStatus(
        for state: ConversationState, messagesMoved: Bool = true, facts given: StatusFacts? = nil
    ) {
        turnStartedAt = StatusFacts.turnStart(in: state)
        if messagesMoved, given == nil { refreshTranscriptFill(state) }
        let facts = given ?? makeFacts(state)
        updateContextChip(range: facts.range)
        updateRangeChips(facts.range)
        rangeSheet?.refresh()
        updateSpendChip()
        updateBackgroundChip(for: facts)
        refreshAgentsChip()
        var text: String?
        var color = Theme.Color.secondaryLabel
        switch facts.phase {
        case .idle, .offline, .connecting:
            text = nil
        case .working:
            text = ChatViewModel.liveLine(for: state)
        case .background(let tasks):
            text = ActivityKind.inBackground(tasks: tasks).title
        case .stalled(let tasks):
            text = ActivityKind.stalled(tasks: tasks).title
        case .compacting:
            text = String(localized: "Compacting…")
        case .awaitingApproval:
            text = ChatViewModel.liveLine(for: state)
            color = Theme.Color.warning
        case .awaitingAnswer:
            text = String(localized: "Waiting for your answer")
            color = Theme.Color.warning
        case .reconnecting:
            text = String(localized: "Reconnecting…")
            color = Theme.Color.warning
        case .failed:
            text = nil
        }
        if let phase = text, facts.queued > 0 {
            text = phase + " · " + ActivityKind.queued(facts.queued).bandWord
        }
        guard let text else {
            navBadge.activity = nil
            navStatusRow.isHidden = true
            navStatusLabel.text = nil
            refreshNavAccessibility()
            turnStartedAt = nil
            elapsedTicker?.cancel()
            elapsedTicker = nil
            lastStatusPhaseText = ""
            return
        }
        if viewModel.isBusy, elapsedTicker == nil {
            elapsedTicker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    self?.renderNavStatus()
                }
            }
        }
        navStatusRow.isHidden = false
        navBadge.activity = facts.activity
        if lastStatusPhaseText != text {
            lastStatusPhaseText = text
            UIView.transition(
                with: navStatusLabel, duration: 0.2, options: .transitionCrossDissolve
            ) {
                self.navStatusLabel.textColor = color
                self.renderNavStatus()
            }
        } else {
            navStatusLabel.textColor = color
            renderNavStatus()
        }
    }

    /// The transcript's own size and what it has cost, read again because the messages moved.
    func refreshTranscriptFill(_ state: ConversationState) {
        countedMessages = state.messages.count
        transcriptFill = ContextFill.read(
            messages: state.messages, sessionModel: viewModel.session.model,
            sessionProvider: viewModel.session.modelProviderID, catalog: availableModels)
        spendReading.note(messages: state.messages, for: viewModel.session.id)
    }
}

extension ChatViewController {
    private func renderNavStatus() {
        refreshBrainCells()
        guard !lastStatusPhaseText.isEmpty else { return }
        guard let started = turnStartedAt else {
            setNavStatusText(lastStatusPhaseText)
            return
        }
        let seconds = Int(Date().timeIntervalSince(started))
        let elapsed = seconds >= 60
            ? String(format: "%d:%02d", seconds / 60, seconds % 60) : "\(seconds)s"
        setNavStatusText(
            seconds >= 3 ? "\(lastStatusPhaseText) · \(elapsed)" : lastStatusPhaseText)
    }

    private func setNavStatusText(_ text: String) {
        guard navStatusLabel.text != text else { return }
        navStatusLabel.text = text
        refreshNavAccessibility()
    }
}

extension ChatViewController {
    func updateNavControls() {
        navigationItem.rightBarButtonItems = [overflowBarButton()] + callController.barItems
        refreshAttachmentGating()
        refreshDial()
        composer.ultracodeEffort = viewModel.currentEffort
        composer.ultracodeInFlight = viewModel.ultracodeInFlight
    }
}
