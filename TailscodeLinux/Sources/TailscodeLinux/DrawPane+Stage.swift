import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension DrawPane {
    /// The stage: one canvas, two faces. Empty is the machine's most recent picture held dimmed
    /// behind four starter ideas; the other face is a frame of exactly the picture's shape holding
    /// a stack of three things that are never rebuilt while a job runs — the machine's sketch, the
    /// finished picture, and the picture held dimmed while the machine thinks. Which one shows is
    /// a decision about visibility, not about layout, so nothing moves when a render lands.
    func buildStage() {
        Gtk.addClass(backdrop, "studio-backdrop")
        gtk_widget_set_hexpand(backdrop, 1)
        gtk_widget_set_vexpand(backdrop, 1)
        Gtk.addClass(emptyOverlay, "studio-drop")
        gtk_widget_set_overflow(emptyOverlay, GTK_OVERFLOW_HIDDEN)
        gtk_overlay_set_child(op(emptyOverlay), backdrop)
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        gtk_widget_set_valign(column, GTK_ALIGN_CENTER)
        gtk_widget_set_halign(column, GTK_ALIGN_CENTER)
        gtk_label_set_text(op(emptyTitle), StudioWords.dropTitle)
        gtk_label_set_xalign(op(emptyTitle), 0.5)
        gtk_label_set_wrap(op(emptyTitle), 1)
        gtk_label_set_justify(op(emptyTitle), GTK_JUSTIFY_CENTER)
        gtk_label_set_max_width_chars(op(emptyTitle), 48)
        gtk_label_set_text(op(emptyBody), StudioWords.dropBody)
        gtk_label_set_xalign(op(emptyBody), 0.5)
        gtk_label_set_justify(op(emptyBody), GTK_JUSTIFY_CENTER)
        gtk_box_append(ptr(column), emptyTitle)
        gtk_box_append(ptr(column), emptyBody)
        let grid = buildStarters()
        starters = grid
        gtk_box_append(ptr(column), grid)
        gtk_overlay_add_overlay(op(emptyOverlay), column)
        emptyColumn = column

        gtk_aspect_frame_set_child(op(frame), art)
        gtk_widget_set_hexpand(frame, 1)
        gtk_widget_set_vexpand(frame, 1)
        gtk_widget_set_hexpand(art, 1)
        gtk_widget_set_vexpand(art, 1)
        gtk_widget_set_overflow(art, GTK_OVERFLOW_HIDDEN)
        Gtk.addClass(art, "studio-art")
        gtk_stack_set_transition_type(op(art), GTK_STACK_TRANSITION_TYPE_NONE)
        gtk_stack_set_hhomogeneous(op(art), 1)
        gtk_stack_set_vhomogeneous(op(art), 1)

        gtk_picture_set_content_fit(op(sketchPicture), GTK_CONTENT_FIT_FILL)
        gtk_widget_set_hexpand(sketchPicture, 1)
        gtk_widget_set_vexpand(sketchPicture, 1)
        Gtk.setHidden(sketchPicture, true)
        gtk_overlay_set_child(op(sketchOverlay), sketchPicture)
        gtk_widget_set_halign(sketchBadge, GTK_ALIGN_START)
        gtk_widget_set_valign(sketchBadge, GTK_ALIGN_START)
        Gtk.margins(sketchBadge, top: 10, leading: 10)
        gtk_widget_set_can_target(sketchBadge, 0)
        gtk_label_set_ellipsize(op(sketchBadge), PANGO_ELLIPSIZE_NONE)
        gtk_overlay_add_overlay(op(sketchOverlay), sketchBadge)
        gtk_widget_set_tooltip_text(sketchOverlay, ImageGenPreviewWords.note)

        for child in [mainSlot, heldSlot] {
            gtk_widget_set_hexpand(child, 1)
            gtk_widget_set_vexpand(child, 1)
        }
        gtk_stack_add_named(op(art), sketchOverlay, "sketch")
        gtk_stack_add_named(op(art), mainSlot, "main")
        gtk_stack_add_named(op(art), heldSlot, "held")

        gtk_stack_add_named(op(faces), emptyOverlay, "empty")
        gtk_stack_add_named(op(faces), frame, "picture")
        gtk_widget_set_hexpand(faces, 1)
        gtk_widget_set_vexpand(faces, 1)
        gtk_box_append(ptr(shell.content), faces)

        Gtk.acceptFileDrops(on: shell.root) { [weak self] paths in
            Gtk.onMain { [weak self] in self?.attachFiles(paths) }
        }
        shell.onResize = { [weak self] _, height in
            Gtk.onMain { [weak self] in self?.stageResized(height: height) }
        }
    }

    /// A stage too short to hold four starter cards under its sentence shows the sentence alone:
    /// the starters are an invitation, and an invitation that is cut off at the bottom of the
    /// stage is clutter. The stage's size does not depend on them, so hiding them cannot loop.
    func stageResized(height: Double) {
        gtk_widget_set_visible(starters, height >= 420 ? 1 : 0)
    }

    /// Four briefs that are known to come back right. They fill the words rather than sending
    /// anything: an empty stage argues for itself and then hands over something to press.
    private func buildStarters() -> UnsafeMutablePointer<GtkWidget> {
        let grid = gtk_flow_box_new()!
        gtk_flow_box_set_selection_mode(op(grid), GTK_SELECTION_NONE)
        gtk_flow_box_set_max_children_per_line(op(grid), 2)
        gtk_flow_box_set_min_children_per_line(op(grid), 1)
        gtk_flow_box_set_row_spacing(op(grid), 8)
        gtk_flow_box_set_column_spacing(op(grid), 8)
        gtk_flow_box_set_homogeneous(op(grid), 1)
        gtk_widget_set_halign(grid, GTK_ALIGN_CENTER)
        gtk_widget_set_margin_top(grid, 14)
        for example in ImageGenBrief.examples {
            let prompt = example.prompt
            let aspect = example.aspect
            let card = gtk_button_new()!
            Gtk.addClass(card, "draw-example")
            let lines = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
            let name = Gtk.label(example.title, css: "draw-example-title", selectable: false)
            let detail = Gtk.label(example.detail, css: "draw-example-detail", wrap: true, selectable: false)
            gtk_label_set_max_width_chars(op(detail), 30)
            gtk_box_append(ptr(lines), name)
            gtk_box_append(ptr(lines), detail)
            gtk_button_set_child(ptr(card), lines)
            gtk_widget_set_tooltip_text(card, ImageGenWords.scaffoldHint)
            Gtk.connect(UnsafeMutableRawPointer(card), "clicked") { [weak self] in
                Gtk.onMain { [weak self] in
                    self?.studio.choose(aspect: aspect)
                    self?.fill(prompt)
                }
            }
            gtk_flow_box_insert(op(grid), card, -1)
        }
        return grid
    }

    /// Everything the stage says, from what the studio holds right now.
    func refreshStage() {
        let busy = slot.isBusy
        let key = stageTextureKey
        let stageBits = key.flatMap { textures[$0] } ?? 0
        if busy || stageBits == 0 { zoomed = false }
        applyZoom()

        var sentence: String?
        var detail: String?
        var tone: ActivityTone?
        var breathing = false
        var card: UnsafeMutablePointer<GtkWidget>?
        var verbs: [StudioVerb] = []
        var verbsShown = false
        var spoken = ImageGenWords.emptyBody

        if busy {
            showPainting()
            sentence = paintingSentence
            tone = .live
            breathing = true
            verbs = stageVerbs(reserved: true)
            spoken = sentence ?? spoken
        } else if case .failed(_, let reason) = slot.phase, reason != ImageGenWords.stoppedNotice {
            showFailureBackdrop(bits: stageBits)
            card = failureCard(reason)
            tone = .danger
            spoken = reason
        } else if stageBits != 0, let key {
            showPicture(key: key, bits: stageBits)
            if case .failed = slot.phase {
                sentence = ImageGenWords.stoppedNotice
                tone = .attention
            } else {
                sentence = stageCaption
                detail = stageFactsLine.isEmpty ? nil : stageFactsLine
            }
            verbs = stageVerbs(reserved: false)
            verbsShown = true
            spoken = [stageCaption, stageFactsLine].filter { !$0.isEmpty }.joined(separator: ". ")
        } else if let reference = slot.references.first, let bits = referenceBits(reference), bits != 0 {
            showHeld(key: "ref:" + reference.path, bits: bits, opacity: 1)
            sentence = ImageGenWords.referenceHint(reference)
            spoken = sentence ?? spoken
        } else {
            showEmpty()
            if backdropKey != nil { sentence = StudioWords.heldFromShelf(machine: studio.endpoint.shortName) }
            if case .failed = slot.phase { sentence = ImageGenWords.stoppedNotice }
        }

        if zoomed {
            sentence = ImageGenWords.zoomHint
            tone = nil
            verbs = []
        }
        shell.setState(sentence, detail: detail, tone: tone, breathing: breathing)
        shell.setProgress(busy ? studio.progress?.bar.map { [$0] } : nil)
        shell.setVerbs(verbs, visible: verbsShown && !zoomed)
        shell.setCard(card)
        shell.describe(spoken)
        refreshSketchBadge()
    }

    private func applyZoom() {
        chrome.setZoomed(zoomed)
    }

    var paintingSentence: String {
        let line = studio.progress?.line ?? slot.busyLine
        let clock = ImageGenStudioWords.clockLine(since: studio.startedAt, ahead: nil)
        return clock.isEmpty ? line : "\(line) · \(clock)"
    }

    /// The shape of the picture a render is about to make, decided before it starts: a reference
    /// being edited sets the shape by its own, otherwise it is the chosen shape at the chosen
    /// size. The sketch and the finished picture are both fitted to this one rectangle.
    private var paintingRatio: Double {
        if slot.mode == .edit, let reference = slot.references.first,
            let bits = referenceBits(reference), let size = Gtk.textureSize(bits: bits)
        {
            return Double(size.width) / Double(size.height)
        }
        let pixels = slot.aspect.pixels(slot.size)
        return Double(pixels.width) / Double(max(pixels.height, 1))
    }

    private func setRatio(_ ratio: Double) {
        guard ratio > 0 else { return }
        gtk_aspect_frame_set_ratio(op(frame), Float(ratio))
    }

    private func showEmpty() {
        gtk_stack_set_visible_child_name(op(faces), "empty")
        gtk_widget_set_visible(emptyColumn, 1)
        refreshBackdrop(dim: 0.16)
        gtk_widget_set_opacity(sketchOverlay, 1)
    }

    /// The machine's newest picture, held dimmed behind everything the empty stage says. It is
    /// the thumbnail the shelf already decoded, drawn far larger than it is, which is exactly the
    /// soft held-behind-glass look the stage wants — no second decode, no blur pass.
    private func refreshBackdrop(dim: Double) {
        let id = entries.first(where: { !$0.isInFlight })?.id
        let bits = id.flatMap { thumbnailBits(for: $0) } ?? 0
        guard bits != 0, let id else {
            if backdropKey != nil {
                Gtk.removeChildren(of: backdrop)
                backdropKey = nil
            }
            return
        }
        if backdropKey != id {
            Gtk.removeChildren(of: backdrop)
            if let picture = Gtk.studioPicture(bits: bits, fit: GTK_CONTENT_FIT_COVER) {
                Gtk.setHidden(picture, true)
                gtk_box_append(ptr(backdrop), picture)
            }
            backdropKey = id
        }
        gtk_widget_set_opacity(backdrop, dim)
    }

    /// While the machine paints: the sketch fills the frame, and until the first one arrives the
    /// picture that was there — or the picture being edited — stays held dimmed in the same
    /// rectangle, so the wait has a shape from the first moment.
    private func showPainting() {
        gtk_stack_set_visible_child_name(op(faces), "picture")
        setRatio(paintingRatio)
        if studio.previewTexture != 0 {
            Gtk.replacePicture(of: sketchPicture, bits: studio.previewTexture)
            gtk_stack_set_transition_type(op(art), GTK_STACK_TRANSITION_TYPE_NONE)
            gtk_stack_set_visible_child_name(op(art), "sketch")
            let finishing: Bool
            switch studio.progress?.stage {
            case .decoding?, .saving?: finishing = true
            default: finishing = false
            }
            gtk_widget_set_opacity(sketchOverlay, finishing ? 0.8 : 1)
            return
        }
        if let held = underwayKey, let bits = bitsForKey(held), bits != 0 {
            showHeld(key: held, bits: bits, opacity: 0.45)
        } else {
            showHeld(key: "working", bits: 0, opacity: 1)
        }
    }

    private func showFailureBackdrop(bits: UInt) {
        if bits != 0, let key = stageTextureKey {
            showHeld(key: key, bits: bits, opacity: 0.35)
        } else {
            gtk_stack_set_visible_child_name(op(faces), "empty")
            gtk_widget_set_visible(emptyColumn, 0)
            refreshBackdrop(dim: 0.3)
        }
    }

    private func showHeld(key: String, bits: UInt, opacity: Double) {
        gtk_stack_set_visible_child_name(op(faces), "picture")
        if let size = bits != 0 ? Gtk.textureSize(bits: bits) : nil, !slot.isBusy {
            setRatio(Double(size.width) / Double(size.height))
        }
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

    /// The finished picture, in the frame the sketch was in. A picture that just landed under a
    /// sketch crossfades from it once, 240 milliseconds, ease-out; anything else — a picture put
    /// on the stage from the shelf, a desk that asked for no animation — is simply there.
    private func showPicture(key: String, bits: UInt) {
        gtk_stack_set_visible_child_name(op(faces), "picture")
        if let size = Gtk.textureSize(bits: bits) {
            setRatio(Double(size.width) / Double(size.height))
        }
        if mainKey != key {
            Gtk.removeChildren(of: mainSlot)
            if let picture = Gtk.studioPicture(bits: bits) {
                Gtk.setHidden(picture, true)
                let button = gtk_button_new()!
                Gtk.addClass(button, "draw-tile")
                Gtk.addClass(button, "studio-main")
                gtk_widget_set_hexpand(button, 1)
                gtk_widget_set_vexpand(button, 1)
                gtk_button_set_child(ptr(button), picture)
                gtk_widget_set_tooltip_text(button, ImageGenAction.open.hint)
                Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
                    Gtk.onMain { [weak self] in self?.openStage() }
                }
                Gtk.onRightClick(button) { [weak self] x, y in
                    Gtk.onMain { [weak self] in
                        guard let self, let button = self.mainSlot.firstChild else { return }
                        self.presentStageMenu(on: button, x: x, y: y)
                    }
                }
                gtk_box_append(ptr(mainSlot), button)
            }
            mainKey = key
        }
        let landing = visibleArt == "sketch" && arrivedKey != key
            && slot.pictures.first?.path == key && studio.previewTexture != 0
        if landing {
            arrivedKey = key
            if Gtk.animationsAllowed {
                gtk_stack_set_transition_duration(op(art), Self.arrivalFade)
                gtk_stack_set_transition_type(op(art), GTK_STACK_TRANSITION_TYPE_CROSSFADE)
                gtk_stack_set_visible_child_name(op(art), "main")
                fadeEnds = Date().addingTimeInterval(Double(Self.arrivalFade + 200) / 1000)
                Gtk.after(Self.arrivalFade + 200) { [weak self] in
                    Gtk.onMain { [weak self] in self?.finishArrival() }
                }
            } else {
                gtk_stack_set_transition_type(op(art), GTK_STACK_TRANSITION_TYPE_NONE)
                gtk_stack_set_visible_child_name(op(art), "main")
                finishArrival()
            }
            return
        }
        if let fadeEnds, fadeEnds > Date(), visibleArt == "main" { return }
        gtk_stack_set_transition_type(op(art), GTK_STACK_TRANSITION_TYPE_NONE)
        gtk_stack_set_visible_child_name(op(art), "main")
    }

    static let arrivalFade: UInt32 = 240

    /// The fade is over: the sketch is let go of, in the studio and in the widget that wore it.
    private func finishArrival() {
        fadeEnds = nil
        gtk_stack_set_transition_type(op(art), GTK_STACK_TRANSITION_TYPE_NONE)
        gtk_picture_set_paintable(op(sketchPicture), nil)
        studio.settleSketch()
    }

    /// A new sketch swaps the paintable of the picture already on the stage, and the shelf's tile
    /// that wears it; only the first frame, which has no picture to swap into, redraws the stage.
    func adoptSketch() {
        guard slot.isBusy, studio.previewTexture != 0 else { return }
        guard visibleArt == "sketch" else {
            refreshStage()
            shelf.refreshPicture(StudioShelf.inFlightID)
            return
        }
        Gtk.replacePicture(of: sketchPicture, bits: studio.previewTexture)
        refreshSketchBadge()
        shelf.refreshPicture(StudioShelf.inFlightID)
    }

    func refreshSketchBadge() {
        let sketching = slot.isBusy && visibleArt == "sketch"
        gtk_widget_set_visible(sketchBadge, sketching ? 1 : 0)
        if sketching { gtk_label_set_text(op(sketchBadge), ImageGenPreviewWords.caption(studio.progress)) }
    }

    /// A step moved: the machine's line, the progress line, the clock and the in-flight tile's
    /// own count change in place. Nothing is rebuilt — a frame changes words, never layout.
    func refreshProgressOnly() {
        guard slot.isBusy else { return }
        shell.setState(paintingSentence, tone: .live, breathing: true)
        shell.setProgress(studio.progress?.bar.map { [$0] })
        shell.describe(paintingSentence)
        refreshSketchBadge()
        updateJobTile()
        startTicking()
    }

    /// One second is the whole resolution a wait like this needs, and the clock stops the moment
    /// the render does — a surface that keeps a timer alive over a settled state is a surface
    /// spending frames on nothing.
    func startTicking() {
        guard !ticking else { return }
        ticking = true
        tick()
    }

    private func tick() {
        Gtk.after(1000) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                guard self.slot.isBusy else {
                    self.ticking = false
                    return
                }
                self.shell.setState(self.paintingSentence, tone: .live, breathing: true)
                self.tick()
            }
        }
    }

    /// What stays on the stage, dimmed, while a render is out: the picture being edited when
    /// there is one — the result replaces it — else the last picture this session made.
    var underwayKey: String? {
        if slot.mode == .edit, let reference = slot.references.first {
            return reference.kept?.id ?? reference.path
        }
        return slot.pictures.first?.path
    }

    func bitsForKey(_ key: String) -> UInt? {
        if let bits = textures[key], bits != 0 { return bits }
        if let bits = studio.library.textures[key], bits != 0 { return bits }
        if let bits = referenceTextures[key], bits != 0 { return bits }
        return nil
    }

    /// The key into ``ImageStudio/textures`` for whatever is on the stage right now: a library
    /// item's own id for a kept picture, a session render's local path otherwise.
    var stageTextureKey: String? {
        if let kept = studio.keptStage { return kept.item.id }
        return slot.onStage?.path
    }

    /// The local file a save, a copy or a reference reads from — nil while a kept picture's
    /// original is still on its way from the machine.
    var stagePath: String? {
        if let kept = studio.keptStage { return kept.path }
        return slot.onStage?.path
    }

    var stageAvailable: Bool { studio.keptStage != nil || slot.onStage != nil }

    var stageCaption: String {
        if let kept = studio.keptStage { return ImageGenFacts.caption(for: kept.facts) }
        return slot.onStage?.prompt ?? ""
    }

    var stageFactsLine: String {
        if let kept = studio.keptStage { return ImageGenFacts.line(for: kept.facts) }
        guard let picture = slot.onStage else { return "" }
        return ImageGenFacts.line(for: picture)
    }

    /// Which shelf tile is the one on the stage — a session render is the same picture as the
    /// machine's own copy of it the moment the listing catches up, so the tile is marked rather
    /// than drawn a second time.
    var onStageLibraryID: String? {
        if let kept = studio.keptStage { return kept.item.id }
        return slot.onStage?.remoteName
    }

    func stageFileName() -> String {
        if let kept = studio.keptStage { return kept.item.filename }
        if let picture = slot.onStage { return ImageGenFacts.fileName(for: picture) }
        return "image.png"
    }

    /// The failure's one honest sentence and the remedies that follow from it: a machine that
    /// lacks the engine's files offers the other engine it can paint with, the machine's own
    /// account and another look; anything else offers the same words again and the machine. A
    /// refusal before anything was sent says so and says where the words are.
    private func failureCard(_ reason: String) -> UnsafeMutablePointer<GtkWidget> {
        let held = studio
        let sighting = studio.sighting
        let missing = sighting.map { $0.reachable && !$0.available(slot.engine) } ?? false
        var remedies: [(title: String, primary: Bool, perform: @Sendable () -> Void)] = []
        if missing, let other = sighting?.readyEngines.first(where: { $0 != slot.engine }) {
            let words = promptText
            remedies.append(
                (
                    title: Localized.text("Paint with %@", other.label), primary: true,
                    perform: { held.choose(engine: other); held.submit(prompt: words) }
                ))
        } else {
            let words = promptText
            remedies.append(
                (title: Localized.text("Try again"), primary: true, perform: { held.submit(prompt: words) }))
        }
        remedies.append(
            (title: ImageGenMachineWords.title + "…", primary: false,
             perform: { [weak self] in self?.machine.open() }))
        remedies.append(
            (title: ImageGenMachineWords.checkAgain, primary: false,
             perform: { held.recheckMachine() }))
        return StudioFailureCard.make(
            sentence: reason, note: missing ? StudioWords.nothingSent : nil, remedies: remedies)
    }

    /// Full size. In a pane that is a window of its own beside it; in a window it is this surface
    /// giving the picture everything it has, because a window opened over a window is how the
    /// pointer was lost. A kept picture has no `ImageGenPicture` of its own record, so one is
    /// built from its facts just for the viewer — nothing here is kept beyond the call.
    func openStage() {
        guard let key = stageTextureKey, let bits = textures[key], bits != 0 else { return }
        if fills {
            zoomed.toggle()
            render()
            return
        }
        if let kept = studio.keptStage, let path = kept.path {
            let facts = kept.facts
            let synthetic = ImageGenPicture(
                path: path, prompt: ImageGenFacts.caption(for: facts),
                engine: facts?.recipe?.engine ?? .quality,
                mode: facts?.recipe?.mode ?? .generate, aspect: facts?.aspect ?? .square,
                seconds: 0, seed: facts?.recipe?.seed ?? 0, madeAt: facts?.modifiedAt ?? Date())
            DrawViewer.present(picture: synthetic, textureBits: bits, parent: hostWindow)
            return
        }
        guard let picture = slot.onStage else { return }
        DrawViewer.present(picture: picture, textureBits: bits, parent: hostWindow)
    }
}

extension UnsafeMutablePointer where Pointee == GtkWidget {
    var firstChild: UnsafeMutablePointer<GtkWidget>? { gtk_widget_get_first_child(self) }
}
