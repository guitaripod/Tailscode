import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension ForgePane {
    func refreshChips() {
        let readings = StudioChips.forge(for: board)
        for reading in readings {
            switch reading.id {
            case .size: sizeChip.apply(reading, tooltip: nil)
            case .length: lengthChip.apply(reading, tooltip: nil)
            case .smoothness: smoothChip.apply(reading, tooltip: nil)
            case .sound: soundChip.apply(reading, tooltip: ForgeWords.soundHint)
            case .avoid: avoidChip.apply(reading, tooltip: ForgeWords.negativeIgnoredHint)
            case .seed:
                seedChip.apply(
                    reading, tooltip: Localized.text("The same seed and prompt make the same clip"))
            case .engine, .aspect, .detail, .cutout, .reference, .craft: break
            }
        }
        dock.tray.relayout(force: false)
    }

    func refreshDock() {
        syncPrompt()
        syncAvoid()
        syncSound()
        dock.setPlaceholder(board.prompt)
        dock.setGo(title: goTitle, stopping: board.isBusy)
        dock.setLocked(board.isBusy)
        gtk_widget_set_tooltip_text(dock.go, board.expectation ?? board.job.hint)
        let about = board.expectation.map { line -> String in
            guard let name = board.endpoint?.shortName else { return line }
            return Localized.text("%@ on %@", line, name)
        }
        let words = ImageGenBrief.words(in: promptText.trimmingCharacters(in: .whitespacesAndNewlines))
        dock.setFoot(
            about,
            tooltip: words == 1 ? Localized.text("1 word") : Localized.text("%@ words", "\(words)"))
        refreshEnhance()
        refreshSlot()
    }

    /// The start-from slot wears the picture the clip opens on, or a glyph for the end of a clip.
    func refreshSlot() {
        guard let frame = board.recipe.frame else {
            slotView.apply(count: 0, bits: 0, tooltip: ForgeWords.frameHint)
            releaseReferenceTexture()
            return
        }
        var bits: UInt = 0
        var glyph: String? = "▤"
        switch frame {
        case .file(let path):
            if referenceTexture?.path != path {
                releaseReferenceTexture()
                if let data = FileManager.default.contents(atPath: path) {
                    let made: UInt = data.withUnsafeBytes { buffer in
                        guard let base = buffer.baseAddress else { return 0 }
                        var width: Int32 = 0
                        var height: Int32 = 0
                        guard
                            let texture = tailscode_texture_scaled(
                                base, gsize(data.count), 256, &width, &height)
                        else { return 0 }
                        return UInt(bitPattern: UnsafeMutableRawPointer(texture))
                    }
                    if made != 0 { referenceTexture = (path, made) }
                }
            }
            bits = referenceTexture?.bits ?? 0
            glyph = nil
        case .kept: glyph = "▤"
        case .clipEnd(let asset):
            glyph = "⏭"
            bits = posters.textures[ForgePosters.key(for: asset)] ?? 0
        }
        slotView.apply(
            count: 1, bits: bits, glyph: bits == 0 ? glyph : nil,
            tooltip: "\(board.continuing?.title ?? frame.label) — \(frame.detail)")
    }

    func releaseReferenceTexture() {
        if let held = referenceTexture, let raw = UnsafeMutableRawPointer(bitPattern: held.bits) {
            g_object_unref(raw)
        }
        referenceTexture = nil
    }

    func refreshMachine() {
        let section = board.sections.first(where: { $0.id == ForgeBoard.rendererID })
        let row = board.rows.first(where: { $0.kind == .field(.endpoint) })
        let name = board.endpoint.map { board.rendererName ?? $0.shortName } ?? ""
        let state: String?
        var tone: StudioMachinePill.Tone
        switch section?.phase ?? .idle {
        case .ready:
            state = row?.badge
            tone = .ready
        case .failed(let why):
            state = board.readiness == nil ? why : row?.badge
            tone = .danger
        case .checking:
            state = board.readiness?.isStarting == true ? MediaWords.startingMark : row?.badge
            tone = .unknown
        case .idle:
            state = board.endpoint == nil ? ForgeSetup.title : row?.badge
            tone = .unknown
        }
        if board.isBusy { tone = .working }
        machine.apply(StudioMachinePill(machine: name, state: state, version: nil, tone: tone))
    }

    // MARK: the shelf

    func refreshShelf() {
        var tiles: [StudioTile] = []
        if board.isBusy {
            tiles.append(
                StudioTile(
                    id: StudioShelf.inFlightID, inFlight: true, badge: board.job.badge,
                    progress: board.job.fraction, glyph: "…", words: busyLine(board.job),
                    tooltip: busyLine(board.job)))
        }
        for entry in entries {
            let ago = ImageGenLibraryWords.ago(entry.finishedAt)
            tiles.append(
                StudioTile(
                    id: entry.id,
                    badge: entry.asset == nil
                        ? entry.badge : StudioWords.duration(entry.recipe.seconds),
                    glyph: entry.isPlayable ? "▶" : "✕",
                    words: StudioWords.shelfTileLabel(words: entry.title, facts: entry.detail),
                    tooltip: "\(ago) · \(entry.detail)"))
        }
        let selected = (chosen ?? playing ?? board.job.asset)
            .flatMap { asset in entries.first(where: { $0.asset == asset })?.id }
        shelf.describe(
            heading: ForgeWords.recentTitle,
            count: entries.isEmpty ? nil : Localized.text("%@ kept", "\(entries.count)"),
            note: entries.isEmpty ? Localized.text("Nothing rendered yet") : nil)
        shelf.update(tiles: tiles, selection: selected)
    }

    /// The decoded poster a tile draws: the sketch for the render in flight, the clip's filed poster
    /// for one that is made, and nothing for a clip with no poster, which wears its glyph.
    func posterBits(for id: String) -> UInt {
        if id == StudioShelf.inFlightID { return sketchTexture }
        guard let asset = entries.first(where: { $0.id == id })?.asset else { return 0 }
        return posters.textures[ForgePosters.key(for: asset)] ?? 0
    }

    func wantPosters(_ ids: [String]) {
        var keys = ids.compactMap { id in
            entries.first(where: { $0.id == id })?.asset.map(ForgePosters.key(for:))
        }
        if let newest = entries.first(where: \.isPlayable)?.asset { keys.append(ForgePosters.key(for: newest)) }
        if let landed = board.job.asset { keys.append(ForgePosters.key(for: landed)) }
        if let leading = board.continuing?.asset { keys.append(ForgePosters.key(for: leading)) }
        posters.want(keys)
    }

    /// What a kept clip offers besides being played: the next clip from where it ended, its
    /// settings back in the draft, and the way to let it go. A receipt for a file that is no longer
    /// on the other machine is exactly the kind of row a history has to be able to lose.
    func presentClipMenu(
        _ entry: ForgeEntry, on widget: UnsafeMutablePointer<GtkWidget>, x: Double, y: Double
    ) {
        var rows: [(String, String?, @Sendable () -> Void)] = []
        if entry.asset != nil {
            rows.append(
                (Localized.text("Play"), entry.detail,
                 { [weak self] in Gtk.onMain { [weak self] in self?.play(entry) } }))
            if board.canContinue(entry), !board.isBusy {
                rows.append(
                    (ForgeWords.extendTitle, ForgeWords.extendHint,
                     { [weak self] in Gtk.onMain { [weak self] in self?.continueFrom(entry) } }))
            }
        }
        rows.append(
            (Localized.text("Use it"), entry.recipe.summary,
             { [weak self] in
                 Gtk.onMain { [weak self] in self?.runner.reuse(entry) }
             }))
        rows.append(
            (Localized.text("Forget it"), nil,
             { [weak self] in
                 Gtk.onMain { [weak self] in self?.runner.forget(entry) }
             }))
        Gtk.contextMenu(on: widget, x: x, y: y, rows: rows)
    }

    // MARK: sketch and player

    func adoptSketch(_ frame: ImageGenPreviewFrame) {
        let bits: UInt = frame.bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress,
                let texture = tailscode_texture_from_bytes(base, gsize(frame.bytes.count))
            else { return 0 }
            return UInt(bitPattern: UnsafeMutableRawPointer(texture))
        }
        guard bits != 0 else { return }
        Gtk.replacePicture(of: sketchPicture, bits: bits)
        if sketchTexture != 0, let raw = UnsafeMutableRawPointer(bitPattern: sketchTexture) {
            g_object_unref(raw)
        }
        sketchTexture = bits
        shownSketch = frame
        shelf.refreshPicture(StudioShelf.inFlightID)
    }

    func dropSketch() {
        guard sketchTexture != 0 else { return }
        gtk_picture_set_paintable(op(sketchPicture), nil)
        if let raw = UnsafeMutableRawPointer(bitPattern: sketchTexture) { g_object_unref(raw) }
        sketchTexture = 0
        shownSketch = nil
    }

    static let arrivalFade: UInt32 = 240

    /// The player takes the stage. A clip that just landed crossfades from its last sketch once,
    /// 240 milliseconds, ease-out; a clip chosen from the shelf is simply there.
    func showPlayer() {
        guard surface != nil else { return }
        let landing = visibleArt != "player" && sketchTexture != 0 && Gtk.animationsAllowed
        if landing {
            gtk_stack_set_transition_duration(op(art), Self.arrivalFade)
            gtk_stack_set_transition_type(op(art), GTK_STACK_TRANSITION_TYPE_CROSSFADE)
            gtk_stack_set_visible_child_name(op(art), "player")
            fadeEnds = Date().addingTimeInterval(Double(Self.arrivalFade + 200) / 1000)
            Gtk.after(Self.arrivalFade + 200) { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.fadeEnds = nil
                    gtk_stack_set_transition_type(op(self.art), GTK_STACK_TRANSITION_TYPE_NONE)
                    if self.loaded { self.dropSketch() }
                }
            }
            return
        }
        if let fadeEnds, fadeEnds > Date(), visibleArt == "player" { return }
        gtk_stack_set_transition_type(op(art), GTK_STACK_TRANSITION_TYPE_NONE)
        gtk_stack_set_visible_child_name(op(art), "player")
        if loaded { dropSketch() }
    }

    func ensurePlayer() -> Bool {
        if player != nil { return true }
        guard tailscode_mpv_available() != 0 else { return false }
        let box = Box(pane: self)
        let raw = Unmanaged.passRetained(box).toOpaque()
        guard
            let created = tailscode_mpv_new(
                { user, kind, text in
                    guard let user, let kind else { return }
                    let event = String(cString: kind)
                    let payload = text.map { String(cString: $0) } ?? ""
                    let box = Unmanaged<Box>.fromOpaque(user).takeUnretainedValue()
                    box.pane?.received(event: event, payload: payload)
                }, raw)
        else {
            Unmanaged<Box>.fromOpaque(raw).release()
            return false
        }
        player = created
        callbackBox = raw
        guard let area = tailscode_mpv_area(created) else { return false }
        surface = area
        gtk_widget_set_hexpand(area, 1)
        gtk_widget_set_vexpand(area, 1)
        gtk_stack_add_named(op(art), area, "player")
        return true
    }

    /// mpv's own words about the file. A clip that will not play says why and hands the board
    /// back, because a black surface with nothing in it is indistinguishable from one still
    /// loading; a clip that loaded is what the stage crosses over to, and the sketch it crossed
    /// from is let go once the fade is done.
    func received(event: String, payload: String) {
        switch event {
        case "error":
            refuse(payload.isEmpty ? Localized.text("That would not play") : payload)
        case "loaded":
            loaded = true
            render()
        case "mute":
            muted = payload == "1"
            render()
        default:
            return
        }
    }

    func withCommand(
        _ arguments: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> Void
    ) {
        var pointers: [UnsafePointer<CChar>?] = arguments.map { argument in
            UnsafePointer(strdup(argument))
        }
        pointers.append(nil)
        pointers.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress { body(base) }
        }
        for pointer in pointers where pointer != nil {
            free(UnsafeMutableRawPointer(mutating: pointer))
        }
    }

    /// The C callback carries a raw pointer, so the pane reaches it through a box it owns and
    /// releases at shutdown — an event arriving after the pane is gone finds nothing rather than a
    /// dangling object.
    final class Box {
        weak var pane: ForgePane?
        init(pane: ForgePane) { self.pane = pane }
    }

    // MARK: enhance and the rewrite card

    /// The Enhance control and the link beside it that names who would write: the helper, or where
    /// the survey stands. Press once to have the caption written, press again while it writes to
    /// stop it, and once more after taking it to get your own sentence back.
    func refreshEnhance() {
        dock.showEnhance(
            host: runner, enhancing: runner.enhancing, canUndo: beforeEnhance != nil,
            locked: board.isBusy)
        refreshRewrite()
    }

    /// The card follows the draft, risen over the stage's lower third.
    func refreshRewrite() {
        shell.showLowerCard(rewrite.refresh(runner.draft, canUse: !board.isBusy))
    }

    /// Takes the caption: into the box, where it can still be edited, with the typed sentence one
    /// press away. The shape the helper chose is followed only where nobody chose one by hand and
    /// the clip does not continue another, which takes its shape from that clip.
    func useRewrite() {
        guard let draft = runner.draft, draft.isUsable else { return }
        beforeEnhance = promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? draft.original : promptText
        if let aspect = draft.aspect, board.recipe.frame?.isClipEnd != true {
            runner.follow(size: ForgeSize.following(aspect))
        }
        describe(draft.written)
        runner.dismissRewrite()
        reason = ImageGenWords.enhancedNotice(draft.helper)
        render()
    }

    func enhancePressed() {
        if let original = beforeEnhance {
            beforeEnhance = nil
            describe(original)
            refreshEnhance()
            return
        }
        if runner.enhancing {
            runner.stopRewrite()
            return
        }
        let brief = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brief.isEmpty else {
            focusPrompt()
            return
        }
        reason = nil
        runner.rewrite(brief)
    }

    func choose(_ field: ForgeField) {
        switch field {
        case .size: sizeChip.open()
        case .seconds: lengthChip.open()
        case .fps: smoothChip.open()
        default: break
        }
    }

    /// What the button under the words says. A clip that has landed is already on the stage, so
    /// the button is never an offer to play it again — it is the offer to make another.
    var goTitle: String {
        board.job.asset != nil ? Localized.text("Render") : board.renderCall
    }

    /// Render, or Stop while one is out. Pressed on the words of a clip that has just landed it
    /// asks for another take of them: the same seed would be asked to make the same clip again,
    /// and a few minutes of the other machine's card spent on a copy.
    func callPressed() {
        if board.job.asset != nil, !board.isBusy { runner.pick(.seed, id: "reroll") }
        guard let action = runner.begin() else { return }
        perform(action)
    }
}
