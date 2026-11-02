import AppKit
import TailscodeCore

/// One action, written or rewritten, as a sheet over the quick ask that asked for it: its name and
/// glyph, the words with their tokens, when it is offered, where it asks and whether it sends at
/// once. The aim it can keep is the one showing on that panel.
@MainActor
final class QuickAskActionSheet: NSWindow {
    static let offers: [QuickAskAction.Offer] = [.always, .text, .link, .picture, .files]

    private let original: QuickAskAction
    private let isNew: Bool
    private let aims: [QuickAskActionAim?]
    private weak var owner: QuickAskPanel?
    private let titleField = NSTextField()
    private let glyphField = NSTextField()
    private let hostsField = NSTextField()
    private let promptView = NSTextView()
    private let offerPopup = NSPopUpButton()
    private let aimPopup = NSPopUpButton()
    private let sendsBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let problem = NSTextField(wrappingLabelWithString: "")
    private let hostsRow: NSStackView

    static func present(
        _ action: QuickAskAction, isNew: Bool, current: QuickAskActionAim, over owner: QuickAskPanel
    ) -> QuickAskActionSheet {
        owner.actionSheet?.dismiss()
        let sheet = QuickAskActionSheet(action, isNew: isNew, current: current, owner: owner)
        owner.beginSheet(sheet)
        sheet.makeFirstResponder(action.title.isEmpty ? sheet.titleField : sheet.promptView)
        return sheet
    }

    private init(
        _ action: QuickAskAction, isNew: Bool, current: QuickAskActionAim, owner: QuickAskPanel
    ) {
        original = action
        self.isNew = isNew
        self.owner = owner
        var aims: [QuickAskActionAim?] = [nil]
        if let own = action.aim { aims.append(own) }
        if action.aim != current { aims.append(current) }
        self.aims = aims
        hostsRow = NSStackView()
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 10), styleMask: [.titled],
            backing: .buffered, defer: false)
        title = isNew ? Localized.text("New action") : Localized.text("Edit action")

        titleField.stringValue = action.title
        titleField.placeholderString = Localized.text("Title")
        glyphField.stringValue = action.glyph
        glyphField.toolTip = Localized.text("One or two characters for the tile")
        glyphField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let naming = NSStackView(views: [titleField, glyphField])
        naming.orientation = .horizontal
        naming.spacing = 8

        promptView.string = action.prompt
        promptView.isRichText = false
        promptView.font = MacTheme.Ramp.font(.rowTitle)
        promptView.isAutomaticQuoteSubstitutionEnabled = false
        promptView.isAutomaticDashSubstitutionEnabled = false
        promptView.textContainerInset = NSSize(width: 6, height: 6)
        promptView.isVerticallyResizable = true
        promptView.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = promptView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 110).isActive = true

        let tokens = NSTextField(wrappingLabelWithString: Self.tokenHelp)
        tokens.font = MacTheme.Ramp.font(.panelFootnote)
        tokens.textColor = MacTheme.Color.secondaryLabel
        tokens.isSelectable = true

        offerPopup.addItems(withTitles: Self.offers.map(Self.offerWords))
        offerPopup.selectItem(at: Self.offers.firstIndex(of: action.offer) ?? 0)
        offerPopup.target = self
        offerPopup.action = #selector(offerChanged)
        hostsField.stringValue = action.hosts.joined(separator: ", ")
        hostsField.placeholderString = Localized.text(
            "Comma-separated, like x.com, youtube.com; empty for any link")
        hostsRow.setViews([Self.caption(Localized.text("Sites")), hostsField], in: .leading)
        hostsRow.orientation = .horizontal
        hostsRow.spacing = 8
        hostsRow.isHidden = action.offer != .link

        aimPopup.addItems(
            withTitles: aims.enumerated().map { index, aim in
                Self.aimOption(aim, own: index == 1 && action.aim != nil, owner: owner)
            })
        aimPopup.selectItem(at: action.aim == nil ? 0 : 1)
        sendsBox.title = Localized.text("Send at once, once its tokens are gathered")
        sendsBox.state = action.sends ? .on : .off

        problem.textColor = MacTheme.Color.secondaryLabel
        problem.font = MacTheme.Ramp.font(.panelFootnote)

        let cancel = NSButton(title: Localized.text("Cancel"), target: self, action: #selector(cancelSheet))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: Localized.text("Save"), target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        save.keyEquivalentModifierMask = [.command]
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let offered = NSStackView(views: [Self.caption(Localized.text("Offered")), offerPopup])
        offered.orientation = .horizontal
        offered.spacing = 8
        let asks = NSStackView(views: [Self.caption(Localized.text("Asks on")), aimPopup])
        asks.orientation = .horizontal
        asks.spacing = 8

        let column = NSStackView(views: [
            naming, Self.caption(Localized.text("Words")), scroll, tokens, offered, hostsRow, asks,
            sendsBox, problem, buttons,
        ])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        for view in [naming, scroll, tokens, buttons, problem] {
            view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -32).isActive = true
        }
        column.widthAnchor.constraint(equalToConstant: 520).isActive = true
        contentView = column
        setContentSize(column.fittingSize)
    }

    static var tokenHelp: String {
        Localized.text(
            "{clipboard} or {link} the copied thing · {session} a chat to hand on · {screen} a drag over the screen · {file} a file · {latest:~/Downloads} the newest file there · {date} today · {cursor} where the caret lands"
        )
    }

    static func offerWords(_ offer: QuickAskAction.Offer) -> String {
        switch offer {
        case .always: return Localized.text("Always, as a tile")
        case .text: return Localized.text("When words are copied")
        case .link: return Localized.text("When a link is copied")
        case .picture: return Localized.text("When a picture is copied")
        case .files: return Localized.text("When files are copied")
        }
    }

    static func aimOption(_ aim: QuickAskActionAim?, own: Bool, owner: QuickAskPanel) -> String {
        guard let aim else { return Localized.text("The aim in force") }
        let words = owner.aimWords(aim)
        return own
            ? Localized.text("Its own: %@", words)
            : Localized.text("The aim showing now: %@", words)
    }

    private static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = MacTheme.Ramp.font(.rowMeta)
        label.textColor = MacTheme.Color.secondaryLabel
        return label
    }

    @objc private func offerChanged() {
        hostsRow.isHidden = Self.offers[offerPopup.indexOfSelectedItem] != .link
        setContentSize(contentView?.fittingSize ?? frame.size)
    }

    @objc private func cancelSheet() {
        dismiss()
    }

    @objc private func save() {
        let words = promptView.string
        guard !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            problem.stringValue = Localized.text("An action needs words to write.")
            return
        }
        let firstLine = words.split(separator: "\n").first.map(String.init) ?? words
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let glyph = glyphField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let offer = Self.offers[max(0, offerPopup.indexOfSelectedItem)]
        var action = original
        action.title = title.isEmpty ? String(firstLine.prefix(40)) : title
        action.glyph = glyph.isEmpty ? "✦" : String(glyph.prefix(2))
        action.prompt = words
        action.offer = offer
        action.hosts =
            offer == .link
            ? hostsField.stringValue.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            : []
        let index = aimPopup.indexOfSelectedItem
        action.aim = aims.indices.contains(index) ? aims[index] : nil
        action.sends = sendsBox.state == .on
        QuickAskActions.save(action)
        dismiss()
    }

    func dismiss() {
        guard let owner else { return }
        if owner.actionSheet === self { owner.actionSheet = nil }
        owner.endSheet(self)
        owner.editor.focus()
    }
}
