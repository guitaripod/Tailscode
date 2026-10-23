import AppKit
import os
import CodingAgentKit
import TailscodeCore

extension TranscriptViewController {
    /// Re-renders every row at the current type scale: the builder's memo and the per-session
    /// row snapshots hold rendering baked at the old size, so both are dropped before the
    /// rebuild.
    /// The pane's own opaque surfaces, which are `CGColor` in a layer and so keep whatever colour
    /// they were given until they are given another. `cgColor` is resolved against the appearance
    /// current while it is asked, which in a callback is the face the pane just left, so the
    /// new face is made current around every colour.
    func applyPaneColours() {
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = MacTheme.Color.canvas.cgColor
        }
    }

    /// The pane restyled for a light/dark flip nobody chose inside the app. `applyPaneColours` is
    /// reached from the theme notification, which a change of *system* appearance never posts — and
    /// a `CGColor` in a layer, a rendering in a memo and a row built under the old face all keep the
    /// colours they were born with, which is white prose on a white pane behind dark chrome. So the
    /// flip takes the road a theme change takes: drop what was baked, rebuild what was drawn.
    func adoptEffectiveAppearance() {
        guard isViewLoaded else { return }
        MacMarkdown.invalidate()
        applyPaneColours()
        applyUIScale()
    }

    /// The labels the pane owns itself, restated. Every row is rebuilt from the ramp on this road,
    /// but a font and an `NSColor` already handed to a label are baked — so without this a pane
    /// showing a placeholder is the one surface a scale step and a theme change both miss entirely.
    private func restyleOwnChrome() {
        emptyLabel.font = MacTheme.Ramp.font(.panelLabel)
        emptyLabel.textColor = MacTheme.Color.secondaryLabel
        identityLabel.font = MacTheme.Ramp.font(.paneIdentity)
        identityLabel.textColor = MacTheme.Color.onGlassSecondary
        identityAlso.font = MacTheme.Ramp.font(.paneIdentity)
        earlierButton.font = MacTheme.Ramp.font(.panelFootnote)
        earlierButton.contentTintColor = MacTheme.Color.secondaryLabel
        jumpChip.restyle()
        calls.restyle()
    }

    func applyUIScale() {
        // Every row is rebuilt at a new size, so a canvas holding a place in the old ones is
        // holding a place that no longer exists.
        keptPages = [:]
        keptOrder = []
        releaseFreshCanvas(animated: false)
        rowBuilder.invalidate()
        MacMarkdown.invalidate()
        Self.codeMemo = nil
        sessionRows = [:]
        sessionRowOrder = []
        pendingSignature = "\u{0}"
        restyleOwnChrome()
        composer.applyPreferences()
        guard let state = lastState else { return }
        tearDownAllRows()
        placeholderShown = true
        let tail = rowTailMessages
        let messages =
            state.messages.count > tail ? Array(state.messages.suffix(tail)) : state.messages
        apply(state: state, rows: buildRows(messages, state: state))
    }

    /// An empty pane asks which server rather than captioning itself. The chooser owns the
    /// canvas until something fills it, and every re-render keeps the person's place.
    func showChooser(_ model: PaneChooser) {
        calls.leave(because: "the pane asked which server")
        chooser = model
        hideEmptyState()
        composer.isHidden = true
        chooserView.isHidden = false
        renderChooser()
    }

    /// One line describing the chooser, for the headless selftest: the question, then the rows
    /// with the cursor marked.
    var chooserSummary: String? {
        guard let chooser else { return nil }
        let rows = chooser.rows.enumerated().map { index, row in
            "\(index == chooser.cursor ? "*" : "")\(row.title)"
        }
        return "\(chooser.heading) [\(rows.joined(separator: " | "))]"
    }

    /// A fresh listing under an open chooser: the same question, answered with what is true now.
    /// - Parameter watch: what is on among the channels this device follows, when the check has
    ///   landed since the question was asked; nil leaves the watch row saying what it already said.
    func restateChooser(
        servers: [PaneChooserServer], entries: [SessionEntry], watch: WatchSummary?
    ) {
        guard let current = chooser else { return }
        var next = current.restated(servers: servers, entries: entries)
        next.watchSummary = watch ?? next.watchSummary
        chooser = next
        renderChooser()
    }

    /// The chooser answers the keyboard before the shortcut table does — but only for the keys it
    /// binds, so the ctrl+w verbs, ? and everything else still reach the window.
    func handleChooserChord(_ chord: KeyChord) -> Bool {
        guard var model = chooser, let command = PaneChooser.command(for: chord) else {
            return false
        }
        let (handled, action) = model.handle(command)
        guard handled else { return false }
        chooser = model
        if let action {
            onChooserAction?(action)
        } else {
            renderChooser()
        }
        return true
    }

    private func renderChooser() {
        guard let model = chooser else { return }
        chooserView.render(model) { [weak self] index in self?.activateChooserRow(index) }
    }

    private func activateChooserRow(_ index: Int) {
        guard var model = chooser, model.rows.indices.contains(index) else { return }
        model.focus(index)
        let outcome = model.activate(model.rows[index].action)
        chooser = model
        if let outcome {
            onChooserAction?(outcome)
        } else {
            renderChooser()
        }
    }

    func dismissChooser() {
        chooser = nil
        chooserView.isHidden = true
    }

    /// A flow of chips is as wide as the pane lets it be, so a wide window holds the starters on a
    /// line or two and a narrow one breaks them, rather than a width chosen once for every window.
    func fillWidth(of view: NSView, in container: NSView) -> NSLayoutConstraint {
        let width = view.widthAnchor.constraint(
            equalTo: container.widthAnchor, constant: -MacTheme.Spacing.xl * 2)
        width.priority = .init(740)
        return width
    }

    func hideEmptyState() {
        emptyLabel.isHidden = true
        starters.isHidden = true
        welcomeView.isHidden = true
    }

    /// The pane with no conversation and no server to hold one draws Core's welcome instead of a
    /// caption. A pane that holds a chat or is asking which server keeps what it has: the hub asks
    /// for the welcome only when nothing else is the pane's business.
    func showWelcome(_ welcome: EmptyWelcome, onAction: @escaping (EmptyWelcome.Intent) -> Void) {
        guard entry == nil, chooser == nil else { return }
        hideEmptyState()
        welcomeView.onAction = onAction
        welcomeView.show(welcome)
        welcomeView.isHidden = false
    }

    func clearWelcome() {
        guard !welcomeView.isHidden else { return }
        welcomeView.isHidden = true
        emptyLabel.isHidden = entry != nil || chooser != nil
    }

    var welcomeButtonTitles: [String] {
        guard !welcomeView.isHidden else { return [] }
        return welcomeView.buttonTitles
    }

    /// The empty conversation's headline and the four ways Core offers to begin one, as chips the
    /// pointer can press. A starter fills the composer and takes the keyboard to it, and sends
    /// nothing: the words are a suggestion until somebody reads them and presses Return.
    func configureStarters() {
        let headline = RowKit.label(
            ChatSuggestion.headline, font: MacTheme.Ramp.font(.panelLabel),
            color: MacTheme.Color.secondaryLabel)
        headline.alignment = .center
        let chips = ChatSuggestion.all.map { suggestion -> NSView in
            let chip = SymbolChip()
            chip.symbol = suggestion.symbol
            chip.text = suggestion.title
            chip.toolTip = suggestion.prompt
            chip.setAccessibilityLabel(suggestion.title)
            chip.setAccessibilityHelp(suggestion.prompt)
            let words = suggestion.prompt
            chip.onTap = { [weak self] in
                guard let composer = self?.composer else { return }
                if !composer.fillIfEmpty(words) { composer.insertText(words) }
                composer.takeFocus()
            }
            return chip
        }
        starterFlow.set(chips)
        starters.orientation = .vertical
        starters.alignment = .centerX
        starters.spacing = MacTheme.Spacing.m
        starters.setViews([headline, starterFlow], in: .center)
        starterFlow.widthAnchor.constraint(equalTo: starters.widthAnchor).isActive = true
        starters.translatesAutoresizingMaskIntoConstraints = false
        starters.isHidden = true
    }

    func showPlaceholder(_ text: String, starting: Bool = false) {
        dismissChooser()
        hoverBar.dismiss()
        railController.dismiss()
        if placeholderShown, currentPlaceholder == text { return }
        currentPlaceholder = text
        tearDownAllRows()
        placeholderShown = true
        pendingReveal = false
        canvas.alphaValue = 1
        emptyLabel.stringValue = text
        emptyLabel.isHidden = starting
        starters.isHidden = !starting
    }
}
