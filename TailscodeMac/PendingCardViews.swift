import AppKit
import CodingAgentKit
import TailscodeCore

/// The cards a turn stops on, docked at the end of the transcript where the CLI would be sitting
/// at a prompt: an approval with its three answers on keys, and a question as a form. Both are
/// states of the conversation, not messages in it — content in the canvas, never glass.
@MainActor
enum PendingCards {
    static func permission(
        _ request: PermissionRequest, respond: @escaping (PermissionDecision) -> Void
    ) -> NSView {
        let card = cardColumn()

        let heading = NSStackView()
        heading.orientation = .horizontal
        heading.alignment = .firstBaseline
        heading.spacing = MacTheme.Spacing.s
        heading.addArrangedSubview(
            RowKit.label("⏸", font: MacTheme.Ramp.font(.code), color: MacTheme.Color.warning))
        let what = request.title ?? request.toolName ?? Localized.text("a tool")
        heading.addArrangedSubview(
            RowKit.wrapping(
                Localized.text("Allow %@?", what), font: MacTheme.Ramp.font(.cardTitle),
                color: MacTheme.Color.label))
        card.addArrangedSubview(heading)

        if let tool = request.toolName, request.title != nil, tool != request.title {
            card.addArrangedSubview(
                RowKit.label(
                    tool, font: MacTheme.Ramp.font(.toolOutput), color: MacTheme.Color.secondaryLabel))
        }

        let once = RowKit.ActionButton(title: Localized.text("Allow once · y")) { respond(.once) }
        once.bezelStyle = .rounded
        once.keyEquivalent = ""
        once.bezelColor = MacTheme.Color.accent
        let always = RowKit.ActionButton(title: Localized.text("Always · a")) { respond(.always) }
        always.bezelStyle = .rounded
        let deny = RowKit.ActionButton(title: Localized.text("Deny · n")) { respond(.reject) }
        deny.bezelStyle = .rounded
        deny.hasDestructiveAction = true
        for button in [once, always, deny] { button.font = MacTheme.Ramp.font(.option) }

        let buttons = NSStackView(views: [once, always, deny, RowKit.spacer()])
        buttons.orientation = .horizontal
        buttons.spacing = MacTheme.Spacing.s
        card.addArrangedSubview(buttons)
        return grounded(card)
    }

    /// One question item at a time, which keeps the single-select fast path a single click. The
    /// collected answers go out through the caller, which routes them by message or by API as the
    /// backend demands.
    ///
    /// - Parameter chat: whose conversation is being asked, so a half-typed answer of your own is
    ///   kept: the question outlives a restart because it is derived from the transcript, and the
    ///   words being written towards it have to outlive one too.
    static func question(
        _ request: QuestionRequest, in chat: SessionEntry?,
        submit: @escaping ([[String]]) -> Void
    ) -> NSView {
        let card = cardColumn()
        let collector = AnswerCollector(request: request, submit: submit)

        for (index, item) in request.questions.enumerated() {
            let section = NSStackView()
            section.orientation = .vertical
            section.alignment = .leading
            section.spacing = 6
            section.translatesAutoresizingMaskIntoConstraints = false
            if !item.header.isEmpty {
                section.addArrangedSubview(
                    RowKit.label(
                        item.header.uppercased(), font: MacTheme.Ramp.font(.panelFootnote),
                        color: MacTheme.Color.tertiaryLabel))
            }
            section.addArrangedSubview(
                RowKit.wrapping(
                    item.question, font: MacTheme.Ramp.font(.cardTitle), color: MacTheme.Color.label))

            let single = !item.multiple && request.questions.count == 1
            for option in item.options {
                let row = RowKit.ActionButton(title: option.label) { [weak collector] in
                    guard let collector else { return }
                    if single {
                        collector.submitSingle(option.label)
                    } else {
                        collector.toggle(question: index, option: option.label)
                    }
                }
                row.bezelStyle = .rounded
                row.font = MacTheme.Ramp.font(.option)
                row.toolTip =
                    option.description.isEmpty
                    ? option.label : "\(option.label)\n\(option.description)"
                section.addArrangedSubview(row)
                collector.register(question: index, option: option.label, button: row)
            }

            if item.custom || item.options.isEmpty {
                let scope = chat.map {
                    DraftScope.answer(
                        profileID: $0.profileID, sessionID: $0.session.id,
                        questionID: "\(request.id):\(index)")
                }
                let field = AnswerField(
                    single: single, collector: collector, question: index, draft: scope)
                section.addArrangedSubview(field)
                field.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
            }
            card.addArrangedSubview(section)
        }

        if request.questions.count > 1 || request.questions.contains(where: \.multiple) {
            let answer = RowKit.ActionButton(title: Localized.text("Answer")) { [weak collector] in
                collector?.submitAll()
            }
            answer.bezelStyle = .rounded
            answer.font = MacTheme.Ramp.font(.option)
            answer.bezelColor = MacTheme.Color.accent
            let row = NSStackView(views: [answer, RowKit.spacer()])
            row.orientation = .horizontal
            card.addArrangedSubview(row)
        }
        card.retainedCollector = collector
        return grounded(card)
    }

    /// The minutes-long summarize as a card docked where the turn would be: the symbol says work,
    /// the words say what and for how long. The elapsed line is handed back so the transcript's
    /// own one-second clock can keep it honest without rebuilding the card.
    static func compacting(
        startedAt: Date, waiting: Bool, elapsedLabel: (NSTextField) -> Void
    ) -> NSView {
        let story = CompactionStory.running(startedAt: startedAt, waiting: waiting)
        let card = RowKit.compactionCard(story, tint: MacTheme.Color.accent)
        let spinner = NSProgressIndicator()
        spinner.style = .bar
        spinner.isIndeterminate = true
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)
        card.addArrangedSubview(spinner)
        spinner.widthAnchor.constraint(
            equalTo: card.widthAnchor, constant: -2 * MacTheme.Spacing.m
        ).isActive = true
        if let footnote = story.footnote {
            let elapsed = RowKit.label(
                footnote, font: MacTheme.Ramp.font(.rowStamp), color: MacTheme.Color.secondaryLabel)
            card.addArrangedSubview(elapsed)
            elapsedLabel(elapsed)
        }
        return card
    }

    /// A refused compaction leads with the reason and ends on the one fact that matters: nothing
    /// was lost.
    static func compactionFailure(_ message: String) -> NSView {
        let story = CompactionStory.failed(message)
        let card = RowKit.compactionCard(story, tint: MacTheme.Color.warning)
        if let footnote = story.footnote {
            card.addArrangedSubview(
                RowKit.wrapping(
                    footnote, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.tertiaryLabel))
        }
        return card
    }

    private static func cardColumn() -> CardView {
        let card = CardView()
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = MacTheme.Spacing.s + 2
        card.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.m, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.m,
            right: MacTheme.Spacing.m)
        card.translatesAutoresizingMaskIntoConstraints = false
        return card
    }

    /// The card's ground and its rule, in a view that resolves both again when the desk changes
    /// colour — a card docked at the end of a transcript nobody has touched since sunset would
    /// otherwise keep the face it was built under.
    private static func grounded(_ card: CardView) -> NSView {
        GroundView(
            around: card, cornerRadius: MacTheme.Radius.card,
            fill: MacTheme.Color.subagentBackground, edge: MacTheme.Color.separator)
    }

    /// The card keeps its collector alive: buttons hold it weakly so the card's subtree owns
    /// exactly one strong reference, released when the card leaves the transcript.
    final class CardView: NSStackView {
        var retainedCollector: AnswerCollector?
    }

    /// Selections for a multi-question or multi-select ask, kept next to the buttons that show
    /// them. Lives as long as its card does; the card is rebuilt when the ask resolves.
    @MainActor
    final class AnswerCollector {
        private let request: QuestionRequest
        private let submit: ([[String]]) -> Void
        private var chosen: [Int: [String]] = [:]
        private var custom: [Int: String] = [:]
        private var buttons: [String: NSButton] = [:]
        private var drafts: [Int: DraftScope] = [:]

        init(request: QuestionRequest, submit: @escaping ([[String]]) -> Void) {
            self.request = request
            self.submit = submit
        }

        func register(question: Int, option: String, button: NSButton) {
            buttons["\(question):\(option)"] = button
        }

        /// Which box a free-typed answer is being written into, so the answer going out — by a
        /// click on an option, by Enter, or by the Answer button — is what lets its draft go.
        func register(question: Int, draft scope: DraftScope) {
            drafts[question] = scope
        }

        func submitSingle(_ answer: String) {
            forgetDrafts()
            submit([[answer]])
        }

        func toggle(question: Int, option: String) {
            var current = chosen[question] ?? []
            let multiple =
                request.questions.indices.contains(question) && request.questions[question].multiple
            if let index = current.firstIndex(of: option) {
                current.remove(at: index)
            } else {
                if !multiple { current = [] }
                current.append(option)
            }
            chosen[question] = current
            restyle(question)
        }

        func setCustom(question: Int, answer: String) {
            custom[question] = answer
            if !request.questions[question].multiple { chosen[question] = [] }
            restyle(question)
        }

        func submitAll() {
            var answers: [[String]] = []
            for index in request.questions.indices {
                var selected = chosen[index] ?? []
                if let extra = custom[index], !extra.isEmpty { selected.append(extra) }
                if selected.isEmpty { selected = [Localized.text("(no answer)")] }
                answers.append(selected)
            }
            forgetDrafts()
            submit(answers)
        }

        private func forgetDrafts() {
            for scope in drafts.values { DraftStore.clear(scope) }
            drafts = [:]
        }

        private func restyle(_ question: Int) {
            guard request.questions.indices.contains(question) else { return }
            let selected = Set(chosen[question] ?? [])
            for option in request.questions[question].options {
                guard let button = buttons["\(question):\(option.label)"] else { continue }
                let isOn = selected.contains(option.label)
                button.title = isOn ? "✓ \(option.label)" : option.label
                button.bezelColor = isOn ? MacTheme.Color.accent : nil
                button.contentTintColor = isOn ? MacTheme.Color.onAccent : nil
                button.setAccessibilityValue(isOn ? Localized.text("selected") : "")
            }
        }
    }

    /// The free-form answer: Enter submits on the single fast path, or records the text for the
    /// Answer button on a multi ask. What is typed here is also written to the draft store as it
    /// is typed, because the card is rebuilt from the transcript on every launch and an answer
    /// half-written when the app closed has nowhere else to live.
    private final class AnswerField: NSTextField, NSTextFieldDelegate {
        private let single: Bool
        private weak var collector: AnswerCollector?
        private let question: Int
        private let draft: DraftScope?

        init(single: Bool, collector: AnswerCollector, question: Int, draft: DraftScope?) {
            self.single = single
            self.collector = collector
            self.question = question
            self.draft = draft
            super.init(frame: .zero)
            placeholderString = Localized.text("Your own answer…")
            font = MacTheme.Ramp.font(.code)
            translatesAutoresizingMaskIntoConstraints = false
            target = self
            action = #selector(entered)
            delegate = self
            if let draft {
                collector.register(question: question, draft: draft)
                restore(DraftStore.text(for: draft), into: collector)
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        /// A restored answer has to reach the collector as well as the field: on a multi ask the
        /// Answer button reads what was collected, not what a text field happens to be showing.
        private func restore(_ text: String, into collector: AnswerCollector) {
            guard !text.isEmpty else { return }
            stringValue = text
            guard !single else { return }
            collector.setCustom(question: question, answer: text)
        }

        @objc private func entered() {
            let answer = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else { return }
            if single {
                collector?.submitSingle(answer)
            } else {
                collector?.setCustom(question: question, answer: answer)
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            let answer = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let draft { DraftStore.record(answer, for: draft) }
            guard !single else { return }
            collector?.setCustom(question: question, answer: answer)
        }
    }
}
