import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension ForgePane {
    /// The board's own keys, offered before the box they are typed into gets them. Only chords a
    /// text field cannot want are claimed, so every letter and digit still types into the prompt —
    /// except while a clip is playing and the prompt does not have the keyboard, when the surface
    /// is a player and answers a player's keys.
    func handleChord(_ chord: KeyChord) -> Bool {
        if isPlaying {
            if chord.keyval == Keymap.escape {
                showBoard()
                return true
            }
            if !fieldHasFocus, let command = VideoCommand.command(for: chord) {
                guard command != .change else {
                    showBoard()
                    return true
                }
                drive(command)
                return true
            }
        }
        guard let command = ForgeBoard.command(for: chord) else { return false }
        if fieldHasFocus {
            switch command {
            case .up, .down, .activate, .expand: return false
            case .render, .cancel, .reroll, .back: break
            }
        }
        if command == .render, !board.isBusy {
            callPressed()
            return true
        }
        let (handled, action) = runner.handle(command)
        guard handled else { return false }
        guard let action else {
            render()
            return true
        }
        perform(action)
        return true
    }

    /// Stops this pane being drawn, and nothing else. It has to happen the instant the window is
    /// destroyed rather than a turn of the main loop later: the runner keeps yielding snapshots for
    /// as long as the render runs, and one that lands after the widgets are gone writes text into
    /// labels GTK has already freed.
    func stopDrawing() {
        runner.unwatch(self)
        runner.onNotice = nil
        if let rewriteObserver { NotificationCenter.default.removeObserver(rewriteObserver) }
        rewriteObserver = nil
        posters.onChange = nil
        openTask?.cancel()
        openTask = nil
    }

    /// The window is closing. The render is deliberately not touched — it lives in the runner, and
    /// a person who closed a window asked for the window to go, never for the other machine to stop
    /// — so what is let go of here is exactly what belongs to this view: the player, the sketch's
    /// texture, the posters and the lookup that would have fed the player.
    func shutdown() {
        stopDrawing()
        dropSketch()
        posters.release()
        if let held = referenceTexture, let raw = UnsafeMutableRawPointer(bitPattern: held.bits) {
            g_object_unref(raw)
        }
        referenceTexture = nil
        dock.tray.release()
        if let player {
            tailscode_mpv_free(player)
            self.player = nil
            surface = nil
        }
        if let callbackBox {
            Unmanaged<Box>.fromOpaque(callbackBox).release()
            self.callbackBox = nil
        }
    }

    var promptHasFocus: Bool { dock.hasFocus }

    var fieldHasFocus: Bool {
        promptHasFocus || gtk_widget_has_focus(avoidEntry) != 0
            || gtk_widget_has_focus(soundEntry) != 0 || rewrite.hasFocus
    }

    func typed() {
        guard !typing else { return }
        if beforeEnhance != nil { beforeEnhance = nil }
        runner.describe(promptText)
    }

    func typedAvoid() {
        guard !typing else { return }
        guard let raw = gtk_editable_get_text(op(avoidEntry)) else { return }
        runner.avoid(String(cString: raw))
    }

    func typedSound() {
        guard !typing else { return }
        guard let raw = gtk_editable_get_text(op(soundEntry)) else { return }
        runner.hear(String(cString: raw))
    }

    /// What activating a row means here. Everything the board can do on its own — walking a
    /// setting, expanding a section, putting an old recipe back in the draft — never reaches this.
    func perform(_ action: ForgeAction) {
        switch action {
        case .render(let recipe):
            reason = nil
            releaseStage()
            runner.start(recipe)
        case .cancel:
            runner.stop()
        case .play(let asset):
            guard let entry = entry(for: asset) else { return }
            play(entry)
        case .edit(let field):
            edit(field)
        case .choose(let field):
            choose(field)
        case .configure:
            openSetup()
        case .checklist:
            openChecklist()
        }
    }

    func edit(_ field: ForgeField) {
        switch field {
        case .endpoint:
            openSetup()
        case .prompt:
            focusPrompt()
        case .negative:
            avoidChip.open()
        case .sound:
            soundChip.open()
        case .frame:
            offerFrame()
        case .size, .seconds, .fps, .seed:
            return
        }
    }

    /// Where the renderer lives, asked for the way a server is asked for: a surface that states
    /// this machine's own address, sweeps the tailnet for the box with the card, checks what it is
    /// given and explains what it finds. Every word of it is Core's.
    ///
    /// The renderer somebody picked is taken up by the runner rather than by this pane, because the
    /// setup window outlives the surface that opened it: closing the forge modal while the setup is
    /// still up must not be what decides whether the address they chose is ever pointed at.
    func openSetup() {
        ForgeSetupWindow.present(parent: hostWindow) { [weak self] in
            Gtk.onMain { [weak self] in
                ForgeRunner.shared.pointAtStoredRenderer()
                self?.reason = nil
            }
        }
    }

    /// What the machine can make, as the shared checklist for images and video led by video: the
    /// same one the server screen and the picture studio open. Finishing it is pressing Render,
    /// which is what the person came to do; changing the machine is the picker above, and it
    /// returns here.
    func openChecklist() {
        MediaChecklistFlow.open(
            endpoint: board.endpoint, focus: .video, parent: hostWindow,
            onFinish: { [weak self] in Gtk.onMain { [weak self] in self?.callPressed() } },
            onChanged: { [weak self] in Gtk.onMain { [weak self] in self?.reason = nil } })
    }

    /// Where the clip starts: a file chosen here, the end of a clip already made, or nothing. The
    /// same rows the start-from slot's own menu offers, so a keyboard and a pointer reach the same
    /// doors.
    func offerFrame() {
        slotView.open()
    }

    func frameRows() -> [(title: String, detail: String?, action: @Sendable () -> Void)] {
        var rows: [(title: String, detail: String?, action: @Sendable () -> Void)] = []
        rows.append(
            (ForgeWords.pickFileTitle, ForgeWords.pickFileHint,
             { [weak self] in Gtk.onMain { [weak self] in self?.pickFrameFile() } }))
        rows.append(
            (ImageGenReferenceSource.clipboard.title, nil,
             { [weak self] in Gtk.onMain { [weak self] in self?.pasteFrame() } }))
        for entry in board.history.filter({ board.canContinue($0) }).prefix(3) {
            rows.append(
                (ForgeWords.continueTitle(entry), ForgeWords.continueHint,
                 { [weak self] in
                     Gtk.onMain { [weak self] in
                         guard let self, let asset = entry.asset else { return }
                         self.runner.start(from: .clipEnd(asset))
                     }
                 }))
        }
        if board.recipe.frame != nil {
            rows.append(
                (ForgeWords.noFrameTitle, nil,
                 { [weak self] in Gtk.onMain { [weak self] in self?.runner.start(from: nil) } }))
        }
        return rows
    }

    func pickFrameFile() {
        Gtk.openFiles(parent: hostWindow) { [weak self] paths in
            guard let self, let path = paths.first else { return }
            Gtk.onMain { [weak self] in
                self?.runner.start(from: .file(path))
                self?.focusPrompt()
            }
        }
    }

    /// A picture on the clipboard is a start: files first, then a picture written once to a file the
    /// render can send.
    func pasteFrame() {
        Gtk.readClipboard { [weak self] offer in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                if let path = offer.paths.first(where: { ImageGenFileKind.of($0) != nil }) {
                    self.runner.start(from: .file(path))
                    return
                }
                guard let data = offer.image else {
                    self.reason = Localized.text("The clipboard holds no picture")
                    self.render()
                    return
                }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("tailscode-start-\(UUID().uuidString).png")
                guard (try? data.write(to: url)) != nil else { return }
                self.runner.start(from: .file(url.path))
            }
        }
    }

    func entry(for asset: ForgeAsset) -> ForgeEntry? {
        entries.first { $0.asset == asset }
    }

    /// A clip, asked for before it is opened. The file is on the machine that wrote it and `/view`
    /// answers one that has been cleaned up with a 404 — which a player reports in its own words,
    /// none of them about this machine — so Core is asked where the file is first and its sentence
    /// is what a clip that is gone says.
    ///
    /// The clip is the stage's from the moment it is asked for. The answer comes back later, and
    /// if the person has chosen something else, started a render or gone back to the board in the
    /// meantime, it is no longer the answer to anything.
    func play(_ entry: ForgeEntry) {
        guard let asset = entry.asset, let client = runner.client(for: entry) else { return }
        AppLog.write(.ui, "forge play entry=\(entry.id) file=\(asset.filename) machine=\(client.endpoint.host)")
        guard tailscode_mpv_available() != 0 else {
            return refuse(Localized.text("This build has no libmpv, so a slot cannot play"))
        }
        if playing == asset, loaded, chosen == asset { return }
        playTicket += 1
        let ticket = playTicket
        chosen = asset
        reason = nil
        working = Localized.text("Checking…")
        render()
        openTask?.cancel()
        openTask = Task { [weak self] in
            do {
                let url = try await client.locate(asset)
                Gtk.onMain { [weak self] in
                    guard let self, self.playTicket == ticket else { return }
                    self.open(asset, at: url)
                }
            } catch {
                let sentence = ForgeClient.reason(error, host: client.endpoint.host)
                Gtk.onMain { [weak self] in
                    guard let self, self.playTicket == ticket else { return }
                    self.refuse(sentence)
                }
            }
        }
    }

    /// The player, pointed at a file the machine has just confirmed it still has. The stage keeps
    /// the face it had until the player says the file is loaded, and only then crosses over.
    func open(_ asset: ForgeAsset, at url: URL) {
        working = nil
        guard ensurePlayer() else {
            return refuse(String(cString: tailscode_mpv_last_error()))
        }
        reason = nil
        playing = asset
        chosen = asset
        loaded = false
        tailscode_mpv_play(player, url.absoluteString)
        render()
        if let surface { gtk_widget_grab_focus(surface) }
    }

    /// Why a clip is not playing, in the sentence whoever refused it wrote — Core's for a file the
    /// machine no longer has, mpv's for one it will not decode. The stage stays up underneath it,
    /// because a reason with nothing to press is a dead end.
    func refuse(_ sentence: String) {
        playTicket += 1
        working = nil
        playing = nil
        chosen = nil
        loaded = false
        reason = sentence
        if player != nil { drive(["stop"]) }
        render()
    }

    /// Takes the stage off whatever it was on, and every answer still on its way back with it. A
    /// render starting, a clip about to be continued and a return to the board all begin here: the
    /// player is stopped, not merely hidden, because a clip left running under the sketch of the
    /// next one keeps its sound on and keeps the landed clip from ever being the one that plays.
    func releaseStage() {
        playTicket += 1
        openTask?.cancel()
        openTask = nil
        working = nil
        chosen = nil
        guard playing != nil else { return }
        playing = nil
        loaded = false
        if player != nil { drive(["stop"]) }
    }

    /// Back to the stage with the clip stopped and the recipe that made it still in the boxes — the
    /// point of keeping a seed is that the next one is one edit away rather than a retype.
    func showBoard() {
        guard isPlaying || chosen != nil else { return }
        releaseStage()
        dropSketch()
        render()
        focusPrompt()
    }

    func drive(_ command: VideoCommand) {
        let arguments = command.mpvCommand
        guard !arguments.isEmpty else { return }
        drive(arguments)
    }

    func drive(_ arguments: [String]) {
        guard let player else { return }
        withCommand(arguments) { tailscode_mpv_command(player, $0) }
    }

    // MARK: drawing

    func render() {
        entries = board.history
        openOnArrival()
        refreshStage()
        refreshChips()
        refreshDock()
        refreshShelf()
        refreshMachine()
        onChange?()
    }

    /// A clip that just landed takes the stage, once: the stage is the room the person was
    /// watching, and the last sketch crossing into the moving picture is the arrival. Nothing
    /// already on the stage can keep it out — a render starting takes the stage off its clip, and
    /// one landing while another clip is being watched is the clip that was waited for.
    func openOnArrival() {
        guard let asset = runner.unpresented, let entry = entry(for: asset) else { return }
        runner.present(asset)
        play(entry)
    }

    /// The shape of the clip, decided before it renders: the recipe's own frame, so the sketch, the
    /// player and the held placeholder all sit in one rectangle.
    var ratio: Double {
        let size = board.isBusy || board.job.isFinished ? board.job.recipe : board.recipe
        return Double(size.width) / Double(max(size.height, 1))
    }
}
