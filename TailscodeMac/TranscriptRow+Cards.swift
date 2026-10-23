import AppKit
import CodingAgentKit
import TailscodeCore

extension TranscriptRow {
    /// What the answer above it took: one quiet strip of symbol-and-number, each figure carrying
    /// the sentence behind it as a tooltip. It is deliberately the dimmest thing in the transcript
    /// — a reader who turned it on wants the numbers available, not competing with the answer they
    /// describe — and it holds perfectly still, like every settled state in this app.
    @MainActor
    static func responseStats(_ stats: ResponseStats) -> NSView {
        let strip = NSStackView()
        strip.orientation = .horizontal
        strip.alignment = .firstBaseline
        strip.spacing = MacTheme.Spacing.m
        strip.translatesAutoresizingMaskIntoConstraints = false
        for fact in stats.facts {
            let cell = NSStackView()
            cell.orientation = .horizontal
            cell.alignment = .firstBaseline
            cell.spacing = 3
            if let symbol = NSImage(
                systemSymbolName: fact.symbol, accessibilityDescription: fact.label)
            {
                let icon = NSImageView(image: symbol)
                icon.contentTintColor = MacTheme.Color.tertiaryLabel
                icon.symbolConfiguration = NSImage.SymbolConfiguration(
                    pointSize: MacTheme.Ramp.font(.responseStat).pointSize, weight: .regular)
                cell.addArrangedSubview(icon)
            }
            cell.addArrangedSubview(
                RowKit.label(
                    fact.value, font: MacTheme.Ramp.font(.responseStat),
                    color: MacTheme.Color.tertiaryLabel))
            cell.toolTip = "\(fact.label) — \(fact.detail)"
            strip.addArrangedSubview(cell)
        }
        strip.setAccessibilityElement(true)
        strip.setAccessibilityRole(.group)
        strip.setAccessibilityLabel(stats.spoken)
        return strip
    }

    /// A board of alternatives, offered rather than described. The letters are on the card
    /// because they are what the reader picks by, and the card is the way in — a design reachable
    /// only through a file path is a design nobody looks at.
    @MainActor
    static func designBoard(_ sighting: DesignSighting, context: TranscriptContext) -> NSView
    {
        var board: DesignBoard?
        if case .board(let directory) = sighting.source {
            if let manifest = context.designBoards[directory] {
                board = DesignBoard(directory: directory, manifest: manifest)
            } else {
                context.requestDesignBoard?(directory)
            }
        }
        let reading = DesignCardReading.make(sighting: sighting, board: board)
        let card = RowKit.card(
            symbol: reading.symbol, title: reading.title, detail: reading.detail,
            tint: MacTheme.Color.info)
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.group)
        card.setAccessibilityLabel("\(reading.title). \(reading.detail)")
        if !reading.letters.isEmpty {
            let strip = NSStackView()
            strip.orientation = .horizontal
            strip.spacing = MacTheme.Spacing.xs
            strip.setHuggingPriority(.defaultHigh, for: .horizontal)
            for letter in reading.letters {
                strip.addArrangedSubview(
                    RowKit.label(
                        letter, font: MacTheme.Ramp.font(.badge), color: MacTheme.Color.accent))
            }
            card.addArrangedSubview(strip)
        }
        let open = context.openDesign
        let source = sighting.source
        card.addArrangedSubview(RowKit.linkButton(reading.action) { open?(source) })
        return card
    }

    /// A turn that finished having said nothing. It is a card rather than a prose row because
    /// there is no prose — the transcript would otherwise show the question and then simply the
    /// next thing, with the whole turn missing.
    @MainActor
    static func answerless(_ turn: AnswerlessTurn, context: TranscriptContext) -> NSView {
        let card = RowKit.card(
            symbol: AnswerlessTurn.symbol, title: turn.title, detail: turn.detail,
            tint: AnswerlessTurn.tone.color)
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.group)
        card.setAccessibilityLabel(turn.spoken)
        guard turn.offersRemedy else { return card }
        let askAgain = context.askAgain
        let words = turn.prompt
        card.addArrangedSubview(RowKit.remedyButton(turn.action) { askAgain?(words) })
        return card
    }

    /// A turn that stopped with an error. The server's own words are quoted in the code role rather
    /// than set as prose, because a failure that reads like an answer is skimmed past, and the one
    /// action sends the question that started the turn again.
    @MainActor
    static func failedTurn(_ turn: FailedTurn, context: TranscriptContext) -> NSView {
        let card = RowKit.card(
            symbol: FailedTurn.symbol, title: turn.title, detail: turn.detail,
            tint: FailedTurn.tone.color)
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.group)
        card.setAccessibilityLabel(turn.spoken)
        card.addArrangedSubview(
            RowKit.wrapping(
                turn.reason, font: MacTheme.Ramp.font(.code), color: MacTheme.Color.secondaryLabel))
        guard turn.offersRemedy else { return card }
        let askAgain = context.askAgain
        let words = turn.prompt
        card.addArrangedSubview(RowKit.remedyButton(turn.action) { askAgain?(words) })
        return card
    }

    /// A turn the machine was pulled out from under. The account of what the work had already done
    /// is the substance of it — a person decides between continuing and starting over on whether
    /// anything on that machine changed — so it is drawn as lines rather than as a sentence.
    ///
    /// Every word on it is Core's, including the one nobody was being told: while the card stands
    /// undecided the server will not carry this session on by itself, so a card left alone quietly
    /// turns unattended continuation off for the whole conversation.
    @MainActor
    static func interruptedTurn(_ turn: InterruptedTurn, context: TranscriptContext)
        -> NSView
    {
        let card = RowKit.card(
            symbol: InterruptedTurn.symbol, title: turn.title, detail: turn.detail,
            tint: InterruptedTurn.tone.color)
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.group)
        card.setAccessibilityLabel(turn.spoken)
        if !turn.prompt.isEmpty {
            card.insertArrangedSubview(
                RowKit.wrapping(
                    turn.prompt, font: MacTheme.Ramp.font(.prompt), color: MacTheme.Color.label),
                at: 1)
        }
        for line in turn.progress {
            card.addArrangedSubview(
                RowKit.wrapping(
                    "· \(line)", font: MacTheme.Ramp.font(.rowNote),
                    color: MacTheme.Color.secondaryLabel))
        }
        if let queued = turn.queuedLine {
            card.addArrangedSubview(
                RowKit.wrapping(
                    queued, font: MacTheme.Ramp.font(.rowNote),
                    color: MacTheme.Color.secondaryLabel))
        }
        if let cost = turn.cost {
            card.addArrangedSubview(
                RowKit.wrapping(
                    cost, font: MacTheme.Ramp.font(.rowNote), color: InterruptedTurn.tone.color))
        }
        if let buttons = interruptedActions(turn, context: context) {
            card.addArrangedSubview(buttons)
        }
        return card
    }

    /// The two things a cut-off turn offers, or nothing at all once the server has picked it back
    /// up — the work is going again there, so "let it go" would mean forgetting the record rather
    /// than stopping anything, and a button that cannot do what its words say is worse than no
    /// button.
    ///
    /// A press already in flight keeps both, wearing Core's in-flight wording and refusing a second
    /// press, because seeing what was asked for is the whole point of acknowledging it — a button
    /// that vanished under the pointer is a press nobody can tell landed.
    @MainActor
    private static func interruptedActions(_ turn: InterruptedTurn, context: TranscriptContext)
        -> NSStackView?
    {
        guard !turn.isResumed else { return nil }
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = MacTheme.Spacing.m
        if let resume = context.resumeInterrupted {
            buttons.addArrangedSubview(
                RowKit.linkButton(turn.resumeTitle, enabled: turn.acceptsPress) { resume() })
        }
        if let dismiss = context.dismissInterrupted {
            buttons.addArrangedSubview(
                RowKit.linkButton(turn.dismissTitle, enabled: turn.acceptsPress) { dismiss() })
        }
        return buttons.arrangedSubviews.isEmpty ? nil : buttons
    }

    /// A line the server wrote for the reader: small, tinted by its tone, holding perfectly still.
    /// Never a bubble and never a card, because a note is a fact about the conversation rather
    /// than something anybody said.
    @MainActor
    static func noteLine(_ line: TranscriptNoteLine) -> NSView {
        Self.quietLine(symbol: line.symbol, text: line.text, tone: line.tone, spoken: line.spoken)
    }

    /// The placeholder an undo wears from the press until the server answers, standing exactly
    /// where the banner will land so the person sees the same slot fill in rather than a card
    /// appearing out of nowhere once the request finally lands.
    @MainActor
    static func revertPending() -> NSView {
        Self.quietLine(
            symbol: RevertBanner.symbol, text: RevertReading.undoingTitle, tone: RevertBanner.tone,
            spoken: RevertReading.undoingTitle)
    }

    /// The one shape a quiet, still line across the transcript is built from: a note, and the
    /// placeholder an undo wears while it is in flight. It is the seam's own divider, because a
    /// fact about the conversation is not something anybody said.
    @MainActor
    private static func quietLine(symbol: String, text: String, tone: ActivityTone, spoken: String)
        -> NSView
    {
        SeamLineView(symbol: symbol, text: text, tint: tone.color, spoken: spoken, onPress: nil)
    }

    /// The rail under a run of prose: its model asks about the first addresses now, and the pane
    /// owns the plate a press or a resting pointer opens.
    @MainActor
    static func linkRail(_ urls: [String], key: String, context: TranscriptContext)
        -> NSView
    {
        let model = LinkRailModel(urls: urls, source: context.linkSource)
        let line = LinkRailLine(
            key: key, model: model, height: CGFloat(ChatLayout.metrics.railRowHeight))
        let toast = context.toast
        line.onActivate = { [weak line, weak context] viaKeyboard in
            guard let line else { return }
            context?.activateRail?(line, viaKeyboard)
        }
        line.menuActions = (
            copyAll: {
                RowKit.copyToClipboard(model.reading.copyAllText)
                toast?(Localized.text("Copied"))
            },
            openAll: {
                for address in model.urls { if let url = URL(string: address) { NSWorkspace.shared.open(url) } }
            }
        )
        if model.opensDirectly, let address = URL(string: model.urls[0]) {
            let text = model.urls[0]
            line.directActions = (
                open: { NSWorkspace.shared.open(address) },
                copy: {
                    RowKit.copyToClipboard(text)
                    toast?(Localized.text("Copied"))
                }
            )
        }
        model.begin(opened: false)
        return line
    }

    /// The card docked while the turn waits on its provider: the reason it gave, the attempt line
    /// that carries the countdown in tabular figures so it never jitters, and the remedy it named,
    /// where it named one. No other action belongs here: stopping the turn stays where it is.
    @MainActor
    static func providerRetry(_ card: ProviderRetryCard) -> NSView {
        let view = RowKit.card(
            symbol: ProviderRetryCard.symbol, title: card.title, detail: card.reason,
            tint: ProviderRetryCard.tone.color)
        view.addArrangedSubview(
            RowKit.label(
                card.attemptLine, font: MacTheme.Ramp.font(.rowStamp),
                color: ProviderRetryCard.tone.color))
        if let remedy = card.remedy {
            view.addArrangedSubview(
                RowKit.label(
                    remedy.title, font: MacTheme.Ramp.font(.rowTitleStrong),
                    color: MacTheme.Color.label))
            view.addArrangedSubview(
                RowKit.wrapping(
                    remedy.message, font: MacTheme.Ramp.font(.cardBody),
                    color: MacTheme.Color.secondaryLabel))
            if let link = remedy.link {
                view.addArrangedSubview(RowKit.linkButton(remedy.label) { NSWorkspace.shared.open(link) })
            }
        }
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel(card.spoken)
        return view
    }

    /// How many set-aside files a revert banner names before it pages the rest: enough that most
    /// reverts show every file, narrow enough that the card never grows past the turn it stands in
    /// for.
    private static let revertFileLimit = 6

    /// The banner where the set-aside messages were: how many were wound back, which files came
    /// back and how, and Restore one press away for as long as the revert stands.
    @MainActor
    static func revertBanner(
        _ banner: RevertBanner, restoring: Bool, context: TranscriptContext
    ) -> NSView {
        let card = RowKit.card(
            symbol: RevertBanner.symbol, title: banner.title, detail: banner.detail,
            tint: RevertBanner.tone.color)
        let paged = banner.files(upTo: Self.revertFileLimit)
        for file in paged.shown {
            card.addArrangedSubview(Self.revertFileRow(file))
        }
        if let more = paged.more {
            card.addArrangedSubview(
                RowKit.label(more, font: MacTheme.Ramp.font(.rowNote), color: MacTheme.Color.tertiaryLabel))
        }
        if let restore = context.restoreRevert {
            card.addArrangedSubview(
                RowKit.linkButton(
                    restoring ? RevertReading.restoringTitle : banner.restoreTitle,
                    enabled: !restoring, action: restore))
        }
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.group)
        card.setAccessibilityLabel(banner.spoken)
        return card
    }

    /// One file a revert put back: its path, what happened to it, and by how much. These are the
    /// same three facts `GitPanelView` draws for a changed file, because a revert's files are
    /// exactly that.
    @MainActor
    private static func revertFileRow(_ file: RevertBanner.FileLine) -> NSView {
        let path = RowKit.label(
            file.path, font: MacTheme.Ramp.font(.panelLabel), color: MacTheme.Color.label)
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let change = RowKit.label(
            file.change, font: MacTheme.Ramp.font(.panelFootnote),
            color: MacTheme.Color.secondaryLabel)
        change.setContentHuggingPriority(.required, for: .horizontal)
        var views = [path, change]
        if let counts = file.counts {
            let countsLabel = RowKit.label(
                counts, font: MacTheme.Ramp.font(.rowStamp), color: MacTheme.Color.tertiaryLabel)
            countsLabel.setContentHuggingPriority(.required, for: .horizontal)
            views.append(countsLabel)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = MacTheme.Spacing.s
        return row
    }
}
