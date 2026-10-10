import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension DrawPane {
    /// The dock's chips, in Core's order: the four decisions a picture is made from, then the ones
    /// that are not values that walk. They are built once and drawn from `StudioChips`.
    func buildChips() {
        dock.tray.fill([
            engineChip, aspectChip, sizeChip, detailChip, cutoutChip, avoidChip, seedChip,
            referenceChip, craftChip,
        ])
    }

    func buildAvoidCard(_ card: UnsafeMutablePointer<GtkWidget>) {
        Gtk.margins(card, 12)
        gtk_widget_set_size_request(card, 360, -1)
        let hint = Gtk.label(ImageGenWords.avoidHint, css: "draw-toggle-detail", wrap: true, selectable: false)
        gtk_label_set_max_width_chars(op(hint), 48)
        gtk_entry_set_placeholder_text(ptr(avoidEntry), ImageGenWords.avoidPlaceholder)
        Gtk.addClass(avoidEntry, "draw-avoid")
        gtk_widget_set_hexpand(avoidEntry, 1)
        gtk_box_append(ptr(card), hint)
        gtk_box_append(ptr(card), avoidEntry)
        Gtk.connect(UnsafeMutableRawPointer(avoidEntry), "changed") { [weak self] in
            guard let self, let raw = gtk_editable_get_text(op(self.avoidEntry)) else { return }
            let words = String(cString: raw)
            Gtk.onMain { [weak self] in self?.studio.setNegative(words) }
        }
    }

    /// The start-from slot lives at the dock's leading edge; files dropped on it or on the dock
    /// are starts.
    func buildSlot() {
        gtk_box_append(ptr(dock.slotHolder), slotView.widget)
        slotView.acceptDrops { [weak self] paths in
            Gtk.onMain { [weak self] in self?.attachFiles(paths) }
        }
        Gtk.acceptFileDrops(on: dock.root) { [weak self] paths in
            Gtk.onMain { [weak self] in self?.attachFiles(paths) }
        }
    }

    func wireDock() {
        dock.onChange = { [weak self] in self?.wordsChanged() }
        dock.onSubmit = { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, !self.slot.isBusy else { return }
                self.submit()
            }
        }
        Gtk.connect(UnsafeMutableRawPointer(dock.go), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.renderPressed() }
        }
        Gtk.connect(UnsafeMutableRawPointer(dock.enhance), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.enhancePressed() }
        }
        shell.setLowerCard(rewrite.root)
        shell.showLowerCard(false)
        rewrite.onUse = { [weak self] in self?.useRewrite() }
        rewrite.onKeep = { [weak self] in self?.studio.dismissRewrite() }
        rewrite.onAgain = { [weak self] in
            guard let self, let draft = self.studio.draft else { return }
            self.studio.rewrite(draft.original)
        }
        rewrite.onStop = { [weak self] in self?.studio.stopRewrite() }
        rewrite.onRevise = { [weak self] words in
            guard let self, let draft = self.studio.draft, draft.isUsable else { return }
            self.studio.rewrite(draft.original, instruction: words)
        }
        machine.details = { [weak self] in
            guard let self else { return Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0) }
            return StudioMachineDetails.image(
                studio: self.studio, sighting: self.studio.sighting,
                onCheck: { [weak self] in Gtk.onMain { [weak self] in self?.studio.recheckMachine() } },
                onChange: { [weak self] in
                    Gtk.onMain { [weak self] in
                        guard let self else { return }
                        let held = self.studio
                        ForgeSetupWindow.present(parent: self.hostWindow) {
                            Gtk.onMain { if held === ImageStudio.shared { held.adoptDoor() } }
                        }
                    }
                })
        }
    }

    /// The words changed under a person's hands: the one nudge this surface gives is a count in
    /// the box's tooltip, and the foot says what the render should cost.
    func wordsChanged() {
        refreshDock()
    }

    // MARK: chips

    /// Every decision the next render is made of, drawn from Core's reading of the slot. A chip
    /// that would change nothing is disabled rather than removed, so the row never moves under
    /// the pointer: an edit takes its frame from the picture it starts from, and the fast engine
    /// reads neither the sampler length nor the alpha channel.
    func refreshChips() {
        let readings = StudioChips.image(for: slot, sighting: studio.sighting)
        for reading in readings {
            switch reading.id {
            case .engine: engineChip.apply(reading, tooltip: slot.engine.detail)
            case .aspect:
                aspectChip.apply(
                    reading,
                    tooltip: slot.applies(.aspect) ? slot.aspect.short : ImageGenWords.aspectFollowsReference)
            case .size:
                sizeChip.apply(
                    reading,
                    tooltip: slot.applies(.size) ? slot.aspect.label(slot.size) : ImageGenWords.aspectFollowsReference)
            case .detail: detailChip.apply(reading, tooltip: slot.detail.detail)
            case .cutout: cutoutChip.apply(reading, tooltip: ImageGenWords.cutoutHint)
            case .avoid: avoidChip.apply(reading, tooltip: ImageGenWords.avoidHint)
            case .seed:
                seedChip.apply(
                    reading,
                    tooltip: slot.seed.isHeld ? ImageGenWords.seedHeldHint : ImageGenWords.seedRollsHint)
            case .reference:
                referenceChip.apply(
                    reading,
                    tooltip: slot.references.isEmpty ? ImageGenWords.attachHint : ImageGenWords.attachMoreHint)
            case .craft: craftChip.apply(reading, tooltip: ImageGenBrief.craftTitle)
            case .length, .smoothness, .sound: break
            }
        }
        dock.tray.relayout(force: false)
        if let current = gtk_editable_get_text(op(avoidEntry)).map({ String(cString: $0) }),
            current != slot.negative
        {
            gtk_editable_set_text(op(avoidEntry), slot.negative)
        }
        gtk_widget_set_sensitive(avoidEntry, slot.negativeApplies ? 1 : 0)
    }

    func refreshDock() {
        resetPlaceholder()
        dock.setGo(
            title: slot.isBusy ? ImageGenWords.stopTitle : ImageGenWords.renderTitle(mode: slot.mode),
            stopping: slot.isBusy)
        dock.setLocked(slot.isBusy)
        let machineName = studio.endpoint.shortName
        let estimate = StudioEstimate.image(
            engine: slot.engine, size: slot.size, mode: slot.mode, pictures: slot.pictures,
            machine: machineName)
        let words = ImageGenBrief.words(in: promptText.trimmingCharacters(in: .whitespacesAndNewlines))
        dock.setFoot(estimate, tooltip: ImageGenStudioWords.countLine(words: words, engine: slot.engine))
        gtk_widget_set_tooltip_text(
            dock.promptView, ImageGenStudioWords.countLine(words: words, engine: slot.engine))
        refreshEnhance()
        refreshSlot()
    }

    /// The prompt says what it will do with what is attached, so the mode is legible in the one
    /// place a person is already looking.
    func resetPlaceholder() {
        let text: String
        switch slot.references.count {
        case 0: text = ImageGenNotice.emptyBody
        case 1: text = Localized.text("What to change in %@…", slot.references[0].name)
        default: text = ImageGenWords.addressHint
        }
        dock.setPlaceholder(text)
    }

    /// Words land in the dock with the caret at their end and nothing is sent. A surface that
    /// sent something the person did not type would be a surface nobody trusts twice.
    func fill(_ text: String) {
        promptText = text
        dock.placeCaretAtEnd()
        focusPrompt()
        wordsChanged()
    }

    /// The craft, as one rule's words each and four worked briefs. Opening one fills the words
    /// rather than sending them: what the person types is theirs, always.
    func craftRows() -> [(title: String, detail: String?, action: @Sendable () -> Void)] {
        let pane = Weak(self)
        var rows: [(title: String, detail: String?, action: @Sendable () -> Void)] = []
        rows.append(
            (
                title: ImageGenWords.scaffoldTitle, detail: ImageGenWords.scaffoldHint,
                action: { Gtk.onMain { pane.value?.fill(ImageGenBrief.scaffold) } }
            ))
        for rule in ImageGenBrief.rules {
            rows.append((title: rule.title, detail: rule.detail, action: {}))
        }
        for example in ImageGenBrief.examples {
            let prompt = example.prompt
            let aspect = example.aspect
            rows.append(
                (
                    title: "\(ImageGenWords.examplePrefix) \(example.title)", detail: example.detail,
                    action: {
                        Gtk.onMain {
                            guard let pane = pane.value else { return }
                            pane.studio.choose(aspect: aspect)
                            pane.fill(prompt)
                        }
                    }
                ))
        }
        return rows
    }

    // MARK: references

    /// Where a picture to start from can come from, and which of the ones held can be let go of.
    /// Always the same meaning: hand the render one more picture to work from.
    func referenceRows() -> [(title: String, detail: String?, action: @Sendable () -> Void)] {
        let pane = Weak(self)
        var rows: [(title: String, detail: String?, action: @Sendable () -> Void)] = []
        let held = slot.references
        rows.append(
            (
                title: held.isEmpty ? ImageGenReferenceSource.files.title : ImageGenWords.attachMoreTitle,
                detail: held.isEmpty ? ImageGenWords.attachHint : ImageGenWords.attachMoreHint,
                action: { Gtk.onMain { pane.value?.offerReference() } }
            ))
        rows.append(
            (
                title: ImageGenReferenceSource.clipboard.title, detail: nil,
                action: { Gtk.onMain { pane.value?.pasteReference() } }
            ))
        for (index, reference) in held.enumerated() {
            let path = reference.path
            rows.append(
                (
                    title: "\(ImageGenWords.removeReference) \(ImageGenWords.referenceSlot(index + 1))",
                    detail: ImageGenWords.releaseHint(reference.name),
                    action: {
                        Gtk.onMain {
                            pane.value?.studio.release(path)
                            pane.value?.resetPlaceholder()
                        }
                    }
                ))
        }
        return rows
    }

    /// Several at once: a person picking three pictures for one edit picks them in one gesture,
    /// and the order they picked is the order the words address them in.
    func offerReference() {
        guard slot.references.count < ImageGenSlot.referenceLimit else { return }
        Gtk.openFiles(parent: hostWindow) { [weak self] paths in
            guard !paths.isEmpty else { return }
            Gtk.onMain { [weak self] in self?.attachFiles(paths) }
        }
    }

    func attachFiles(_ paths: [String]) {
        var any = false
        for path in paths where ImageGenFileKind.of(path) != nil {
            studio.attach(ImageGenReference(path: path))
            loadReference(path)
            any = true
        }
        guard any else { return }
        resetPlaceholder()
        focusPrompt()
    }

    /// A paste is an attach when a file manager or a screenshot tool put something on the
    /// clipboard: files first, then a picture, written once to a file the render can read.
    func pasteReference() {
        Gtk.readClipboard { [weak self] offer in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                if !offer.paths.isEmpty {
                    self.attachFiles(offer.paths)
                    return
                }
                guard let data = offer.image else {
                    self.onNotice?(Localized.text("The clipboard holds no picture"))
                    return
                }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("tailscode-reference-\(UUID().uuidString).png")
                guard (try? data.write(to: url)) != nil else { return }
                self.attachFiles([url.path])
            }
        }
    }

    /// The bits of a picture the slot and the stage draw for a reference: a kept picture's own
    /// decode, or the file's, decoded once off the main loop and held only while it is a
    /// reference.
    func referenceBits(_ reference: ImageGenReference) -> UInt? {
        if let kept = reference.kept {
            if let bits = textures[kept.id], bits != 0 { return bits }
            if let bits = studio.library.textures[kept.id], bits != 0 { return bits }
        }
        if let bits = textures[reference.path], bits != 0 { return bits }
        if let bits = referenceTextures[reference.path], bits != 0 { return bits }
        loadReference(reference.path)
        return nil
    }

    func loadReference(_ path: String) {
        guard referenceTextures[path] == nil, !loadingReferences.contains(path) else { return }
        loadingReferences.insert(path)
        Task.detached { [weak self] in
            let bits: UInt = {
                guard let data = FileManager.default.contents(atPath: path) else { return 0 }
                return data.withUnsafeBytes { buffer in
                    guard let base = buffer.baseAddress else { return 0 }
                    var width: Int32 = 0
                    var height: Int32 = 0
                    guard
                        let texture = tailscode_texture_scaled(
                            base, gsize(data.count), 1024, &width, &height)
                    else { return 0 }
                    return UInt(bitPattern: UnsafeMutableRawPointer(texture))
                }
            }()
            Gtk.onMain { [weak self] in
                guard let self else {
                    if bits != 0, let raw = UnsafeMutableRawPointer(bitPattern: bits) { g_object_unref(raw) }
                    return
                }
                self.loadingReferences.remove(path)
                guard bits != 0, self.slot.references.contains(where: { $0.path == path }) else {
                    if bits != 0, let raw = UnsafeMutableRawPointer(bitPattern: bits) { g_object_unref(raw) }
                    return
                }
                self.referenceTextures[path] = bits
                self.render()
            }
        }
    }

    /// The slot wears the first picture the render starts from, with a count when there are more,
    /// and lets go of the decode of any picture that is no longer one.
    func refreshSlot() {
        let references = slot.references
        let live = Set(references.map(\.path))
        for (path, bits) in referenceTextures where !live.contains(path) {
            referenceTextures.removeValue(forKey: path)
            if let raw = UnsafeMutableRawPointer(bitPattern: bits) { g_object_unref(raw) }
        }
        let bits = references.first.flatMap(referenceBits) ?? 0
        slotView.apply(
            count: references.count, bits: bits,
            tooltip: references.first.map(ImageGenWords.referenceHint) ?? StudioWords.startFromHint)
    }

    // MARK: enhance and the rewrite card

    /// The one control that writes words rather than choosing a value, so it says which model
    /// will write them and never runs on its own.
    func refreshEnhance() {
        dock.showEnhance(
            host: studio, enhancing: studio.enhancing, canUndo: beforeEnhance != nil,
            locked: slot.isBusy)
        refreshRewrite()
    }

    /// The card follows the draft, risen over the stage's lower third.
    func refreshRewrite() {
        let showing = rewrite.refresh(studio.draft, canUse: !slot.isBusy)
        shell.showLowerCard(showing)
    }

    /// Takes the paragraph: into the box, where it can still be edited, with the typed sentence
    /// one press away. The shape the helper chose is followed only where nobody chose one by
    /// hand, and never for an edit, which takes its shape from the picture.
    func useRewrite() {
        guard let draft = studio.draft, draft.isUsable else { return }
        beforeEnhance = promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? draft.original : promptText
        if let aspect = draft.aspect, !studio.aspectChosen, slot.applies(.aspect) {
            studio.follow(aspect: aspect)
        }
        fill(draft.written)
        studio.dismissRewrite()
        onNotice?(ImageGenWords.enhancedNotice(draft.helper))
        refreshEnhance()
    }

    /// Press once to have the brief written out, press again while it writes to stop it, and
    /// press once more after taking it to get your own sentence back.
    func enhancePressed() {
        if let original = beforeEnhance {
            fill(original)
            beforeEnhance = nil
            refreshEnhance()
            return
        }
        if studio.enhancing {
            studio.stopRewrite()
            return
        }
        let brief = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brief.isEmpty else {
            focusPrompt()
            return
        }
        studio.rewrite(brief)
    }

    // MARK: sending and the verbs

    func renderPressed() {
        if slot.isBusy {
            studio.stop()
        } else {
            submit()
        }
    }

    func submit() {
        studio.submit(prompt: promptText)
        render()
    }

    func handle(_ command: ImageGenCommand) {
        guard !slot.isBusy || command.duringRender else { return }
        switch command {
        case .submit: submit()
        case .stop: studio.stop()
        case .engine: studio.advance(.engine)
        case .aspect: studio.advance(.aspect)
        case .size: studio.advance(.size)
        case .detail: studio.advance(.detail)
        case .cutout: studio.setCutout(!slot.cutout)
        case .seed: studio.toggleSeedHold()
        case .reference: offerReference()
        case .again: performAgain()
        case .save: perform(.save)
        case .copy: perform(.copy)
        case .open: openStage()
        case .next: step(by: 1)
        case .previous: step(by: -1)
        }
        render()
    }

    /// Walks the shelf: the newest is first, so "next" moves back through what was made the way
    /// the eye reads it rather than the way the list is stored. Stops where the shelf does.
    func step(by delta: Int) {
        guard let next = StudioShelf.step(from: selectedTile, by: delta, in: entries) else { return }
        choose(tile: next)
        shelf.reveal(next)
    }

    /// The same words again, with whichever engine made the picture in the first place when that
    /// is known — a kept picture rolled again should paint with what made it, not with whatever
    /// chip happens to be selected.
    func performAgain() {
        if let kept = studio.keptStage {
            guard let prompt = kept.facts?.recipe?.prompt else { return }
            studio.again(prompt: prompt, engine: kept.facts?.recipe?.engine)
        } else {
            studio.again()
        }
    }

    func perform(_ action: ImageGenAction) {
        guard let path = stagePath else { return }
        switch action {
        case .save:
            guard let data = studio.bytes(atPath: path) else { return }
            Gtk.saveFile(parent: hostWindow, suggestedName: stageFileName(), data: data) { [weak self] savedPath in
                guard let savedPath else { return }
                Gtk.onMain { [weak self] in self?.onNotice?(ImageGenWords.savedNotice(path: savedPath)) }
            }
        case .copy:
            guard let data = studio.bytes(atPath: path) else { return }
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                tailscode_clipboard_set_image_png(base, gsize(data.count))
            }
            onNotice?(ImageGenWords.copiedNotice)
        case .open:
            openStage()
        case .again:
            performAgain()
        case .reference:
            if let kept = studio.keptStage {
                studio.attach(ImageGenReference(path: path, kept: kept.item))
            } else {
                studio.attach(ImageGenReference(path: path))
            }
            resetPlaceholder()
            focusPrompt()
        case .discard:
            studio.discard(path)
        case .share, .stage:
            break
        }
    }

    /// What a finished picture can be made to do, in the order a hand reaches for it, with the
    /// one that destroys apart from the others. The set is Core's; the bridge to the forge is the
    /// one verb the desk adds.
    func stageVerbs(reserved: Bool) -> [StudioVerb] {
        let actions: [ImageGenAction]
        if reserved {
            actions = ImageGenAction.offered(kept: false, hasWords: true, sharing: false, tapOpens: false)
        } else if let kept = studio.keptStage {
            actions = ImageGenAction.offered(
                kept: true, hasWords: kept.facts?.recipe?.prompt != nil, sharing: false, tapOpens: false)
        } else if slot.onStage != nil {
            actions = ImageGenAction.offered(kept: false, hasWords: true, sharing: false, tapOpens: false)
        } else {
            return []
        }
        let pane = Weak(self)
        var verbs: [StudioVerb] = []
        for action in actions {
            verbs.append(
                StudioVerb(
                    id: action.rawValue, glyph: action.glyph, title: action.title, hint: action.hint,
                    isDestructive: action.isDestructive, isPrimary: action == .again,
                    perform: { pane.value?.perform(action) }))
            if action == .reference {
                verbs.append(
                    StudioVerb(
                        id: "animate", glyph: "▶", title: ForgeWords.animateTitle, hint: ForgeWords.animateHint,
                        perform: { pane.value?.animateStage() }))
            }
        }
        return verbs
    }

    /// The verbs, offered where a hand already is: a right click on the picture. The same set as
    /// the capsule, from the same source.
    func presentStageMenu(on widget: UnsafeMutablePointer<GtkWidget>, x: Double, y: Double) {
        let rows = stageVerbs(reserved: false).map { verb in
            (title: "\(verb.glyph)  \(verb.title)", detail: Optional(verb.hint), action: verb.perform)
        }
        Gtk.contextMenu(on: widget, x: x, y: y, rows: rows)
    }

    /// The bridge to the other thing this app makes: the forge opened over the work, holding
    /// this picture as the clip's first frame. A picture the machine keeps is named in its own
    /// directory so no byte travels; one only this device holds is sent with the render.
    func animateStage() {
        let frame: ForgeFrame
        var width: Int?
        var height: Int?
        if let kept = studio.keptStage {
            frame = .kept(kept.item.annotatedName)
            width = kept.facts?.width
            height = kept.facts?.height
        } else if let picture = slot.onStage, let remote = picture.remoteName {
            frame = .kept(ImageGenLibraryItem(filename: remote).annotatedName)
            width = picture.aspect.pixels.width
            height = picture.aspect.pixels.height
        } else if let path = stagePath {
            frame = .file(path)
        } else {
            return
        }
        ForgeRunner.shared.start(from: frame, width: width, height: height)
        StudioSheet.shared?.show(.video)
    }
}
