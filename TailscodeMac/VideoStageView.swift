import AVFoundation
import AppKit
import TailscodeCore

/// A clip the stage can play: which one, and where the renderer says it is.
struct VideoClipHold: Equatable {
    let id: String
    let url: URL
}

/// Everything the Video stage draws, decided once by the lane from the board so the stage, the
/// verbs, the dock and the shelf can never disagree. The stage holds no forge of its own: it is
/// handed a model on every change and redraws only what that change touches.
struct VideoStageModel {
    var state: StudioVideoState = .empty
    var size: ForgeSize = .landscape
    var caption = ""
    var sentence = ""
    var sketchCaption = ""
    var segments: [StudioProgressLine.Segment] = []
    var clip: VideoClipHold?
    var held: CGImage?
    var sketch: CGImage?
    var verbs: [StudioStageVerb] = []
    var spoken = ""
    var needsRenderer = false
    var invitationTitle = ""
    var invitationBody = ""
    var landed: String?
}

/// The Video stage: the clip owns the window. An opaque canvas with a sixteen-point corner, the
/// clip aspect-fit inside it with a margin all round and clear of the dock that floats over its
/// foot. The rectangle is decided before a render starts, from the size that was asked for, so the
/// machine's sketch fills it and the clip lands in it and nothing moves when it arrives.
///
/// It says what `StudioVideoState` says: an invitation when empty, the first frame while drafting,
/// one sentence on a glyph that breathes while the machine works out what it was asked, the
/// machine's own sketch while it samples with a line along the sketch's edge — one segment for each
/// pass the graph samples in — the clip once it lands, crossfaded from the sketch in one 240 ms
/// ease-out or instantly under reduced motion, and a failure in the failure tone, perfectly still,
/// with the one thing that fixes it. A finished clip plays in place, loops, and is muted unless it
/// has sound; there is no player chrome, because the verbs capsule is the only floating control the
/// picture carries.
@MainActor
final class VideoStageView: NSView, StudioStaging {
    var bottomReserve: CGFloat = StudioTheme.dockBase + StudioTheme.dockInset + 12 {
        didSet {
            guard bottomReserve != oldValue else { return }
            needsLayout = true
        }
    }

    var onVerb: ((StudioStageVerb) -> Void)?
    var onRemedy: ((StudioRemedy) -> Void)?
    var onDrop: ((StudioDrop) -> Void)?
    var onOpen: (() -> Void)?
    var onSetup: (() -> Void)?
    var onClipFailed: ((String) -> Void)?
    var onPlaybackChanged: (() -> Void)?
    var onWindowChange: (() -> Void)?

    private(set) var model = VideoStageModel()
    private let held = CALayer()
    private let sketchLayer = CALayer()
    private let playerLayer = AVPlayerLayer()
    private let dash = CAShapeLayer()
    private var tracks: [CALayer] = []
    private var fills: [CALayer] = []
    private let caption = StudioTheme.label(.panelFootnote, color: MacTheme.Color.secondaryLabel, alignment: .center)
    private let clockDot = ActivityBadgeView(pointSize: 11)
    private let sketchPill = StudioPill()
    private let soundPill = StudioPill()
    private let invitation = VideoInvitationView()
    private let status = StudioStatusView()
    private let failure = StudioFailureCard()
    private let capsule = StudioVerbsCapsule()
    private let dropNote = StudioPill()
    private let playGlyph = VideoPlayGlyph()

    private var pictureRect: NSRect = .zero
    private var landingPending = false
    private var link: CADisplayLink?
    private var sketchDirty = false
    private var dropping = false

    private var player: AVPlayer?
    private var clipID: String?
    private var playerReady = false
    private var hasSound = false
    private var muted = false
    private(set) var isPlaying = false
    private var readiness: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var loadTask: Task<Void, Never>?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = StudioTheme.stageRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        for picture in [held, sketchLayer, playerLayer] {
            picture.masksToBounds = true
            picture.cornerRadius = StudioTheme.pictureRadius
            picture.cornerCurve = .continuous
            layer?.addSublayer(picture)
        }
        for picture in [held, sketchLayer] {
            picture.contentsGravity = .resizeAspect
            picture.magnificationFilter = .linear
            picture.minificationFilter = .trilinear
        }
        playerLayer.videoGravity = .resizeAspect
        playerLayer.opacity = 0
        sketchLayer.isHidden = true
        dash.fillColor = nil
        dash.lineWidth = 1
        dash.lineDashPattern = [6, 5]
        dash.isHidden = true
        layer?.addSublayer(dash)

        for view in [caption, clockDot, sketchPill, soundPill, invitation, status, failure, playGlyph, capsule, dropNote] as [NSView] {
            addSubview(view)
        }
        for view in [clockDot, sketchPill, soundPill, invitation, status, failure, playGlyph, dropNote] as [NSView] {
            view.isHidden = true
        }

        invitation.onSetup = { [weak self] in self?.onSetup?() }
        failure.onRemedy = { [weak self] remedy in self?.onRemedy?(remedy) }
        capsule.onVerb = { [weak self] verb in self?.onVerb?(verb) }
        capsule.primaryID = StudioVideoVerbs.primaryID
        capsule.setAccessibilityLabel(Localized.text("Clip actions"))
        dropNote.text = Localized.text("Start from this picture")
        soundPill.toolTip = ForgeWords.soundToggleHint

        registerForDraggedTypes(StudioDrop.registered)
        setAccessibilityRole(.group)
        restyle()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged), name: MacTheme.Chrome.didRepaint, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        link?.invalidate()
        loadTask?.cancel()
        tearDownPlayer()
    }

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override var isOpaque: Bool { true }

    @objc private func themeChanged() { restyle() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    /// Colours are asked for again rather than remembered: a layer holds a `CGColor`, which is one
    /// resolved answer, and a theme or an appearance changing under it would otherwise leave the
    /// stage wearing the palette it was born with.
    private func restyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = StudioTheme.ground.cgColor
            dash.strokeColor = MacTheme.Color.tertiaryLabel.cgColor
            for track in tracks { track.backgroundColor = MacTheme.Color.label.withAlphaComponent(0.18).cgColor }
            for fill in fills { fill.backgroundColor = MacTheme.Color.accent.cgColor }
        }
        caption.font = MacTheme.Ramp.font(.panelFootnote)
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            link?.invalidate()
            link = nil
            pausePlayback()
        } else {
            recompute(from: model.state)
        }
        onWindowChange?()
    }

    var showsClip: Bool { model.state.showsClip }

    var currentPictureRect: NSRect { pictureRect }

    func apply(_ next: VideoStageModel, change: StudioLaneChange) {
        switch change {
        case .sketch:
            model.sketch = next.sketch
            sketchDirty = true
            startLink()
            return
        case .progress:
            model = next
            updateProgress()
            updateCaption()
            return
        case .everything, .shelf, .tile:
            break
        }
        let before = model.state
        model = next
        recompute(from: before)
    }

    private func recompute(from before: StudioVideoState) {
        loadClip(model.clip)
        let landed = before.isWorking && model.state == .done
        if landed { landingPending = true }
        if model.state != .done { landingPending = false }
        applyState(landing: landingPending)
        needsLayout = true
        layoutSubtreeIfNeeded()
        if landed, let words = model.landed { announce(words) }
    }

    /// A finished clip is said once, politely: a screen reader cannot see it land.
    private func announce(_ words: String) {
        NSAccessibility.post(
            element: self, notification: .announcementRequested,
            userInfo: [.announcement: words, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    private func startLink() {
        guard link == nil, window != nil else {
            link?.isPaused = false
            return
        }
        let fresh = displayLink(target: self, selector: #selector(step(_:)))
        fresh.runAtActivityTempo()
        fresh.add(to: .main, forMode: .common)
        link = fresh
    }

    /// A sketch lands at the pace the machine sends them, but is drawn no faster than the display
    /// asks: the newest one wins, and the link rests until another arrives.
    @objc private func step(_ link: CADisplayLink) {
        link.isPaused = true
        guard sketchDirty else { return }
        sketchDirty = false
        guard model.state.isWorking, let sketch = model.sketch else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sketchLayer.contents = sketch
        sketchLayer.isHidden = false
        CATransaction.commit()
        status.isHidden = true
        sketchPill.text = model.sketchCaption
        sketchPill.isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func applyState(landing: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let state = model.state
        let dim: Float
        switch state {
        case .empty: dim = StudioTheme.dimmed
        case .failed, .stopped: dim = 0.32
        case .waiting, .working, .painting: dim = 0.4
        case .finishing, .drafting, .done: dim = 1
        }
        held.contents = model.held
        held.opacity = model.held == nil ? 0 : dim

        if let sketch = model.sketch, state.isWorking {
            if sketchLayer.contents == nil { sketchLayer.contents = sketch }
            sketchLayer.isHidden = false
        } else if !(landing && sketchLayer.contents != nil) {
            sketchLayer.isHidden = true
            sketchLayer.contents = nil
            sketchPill.isHidden = true
        }
        if case .finishing = state, sketchLayer.contents != nil { sketchLayer.opacity = 0.6 } else if !landing { sketchLayer.opacity = 1 }

        dash.isHidden = !(state == .empty || (state == .drafting && model.held == nil))
        invitation.isHidden = state != .empty
        if state == .empty {
            invitation.show(
                title: model.invitationTitle, body: model.invitationBody, needsRenderer: model.needsRenderer)
        }
        switch state {
        case .waiting(let line), .working(let line), .finishing(let line):
            status.show(line: line, working: !isFinishing(state))
            status.isHidden = false
        case .painting(let line):
            status.show(line: line, working: true)
            status.isHidden = model.sketch != nil
            if model.sketch != nil {
                sketchPill.text = model.sketchCaption
                sketchPill.isHidden = false
            }
        default:
            status.isHidden = true
        }
        if case .failed(let reason, let remedy) = state {
            failure.show(reason: reason, remedy: remedy)
            failure.isHidden = false
        } else {
            failure.isHidden = true
        }

        if state == .done {
            if playerReady { revealPlayer(landing: landing) }
        } else {
            pausePlayback()
            playerLayer.opacity = 0
        }
        updateProgress()
        updateCaption()
        updateCapsule()
        updateGlyphs()
        setAccessibilityLabel(model.spoken)
    }

    private func isFinishing(_ state: StudioVideoState) -> Bool {
        if case .finishing = state { return true }
        return false
    }

    private func updateCapsule() {
        let verbs = model.verbs
        let reserved = model.state.isWorking
        capsule.show(verbs, holdsRoom: reserved || !verbs.isEmpty)
        capsule.alphaValue = verbs.isEmpty ? 0 : 1
        capsule.isHidden = verbs.isEmpty && !reserved
        capsule.setAccessibilityElement(!verbs.isEmpty)
    }

    private func updateCaption() {
        clockDot.activity = nil
        clockDot.isHidden = true
        if case .painting = model.state {
            clockDot.activity = .working
            clockDot.isHidden = false
        } else if model.state.isWorking {
            clockDot.activity = .working
            clockDot.isHidden = false
        }
        caption.stringValue = model.caption
        sketchPill.text = model.sketchCaption
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func updateProgress() {
        let wanted = model.state.isWorking ? model.segments : []
        while tracks.count < wanted.count {
            let track = CALayer()
            let fill = CALayer()
            layer?.addSublayer(track)
            layer?.addSublayer(fill)
            tracks.append(track)
            fills.append(fill)
        }
        restyleBars()
        for (index, track) in tracks.enumerated() {
            let shown = index < wanted.count
            track.isHidden = !shown
            fills[index].isHidden = !shown
        }
        layoutProgress()
    }

    private func restyleBars() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for track in tracks { track.backgroundColor = MacTheme.Color.label.withAlphaComponent(0.18).cgColor }
            for fill in fills { fill.backgroundColor = MacTheme.Color.accent.cgColor }
        }
    }

    private func layoutProgress() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if model.state.isWorking, !model.segments.isEmpty {
            let y = pictureRect.maxY - StudioTheme.progressThickness
            let laid = StudioProgressLine.filled(
                model.segments, width: Double(pictureRect.width), gap: model.segments.count > 1 ? 4 : 0)
            for (index, part) in laid.enumerated() where index < tracks.count {
                tracks[index].frame = CGRect(
                    x: pictureRect.minX + part.origin, y: y, width: part.length,
                    height: StudioTheme.progressThickness)
                fills[index].frame = CGRect(
                    x: pictureRect.minX + part.origin, y: y, width: part.filled,
                    height: StudioTheme.progressThickness)
            }
        } else if isPlaying, let player, let duration = player.currentItem?.duration.seconds, duration.isFinite,
            duration > 0, let first = fills.first, let track = tracks.first
        {
            let y = pictureRect.maxY - StudioTheme.progressThickness
            track.isHidden = false
            first.isHidden = false
            track.frame = CGRect(x: pictureRect.minX, y: y, width: pictureRect.width, height: StudioTheme.progressThickness)
            let fraction = max(0, min(1, player.currentTime().seconds / duration))
            first.frame = CGRect(
                x: pictureRect.minX, y: y, width: pictureRect.width * CGFloat(fraction),
                height: StudioTheme.progressThickness)
        }
    }

    private func updateGlyphs() {
        playGlyph.isHidden = !(model.state == .done && playerReady && !isPlaying)
        let showsSound = model.state == .done && isPlaying && hasSound
        soundPill.isHidden = !showsSound
        if showsSound { soundPill.text = muted ? ForgeWords.soundOffMark : ForgeWords.soundOnMark }
        needsLayout = true
    }

    private func updateStillTracks() {
        guard model.state == .done, !isPlaying else { return }
        for (track, fill) in zip(tracks, fills) {
            track.isHidden = true
            fill.isHidden = true
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let area = NSRect(
            x: StudioTheme.stageMargin, y: StudioTheme.captionBand,
            width: max(0, bounds.width - 2 * StudioTheme.stageMargin),
            height: max(0, bounds.height - StudioTheme.captionBand - bottomReserve))
        let ratio = max(model.size.height, 1)
        pictureRect = StudioStageView.fit(aspect: Double(model.size.width) / Double(ratio), in: area)
        for picture in [held, sketchLayer, playerLayer] { picture.frame = pictureRect }
        dash.frame = pictureRect
        dash.path = CGPath(
            roundedRect: CGRect(origin: .zero, size: pictureRect.size).insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: StudioTheme.pictureRadius, cornerHeight: StudioTheme.pictureRadius,
            transform: nil)

        let captionHeight = StudioTheme.height(of: .panelFootnote)
        let dotWidth: CGFloat = clockDot.isHidden ? 0 : 18
        let captionWidth = min(
            bounds.width - 2 * StudioTheme.stageMargin - dotWidth, ceil(caption.intrinsicContentSize.width) + 14)
        let total = captionWidth + dotWidth
        let originX = (bounds.width - total) / 2
        let captionY = (StudioTheme.captionBand - 8 - captionHeight) / 2 + 4
        clockDot.frame = NSRect(x: originX, y: captionY - 1, width: dotWidth, height: captionHeight + 2)
        caption.frame = NSRect(x: originX + dotWidth, y: captionY, width: captionWidth, height: captionHeight)

        let pill = sketchPill.fittingSize
        sketchPill.frame = NSRect(
            x: pictureRect.minX + 12, y: pictureRect.minY + 12, width: pill.width, height: pill.height)
        let sound = soundPill.fittingSize
        soundPill.frame = NSRect(
            x: pictureRect.maxX - 12 - sound.width, y: pictureRect.minY + 12, width: sound.width,
            height: sound.height)
        let note = dropNote.fittingSize
        dropNote.frame = NSRect(
            x: pictureRect.midX - note.width / 2, y: pictureRect.minY + 16, width: note.width,
            height: note.height)

        let inviteWidth = min(max(pictureRect.width - 40, 0), 560)
        let invite = invitation.fitting(width: inviteWidth)
        invitation.frame = NSRect(
            x: pictureRect.midX - invite.width / 2, y: pictureRect.midY - invite.height / 2,
            width: invite.width, height: invite.height)
        invitation.needsLayout = true

        let statusSize = status.fitting(width: min(pictureRect.width - 32, 520))
        status.frame = NSRect(
            x: pictureRect.midX - statusSize.width / 2, y: pictureRect.midY - statusSize.height / 2,
            width: statusSize.width, height: statusSize.height)
        let failureSize = failure.fitting(width: min(max(pictureRect.width - 48, 0), 520))
        failure.frame = NSRect(
            x: pictureRect.midX - failureSize.width / 2, y: pictureRect.midY - failureSize.height / 2,
            width: failureSize.width, height: failureSize.height)
        playGlyph.frame = NSRect(
            x: pictureRect.midX - VideoPlayGlyph.side / 2, y: pictureRect.midY - VideoPlayGlyph.side / 2,
            width: VideoPlayGlyph.side, height: VideoPlayGlyph.side)

        let capsuleSize = capsule.fitting(maxWidth: max(0, pictureRect.width - 24))
        capsule.frame = NSRect(
            x: pictureRect.midX - capsuleSize.width / 2,
            y: pictureRect.maxY - StudioTheme.capsuleLift - capsuleSize.height,
            width: capsuleSize.width, height: capsuleSize.height)
        layoutProgress()
        updateStillTracks()
    }

    var spokenState: String { model.spoken }

    private func loadClip(_ hold: VideoClipHold?) {
        guard hold?.id != clipID else { return }
        loadTask?.cancel()
        tearDownPlayer()
        clipID = hold?.id
        guard let hold else { return }
        let url = hold.url
        let id = hold.id
        loadTask = Task { [weak self] in
            let asset = AVURLAsset(url: url)
            do {
                let playable = try await asset.load(.isPlayable)
                guard playable else { throw CocoaError(.fileReadCorruptFile) }
                let audio = try await asset.loadTracks(withMediaType: .audio)
                guard !Task.isCancelled, let self, self.clipID == id else { return }
                self.attach(asset, hasSound: !audio.isEmpty)
            } catch {
                guard !Task.isCancelled, let self, self.clipID == id else { return }
                self.onClipFailed?(error.localizedDescription)
            }
        }
    }

    private func attach(_ asset: AVURLAsset, hasSound sound: Bool) {
        hasSound = sound
        let item = AVPlayerItem(asset: asset)
        let fresh = AVPlayer(playerItem: item)
        fresh.isMuted = !sound || muted
        fresh.actionAtItemEnd = .none
        player = fresh
        playerReady = false
        playerLayer.player = fresh
        readiness = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.playerBecameReady() }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.loop() }
        }
        timeObserver = fresh.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutProgress() }
        }
    }

    private func playerBecameReady() {
        playerReady = true
        if model.state == .done {
            revealPlayer(landing: landingPending)
            updateGlyphs()
        }
    }

    /// The clip arrives under the sketch and the sketch lets go of it: one ease-out of 240 ms on the
    /// sketch's opacity, once, after which its pixels are dropped. The sketch holds the rectangle
    /// while it does, so nothing moves; with no sketch, or under reduced motion, the clip is simply
    /// there.
    private func revealPlayer(landing: Bool) {
        let fading = landing && sketchLayer.contents != nil && StudioTheme.motionAllowed
        landingPending = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.opacity = 1
        CATransaction.commit()
        guard sketchLayer.contents != nil else { return }
        guard fading else {
            sketchLayer.isHidden = true
            sketchLayer.contents = nil
            sketchPill.isHidden = true
            return
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(StudioTheme.crossfade)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sketchLayer.isHidden = true
                self.sketchLayer.contents = nil
                self.sketchLayer.opacity = 1
                self.sketchPill.isHidden = true
            }
        }
        sketchLayer.opacity = 0
        CATransaction.commit()
        sketchPill.isHidden = true
    }

    private func loop() {
        guard let player, isPlaying else { return }
        player.seek(to: .zero) { [weak player] _ in player?.play() }
    }

    private func tearDownPlayer() {
        isPlaying = false
        playerReady = false
        readiness?.invalidate()
        readiness = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player = nil
        playerLayer.player = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.opacity = 0
        CATransaction.commit()
    }

    func togglePlayback() {
        guard model.state == .done, playerReady, let player else { return }
        if isPlaying { pausePlayback() } else {
            isPlaying = true
            player.play()
            updateGlyphs()
            onPlaybackChanged?()
        }
    }

    func pausePlayback() {
        guard isPlaying else { return }
        isPlaying = false
        player?.pause()
        updateGlyphs()
        onPlaybackChanged?()
    }

    private func toggleMute() {
        muted.toggle()
        player?.isMuted = muted
        updateGlyphs()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if !soundPill.isHidden, soundPill.frame.contains(point) {
            toggleMute()
            return
        }
        guard model.state == .done, pictureRect.contains(point) else { return }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(singleClick), object: nil)
        if event.clickCount >= 2 {
            onOpen?()
        } else {
            perform(#selector(singleClick), with: nil, afterDelay: NSEvent.doubleClickInterval)
        }
    }

    @objc private func singleClick() { togglePlayback() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard StudioDrop.accepts(sender.draggingPasteboard) else { return [] }
        setDropping(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropping ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { setDropping(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDropping(false)
        guard let drop = StudioDrop.read(sender.draggingPasteboard) else { return false }
        onDrop?(drop)
        return true
    }

    private func setDropping(_ on: Bool) {
        dropping = on
        dropNote.isHidden = !on
        dash.isHidden = !on && !(model.state == .empty || (model.state == .drafting && model.held == nil))
        dash.strokeColor = (on ? MacTheme.Color.accent : MacTheme.Color.tertiaryLabel).cgColor
        needsLayout = true
    }

    @objc func copy(_ sender: Any?) {
        guard model.state == .done else { return }
        onVerb?(StudioStageVerb(id: "copy", title: "", hint: "", symbol: ""))
    }

    override func drawFocusRingMask() {
        NSBezierPath(
            roundedRect: bounds, xRadius: StudioTheme.stageRadius, yRadius: StudioTheme.stageRadius
        ).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func accessibilityPerformPress() -> Bool {
        guard model.state == .done else { return false }
        togglePlayback()
        return true
    }
}

extension VideoStageView: NSMenuItemValidation {
    /// Edit ▸ Copy reaches the stage through the responder chain when the stage has focus, and is
    /// available exactly when a finished clip is on it.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) { return showsClip }
        return true
    }
}

/// The empty stage's invitation: one sentence about what the box is for, where a render happens,
/// and — when there is no machine to ask yet — the one button that goes and gets one.
@MainActor
final class VideoInvitationView: NSView {
    var onSetup: (() -> Void)?
    private let title = StudioTheme.label(.headline, color: MacTheme.Color.label, lines: 2, alignment: .center)
    private let body = StudioTheme.label(.panelFootnote, color: MacTheme.Color.secondaryLabel, lines: 3, alignment: .center)
    private let button = NSButton(title: "", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        addSubview(title)
        addSubview(body)
        button.bezelStyle = .rounded
        button.bezelColor = MacTheme.Color.accent
        button.target = self
        button.action = #selector(pressed)
        button.keyEquivalent = ""
        button.isHidden = true
        addSubview(button)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func show(title text: String, body words: String, needsRenderer: Bool) {
        title.stringValue = text
        body.stringValue = words
        button.title = ForgeSetup.title
        button.isHidden = !needsRenderer
        setAccessibilityLabel([text, words].filter { !$0.isEmpty }.joined(separator: ". "))
        needsLayout = true
    }

    func fitting(width: CGFloat) -> NSSize {
        let titleHeight = ceil(
            title.attributedStringValue.boundingRect(
                with: NSSize(width: max(40, width), height: 200), options: [.usesLineFragmentOrigin]
            ).height)
        let bodyHeight = ceil(
            body.attributedStringValue.boundingRect(
                with: NSSize(width: max(40, width), height: 200), options: [.usesLineFragmentOrigin]
            ).height)
        return NSSize(width: width, height: titleHeight + 8 + bodyHeight + (button.isHidden ? 0 : 44))
    }

    override func layout() {
        super.layout()
        let titleHeight = ceil(
            title.attributedStringValue.boundingRect(
                with: NSSize(width: max(40, bounds.width), height: 200), options: [.usesLineFragmentOrigin]
            ).height)
        let bodyHeight = ceil(
            body.attributedStringValue.boundingRect(
                with: NSSize(width: max(40, bounds.width), height: 200), options: [.usesLineFragmentOrigin]
            ).height)
        title.frame = NSRect(x: 0, y: 0, width: bounds.width, height: titleHeight)
        body.frame = NSRect(x: 0, y: titleHeight + 8, width: bounds.width, height: bodyHeight)
        let size = button.fittingSize
        button.frame = NSRect(
            x: (bounds.width - size.width) / 2, y: titleHeight + 8 + bodyHeight + 14, width: size.width,
            height: 28)
    }

    @objc private func pressed() { onSetup?() }
}

/// The play control a finished clip rests behind: a disc of the scrim token, so it clears contrast
/// over a bright first frame as well as a dark one, with the system's own play glyph. It is only a
/// picture of the verb — a press anywhere on the clip plays it.
@MainActor
final class VideoPlayGlyph: NSView {
    static let side: CGFloat = 68

    private let glyph = NSImageView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.side / 2
        glyph.image = StudioTheme.symbol("play.fill", size: 22, weight: .semibold)
        glyph.imageScaling = .scaleProportionallyDown
        glyph.contentTintColor = MacTheme.Color.onGlass
        addSubview(glyph)
        setAccessibilityElement(false)
        restyle()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged), name: MacTheme.Chrome.didRepaint, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    @objc private func themeChanged() { restyle() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = StudioTheme.scrim.cgColor
            layer?.borderColor = MacTheme.Color.separator.cgColor
        }
        layer?.borderWidth = 1
        glyph.contentTintColor = MacTheme.Color.onGlass
    }

    override func layout() {
        super.layout()
        glyph.frame = NSRect(x: bounds.midX - 14 + 2, y: bounds.midY - 14, width: 28, height: 28)
    }
}
