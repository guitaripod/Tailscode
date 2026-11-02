import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

extension QuickAskPanel {
    /// Words or things in the box, and no template waiting for a chat: the list is then the verbs
    /// for what was typed rather than everything that can be done.
    var isTyping: Bool {
        gathering?.awaiting != .session
            && !(editor.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && attachments.isEmpty)
    }

    /// Whether an arrow is the list's rather than the box's. With the box empty every arrow walks
    /// the list; with words in it ↓ steps into the list only from the box's last line, so a
    /// question of several lines is still walked line by line, and ↑ is the list's only while a
    /// line of it is held — from the first line it hands the keyboard back to the box.
    func walksList(down: Bool) -> Bool {
        guard isTyping else { return true }
        if menuCursor.index != nil { return true }
        guard down else { return false }
        let text = editor.text
        let caret = text.index(text.startIndex, offsetBy: min(max(editor.cursor, 0), text.count))
        return !text[caret...].contains("\n")
    }

    /// The panel below the question: Core's sections — what was just copied with what can be done
    /// with it, the person's actions, what is waiting for later, what was asked here — or, with
    /// words typed, the verbs for them, or, while `{session}` waits, the chats to hand on. A redraw
    /// keeps the keyboard on the line it was on.
    func renderStarters() {
        let selected = menuCursor.index.flatMap {
            menuItems.indices.contains($0) ? menuItems[$0].id : nil
        }
        starters.arrangedSubviews.forEach { $0.removeFromSuperview() }
        menuRows = []
        typingShown = isTyping
        let sections: [QuickAskMenuSection]
        if gathering?.awaiting == .session {
            sections = QuickAskMenu.sessions(QuickAskSessionReference.candidates(among: recents))
        } else if isTyping {
            offered = QuickAskStarters.offered(for: abilities, surface: surface)
            sections = QuickAskMenu.verbs(
                offered, aimWords: { [weak self] aim in self?.aimBadge(aim) })
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
        renderFooter()
        refreshStarterVisibility()
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
            guard gathering == nil else { return }
            if isTyping {
                menuCursor.clear()
                applyVerb(starter)
                return
            }
            guard editor.text.isEmpty else { return }
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

    /// The list is redrawn as the verbs or as everything only when the box crosses between empty
    /// and not, and a line held for the other list is let go.
    func renderTyping() {
        guard isTyping != typingShown else { return }
        menuCursor.clear()
        renderStarters()
    }

    /// The words typed so far, handed to an action as what it is about.
    func applyVerb(_ starter: QuickAskStarter) {
        guard !asking, gathering == nil else { return }
        let typed = editor.text
        editor.setText("", caretAtEnd: true)
        run(starter.action, copied: false, typed: typed)
    }

    /// One line of keys for the box as it is, and on its far end the chord that opens the panel
    /// from anywhere.
    func renderFooter() {
        footKeys.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let keys =
            QuickAskFooter.keys(
                platform: .apple, typing: isTyping,
                party: QuickAskParty.targets(partyCards()).count > 1,
                screen: surface.screen && abilities.vision, verbs: picks.count)
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
        editor.focus()
    }

    func pick(at index: Int) {
        guard picks.indices.contains(index) else { return }
        activate(id: picks[index].id)
    }

    /// The list stays where it is while a question is out, dimmed, since nothing on it can be run
    /// until the machine has answered.
    func refreshStarterVisibility() {
        listScroll.alphaValue = asking ? 0.45 : 1
    }

    /// Everything the panel says about itself goes through here, because the sentence is sometimes
    /// a whole failure — what the other machine refused and why — and it is held whole: the list
    /// gives up its height to it first, and the panel grows only past that.
    func setStatus(_ text: String) {
        status.stringValue = text
        status.isHidden = text.isEmpty
        makeRoom()
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
        renderTyping()
        refreshSend()
        makeRoom()
    }
}
