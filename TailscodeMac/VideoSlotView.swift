import AVFoundation
import AVKit
import AppKit
import TailscodeCore

/// A stream living inside the split tree. The Mac plays through AVKit rather than embedding a
/// player process — a foreign process cannot draw into this app's view — so the page is resolved
/// to a stream first and handed to `AVPlayer`, which the pane then owns like any other subview:
/// the dividers resize it, zoom hides its siblings, and closing the pane hands the space back.
///
/// An empty slot is not a text box. It is a board of what is actually on — the channels this
/// device follows with their live state, what is popular now, the categories to browse — because
/// the question "what do you want to watch" is one almost nobody can answer from memory. The box
/// stays exactly what it was: `VideoTarget.classify` still decides what a typed line means, and
/// typing turns the board into an answer for those words rather than replacing it.
@MainActor
final class VideoSlotView: NSView, NSTextFieldDelegate {
    private(set) var slot: VideoSlot
    private let playerView = AVPlayerView()
    private let promptStack = FillingStack()
    private let field = NSTextField()
    private let headingLabel = NSTextField(labelWithString: Localized.text("Watch"))
    private let reasonLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let noticeLabel = NSTextField(wrappingLabelWithString: "")
    private let boardView = WatchBoardView()
    private var board = WatchChooser()
    private var accountChannels: [MediaChannel] = []
    private var accountsWatch: (any NSObjectProtocol)?
    private var loads: [String: Task<Void, Never>] = [:]
    private var ticker: Task<Void, Never>?
    private var searching: String?
    private var openedCategory: MediaCategory?
    private var player: AVPlayer?
    private var statusObservation: NSKeyValueObservation?
    private var resolving: Task<Void, Never>?

    /// The board's sections, named here because the Kit keeps their identifiers to itself. They are
    /// how a fetch says which section it is answering, so the client needs the same five words.
    /// The board's own names for its sections, so a task keyed to one cancels the request the
    /// board is actually waiting on rather than a string that merely looks like it.
    private enum Feed {
        static let live = WatchChooser.liveID
        static let following = WatchChooser.followingID
        static let results = WatchChooser.resultsID
        static let browse = WatchChooser.browseID
        static let top = WatchChooser.topID
        static let inside = WatchChooser.insideID
    }

    private static let boardHeight: CGFloat = 360
    private static let promptWidth: CGFloat = 460

    /// Told to the pane whenever the slot changes what it says about itself, so the identity strip
    /// and the persisted layout follow the stream rather than lag a state behind.
    var onChange: (() -> Void)?

    init(target: VideoTarget?) {
        slot = VideoSlot(target: target)
        super.init(frame: .zero)
        build()
        if let target {
            point(at: target)
        } else {
            beginAsking()
            render()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        wantsLayer = true

        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.controlsStyle = .floating
        playerView.videoGravity = .resizeAspect
        playerView.isHidden = true
        addSubview(playerView)

        headingLabel.font = MacTheme.Ramp.font(.cardTitle)
        headingLabel.alignment = .center
        reasonLabel.font = MacTheme.Ramp.font(.panelFootnote)
        reasonLabel.textColor = MacTheme.Color.secondaryLabel
        reasonLabel.alignment = .center

        hintLabel.font = MacTheme.Ramp.font(.panelFootnote)
        hintLabel.textColor = MacTheme.Color.secondaryLabel
        hintLabel.alignment = .left
        hintLabel.maximumNumberOfLines = 1
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        field.placeholderString = slot.prompt
        field.font = MacTheme.Ramp.font(.panelLabel)
        field.target = self
        field.action = #selector(submit)
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        boardView.translatesAutoresizingMaskIntoConstraints = false
        boardView.setContentCompressionResistancePriority(.init(1), for: .vertical)

        noticeLabel.font = MacTheme.Ramp.font(.panelFootnote)
        noticeLabel.textColor = MacTheme.Color.secondaryLabel
        noticeLabel.alignment = .center
        noticeLabel.isSelectable = false
        noticeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        noticeLabel.translatesAutoresizingMaskIntoConstraints = false
        renderNotice()

        promptStack.spacing = MacTheme.Spacing.m
        promptStack.translatesAutoresizingMaskIntoConstraints = false
        promptStack.setViews(
            [
                headingLabel, field, reasonLabel, boardView, hintLabel,
                Self.noticeCard(around: noticeLabel),
            ],
            in: .center)
        addSubview(promptStack)

        let preferredWidth = promptStack.widthAnchor.constraint(
            equalToConstant: Self.promptWidth)
        preferredWidth.priority = .defaultLow
        let centred = promptStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        centred.priority = .defaultLow
        let top = promptStack.topAnchor.constraint(
            greaterThanOrEqualTo: topAnchor, constant: MacTheme.Spacing.l)
        top.priority = .init(999)
        let bottom = promptStack.bottomAnchor.constraint(
            lessThanOrEqualTo: bottomAnchor, constant: -MacTheme.Spacing.l)
        bottom.priority = .init(999)
        let preferredBoard = boardView.heightAnchor.constraint(
            equalToConstant: Self.boardHeight)
        preferredBoard.priority = .defaultLow

        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: topAnchor),
            playerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            promptStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            promptStack.widthAnchor.constraint(lessThanOrEqualToConstant: Self.promptWidth),
            promptStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor, constant: MacTheme.Spacing.l),
            promptStack.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -MacTheme.Spacing.l),
            boardView.heightAnchor.constraint(lessThanOrEqualToConstant: Self.boardHeight),
            preferredWidth, centred, top, bottom, preferredBoard,
        ])
    }

    /// The tinted card the split-cost notice sits in. Content rather than chrome, so it is a plain
    /// rounded fill on the opaque canvas and never glass — prose does not sit on glass.
    private static func noticeCard(around content: NSView) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = MacTheme.Radius.card
        card.layer?.backgroundColor = MacTheme.Color.accent.withAlphaComponent(0.10).cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = MacTheme.Color.accent.withAlphaComponent(0.30).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(
                equalTo: card.leadingAnchor, constant: MacTheme.Spacing.m),
            content.trailingAnchor.constraint(
                equalTo: card.trailingAnchor, constant: -MacTheme.Spacing.m),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: MacTheme.Spacing.s),
            content.bottomAnchor.constraint(
                equalTo: card.bottomAnchor, constant: -MacTheme.Spacing.s),
        ])
        return card
    }

    var target: VideoTarget? { slot.target }
    var isAsking: Bool { slot.isAsking }

    /// One line for the headless selftest: the phase, then what the slot is showing, then how much
    /// board it drew — a board that silently stopped filling is otherwise indistinguishable from a
    /// night when nothing is on.
    var summary: String {
        let phase: String
        switch slot.phase {
        case .asking: phase = "asking"
        case .loading: phase = "loading"
        case .playing: phase = "playing"
        case .failed: phase = "failed"
        }
        let line = "\(phase) \(slot.target?.address ?? "-") [\(slot.title)] \(slot.subtitle)"
        guard slot.isAsking else { return line }
        return "\(line) board=\(board.rows.count)/\(board.sections.count)"
    }

    func focusPrompt() {
        window?.makeFirstResponder(field)
    }

    @objc private func submit() {
        guard let target = VideoTarget.classify(field.stringValue) else { return }
        point(at: target)
    }

    /// - Parameter named: what the row that offered this called it, so a channel joins the recents
    ///   under the name a person would recognise rather than under its login.
    func point(at target: VideoTarget, named: String? = nil) {
        WatchStore.record(target, title: named)
        endAsking()
        slot.point(at: target)
        render()
        resolving?.cancel()
        resolving = Task { [weak self] in
            let outcome = await Self.resolve(target)
            guard !Task.isCancelled else { return }
            self?.finish(outcome)
        }
    }

    private static func resolve(_ target: VideoTarget) async -> Result<URL, Error> {
        await Task.detached(priority: .userInitiated) {
            do {
                return .success(try VideoResolver.directURL(for: target))
            } catch {
                return .failure(error)
            }
        }.value
    }

    private func finish(_ outcome: Result<URL, Error>) {
        switch outcome {
        case .success(let url):
            play(url)
        case .failure(let error):
            slot.failed("\(error)")
            render()
        }
    }

    private func play(_ url: URL) {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = slot.muted
        playerView.player = player
        self.player = player
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.slot.loaded(title: nil)
                case .failed:
                    self.slot.failed(
                        item.error?.localizedDescription ?? Localized.text("That would not play"))
                default:
                    return
                }
                self.render()
            }
        }
        player.play()
    }

    /// Back to the question with the old target in the box — a mistyped channel is a correction,
    /// not a retype — and the board agrees with the box it is under, so it answers for those words
    /// rather than reverting to what is on generally.
    func ask() {
        slot.ask()
        field.stringValue = slot.draft
        board.type(slot.draft)
        stop()
        beginAsking()
        render()
        focusPrompt()
    }

    func handle(_ command: VideoCommand) {
        guard command != .change else {
            ask()
            return
        }
        guard let player, !slot.isAsking else { return }
        switch command {
        case .playPause:
            slot.paused.toggle()
            slot.paused ? player.pause() : player.play()
        case .mute:
            slot.muted.toggle()
            player.isMuted = slot.muted
        case .volumeUp:
            player.volume = min(1, player.volume + 0.05)
        case .volumeDown:
            player.volume = max(0, player.volume - 0.05)
        case .seekBack, .seekForward:
            let delta = command == .seekBack ? -10.0 : 10.0
            let time = player.currentTime() + CMTime(seconds: delta, preferredTimescale: 600)
            player.seek(to: time)
        case .reload:
            if let target = slot.target { point(at: target) }
        case .change:
            return
        }
        render()
    }

    /// The keys the board claims while the slot is still asking. Every one of them is a chord the
    /// text field under it has no use for, because the same keystrokes are typing a channel name.
    func handleBoard(_ chord: KeyChord) -> Bool {
        guard slot.isAsking, let command = WatchChooser.command(for: chord) else { return false }
        let named = board.focused?.channel?.name
        let (handled, action) = board.handle(command)
        guard handled else { return false }
        if command == .back { field.stringValue = board.query }
        if let action {
            perform(action, named: named)
        } else {
            boardChanged()
        }
        if slot.isAsking, let focused = board.focused { boardView.reveal(focused.id) }
        return true
    }

    func shutdown() {
        resolving?.cancel()
        resolving = nil
        endAsking()
        stop()
    }

    private func stop() {
        statusObservation?.invalidate()
        statusObservation = nil
        player?.pause()
        player = nil
        playerView.player = nil
    }

    private func render() {
        let showing = !slot.isAsking
        var failed = false
        if case .failed(let reason) = slot.phase {
            failed = true
            reasonLabel.stringValue = reason
        }
        reasonLabel.isHidden = !failed
        playerView.isHidden = !showing || failed
        promptStack.isHidden = showing && !failed
        applyBackground()
        if slot.isAsking {
            renderBoard()
        } else {
            headingLabel.stringValue = Localized.text("Watch")
            hintLabel.stringValue = slot.hint
            boardView.isHidden = true
            renderNotice()
        }
        onChange?()
    }

    /// What a stream costs the grid, at the width the pane has left for it. An empty slot gets the
    /// whole paragraph in its tinted card — there is nothing else in the pane to read — but a slot
    /// showing a board has spent that room on what is actually on, so the same fact rides one line
    /// under it rather than pushing the board off the pane.
    private func renderNotice() {
        let whole = board.isEmpty
        noticeLabel.stringValue = whole ? slot.notice : VideoNotice.splitCostLine
        noticeLabel.maximumNumberOfLines = whole ? 0 : 1
        noticeLabel.lineBreakMode = whole ? .byWordWrapping : .byTruncatingTail
    }

    /// Black behind a player, the app's own canvas behind the board: a video needs its letterbox,
    /// and the board is content, which sits on the opaque canvas like every other row of prose.
    private func applyBackground() {
        var failed = false
        if case .failed = slot.phase { failed = true }
        let playing = !slot.isAsking && !failed
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor =
                playing ? NSColor.black.cgColor : MacTheme.Color.canvas.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackground()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextField) === field else { return }
        board.type(field.stringValue)
        boardChanged()
    }

    private func renderBoard() {
        headingLabel.stringValue = board.heading
        hintLabel.stringValue = board.hint
        boardView.isHidden = board.isEmpty
        renderNotice()
        boardView.render(board) { [weak self] section, offset in
            self?.pressed(section: section, offset: offset)
        }
    }

    /// A press on a row is the same act as walking to it and pressing enter, so it goes through the
    /// cursor rather than around it — the board keeps one idea of where somebody is.
    private func pressed(section: String, offset: Int) {
        board.focus(section: section, offset: offset)
        guard let row = board.focused else {
            renderBoard()
            return
        }
        let named = row.channel?.name
        if let action = board.activate(row) {
            perform(action, named: named)
        } else {
            boardChanged()
        }
    }

    /// What the board asked the pane to do. Playing ends the question; following or reloading
    /// leaves the board where it was, restocked with what this device now knows about itself.
    private func perform(_ action: WatchAction, named: String?) {
        switch action {
        case .play(let target):
            point(at: target, named: named)
        case .follow(let channel):
            WatchStore.toggle(channel)
            stockBoard()
            fetchLive()
            boardChanged()
        case .reload:
            refreshBoard()
        }
    }

    /// Everything that follows a change to the board: a category it just opened is fetched, words
    /// it is still owed an answer for are asked once the typing settles, and the pane redraws.
    private func boardChanged() {
        syncOpenCategory()
        syncSearch()
        renderBoard()
    }

    private func beginAsking() {
        observeAccounts()
        refreshBoard()
        startTicker()
    }

    /// Signing in or out rewrites who this device follows, which is the whole of the board's first
    /// two sections — so an account landing while the question is still on screen re-asks every
    /// source rather than waiting for the next time somebody opens an empty pane.
    private func observeAccounts() {
        guard accountsWatch == nil else { return }
        accountsWatch = NotificationCenter.default.addObserver(
            forName: MediaAccounts.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBoard() }
        }
    }

    private func releaseAccountsWatch() {
        guard let accountsWatch else { return }
        NotificationCenter.default.removeObserver(accountsWatch)
        self.accountsWatch = nil
    }

    /// Asks every source again from nothing: the list this device owns is re-read, each section is
    /// put back into its waiting state, and a question the board is in the middle of — an open
    /// category, words already typed — is asked again rather than left holding a stale answer.
    private func refreshBoard() {
        stockBoard()
        searching = nil
        fetchFollowing()
        fetchLive()
        fetchTop()
        fetchCategories()
        if let category = board.opened { fetchInside(category) }
        boardChanged()
    }

    private func endAsking() {
        for task in loads.values { task.cancel() }
        loads = [:]
        searching = nil
        openedCategory = nil
        ticker?.cancel()
        ticker = nil
        releaseAccountsWatch()
        releaseField()
    }

    /// The box gives the keyboard back the moment the question is over. Hiding a text field does
    /// not resign its field editor, and while that editor is first responder the window reads every
    /// chord as text — so a slot that had just started playing would never be offered space, m, e
    /// or the arrows it answers.
    private func releaseField() {
        guard field.currentEditor() != nil else { return }
        window?.makeFirstResponder(nil)
    }

    private func stockBoard() {
        var seen = Set<String>()
        let merged = (WatchStore.watchlist() + accountChannels).filter {
            seen.insert($0.id).inserted
        }
        board.stock(watchlist: merged, followed: WatchStore.channels())
        board.attribute(Self.hasAccount ? WatchAccounts.summary : nil)
    }

    /// Whether either site has an account on this device, read the way the settings rows read it —
    /// off the name a row draws with rather than off the token — so deciding what the board says
    /// never waits on the Keychain.
    private static var hasAccount: Bool {
        WatchAccounts.rows().contains(where: \.isSignedIn)
    }

    /// Who the signed-in accounts follow, merged with what this device typed in. Asked once per
    /// refresh and then kept, because starring a channel restocks the board and must not cost a
    /// round trip to somebody else's site to redraw one star.
    private func fetchFollowing() {
        let local = WatchStore.watchlist()
        guard Self.hasAccount else {
            accountChannels = []
            loads[Feed.following]?.cancel()
            loads[Feed.following] = nil
            return
        }
        loads[Feed.following]?.cancel()
        loads[Feed.following] = Task { [weak self] in
            let feed = await Task.detached(priority: .userInitiated) {
                await MediaFollowing().watchlist(local: local)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.accountChannels = feed.entries.map(\.channel)
            self.stockBoard()
            self.boardChanged()
        }
    }

    /// What is live among them, by each source's cheapest honest route: a signed-in Twitch answers
    /// for the whole account in one request, and everything else falls back to the free per-channel
    /// path the signed-out board has always used.
    private func fetchLive() {
        let channels = WatchStore.watchlist()
        guard !channels.isEmpty || Self.hasAccount else { return }
        loads[Feed.live]?.cancel()
        board.loading(Feed.live)
        loads[Feed.live] = Task { [weak self] in
            let feed = await Task.detached(priority: .userInitiated) {
                await MediaFollowing().live(local: channels)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.board.filled(live: feed)
            self.boardChanged()
        }
    }

    private func fetchTop() {
        loads[Feed.top]?.cancel()
        board.loading(Feed.top)
        loads[Feed.top] = Task { [weak self] in
            let feed = await Task.detached(priority: .userInitiated) {
                await MediaDirectory().top()
            }.value
            guard !Task.isCancelled, let self else { return }
            self.board.filled(top: feed)
            self.boardChanged()
        }
    }

    private func fetchCategories() {
        loads[Feed.browse]?.cancel()
        board.loading(Feed.browse)
        loads[Feed.browse] = Task { [weak self] in
            let feed = await Task.detached(priority: .userInitiated) {
                await MediaDirectory().categories()
            }.value
            guard !Task.isCancelled, let self else { return }
            self.board.filled(categories: feed)
            self.boardChanged()
        }
    }

    private func fetchInside(_ category: MediaCategory) {
        openedCategory = category
        loads[Feed.inside]?.cancel()
        board.loading(Feed.inside)
        loads[Feed.inside] = Task { [weak self] in
            let feed = await Task.detached(priority: .userInitiated) {
                await MediaDirectory().inside(category)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.board.filled(inside: feed, of: category)
            self.boardChanged()
        }
    }

    private func syncOpenCategory() {
        guard board.opened != openedCategory else { return }
        guard let opened = board.opened else {
            openedCategory = nil
            loads[Feed.inside]?.cancel()
            loads[Feed.inside] = nil
            return
        }
        fetchInside(opened)
    }

    /// A keystroke is not a question yet. The words settle for a moment before either site is
    /// asked, so a channel name typed at speed costs one round trip rather than one per letter.
    private func syncSearch() {
        guard let words = board.pendingSearch else {
            guard searching != nil else { return }
            searching = nil
            loads[Feed.results]?.cancel()
            loads[Feed.results] = nil
            return
        }
        guard words != searching else { return }
        searching = words
        loads[Feed.results]?.cancel()
        loads[Feed.results] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let feed = await Task.detached(priority: .userInitiated) {
                await MediaDirectory().search(words)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.board.filled(results: feed, for: words)
            self.boardChanged()
        }
    }

    /// A board left open goes stale quietly: nothing on it changes, but every uptime it states
    /// grows wrong by a minute a minute. Re-reading them costs nothing and asks no source.
    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self, self.slot.isAsking else { return }
                self.board.tick()
                self.renderBoard()
            }
        }
    }
}
