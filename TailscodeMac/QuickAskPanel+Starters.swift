import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

extension QuickAskPanel {
    /// The empty panel's argument for itself: what was just copied and what can be done with it,
    /// what this thing can be asked to do, offered against what the aim can take, and the last few
    /// questions asked here. It gets out of the way the moment there is a question and comes back
    /// if the field is emptied again.
    func renderStarters() {
        starters.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if gathering?.awaiting == .session {
            renderSessionPicker()
            return
        }
        let surface = self.surface
        offered = QuickAskStarters.offered(for: abilities, surface: surface)
        copied = clipboard.flatMap {
            QuickAskClipboard.reading(
                holding: $0.holding, fingerprint: $0.fingerprint, abilities: abilities,
                surface: surface)
        }
        let errands = copied?.errands ?? []
        picks = errands.map(Pick.errand) + offered.indices.map(Pick.starter)
        if let copied {
            fill(
                QuickAskCopiedCard(
                    copied: copied, shortcuts: errands.indices.map(Self.shortcut),
                    onErrand: { [weak self] errand in self?.pickErrand(errand) },
                    onSetAside: { [weak self] in self?.setCopiedAside() },
                    menu: { [weak self] errand in self?.actionMenu(for: errand.action) }))
        }
        starters.addArrangedSubview(sectionLabel(QuickAskWords.offer))
        var tiles: [NSView] = offered.indices.map { index in
            let tile = QuickAskTiles.tile(
                offered[index], shortcut: Self.shortcut(at: errands.count + index)
            ) { [weak self] in
                self?.pickStarter(at: index)
            }
            tile.menu = actionMenu(for: offered[index].action)
            return tile
        }
        let more = QuickAskTiles.addTile { [weak self] in self?.newAction() }
        more.menu = actionMenu(for: nil)
        tiles.append(more)
        for first in stride(from: 0, to: tiles.count, by: 2) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = QuickAskTiles.spacing
            for tile in tiles[first..<min(first + 2, tiles.count)] { row.addArrangedSubview(tile) }
            if row.arrangedSubviews.count == 1 { row.addArrangedSubview(NSView()) }
            fill(row)
        }
        let unread = QuickAskActions.unreadable
        if unread > 0 {
            let note = NSTextField(
                wrappingLabelWithString: unread == 1
                    ? Localized.text("1 entry in quick-actions.json could not be read")
                    : Localized.text(
                        "%@ entries in quick-actions.json could not be read", "\(unread)"))
            note.font = MacTheme.Ramp.font(.panelFootnote)
            note.textColor = MacTheme.Color.secondaryLabel
            fill(note)
        }
        let waiting = laterRows()
        if !waiting.isEmpty {
            starters.addArrangedSubview(sectionLabel(QuickAskLaterWords.section))
            waiting.forEach(fill)
        }
        let asked = QuickAskRecents.asks(among: recents, profileID: targetServer.id)
        guard !asked.isEmpty else { return }
        starters.addArrangedSubview(sectionLabel(QuickAskWords.asked))
        for entry in asked {
            let title = AgentSession.isPlaceholderTitle(entry.session.title)
                ? QuickAskWords.untitled : entry.session.title
            fill(
                QuickAskTiles.recent(
                    title: title,
                    age: Localized.text(
                        "asked %@ ago", SessionRowModel.age(of: entry.session.updatedAt))
                ) { [weak self] in
                    self?.resume(entry)
                })
        }
    }

    /// Everything in the empty panel runs the field's full width, so the tiles, the card and the
    /// rows line up under the box they are offering to fill.
    private func fill(_ view: NSView) {
        starters.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: editor.widthAnchor).isActive = true
    }

    /// `{session}` asks which chat: the recent ones on every machine, newest first, each said with
    /// the agent and the machine that ran it. A number or a click hands it on; Escape sets the
    /// action aside.
    private func renderSessionPicker() {
        let candidates = QuickAskSessionReference.candidates(among: recents)
        picks = candidates.map(Pick.session)
        starters.addArrangedSubview(sectionLabel(Localized.text("Which chat?")))
        guard !candidates.isEmpty else {
            starters.addArrangedSubview(
                NSTextField(labelWithString: Localized.text("No chats yet on any machine.")))
            return
        }
        for (index, entry) in candidates.enumerated() {
            let title = AgentSession.isPlaceholderTitle(entry.session.title)
                ? QuickAskWords.untitled : entry.session.title
            let detail = [
                entry.backendType.displayName, entry.profileName,
                SessionRowModel.age(of: entry.session.updatedAt),
            ].joined(separator: " · ")
            fill(
                QuickAskTiles.recent(
                    title: (Self.shortcut(at: index).map { $0 + "  " } ?? "") + title, age: detail
                ) { [weak self] in
                    self?.pickSession(entry)
                })
        }
    }

    private static func shortcut(at index: Int) -> String? {
        index < 9 ? "⌘\(index + 1)" : nil
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
    private func pickErrand(_ errand: QuickAskClipboardErrand) {
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
        switch picks[index] {
        case .errand(let errand): pickErrand(errand)
        case .starter(let starter): pickStarter(at: starter)
        case .session(let entry): pickSession(entry)
        }
    }

    /// The name of a group, set in the ramp's own answer for one — bold and tracked, against the
    /// plain footnote its rows are set in, so the panel reads as two named groups rather than one
    /// column of small grey text.
    private func sectionLabel(_ text: String) -> NSTextField {
        NSTextField(
            labelWithAttributedString: NSAttributedString(
                string: text,
                attributes: MacTheme.Ramp.attributes(
                    .sectionLabel, color: MacTheme.Color.secondaryLabel)))
    }

    func refreshStarterVisibility() {
        let empty =
            (editor.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && attachments.isEmpty) || gathering?.awaiting == .session
        let hidden = !(empty && !asking)
        guard starters.isHidden != hidden else { return }
        starters.isHidden = hidden
        resize()
    }

    /// The box measures its own height one runloop pass after the keystroke that changed it, so
    /// the size read here is still the previous line count. The panel takes that size now — the
    /// first one is what places the window as it opens — and takes it again once the editor has
    /// answered, so a question that wraps onto a second line is not one keystroke behind the
    /// window holding it.
    func resize() {
        guard let content = contentView else { return }
        setContentSize(content.fittingSize)
        guard !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeScheduled = false
            guard let content = self.contentView else { return }
            self.setContentSize(content.fittingSize)
        }
    }

    /// Everything the panel says about itself goes through here, because the sentence is sometimes
    /// a whole failure — what the other machine refused and why — and the panel has to grow to
    /// hold it rather than cut it off at the tail.
    func setStatus(_ text: String) {
        status.stringValue = text
        resize()
    }

    /// A starter is the first half of a sentence, never a question the app asked on somebody's
    /// behalf: the words land in the field with the caret where the action left room, after
    /// whatever its template fetches — a chooser, a drag over the screen, a chat to hand on.
    private func pickStarter(at index: Int) {
        guard !asking, gathering == nil, offered.indices.contains(index), editor.text.isEmpty
        else { return }
        run(offered[index].action, copied: false)
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
            ? Localized.text("Attach…")
            : Localized.text("Attach… (%@)", "\(attachments.count)")
        refreshStarterVisibility()
        resize()
    }
}
