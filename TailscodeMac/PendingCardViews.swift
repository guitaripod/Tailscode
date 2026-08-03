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
            RowKit.label("⏸", font: MacTheme.Font.mono(12), color: MacTheme.Color.warning))
        let what = request.title ?? request.toolName ?? Localized.text("a tool")
        heading.addArrangedSubview(
            RowKit.wrapping(
                Localized.text("Allow %@?", what), font: MacTheme.Font.emphasis(),
                color: MacTheme.Color.label))
        card.addArrangedSubview(heading)

        if let tool = request.toolName, request.title != nil, tool != request.title {
            card.addArrangedSubview(
                RowKit.label(
                    tool, font: MacTheme.Font.mono(11), color: MacTheme.Color.secondaryLabel))
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

        let buttons = NSStackView(views: [once, always, deny, RowKit.spacer()])
        buttons.orientation = .horizontal
        buttons.spacing = MacTheme.Spacing.s
        card.addArrangedSubview(buttons)
        return card
    }

    /// One question item at a time, which keeps the single-select fast path a single click. The
    /// collected answers go out through the caller, which routes them by message or by API as the
    /// backend demands.
    static func question(
        _ request: QuestionRequest, submit: @escaping ([[String]]) -> Void
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
                        item.header.uppercased(), font: MacTheme.Font.caption(),
                        color: MacTheme.Color.tertiaryLabel))
            }
            section.addArrangedSubview(
                RowKit.wrapping(
                    item.question, font: MacTheme.Font.emphasis(), color: MacTheme.Color.label))

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
                if !option.description.isEmpty { row.toolTip = option.description }
                section.addArrangedSubview(row)
                collector.register(question: index, option: option.label, button: row)
            }

            if item.custom || item.options.isEmpty {
                let field = AnswerField(single: single, collector: collector, question: index)
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
            answer.bezelColor = MacTheme.Color.accent
            let row = NSStackView(views: [answer, RowKit.spacer()])
            row.orientation = .horizontal
            card.addArrangedSubview(row)
        }
        card.retainedCollector = collector
        return card
    }

    static func compactionFailure(_ message: String) -> NSView {
        let card = cardColumn()
        card.addArrangedSubview(
            RowKit.wrapping(
                Localized.text("Compaction failed: %@", message), font: MacTheme.Font.body(),
                color: MacTheme.Color.danger))
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
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.quinarySystemFill.cgColor
        card.layer?.cornerRadius = MacTheme.Radius.card
        card.layer?.borderWidth = 1
        card.layer?.borderColor = MacTheme.Color.separator.cgColor
        return card
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

        init(request: QuestionRequest, submit: @escaping ([[String]]) -> Void) {
            self.request = request
            self.submit = submit
        }

        func register(question: Int, option: String, button: NSButton) {
            buttons["\(question):\(option)"] = button
        }

        func submitSingle(_ answer: String) {
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
            submit(answers)
        }

        private func restyle(_ question: Int) {
            guard request.questions.indices.contains(question) else { return }
            let selected = Set(chosen[question] ?? [])
            for option in request.questions[question].options {
                guard let button = buttons["\(question):\(option.label)"] else { continue }
                let isOn = selected.contains(option.label)
                button.bezelColor = isOn ? MacTheme.Color.accent : nil
                button.contentTintColor = isOn ? .white : nil
            }
        }
    }

    /// The free-form answer: Enter submits on the single fast path, or records the text for the
    /// Answer button on a multi ask.
    private final class AnswerField: NSTextField, NSTextFieldDelegate {
        private let single: Bool
        private weak var collector: AnswerCollector?
        private let question: Int

        init(single: Bool, collector: AnswerCollector, question: Int) {
            self.single = single
            self.collector = collector
            self.question = question
            super.init(frame: .zero)
            placeholderString = Localized.text("Your own answer…")
            font = MacTheme.Font.mono(12)
            translatesAutoresizingMaskIntoConstraints = false
            target = self
            action = #selector(entered)
            delegate = self
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

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
            guard !single else { return }
            collector?.setCustom(
                question: question,
                answer: stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
