import AVFoundation
import AVKit
import AppKit
import TailscodeCore

/// A video being asked for, made, and watched — the whole of what the forge sheet holds.
///
/// The whole of what this shows is `ForgeBoard`'s: which machine renders and whether it answered,
/// the render in hand with its bar and its stage, the settings the next one is made from, and the
/// clips already kept. The board, the connection and the render's own task are not this view's:
/// they live in ``ForgeRunner`` above it, so the sheet can be dismissed without cancelling four
/// minutes of somebody else's card. What this owns is the drawing — the prompt box, the players,
/// and the lookups a press needs — and every answer goes straight back into the runner, so the
/// words on screen are Core's in every state this surface has.
///
/// The board is content on the opaque canvas; the prompt and the one button under it are the
/// floating control layer, the same arrangement the transcript keeps under its composer. A clip
/// plays twice over: small, in the row that made it, so a finished render is watched where it
/// happened — and, on a press, over the whole surface, which Escape hands back with the recipe that
/// made it still in the boxes.
@MainActor
final class ForgeSlotView: NSView, NSTextFieldDelegate {
    private let runner = ForgeRunner.shared
    private var board: ForgeBoard { runner.board }
    private let boardView = ForgeBoardView()
    private let field = NSTextField()
    private let call = NSButton()
    private let asideLabel = NSTextField(wrappingLabelWithString: "")
    private var asideGlass: NSGlassEffectView?
    private var dockGroup: NSView?
    private let theatre = AVPlayerView()

    private var openTask: Task<Void, Never>?
    private var stageTask: Task<Void, Never>?
    /// The render in hand's own file, once the machine has confirmed it still has it. Asked once
    /// per asset: the board restates itself several times a second while a render runs.
    private var stageClip: (asset: ForgeAsset, url: URL)?
    private var stageAsking: ForgeAsset?
    private var stageFailure: String?
    private var playing: ForgeAsset?
    private var theatrePlayer: AVPlayer?
    private var muted = false
    private var paused = false
    /// Why the last thing somebody pressed did not happen — a machine that would not answer, a file
    /// that is gone, a player that would not decode. Never a render's own failure: that one is the
    /// job's, and the board says it on the render row where it happened.
    private var reason: String?
    /// What this surface itself is waiting on, as opposed to what the renderer is. Only the lookup
    /// before a clip opens lands here, and it says so rather than leaving a pressed row silent.
    private var working: String?
    private var typing = false

    /// Told to whoever is holding this whenever the slot changes what it says about itself, so the
    /// sheet's own footer follows the render rather than lagging a state behind it.
    var onChange: (() -> Void)?

    init() {
        super.init(frame: .zero)
        build()
        runner.watch(self) { [weak self] in self?.render() }
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        wantsLayer = true

        theatre.translatesAutoresizingMaskIntoConstraints = false
        theatre.controlsStyle = .inline
        theatre.videoGravity = .resizeAspect
        theatre.isHidden = true
        addSubview(theatre)

        boardView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(boardView)
        boardView.onActivate = { [weak self] section, offset in
            self?.pressed(section: section, offset: offset)
        }
        boardView.onClipMenu = { [weak self] entry, view, point in
            self?.presentClipMenu(entry, on: view, at: point)
        }

        let dock = buildDock()
        addSubview(dock)
        dockGroup = dock

        NSLayoutConstraint.activate([
            theatre.topAnchor.constraint(equalTo: topAnchor),
            theatre.bottomAnchor.constraint(equalTo: bottomAnchor),
            theatre.leadingAnchor.constraint(equalTo: leadingAnchor),
            theatre.trailingAnchor.constraint(equalTo: trailingAnchor),
            boardView.topAnchor.constraint(equalTo: topAnchor),
            boardView.bottomAnchor.constraint(equalTo: bottomAnchor),
            boardView.leadingAnchor.constraint(equalTo: leadingAnchor),
            boardView.trailingAnchor.constraint(equalTo: trailingAnchor),
            dock.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacTheme.Spacing.l),
            dock.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacTheme.Spacing.l),
            dock.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -MacTheme.Spacing.m),
        ])
    }

    /// The prompt and the one button under it, on the material the rest of this window's floating
    /// layer is made of — with the pane's own aside above it, tinted rather than clear so a wait
    /// and a refusal are told apart before either is read.
    private func buildDock() -> NSView {
        field.placeholderString = board.prompt
        field.font = MacTheme.Ramp.font(.composer)
        field.delegate = self
        field.target = self
        field.action = #selector(promptSubmitted)
        field.translatesAutoresizingMaskIntoConstraints = false

        call.title = board.renderCall
        call.bezelStyle = .rounded
        call.target = self
        call.action = #selector(callPressed)
        call.setContentHuggingPriority(.required, for: .horizontal)
        call.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [field, call])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MacTheme.Spacing.s
        row.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.s, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.s,
            right: MacTheme.Spacing.m)
        row.translatesAutoresizingMaskIntoConstraints = false
        let card = MacTheme.glass(around: row, cornerRadius: MacTheme.Radius.card)

        asideLabel.font = MacTheme.Ramp.font(.panelFootnote)
        asideLabel.textColor = MacTheme.Color.onGlass
        asideLabel.isSelectable = false
        asideLabel.maximumNumberOfLines = 2
        asideLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let asideRow = NSStackView(views: [asideLabel])
        asideRow.orientation = .horizontal
        asideRow.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.s, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.s,
            right: MacTheme.Spacing.m)
        asideRow.translatesAutoresizingMaskIntoConstraints = false
        let aside = MacTheme.tintedGlass(
            around: asideRow, tint: MacTheme.Color.accent, cornerRadius: MacTheme.Radius.card)
        aside.isHidden = true
        asideGlass = aside

        let host = FillingStack(views: [aside, card])
        host.spacing = MacTheme.Spacing.s
        host.translatesAutoresizingMaskIntoConstraints = false
        let group = MacTheme.glassGroup()
        group.contentView = host
        return group
    }

    override func layout() {
        super.layout()
        let bottom =
            (dockGroup?.frame.height ?? 0) + MacTheme.Spacing.m + MacTheme.Spacing.l
        boardView.insets = NSEdgeInsets(
            top: safeAreaInsets.top + MacTheme.Spacing.s, left: 0, bottom: bottom, right: 0)
    }

    var isPlaying: Bool { playing != nil }

    var isBusy: Bool { board.isBusy }

    /// One line for the headless driver: where the renderer is, where the render is, what the
    /// button under it would do, how the board is grouped, and what is playing.
    var summary: String {
        let sections = board.sections.map {
            "\($0.id):\($0.rows.count)\($0.hidden > 0 ? "+\($0.hidden)" : "")"
        }
        let bar = board.job.percent.map { "\($0)%" } ?? "-"
        return
            "\(jobWord) renderer=\(board.value(of: .endpoint))/\(reachWord) [\(board.job.title)] "
            + "\(board.job.subtitle) badge=\(board.job.badge ?? "-") bar=\(bar) "
            + "call=\(board.renderCall) [\(sections.joined(separator: " "))] "
            + "cursor=\(board.focused?.title ?? "-") history=\(board.history.count) "
            + "playing=\(playing?.filename ?? "-") aside=\(reason ?? working ?? "-")"
    }

    private var jobWord: String {
        switch board.job.phase {
        case .drafting: return "drafting"
        case .submitting: return "submitting"
        case .queued(let ahead): return "queued(\(ahead))"
        case .running(let fraction): return fraction >= 1 ? "collecting" : "running"
        case .done: return "done"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }

    private var reachWord: String {
        guard let section = board.sections.first(where: { $0.id == ForgeBoard.rendererID })
        else { return "-" }
        switch section.phase {
        case .idle: return board.endpoint == nil ? "unset" : "unchecked"
        case .checking: return "checking"
        case .ready: return "up"
        case .failed: return "down"
        }
    }

    func focusPrompt() {
        window?.makeFirstResponder(field)
    }

    /// Types into the prompt as a person would, so the driver exercises the same path a keystroke
    /// does rather than a private one that could drift from it.
    func describe(_ text: String) {
        typing = true
        field.stringValue = text
        typing = false
        typed()
    }

    /// The surface is going away. Everything this view started is let go of — the players and the
    /// lookups behind them — and nothing the runner started is touched, because a sheet closing is a
    /// sheet closing rather than a render being cancelled.
    func shutdown() {
        runner.unwatch(self)
        runner.rememberRecipe()
        openTask?.cancel()
        openTask = nil
        stageTask?.cancel()
        stageTask = nil
        stopTheatre()
        boardView.quietStage()
        releaseField()
    }

    /// The board's own keys, offered before the box they are typed into gets them. Only chords a
    /// text field cannot want are claimed, so every letter and digit still types into the prompt —
    /// except while a clip has the whole pane and the prompt does not have the keyboard, when this
    /// is a player and answers a player's keys.
    func handleChord(_ chord: KeyChord) -> Bool {
        if isPlaying {
            if chord.keyval == Keymap.escape {
                showBoard()
                return true
            }
            if !promptHasFocus, let command = VideoCommand.command(for: chord) {
                guard command != .change else {
                    showBoard()
                    return true
                }
                drive(command)
                return true
            }
        }
        guard let command = ForgeBoard.command(for: chord) else { return false }
        let (handled, action) = runner.handle(command)
        guard handled else { return false }
        guard let action else { return true }
        perform(action)
        return true
    }

    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextField) === field else { return }
        typed()
    }

    private var promptHasFocus: Bool { field.currentEditor() != nil }

    private func typed() {
        guard !typing else { return }
        runner.describe(field.stringValue)
    }

    @objc private func promptSubmitted() {
        perform(runner.begin())
    }

    @objc private func callPressed() {
        perform(runner.begin())
    }

    /// A press on a row is the same act as walking to it and pressing enter, so it goes through the
    /// cursor rather than around it — the board keeps one idea of where somebody is.
    private func pressed(section: String, offset: Int) {
        runner.focus(section: section, offset: offset)
        guard let action = runner.activate() else { return }
        perform(action)
    }

    /// What activating a row means here. Everything the board can do on its own — walking a
    /// setting, expanding a section, putting an old recipe back in the draft — never reaches this.
    private func perform(_ action: ForgeAction?) {
        guard let action else {
            render()
            return
        }
        switch action {
        case .render(let recipe):
            start(recipe)
        case .cancel:
            runner.stop()
        case .play(let asset):
            play(asset, entryID: nil)
        case .edit(let field):
            edit(field)
        case .configure:
            askForRenderer()
        }
    }

    private func edit(_ field: ForgeField) {
        switch field {
        case .endpoint:
            askForRenderer()
        case .prompt:
            focusPrompt()
        case .negative:
            askForAvoidance()
        case .size, .seconds, .fps, .model, .seed:
            return
        }
    }

    /// Where the renderer lives, which is a machine to find rather than a string to type — so it
    /// opens the setup, the same flow adding a server opens, and every word and rule in it is
    /// `ForgeSetup`'s.
    func openRenderer() {
        askForRenderer()
    }

    private func askForRenderer() {
        guard let window else { return }
        ForgeSetupSheet.present(on: window) { [weak self] in
            self?.reason = nil
            ForgeRunner.shared.pointAtStoredRenderer()
        }
    }

    private func askForAvoidance() {
        MacDialogs.prompt(
            on: window, title: ForgeField.negative.label,
            placeholder: board.value(of: .negative), initial: board.recipe.negative,
            confirmLabel: Localized.text("Save")
        ) { [weak self] text in
            self?.runner.avoid(text)
        }
    }

    /// One render, handed to the runner because it has to outlive this view. Everything this view
    /// does about it is get out of the way: the box gives the keyboard back and the last clip's
    /// lookup is dropped.
    private func start(_ recipe: ForgeRecipe) {
        reason = nil
        working = nil
        forgetStageClip()
        releaseField()
        runner.start(recipe)
    }

    /// A clip, asked for before it is opened. The file is on the other machine and `/view` answers
    /// one that has been cleaned up with a 404 — which a player reports in its own words, none of
    /// them about this machine — so Core is asked where the file is first, and its sentence is what
    /// a clip that is gone says.
    private func play(_ asset: ForgeAsset, entryID: String?) {
        guard let renderer = runner.renderer(for: asset) else {
            refuse(ForgeFailure.unconfigured.description)
            return
        }
        reason = nil
        working = Localized.text("Checking…")
        render()
        openTask?.cancel()
        openTask = Task { [weak self] in
            do {
                let url = try await ForgeRunner.shared.locate(asset, entryID: entryID)
                guard !Task.isCancelled, let self else { return }
                self.openTheatre(asset, at: url)
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.refuse(ForgeClient.reason(error, host: renderer.endpoint.host))
            }
        }
    }

    /// The whole pane, given over to one clip. The small player in the row it came from is stopped
    /// first: two copies of the same clip running against each other is a fault nobody would read
    /// as one.
    private func openTheatre(_ asset: ForgeAsset, at url: URL) {
        working = nil
        reason = nil
        boardView.quietStage()
        let player = AVPlayer(url: url)
        player.isMuted = muted
        theatre.player = player
        theatrePlayer = player
        playing = asset
        paused = false
        player.play()
        render()
        window?.makeFirstResponder(theatre)
    }

    /// Back to the board with the clip stopped and the recipe that made it still in the boxes — the
    /// point of keeping a seed is that the next one is one edit away rather than a retype.
    private func showBoard() {
        guard isPlaying else { return }
        stopTheatre()
        playing = nil
        render()
        focusPrompt()
    }

    private func stopTheatre() {
        theatrePlayer?.pause()
        theatrePlayer = nil
        theatre.player = nil
    }

    /// Why a clip is not playing, in the sentence whoever refused it wrote — Core's for a file the
    /// machine no longer has, the player's for one it will not decode. The board stays up
    /// underneath it, because a reason with nothing to press is a dead end.
    private func refuse(_ sentence: String) {
        working = nil
        reason = sentence
        render()
    }

    private func drive(_ command: VideoCommand) {
        guard let player = theatrePlayer else { return }
        switch command {
        case .playPause:
            paused.toggle()
            paused ? player.pause() : player.play()
        case .mute:
            muted.toggle()
            player.isMuted = muted
        case .volumeUp:
            player.volume = min(1, player.volume + 0.05)
        case .volumeDown:
            player.volume = max(0, player.volume - 0.05)
        case .seekBack, .seekForward:
            let delta = command == .seekBack ? -10.0 : 10.0
            let time = player.currentTime() + CMTime(seconds: delta, preferredTimescale: 600)
            player.seek(to: time)
        case .reload, .change:
            return
        }
        render()
    }

    /// What a kept clip offers besides being played: its settings back in the draft, and the way to
    /// let it go. A receipt for a file that is no longer on the other machine is exactly the kind of
    /// row a history has to be able to lose.
    private func presentClipMenu(_ entry: ForgeEntry, on view: NSView, at point: NSPoint) {
        let menu = NSMenu()
        if let asset = entry.asset {
            let play = ClosureMenuItem(title: Localized.text("Play")) { [weak self] in
                self?.play(asset, entryID: entry.id)
            }
            play.subtitle = entry.detail
            menu.addItem(play)
        }
        let reuse = ClosureMenuItem(title: Localized.text("Use these settings")) { [weak self] in
            guard let self else { return }
            self.runner.reuse(entry)
            self.describe(entry.recipe.prompt)
        }
        reuse.subtitle = entry.recipe.summary
        menu.addItem(reuse)
        menu.addItem(.separator())
        menu.addItem(
            ClosureMenuItem(title: Localized.text("Remove")) { [weak self] in
                self?.runner.forget(entry)
            })
        menu.popUp(positioning: nil, at: point, in: view)
    }

    private func goneWords(for entry: ForgeEntry) -> String? {
        guard runner.isMissing(entry), let host = board.endpoint?.host else { return nil }
        return ForgeFailure.missingFile(host).description
    }

    private func render() {
        let watching = isPlaying
        theatre.isHidden = !watching
        boardView.isHidden = watching
        dockGroup?.isHidden = watching
        applyBackground()
        call.title = board.renderCall
        call.setAccessibilityLabel(board.renderCall)
        call.contentTintColor = board.isBusy ? MacTheme.Color.danger : MacTheme.Color.accent
        field.placeholderString = board.prompt
        field.toolTip = board.hint
        if !watching {
            syncStageClip()
            boardView.render(board, clip: stageClip?.url, clipFailure: stageFailure) { entry in
                self.goneWords(for: entry)
            }
            if let focused = board.focused { boardView.reveal(focused.id) }
        }
        drawAside()
        onChange?()
    }

    /// The one line the pane says on its own behalf: what it is waiting on, or why the last press
    /// did nothing. They share a slot because they are the same reading — the answer to "what
    /// happened when I pressed that" — and wear different tones so a wait is never mistaken for a
    /// refusal.
    private func drawAside() {
        guard let line = reason ?? working else {
            asideGlass?.isHidden = true
            return
        }
        asideLabel.stringValue = line
        asideGlass?.tintColor =
            (reason == nil ? MacTheme.Color.accent : MacTheme.Color.danger)
            .withAlphaComponent(0.35)
        asideGlass?.isHidden = false
    }

    /// Black behind a player, the app's own canvas behind the board: a video needs its letterbox,
    /// and the board is content, which sits on the opaque canvas like every other row of prose.
    private func applyBackground() {
        let watching = isPlaying
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor =
                watching ? NSColor.black.cgColor : MacTheme.Color.canvas.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackground()
    }

    /// The box gives the keyboard back when a render starts or the pane goes. Hiding a text field
    /// does not resign its field editor, and while that editor is first responder the window reads
    /// every chord as text.
    private func releaseField() {
        guard field.currentEditor() != nil else { return }
        window?.makeFirstResponder(nil)
    }

    /// The clip the render in hand produced, confirmed to still be there before a player is pointed
    /// at it. Asked once per asset: this runs on every frame off the socket.
    private func syncStageClip() {
        guard let asset = board.job.asset else {
            forgetStageClip()
            return
        }
        guard stageClip?.asset != asset, stageAsking != asset else { return }
        stageTask?.cancel()
        stageAsking = asset
        stageFailure = nil
        guard let renderer = runner.renderer(for: asset) else { return }
        stageTask = Task { [weak self] in
            do {
                let url = try await ForgeRunner.shared.locate(asset)
                guard !Task.isCancelled, let self else { return }
                self.stageClip = (asset, url)
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.stageFailure = ForgeClient.reason(error, host: renderer.endpoint.host)
            }
            guard let self else { return }
            self.stageTask = nil
            self.render()
        }
    }

    private func forgetStageClip() {
        stageTask?.cancel()
        stageTask = nil
        stageAsking = nil
        stageClip = nil
        stageFailure = nil
    }
}

extension ForgeSlotView {
    /// Every state the surface has, put on screen without a renderer to make one happen. A render
    /// is minutes of another machine's card, so the states between pressing the button and holding
    /// a file cannot be reached in a build loop — and they are exactly the states worth checking,
    /// since each of them is a different sentence. Every value here is Core's own: the phases come
    /// from `ForgeJob`'s mutators and the frames from `ForgeEvent`, so nothing is described in
    /// words this client made up.
    func demonstrate(_ name: String) {
        quiet()
        runner.demonstrate(name)
        typing = true
        field.stringValue = board.recipe.prompt
        typing = false
        reason = nil
        working = nil
        forgetStageClip()
        render()
    }

    /// Everything this view has in flight, let go of before a state is put on screen by hand — a
    /// lookup landing a second later would quietly rewrite the state somebody asked to look at. What
    /// the runner has in flight is its own to drop, and `demonstrate` drops it.
    private func quiet() {
        showBoard()
        openTask?.cancel()
        openTask = nil
        stageTask?.cancel()
        stageTask = nil
    }
}

/// The forge's states as values, built from Core's own mutators rather than described in words this
/// client invented. It is a plain function of a name so the selftest can assert what each state
/// says without a window, and the pane can put the same state on screen for a picture.
enum ForgeDemo {
    static let host = "arch"
    static let promptID = "demo"
    static let prompt = "a cat asleep on a warm tiled roof, late afternoon light"
    static let avoidance = "blurry, jitter"
    static let asset = ForgeAsset(filename: "forge_00007.mp4", subfolder: "video", type: "output")

    /// Every name this understands, which is also the list `--open forge:<state>` accepts.
    static let states = [
        "unset", "checking", "down", "ready", "waking", "queued", "running", "collecting", "done",
        "failed", "stopped", "empty", "history",
    ]

    static func board(_ name: String) -> ForgeBoard {
        let recipe = ForgeRecipe(
            prompt: name == "unset" ? "" : prompt, negative: avoidance, width: 1280, height: 704,
            seconds: 5, fps: 24, seed: 481_723)
        var board = ForgeBoard(
            recipe: recipe, endpoint: name == "unset" ? nil : ForgeEndpoint(host: host))
        switch name {
        case "unset":
            board.filled(history: [])
        case "checking":
            board.checking()
            board.filled(history: [])
        case "down":
            board.reached(.timedOut)
            board.filled(history: [])
        case "empty":
            board.reached(.listening)
            board.filled(history: [])
        case "history", "ready":
            board.reached(.listening)
            board.filled(history: history(recipe))
        default:
            board.reached(.listening)
            board.saw(job(name, recipe: recipe))
            board.filled(history: history(recipe))
        }
        return board
    }

    private static func job(_ name: String, recipe: ForgeRecipe) -> ForgeJob {
        var job = ForgeJob(recipe: recipe)
        job.submitting(at: Date().addingTimeInterval(-74))
        guard name != "waking" else { return job }
        job.accepted(promptID: promptID, queued: 2)
        guard name != "queued" else { return job }
        switch name {
        case "failed":
            job.saw(.failed(promptID, reason: "UNETLoader failed: CUDA out of memory"))
        case "stopped":
            job.saw(.interrupted(promptID))
        case "collecting", "done":
            job.saw(
                .progressed(promptID, census: ForgeCensus(finished: 27, total: 28, running: "save")))
            job.saw(.finished(promptID))
            if name == "done" { job.delivered(asset) }
        default:
            job.saw(.started(promptID))
            job.saw(
                .progressed(promptID, census: ForgeCensus(finished: 14, total: 28, running: "pass2")))
            job.saw(.sampling(promptID, node: "pass2", step: 3, steps: 4))
        }
        return job
    }

    /// Six clips that came back and one that never did, newest first the way the store files them.
    /// The one that never did leads, because a history where every visible row succeeded proves
    /// nothing about the row that has to say why one of them did not.
    private static func history(_ recipe: ForgeRecipe) -> [ForgeEntry] {
        let words = [
            "a cat asleep on a warm tiled roof, late afternoon light",
            "rain on a neon street, shallow depth of field",
            "a paper boat going over a weir in slow motion",
            "a lighthouse beam sweeping fog",
            "a hand turning the page of an old atlas",
            "steam rising off a cup on a cold morning",
        ]
        let made = words.enumerated().map { index, words in
            ForgeEntry(
                id: "\(promptID)-\(index)",
                recipe: recipe.with(prompt: words).with(seed: 1000 + index),
                asset: ForgeAsset(filename: "forge_0000\(index).mp4", subfolder: "video"),
                finishedAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(index) * 3600))
        }
        let lost = ForgeEntry(
            id: "\(promptID)-lost", recipe: recipe.with(seed: 9), asset: nil,
            failure: ForgeFailure.noOutput(host).description,
            finishedAt: Date(timeIntervalSince1970: 1_700_003_600))
        return [lost] + made
    }
}
