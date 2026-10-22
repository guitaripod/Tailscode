import AppKit
import CodingAgentKit
import TailscodeCore

/// Everything a drawn block can ask of first run, as closures the window fills. A block names what
/// the person pressed and never how the flow answers it.
@MainActor
struct FirstRunIntents {
    var choose: (FirstRunPlan.Way.Kind) -> Void
    var paste: (String) -> Void
    var useClipboard: () -> Void
    var selectAgent: (AgentType) -> Void
    var copied: () -> Void
    var setPassword: (String) -> Void
    var confirmOffTailnet: () -> Void
    var fix: (ConnectDiagnosis.Fix) -> Void
    var back: () -> Void
}

/// One block of a row, kept alive from plan to plan. A block that holds a text field is updated in
/// place, because rebuilding it would take the keyboard away from the person typing in it.
@MainActor
protocol FirstRunBlockPart: AnyObject {
    var view: NSView { get }
    func apply(_ block: FirstRunPlan.Block)
    func didAppear()
}

extension FirstRunBlockPart {
    func didAppear() {}
}

/// One step of the checklist: a number, a title, a pill and a glyph, the plan's detail under them
/// and the blocks the plan puts in the step. The plan's rows are fixed for a mode, so a row view is
/// made once and only told what it now says.
@MainActor
final class FirstRunRow {
    let view = FillingStack(topDown: true)
    private let number = RowKit.label(
        "", font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.tertiaryLabel)
    private let title = RowKit.label(
        "", font: MacTheme.Ramp.font(.panelLabel), color: MacTheme.Color.label)
    private let pill = MacDialogs.detailLabel("")
    private let glyph = NSImageView()
    private let spinner = NSProgressIndicator()
    private let detail = RowKit.wrapping(
        "", font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.secondaryLabel)
    private let blocks = FillingStack(topDown: true)
    private let intents: FirstRunIntents
    private let remedy: TailnetRemedyView
    private var parts: [String: FirstRunBlockPart] = [:]
    private lazy var backButton = RowKit.ActionButton(title: "") { [weak self] in
        self?.intents.back()
    }
    private lazy var backRow = FirstRunBlocks.buttonRow([backButton])
    private lazy var offerButton = RowKit.ActionButton(title: "") { [weak self] in
        self?.intents.useClipboard()
    }
    private let offerDetail = RowKit.wrapping(
        "", font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.secondaryLabel)
    private lazy var offerRow: NSView = {
        let column = FillingStack(topDown: true)
        column.spacing = 2
        column.addArrangedSubview(FirstRunBlocks.buttonRow([offerButton]))
        column.addArrangedSubview(offerDetail)
        return column
    }()

    init(intents: FirstRunIntents, remedy: TailnetRemedyView) {
        self.intents = intents
        self.remedy = remedy
        view.spacing = MacTheme.Spacing.xs

        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.setAccessibilityElement(false)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [
            number, title, RowKit.spacer(), pill, glyph, spinner,
        ])
        header.orientation = .horizontal
        header.spacing = MacTheme.Spacing.s
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addArrangedSubview(header)

        blocks.spacing = MacTheme.Spacing.s
        let body = FillingStack(topDown: true)
        body.spacing = MacTheme.Spacing.xs
        body.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 0)
        body.addArrangedSubview(detail)
        body.addArrangedSubview(blocks)
        view.addArrangedSubview(body)
    }

    func update(_ row: FirstRunPlan.Row, back: String?, offer: FirstRunPlan.Offer?) {
        number.stringValue = "\(row.number) ·"
        title.stringValue = row.title
        pill.stringValue = row.pill ?? ""
        pill.isHidden = row.pill == nil
        pill.textColor = Self.ink(row.glyph)
        showGlyph(row.glyph)
        let remedyTellsIt = row.blocks.contains {
            if case .remedy = $0 { return true }
            return false
        }
        detail.stringValue = row.detail ?? ""
        detail.isHidden = row.detail == nil || remedyTellsIt
        reconcile(row.blocks, back: back, offer: offer)
    }

    private func showGlyph(_ state: FirstRunPlan.Row.Glyph) {
        if state == .working {
            glyph.isHidden = true
            spinner.isHidden = false
            spinner.startAnimation(nil)
            return
        }
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        glyph.isHidden = false
        let symbol: String
        switch state {
        case .waiting: symbol = "circle"
        case .current: symbol = "smallcircle.filled.circle"
        case .proven: symbol = "checkmark.circle.fill"
        case .attention: symbol = "exclamationmark.triangle.fill"
        case .working: symbol = "circle"
        }
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: 13 * MacTheme.UIScale.factor, weight: .semibold))
        glyph.contentTintColor = Self.ink(state)
    }

    private static func ink(_ state: FirstRunPlan.Row.Glyph) -> NSColor {
        switch state {
        case .proven: return MacTheme.Color.success
        case .attention: return MacTheme.Color.warning
        case .current: return MacTheme.Color.accent
        case .waiting, .working: return MacTheme.Color.secondaryLabel
        }
    }

    /// Parts are matched to blocks by kind and by how many of that kind came before, so the field
    /// the person is typing in keeps its place while a status line comes and goes around it.
    private func reconcile(_ planned: [FirstRunPlan.Block], back: String?, offer: FirstRunPlan.Offer?) {
        var counts: [String: Int] = [:]
        var wanted: [(key: String, view: NSView)] = []
        var fresh: [FirstRunBlockPart] = []
        var live: Set<String> = []
        for block in planned {
            let kind = FirstRunBlocks.kind(of: block)
            let index = counts[kind, default: 0]
            counts[kind] = index + 1
            let key = "\(kind)#\(index)"
            let part: FirstRunBlockPart
            if let existing = parts[key] {
                part = existing
            } else {
                part = FirstRunBlocks.make(for: block, intents: intents, remedy: remedy)
                parts[key] = part
                fresh.append(part)
            }
            part.apply(block)
            live.insert(key)
            wanted.append((key, part.view))
        }
        for key in parts.keys where !live.contains(key) { parts[key] = nil }
        if let offer {
            offerButton.title = offer.title
            offerButton.setAccessibilityHelp(offer.detail)
            offerDetail.stringValue = offer.detail
            wanted.insert(("offer", offerRow), at: 0)
        }
        if let back {
            backButton.title = back
            wanted.append(("back", backRow))
        }
        for arranged in blocks.arrangedSubviews where !wanted.contains(where: { $0.view === arranged }) {
            arranged.removeFromSuperview()
        }
        for (index, item) in wanted.enumerated() {
            if index < blocks.arrangedSubviews.count, blocks.arrangedSubviews[index] === item.view {
                continue
            }
            if blocks.arrangedSubviews.contains(item.view) { blocks.removeArrangedSubview(item.view) }
            blocks.insertArrangedSubview(item.view, at: index)
        }
        blocks.isHidden = wanted.isEmpty
        guard !fresh.isEmpty else { return }
        Task { @MainActor in fresh.forEach { $0.didAppear() } }
    }
}

/// How each kind of block is drawn. Every word is the plan's.
@MainActor
enum FirstRunBlocks {
    static func kind(of block: FirstRunPlan.Block) -> String {
        switch block {
        case .note: return "note"
        case .ways: return "ways"
        case .paste: return "paste"
        case .agents: return "agents"
        case .command: return "command"
        case .waiting: return "waiting"
        case .diagnosis: return "diagnosis"
        case .link: return "link"
        case .password: return "password"
        case .signIn: return "signIn"
        case .remedy: return "remedy"
        }
    }

    static func make(
        for block: FirstRunPlan.Block, intents: FirstRunIntents, remedy: TailnetRemedyView
    ) -> FirstRunBlockPart {
        switch block {
        case .paste: return FirstRunPastePart(intents: intents)
        case .agents: return FirstRunAgentsPart(intents: intents)
        case .password: return FirstRunPasswordPart(intents: intents)
        case .remedy: return FirstRunRemedyPart(remedy: remedy)
        case .note, .ways, .command, .waiting, .diagnosis, .link, .signIn:
            return FirstRunRebuiltPart { drawn in views(for: drawn, intents: intents) }
        }
    }

    private static func views(for block: FirstRunPlan.Block, intents: FirstRunIntents) -> [NSView] {
        switch block {
        case .note(let text):
            return [RowKit.wrapping(text, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.secondaryLabel)]
        case .ways(let ways):
            return ways.filter { $0.kind != .scan }.map { way($0, intents: intents) }
        case .command(let card):
            return command(card, intents: intents)
        case .waiting(let text):
            return [waiting(text)]
        case .diagnosis(let diagnosis):
            return [diagnosisCard(diagnosis, intents: intents)]
        case .link(let card):
            return [linkCard(card, intents: intents)]
        case .signIn(let card):
            return signIn(card)
        case .paste, .agents, .password, .remedy:
            return []
        }
    }

    static func buttonRow(_ buttons: [NSButton]) -> NSStackView {
        let row = NSStackView(views: buttons + [RowKit.spacer()])
        row.orientation = .horizontal
        row.spacing = MacTheme.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// The three ways in are one choice, so their buttons share a width instead of ragging by title length.
    private static let wayButtonWidth: CGFloat = 280

    private static func way(_ way: FirstRunPlan.Way, intents: FirstRunIntents) -> NSView {
        let column = FillingStack(topDown: true)
        column.spacing = 2
        let button = RowKit.ActionButton(title: way.title) { intents.choose(way.kind) }
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: wayButtonWidth).isActive = true
        column.addArrangedSubview(buttonRow([button]))
        column.addArrangedSubview(
            RowKit.wrapping(
                way.detail, font: MacTheme.Ramp.font(.panelFootnote),
                color: MacTheme.Color.secondaryLabel))
        return column
    }

    private static func command(_ card: FirstRunPlan.CommandCard, intents: FirstRunIntents) -> [NSView] {
        let line = RowKit.wrapping(
            card.command, font: MacTheme.Ramp.font(.code), color: MacTheme.Color.label)
        let box = FillingStack(topDown: true)
        box.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        RowKit.ground(
            behind: box, fill: MacTheme.Color.codeBackground, stroke: MacTheme.Color.separator,
            radius: 8)
        box.addArrangedSubview(line)
        var views: [NSView] = [
            RowKit.wrapping(
                card.title, font: MacTheme.Ramp.font(.panelLabel), color: MacTheme.Color.label),
            RowKit.wrapping(
                card.detail, font: MacTheme.Ramp.font(.panelFootnote),
                color: MacTheme.Color.secondaryLabel),
            box,
            buttonRow([
                RowKit.ActionButton(title: card.copyTitle) {
                    RowKit.copyToClipboard(card.command)
                    intents.copied()
                }
            ]),
        ]
        if let note = card.note {
            views.append(
                RowKit.wrapping(
                    note, font: MacTheme.Ramp.font(.panelFootnote),
                    color: MacTheme.Color.secondaryLabel))
        }
        return views
    }

    private static func waiting(_ text: String) -> NSView {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)
        spinner.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [
            spinner,
            RowKit.wrapping(
                text, font: MacTheme.Ramp.font(.panelFootnote),
                color: MacTheme.Color.secondaryLabel),
        ])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = MacTheme.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    static func diagnosisCard(_ diagnosis: ConnectDiagnosis, intents: FirstRunIntents) -> NSView {
        let card = RowKit.card(
            symbol: diagnosis.symbol, title: diagnosis.title, detail: diagnosis.detail,
            tint: MacTheme.Color.warning)
        if let title = diagnosis.actionTitle, diagnosis.fix != .none {
            card.addArrangedSubview(
                buttonRow([RowKit.ActionButton(title: title) { intents.fix(diagnosis.fix) }]))
        }
        return card
    }

    private static func linkCard(_ card: FirstRunPlan.LinkCard, intents: FirstRunIntents) -> NSView {
        let view = RowKit.card(
            symbol: "link", title: card.headline, detail: card.lines.joined(separator: "\n"),
            tint: MacTheme.Color.accent)
        if let title = card.connectAnywayTitle {
            view.addArrangedSubview(
                buttonRow([RowKit.ActionButton(title: title) { intents.confirmOffTailnet() }]))
        }
        return view
    }

    private static func signIn(_ card: FirstRunPlan.SignInCard) -> [NSView] {
        [
            RowKit.wrapping(
                card.title, font: MacTheme.Ramp.font(.panelLabel), color: MacTheme.Color.label)
        ]
    }
}

/// A block with no state of its own: it is torn down and drawn again whenever the plan changes it.
@MainActor
final class FirstRunRebuiltPart: FirstRunBlockPart {
    private let stack = FillingStack(topDown: true)
    var view: NSView { stack }
    private var shown: FirstRunPlan.Block?
    private let build: (FirstRunPlan.Block) -> [NSView]

    init(build: @escaping (FirstRunPlan.Block) -> [NSView]) {
        self.build = build
        stack.spacing = MacTheme.Spacing.xs
    }

    func apply(_ block: FirstRunPlan.Block) {
        guard shown != block else { return }
        shown = block
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for drawn in build(block) { stack.addArrangedSubview(drawn) }
    }
}

/// The one field that takes a link or an address. What the person types goes to the flow as they
/// type; what the plan says the field should read is written back only while the person is not
/// mid-edit, so a plan that is a keystroke behind never takes a letter away.
@MainActor
final class FirstRunPastePart: NSObject, FirstRunBlockPart, NSTextFieldDelegate {
    private let stack = FillingStack(topDown: true)
    var view: NSView { stack }
    private let field = NSTextField()
    private let reading = MacDialogs.detailLabel("", wraps: true)
    private let messageSlot = FillingStack(topDown: true)
    private let intents: FirstRunIntents
    private var sent = ""
    private var shownMessage: ConnectLinkReading.Message?

    init(intents: FirstRunIntents) {
        self.intents = intents
        super.init()
        stack.spacing = MacTheme.Spacing.xs
        field.font = MacTheme.Ramp.font(.code)
        field.delegate = self
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(field)
        stack.addArrangedSubview(reading)
        stack.addArrangedSubview(messageSlot)
    }

    func apply(_ block: FirstRunPlan.Block) {
        guard case .paste(let paste) = block else { return }
        field.placeholderString = paste.placeholder
        if (field.currentEditor() == nil || field.stringValue.isEmpty), field.stringValue != paste.text {
            field.stringValue = paste.text
            sent = paste.text
        }
        reading.stringValue = paste.reading ?? ""
        reading.isHidden = paste.reading == nil
        if shownMessage != paste.message {
            shownMessage = paste.message
            messageSlot.arrangedSubviews.forEach { $0.removeFromSuperview() }
            if let message = paste.message {
                messageSlot.addArrangedSubview(
                    RowKit.card(
                        symbol: "exclamationmark.triangle", title: message.title,
                        detail: message.detail, tint: MacTheme.Color.warning))
            }
            messageSlot.isHidden = paste.message == nil
        }
    }

    func didAppear() {
        field.window?.makeFirstResponder(field)
    }

    func controlTextDidChange(_ notification: Notification) {
        send()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        send()
    }

    private func send() {
        let text = field.stringValue
        guard text != sent else { return }
        sent = text
        intents.paste(text)
    }
}

/// The password field a machine asked for, written to by the person and by the flow when a copied
/// command or a pasted line already carries the password.
@MainActor
final class FirstRunPasswordPart: NSObject, FirstRunBlockPart, NSTextFieldDelegate {
    private let stack = FillingStack(topDown: true)
    var view: NSView { stack }
    private let field = NSSecureTextField()
    private let note = MacDialogs.detailLabel("", wraps: true)
    private let intents: FirstRunIntents
    private var sent = ""
    private var empty = true

    init(intents: FirstRunIntents) {
        self.intents = intents
        super.init()
        stack.spacing = MacTheme.Spacing.xs
        field.placeholderString = Localized.text("Password")
        field.font = MacTheme.Ramp.font(.code)
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [field, RowKit.spacer()])
        row.orientation = .horizontal
        row.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        stack.addArrangedSubview(row)
        stack.addArrangedSubview(note)
    }

    func apply(_ block: FirstRunPlan.Block) {
        guard case .password(let password) = block else { return }
        empty = password.text.isEmpty
        if (field.currentEditor() == nil || field.stringValue.isEmpty),
            field.stringValue != password.text
        {
            field.stringValue = password.text
            sent = password.text
        }
        note.stringValue = password.note ?? ""
        note.isHidden = password.note == nil
    }

    func didAppear() {
        guard empty else { return }
        field.window?.makeFirstResponder(field)
    }

    func controlTextDidChange(_ notification: Notification) {
        let text = field.stringValue
        guard text != sent else { return }
        sent = text
        intents.setPassword(text)
    }
}

/// Which agent the person is installing, as the plan lists them.
@MainActor
final class FirstRunAgentsPart: NSObject, FirstRunBlockPart {
    private let stack = FillingStack(topDown: true)
    var view: NSView { stack }
    private let control = NSSegmentedControl()
    private let detail = RowKit.wrapping(
        "", font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.secondaryLabel)
    private let intents: FirstRunIntents
    private var choices: [FirstRunPlan.AgentChoice] = []

    init(intents: FirstRunIntents) {
        self.intents = intents
        super.init()
        stack.spacing = MacTheme.Spacing.xs
        control.segmentStyle = .rounded
        control.trackingMode = .selectOne
        control.target = self
        control.action = #selector(picked)
        control.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [control, RowKit.spacer()])
        row.orientation = .horizontal
        row.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(row)
        stack.addArrangedSubview(detail)
    }

    func apply(_ block: FirstRunPlan.Block) {
        guard case .agents(let agents) = block else { return }
        choices = agents
        if control.segmentCount != agents.count { control.segmentCount = agents.count }
        for (index, choice) in agents.enumerated() { control.setLabel(choice.title, forSegment: index) }
        if let selected = agents.firstIndex(where: \.isSelected) {
            control.selectedSegment = selected
            detail.stringValue = agents[selected].detail
        }
    }

    @objc private func picked() {
        let index = control.selectedSegment
        guard choices.indices.contains(index) else { return }
        intents.selectAgent(choices[index].agent)
    }
}

/// The tailnet remedy the window already owns, drawn where the plan asks for it.
@MainActor
final class FirstRunRemedyPart: FirstRunBlockPart {
    let view: NSView
    private let remedy: TailnetRemedyView

    init(remedy: TailnetRemedyView) {
        self.remedy = remedy
        view = remedy
    }

    func apply(_ block: FirstRunPlan.Block) {
        guard case .remedy(let reading) = block else { return }
        remedy.write(reading)
    }
}
