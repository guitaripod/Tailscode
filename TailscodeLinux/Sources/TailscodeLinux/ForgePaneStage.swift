import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension ForgePane {
    /// Everything the stage says, from what the board and the player hold right now.
    func refreshStage() {
        let job = board.job
        gtk_aspect_frame_set_ratio(op(frame), Float(ratio))
        if let frame = job.sketch, frame != shownSketch { adoptSketch(frame) }
        switch job.phase {
        case .drafting, .failed, .cancelled: if !isPlaying { dropSketch() }
        default: break
        }

        var sentence: String?
        var detail: String?
        var tone: ActivityTone?
        var breathing = false
        var card: UnsafeMutablePointer<GtkWidget>?
        var verbs: [StudioVerb] = []
        var showVerbs = false
        var spoken = ForgeBoard().prompt

        if let aside = reason {
            sentence = aside
            tone = .danger
        } else if let waiting = working {
            sentence = waiting
            tone = .live
            breathing = true
        }

        if board.isBusy {
            showFace("picture")
            if sentence == nil {
                sentence = busyLine(job)
                tone = .live
                breathing = true
            }
            spoken = busyLine(job)
            if sketchTexture != 0 {
                gtk_stack_set_visible_child_name(op(art), "sketch")
            } else {
                showHeld(key: "working", bits: 0, opacity: 1)
            }
            verbs = clipVerbs(reserved: true)
        } else if case .failed(let why) = job.phase, !isPlaying {
            showFace("empty")
            gtk_widget_set_visible(emptyColumn, 0)
            refreshBackdrop(asset: entries.first(where: \.isPlayable)?.asset, dim: 0.3)
            card = failureCard(why)
            runner.acknowledgeFailure()
            tone = tone ?? .danger
            spoken = why
        } else if isPlaying {
            showFace("picture")
            if loaded { showPlayer() }
            if sentence == nil, let entry = entries.first(where: { $0.asset == playing }) {
                sentence = entry.title
                detail = entry.detail
            }
            if let entry = entries.first(where: { $0.asset == playing }) {
                verbs = clipVerbs(for: entry)
                showVerbs = loaded
                spoken = entry.title
            }
        } else if let entry = continuation(), !isLocating {
            showFace("empty")
            gtk_widget_set_visible(emptyColumn, 0)
            refreshBackdrop(asset: entry.asset, dim: 0.34)
            card = continuationCard(entry)
            if case .cancelled = job.phase, sentence == nil {
                sentence = ImageGenWords.stoppedNotice
                tone = .attention
            }
            spoken = ForgeWords.continuingTitle(entry)
        } else if let asset = job.asset, let entry = entries.first(where: { $0.asset == asset }) {
            showFace("picture")
            let key = ForgePosters.key(for: asset)
            showHeld(key: key, bits: posters.textures[key] ?? 0, opacity: 1)
            if sentence == nil {
                sentence = entry.title
                detail = entry.detail
            }
            verbs = clipVerbs(for: entry)
            showVerbs = true
            spoken = entry.title
        } else {
            showFace("empty")
            gtk_widget_set_visible(emptyColumn, 1)
            refreshBackdrop(asset: entries.first(where: \.isPlayable)?.asset, dim: 0.16)
            if sentence == nil, case .cancelled = job.phase {
                sentence = ImageGenWords.stoppedNotice
                tone = .attention
            }
            if sentence == nil, let line = board.readiness.flatMap(MediaReading.videoLine) {
                sentence = line.detail
                tone = line.tone
                breathing = line.state == .working
            }
            if sentence == nil, backdropKey != nil, let name = board.endpoint?.shortName {
                sentence = StudioWords.heldFromShelf(machine: name)
            }
        }
        shell.setState(sentence, detail: detail, tone: tone, breathing: breathing)
        shell.setProgress(progressSegments(job))
        shell.setVerbs(verbs, visible: showVerbs)
        shell.setCard(card)
        shell.describe(spoken)
        refreshSketchBadge()
    }

    /// A picture held in the frame while nothing is playing and nothing is painting: a landed
    /// clip's poster, or an empty placeholder in the clip's own shape until there is one.
    func showHeld(key: String, bits: UInt, opacity: Double) {
        showFace("picture")
        if heldKey != key {
            Gtk.removeChildren(of: heldSlot)
            if bits != 0, let picture = Gtk.studioPicture(bits: bits) {
                Gtk.setHidden(picture, true)
                gtk_box_append(ptr(heldSlot), picture)
            } else {
                let placeholder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
                Gtk.addClass(placeholder, "draw-working")
                gtk_widget_set_hexpand(placeholder, 1)
                gtk_widget_set_vexpand(placeholder, 1)
                gtk_box_append(ptr(heldSlot), placeholder)
            }
            heldKey = key
        }
        gtk_widget_set_opacity(heldSlot, opacity)
        gtk_stack_set_transition_type(op(art), GTK_STACK_TRANSITION_TYPE_NONE)
        gtk_stack_set_visible_child_name(op(art), "held")
    }

    func showFace(_ name: String) {
        gtk_stack_set_visible_child_name(op(faces), name)
    }

    /// The sentence for a render in flight, in the order a person watches it: which pass, which
    /// step, how long it has been going — or, before the machine is painting, what it is waiting on.
    func busyLine(_ job: ForgeJob) -> String {
        let clock = job.spent() ?? ""
        if job.samplerSteps > 0 {
            let base = job.detail
            return clock.isEmpty ? base : "\(base) · \(clock)"
        }
        let base = job.stageName ?? job.subtitle
        return clock.isEmpty ? base : "\(base) · \(clock)"
    }

    /// The progress line, one segment per pass when the machine says which node is working and the
    /// one bar it has otherwise — and nothing at all until there is a count to draw it from.
    func progressSegments(_ job: ForgeJob) -> [Double]? {
        guard job.isBusy, let fraction = job.fraction else { return nil }
        if let passes = StudioProgress.passes(
            running: job.census?.running, step: job.samplerStep, steps: job.samplerSteps)
        {
            return passes
        }
        return [fraction]
    }

    func refreshSketchBadge() {
        let sketching = board.isBusy && visibleArt == "sketch"
        gtk_widget_set_visible(sketchBadge, sketching ? 1 : 0)
        if sketching { gtk_label_set_text(op(sketchBadge), ForgeWords.sketchCaption(board.job)) }
    }

    /// A clip's poster, held dimmed behind everything the empty stage says: the newest clip's by
    /// default, and the clip a continuation opens on while one is waiting to be written.
    func refreshBackdrop(asset: ForgeAsset?, dim: Double) {
        let key = asset.map(ForgePosters.key(for:))
        let bits = key.flatMap { posters.textures[$0] } ?? 0
        guard bits != 0, let key else {
            if backdropKey != nil {
                Gtk.removeChildren(of: backdrop)
                backdropKey = nil
            }
            return
        }
        if backdropKey != key {
            Gtk.removeChildren(of: backdrop)
            if let picture = Gtk.studioPicture(bits: bits, fit: GTK_CONTENT_FIT_COVER) {
                Gtk.setHidden(picture, true)
                gtk_box_append(ptr(backdrop), picture)
            }
            backdropKey = key
        }
        gtk_widget_set_opacity(backdrop, dim)
    }

    /// The finished clip's verbs: a copy somewhere of the person's own, and the next clip from
    /// where this one ended. They hold their room while a render is out. Each verb acts on the
    /// clip the stage is on when it is pressed — the stage looks the action up then, not when the
    /// button was drawn.
    func clipVerbs(for entry: ForgeEntry) -> [StudioVerb] {
        guard entry.asset != nil else { return [] }
        let pane = Weak(self)
        var verbs = [
            StudioVerb(
                id: "save", glyph: "↓", title: ImageGenAction.save.title,
                hint: Localized.text("Write the clip somewhere of your own"),
                perform: { pane.value?.save(entry) })
        ]
        if board.canContinue(entry) {
            verbs.append(
                StudioVerb(
                    id: "extend", glyph: "⏭", title: ForgeWords.extendTitle, hint: ForgeWords.extendHint,
                    isPrimary: true, perform: { pane.value?.continueFrom(entry) }))
        }
        return verbs
    }

    func clipVerbs(reserved: Bool) -> [StudioVerb] {
        [
            StudioVerb(id: "save", glyph: "↓", title: ImageGenAction.save.title, hint: "", perform: {}),
            StudioVerb(id: "extend", glyph: "⏭", title: ForgeWords.extendTitle, hint: "", perform: {}),
        ]
    }

    /// The next clip opens where this one ended. The stage lets go of the clip and says what it is
    /// now waiting for — a card naming the clip, its poster behind it, the words in the box to be
    /// changed into what happens next — so the press has an answer on screen rather than a slot
    /// that changed beside the prompt.
    func continueFrom(_ entry: ForgeEntry) {
        guard !board.isBusy else { return }
        guard board.canContinue(entry) else {
            reason = ForgeWords.continueElsewhere(entry.endpoint?.shortName ?? "")
            render()
            return
        }
        AppLog.write(.ui, "forge continue entry=\(entry.id) file=\(entry.asset?.filename ?? "-")")
        releaseStage()
        dropSketch()
        reason = nil
        runner.extend(entry)
        render()
        focusPrompt()
    }

    var isLocating: Bool { chosen != nil && !isPlaying }

    /// The clip the next render would open on the end of, while the stage has nothing else to say.
    func continuation() -> ForgeEntry? {
        guard !board.isBusy, board.job.asset == nil, let entry = board.continuing else { return nil }
        return entry
    }

    func continuationCard(_ entry: ForgeEntry) -> UnsafeMutablePointer<GtkWidget> {
        let pane = Weak(self)
        return StudioFailureCard.make(
            sentence: ForgeWords.continuingTitle(entry), note: ForgeWords.continuingBody, mark: "⏭",
            remedies: [
                (title: ForgeWords.continuingFreshTitle, primary: false,
                 perform: { pane.value?.runner.start(from: nil) })
            ])
    }

    /// The clip's bytes, fetched from the machine that wrote them, into a file of the person's
    /// choosing — never a re-encode of what the player showed. The name offered says what the clip
    /// is rather than where the machine happened to file it.
    func save(_ entry: ForgeEntry) {
        guard !saving, let asset = entry.asset, let client = runner.client(for: entry) else { return }
        AppLog.write(.ui, "forge save entry=\(entry.id) file=\(asset.filename) as=\(entry.fileName) machine=\(client.endpoint.host)")
        saving = true
        working = Localized.text("Fetching…")
        render()
        Task { [weak self] in
            do {
                let data = try await client.fetch(asset)
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.saving = false
                    self.working = nil
                    self.render()
                    Gtk.saveFile(parent: self.hostWindow, suggestedName: entry.fileName, data: data) { [weak self] path in
                        guard let path else { return }
                        Gtk.onMain { [weak self] in
                            self?.reason = nil
                            self?.working = nil
                            self?.flash(ImageGenWords.savedNotice(path: path))
                        }
                    }
                }
            } catch {
                let sentence = ForgeClient.reason(error, host: client.endpoint.host)
                Gtk.onMain { [weak self] in
                    self?.saving = false
                    self?.working = nil
                    self?.reason = sentence
                    self?.render()
                }
            }
        }
    }

    /// One line on the stage's own state row for a few seconds — a file written — and then the
    /// stage says what it was saying.
    func flash(_ line: String) {
        shell.setState(line, tone: .live, breathing: false)
        Gtk.after(4000) { [weak self] in Gtk.onMain { [weak self] in self?.render() } }
    }

    /// The failure's one honest sentence and the remedies that follow from it: the same words
    /// again, the machine's own account, and another look.
    func failureCard(_ why: String) -> UnsafeMutablePointer<GtkWidget> {
        let pane = Weak(self)
        return StudioFailureCard.make(
            sentence: why, note: nil,
            remedies: [
                (title: Localized.text("Try again"), primary: true,
                 perform: { pane.value?.callPressed() }),
                (title: ImageGenMachineWords.title + "…", primary: false,
                 perform: { pane.value?.machine.open() }),
                (title: ImageGenMachineWords.checkAgain, primary: false,
                 perform: { pane.value?.runner.probe() }),
            ])
    }

    // MARK: the dock
}
