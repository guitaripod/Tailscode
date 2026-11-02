import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

extension QuickAskPanel {
    /// The list is what the keyboard walks while the box is empty, and while a template is waiting
    /// for a chat to hand on.
    var isListing: Bool {
        gathering?.awaiting == .session
            || (editor.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && attachments.isEmpty)
    }

    /// The panel below the question: Core's sections — what was just copied with what can be done
    /// with it, the person's actions, what is waiting for later, what was asked here — or, while
    /// `{session}` waits, the chats to hand on. A redraw keeps the keyboard on the line it was on.
    func renderStarters() {
        let selected = menuCursor.index.flatMap {
            menuItems.indices.contains($0) ? menuItems[$0].id : nil
        }
        starters.arrangedSubviews.forEach { $0.removeFromSuperview() }
        menuRows = []
        let sections: [QuickAskMenuSection]
        if gathering?.awaiting == .session {
            sections = QuickAskMenu.sessions(QuickAskSessionReference.candidates(among: recents))
        } else {
            let surface = self.surface
            offered = QuickAskStarters.offered(for: abilities, surface: surface)
            copied = clipboard.flatMap {
                QuickAskClipboard.reading(
                    holding: $0.holding, fingerprint: $0.fingerprint, abilities: abilities,
                    surface: surface)
            }
            sections = QuickAskMenu.sections(
                copied: copied, starters: offered, later: QuickAskLaterStore.all(),
                recents: QuickAskRecents.asks(among: recents, profileID: targetServer.id),
                aimWords: { [weak self] aim in self?.aimBadge(aim) })
        }
        menuItems = QuickAskMenu.items(sections)
        picks = menuItems.filter { $0.digit != nil }
        for section in sections {
            fill(
                section.isCopied
                    ? QuickAskList.copiedHeader(section) { [weak self] in self?.setCopiedAside() }
                    : QuickAskList.section(section.title))
            for item in section.items {
                let id = item.id
                let row = QuickAskList.row(item) { [weak self] in self?.activate(id: id) }
                row.menu = menu(for: item)
                menuRows.append(row)
                fill(row)
            }
            if section.id == "later" { fill(QuickAskList.note(QuickAskLaterWords.reach)) }
        }
        let unread = QuickAskActions.unreadable
        if unread > 0 {
            fill(
                QuickAskList.note(
                    unread == 1
                        ? Localized.text("1 entry in quick-actions.json could not be read")
                        : Localized.text(
                            "%@ entries in quick-actions.json could not be read", "\(unread)")))
        }
        menuCursor.follow(id: selected, in: menuItems)
        paintSelection()
        sizeList()
        renderTyping(force: true)
        refreshStarterVisibility()
        resize()
    }

    /// Where an action asks when it asks somewhere of its own, said as short as it can be.
    func aimBadge(_ aim: QuickAskActionAim) -> String? {
        let profileID = aim.profileID(among: servers)
        if let selection = aim.selection {
            return ModelBadge.word(
                for: selection, in: ModelCatalogStore.cached(profileID ?? targetServer.id))
        }
        return servers.first { $0.id == profileID }?.name ?? aim.server
    }

    private func menu(for item: QuickAskMenuItem) -> NSMenu? {
        switch item.kind {
        case .starter, .errand: return item.action.map { actionMenu(for: $0) }
        case .newAction: return actionMenu(for: nil)
        case .later(let later): return laterMenu(later)
        case .recent, .session: return nil
        }
    }

    private func laterMenu(_ later: QuickAskLater) -> NSMenu {
        let id = later.id
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: Localized.text("Ask now")) {
            QuickAskLaterStore.askNow(id: id)
        })
        menu.addItem(ClosureMenuItem(title: Localized.text("Remove")) {
            QuickAskLaterStore.remove(id: id)
        })
        return menu
    }

    /// The list is held at the height its lines want, up to the ceiling past which it scrolls.
    func sizeList() {
        starters.layoutSubtreeIfNeeded()
        listHeight?.constant = min(starters.fittingSize.height, Self.listCeiling)
    }

    func paintSelection() {
        for (index, row) in menuRows.enumerated() { row.isSelected = index == menuCursor.index }
        guard let index = menuCursor.index, menuRows.indices.contains(index) else { return }
        menuRows[index].scrollToVisible(menuRows[index].bounds.insetBy(dx: 0, dy: -24))
    }

    func moveSelection(by delta: Int) {
        guard !asking else { return }
        menuCursor.move(by: delta, count: menuItems.count)
        paintSelection()
    }

    func clearSelection() {
        menuCursor.clear()
        paintSelection()
    }

    func runSelected() {
        guard let index = menuCursor.index, menuItems.indices.contains(index) else { return }
        activate(id: menuItems[index].id)
    }

    /// A line pressed, picked by its chord or run with Return: an action runs, a waiting question
    /// offers to be asked now or removed, a past question opens, a chat is handed on.
    func activate(id: String) {
        guard !asking, let index = menuItems.firstIndex(where: { $0.id == id }) else { return }
        let item = menuItems[index]
        switch item.kind {
        case .errand(let errand):
            menuCursor.clear()
            pickErrand(errand)
        case .starter(let starter):
            guard gathering == nil, editor.text.isEmpty else { return }
            menuCursor.clear()
            run(starter.action, copied: false)
        case .later(let later):
            guard menuRows.indices.contains(index) else { return }
            let row = menuRows[index]
            laterMenu(later).popUp(positioning: nil, at: NSPoint(x: 40, y: row.bounds.height), in: row)
        case .recent(let entry):
            resume(entry)
        case .session(let entry):
            menuCursor.clear()
            pickSession(entry)
        case .newAction:
            newAction()
        }
    }

    /// With words in the box the list steps aside for a row of verbs: the person's first few
    /// actions, each taking the typed words as what it is about. Redrawn only when the box crosses
    /// between empty and not.
    func renderTyping(force: Bool = false) {
        let typing = !isListing
        guard force || typing != typingShown else { return }
        typingShown = typing
        suggest.arrangedSubviews.forEach { $0.removeFromSuperview() }
        suggestions = typing && gathering == nil ? QuickAskMenu.suggestions(offered) : []
        if !suggestions.isEmpty {
            let label = NSTextField(labelWithString: QuickAskMenuWords.suggest)
            label.font = MacTheme.Ramp.font(.panelFootnote)
            label.textColor = MacTheme.Color.secondaryLabel
            suggest.addArrangedSubview(label)
            for (index, starter) in suggestions.enumerated() {
                let button = RowKit.ActionButton(title: starter.title + "  ⌥\(index + 1)") {
                    [weak self] in
                    self?.applySuggestion(at: index)
                }
                button.image = NSImage(systemSymbolName: starter.symbol, accessibilityDescription: nil)
                button.imagePosition = .imageLeading
                button.controlSize = .small
                button.font = MacTheme.Ramp.font(.control)
                button.toolTip = starter.prompt
                button.lineBreakMode = .byTruncatingTail
                button.setContentCompressionResistancePriority(.init(250), for: .horizontal)
                suggest.addArrangedSubview(button)
            }
        }
        renderFooter()
        refreshStarterVisibility()
    }

    /// The words typed so far, handed to an action as what it is about.
    func applySuggestion(at index: Int) {
        guard !asking, gathering == nil, suggestions.indices.contains(index) else { return }
        let typed = editor.text
        let action = suggestions[index].action
        editor.setText("", caretAtEnd: true)
        run(action, copied: false, typed: typed)
    }

    /// One line of keys for the box as it is, and on its far end the chord that opens the panel
    /// from anywhere.
    func renderFooter() {
        footKeys.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let keys =
            QuickAskFooter.keys(
                platform: .apple, typing: !isListing,
                party: QuickAskParty.targets(partyCards()).count > 1,
                screen: surface.screen && abilities.vision, suggestions: suggestions.count)
            + [QuickAskFooter.Key(keys: "esc", word: Localized.text("close"))]
        for key in keys { footKeys.addArrangedSubview(QuickAskList.key(key)) }
        let summon = MacSummon.shared.state
        chordLabel.stringValue =
            summon.isLive
            ? summon.chord.map { Localized.text("%@ from anywhere", $0.display(on: .apple)) } ?? ""
            : ""
    }

    /// The send arrow is lit by the same rule that lets Return through.
    func refreshSend() {
        let ready = QuickAskComposition.canSend(text: editor.text, attachments: attachments.count)
        sendButton.isEnabled = ready && !asking
        sendButton.contentTintColor = ready ? MacTheme.Color.accent : MacTheme.Color.tertiaryLabel
    }

    /// Everything in the list runs the list's full width, so the lines line up under the box.
    private func fill(_ view: NSView) {
        starters.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: starters.widthAnchor, constant: -20).isActive = true
    }

    static func pasteboardFingerprint() -> String {
        "pasteboard:\(NSPasteboard.general.changeCount)"
    }

    /// What the pasteboard holds, told from its types and its change count alone. Reading the
    /// contents of a pasteboard another app wrote raises the system's paste alert, and a summon
    /// that asked permission every time it opened would be a summon nobody kept, so the words are
    /// read for the glimpse only where the person has already allowed it, and otherwise when an
    /// errand is picked.
    static func detectClipboard()
        -> (holding: QuickAskClipboardHolding, fingerprint: String)?
    {
        #if DEBUG
            if CommandLine.arguments.contains("--shot-live") { return nil }
        #endif
        let pasteboard = NSPasteboard.general
        let types = pasteboard.types ?? []
        let holding: QuickAskClipboardHolding
        if types.contains(.fileURL) {
            holding = .files([])
        } else if types.contains(.png) || types.contains(.tiff) {
            holding = .picture
        } else if types.contains(.string) || types.contains(.URL) {
            let readable = pasteboard.accessBehavior == .alwaysAllow
            let words = readable ? pasteboard.string(forType: .string) : nil
            if let address = words.flatMap(QuickAskClipboard.link(in:)) {
                holding = .link(address)
            } else if !readable, types.contains(.URL) {
                holding = .link("")
            } else {
                holding = .text(words)
            }
        } else {
            return nil
        }
        return (holding, pasteboardFingerprint())
    }

    func readCopied() {
        guard !asking, clipboard?.fingerprint != Self.pasteboardFingerprint() else { return }
        clipboard = Self.detectClipboard()
        renderStarters()
        resize()
    }

    /// An errand is the first half of a sentence, the same as a starter: the instruction lands in
    /// the field and the pasteboard follows it through the paste the field already does, so a page
    /// of log still becomes the file it already is, and the person sends it.
    func pickErrand(_ errand: QuickAskClipboardErrand) {
        guard !asking, gathering == nil, editor.text.isEmpty, attachments.isEmpty, copied != nil
        else { return }
        run(errand.action, copied: true)
    }

    private func setCopiedAside() {
        guard let copied else { return }
        QuickAskClipboardMemory.settle(copied.fingerprint)
        renderStarters()
        resize()
        editor.focus()
    }

    func pick(at index: Int) {
        guard picks.indices.contains(index) else { return }
        activate(id: picks[index].id)
    }

    /// The list is the empty box's and the verbs are the typed box's; the panel takes its new
    /// height whenever one comes or goes.
    func refreshStarterVisibility() {
        let listing = isListing && !asking
        let verbs = !isListing && !asking && !suggestions.isEmpty
        guard listScroll.isHidden == listing || suggest.isHidden == verbs else { return }
        listScroll.isHidden = !listing
        listRule.isHidden = !listing
        suggest.isHidden = !verbs
        resize()
    }

    /// The box measures its own height one runloop pass after the keystroke that changed it, so
    /// the size read here is still the previous line count. The panel takes that size now — the
    /// first one is what places the window as it opens — and takes it again once the editor has
    /// answered, so a question that wraps onto a second line is not one keystroke behind the
    /// window holding it.
    func resize() {
        guard let content = card ?? contentView else { return }
        setContentSize(content.fittingSize)
        guard !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeScheduled = false
            guard let content = self.card ?? self.contentView else { return }
            self.setContentSize(content.fittingSize)
        }
    }

    /// Everything the panel says about itself goes through here, because the sentence is sometimes
    /// a whole failure — what the other machine refused and why — and the panel has to grow to
    /// hold it rather than cut it off at the tail.
    func setStatus(_ text: String) {
        status.stringValue = text
        status.isHidden = text.isEmpty
        resize()
    }

    private func resume(_ entry: SessionEntry) {
        guard !asking else { return }
        let onResume = onResume
        close()
        onResume(entry)
    }

    @objc func pickAttachments() {
        guard !asking, abilities.attachments || isLocalAim else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: self) { [weak self] response in
            guard response == .OK else { return }
            self?.attach(paths: panel.urls.map(\.path))
        }
    }

    /// Read fully at pick time, so a file edited or deleted between picking and sending still
    /// sends the bytes that were chosen; a refusal names its reason instead of shrinking a file.
    /// When the machine asked is this Mac, the files go by their paths instead: the agent opens
    /// them where they are, and nothing is capped.
    func attach(paths: [String]) {
        if isLocalAim, !paths.isEmpty {
            editor.insertAtCaret(QuickAskLocal.mention(paths) + "\n")
            setStatus(Localized.text("This machine is the one asked, so the files go by their paths."))
            return
        }
        let able = abilities
        for path in paths {
            switch AttachmentIntake.read(path: path) {
            case .success(let attachment):
                guard able.accepts(mime: attachment.mime) else {
                    setStatus(Localized.text("This model can't read %@", attachment.name))
                    continue
                }
                attachments.append(attachment)
            case .failure(let refusal):
                setStatus(refusal.message)
            }
        }
        syncAttachments()
    }

    func pasteImageAttachment() {
        guard abilities.vision else { return }
        let pasteboard = NSPasteboard.general
        guard let data = pasteboard.data(forType: .png) ?? pngFromTIFF(pasteboard) else {
            setStatus(Localized.text("The clipboard holds no picture."))
            return
        }
        addPastedImage(data)
    }

    func addPastedImage(_ data: Data) {
        guard abilities.vision else { return }
        guard data.count <= AttachmentIntake.byteCap else {
            setStatus(
                Localized.text(
                    "That picture is %@ — the cap is 8 MB", AttachmentIntake.sizeText(data.count)))
            return
        }
        pastedImageCount += 1
        attachments.append(
            PendingAttachment(
                name: "pasted-\(pastedImageCount).png", mime: "image/png", data: data))
        syncAttachments()
    }

    func pngFromTIFF(_ pasteboard: NSPasteboard) -> Data? {
        guard let tiff = pasteboard.data(forType: .tiff),
            let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    func syncAttachments() {
        chips.set(attachments)
        attachButton.title =
            attachments.isEmpty
            ? Localized.text("Attach") : Localized.text("%@ attached", "\(attachments.count)")
        refreshStarterVisibility()
        refreshSend()
        resize()
    }
}
