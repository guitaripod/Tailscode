import AppKit
import ImageIO
import TailscodeCore

/// The stage: the output owns the window. An opaque canvas with a sixteen-point corner, the picture
/// aspect-fit inside it with a margin all round and — by `bottomReserve` — clear of the dock that
/// floats over its foot, so the dock never hides the footer of a picture. The rectangle is decided
/// before a render starts, from the shape that was asked for, so the sketch fills it and the picture
/// lands in it and nothing moves when it arrives.
///
/// What it says is `StudioStageState`'s, decided once from the slot and the machine's own socket: an
/// invitation when empty, the start-from picture while drafting, one sentence on a glyph that
/// breathes while the machine works out what it was asked, the live sketch while it paints with a
/// two-point line along the sketch's own edge, the picture once it lands — crossfaded from the sketch
/// in one 240 ms ease-out, or instantly under reduced motion — and, when it failed, one sentence in
/// the failure tone, perfectly still, with the one thing that fixes it. Frames change a layer's
/// contents and never a layout.
@MainActor
final class StudioStageView: NSView, StudioStaging {
    var bottomReserve: CGFloat = StudioTheme.dockBase + StudioTheme.dockInset + 12 {
        didSet {
            guard bottomReserve != oldValue else { return }
            needsLayout = true
        }
    }

    var onVerb: ((StudioStageVerb) -> Void)?
    var onStarter: ((ImageGenBrief.Example) -> Void)?
    var onRemedy: ((StudioRemedy) -> Void)?
    var onDrop: ((StudioDrop) -> Void)?
    var onOpen: (() -> Void)?

    private let studio: MacImageStudio
    private let held = CALayer()
    private let sketchLayer = CALayer()
    private let dash = CAShapeLayer()
    private let track = CALayer()
    private let fill = CALayer()
    private let caption = StudioTheme.label(.panelFootnote, color: MacTheme.Color.secondaryLabel, alignment: .center)
    private let clockDot = ActivityBadgeView(pointSize: 11)
    private let sketchPill = StudioPill()
    private let invitation = StudioInvitationView()
    private let status = StudioStatusView()
    private let failure = StudioFailureCard()
    private let capsule = StudioVerbsCapsule()
    private let dropNote = StudioPill()

    private var state: StudioStageState = .empty
    private var lastState: StudioStageState = .empty
    private var heldID: String?
    private var heldBitmap: CGImage?
    private var referenceBitmaps: [String: CGImage] = [:]
    private var referenceLoads: Set<String> = []
    private var backdropID: String?
    private var backdropLoad: Task<Void, Never>?
    private var pictureRect: NSRect = .zero
    private var link: CADisplayLink?
    private var sketchDirty = false
    private var clock: Timer?
    private var dropping = false

    init(studio: MacImageStudio) {
        self.studio = studio
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = StudioTheme.stageRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        for picture in [held, sketchLayer] {
            picture.contentsGravity = .resizeAspect
            picture.masksToBounds = true
            picture.cornerRadius = StudioTheme.pictureRadius
            picture.cornerCurve = .continuous
            picture.magnificationFilter = .linear
            picture.minificationFilter = .trilinear
            layer?.addSublayer(picture)
        }
        sketchLayer.isHidden = true
        dash.fillColor = nil
        dash.lineWidth = 1
        dash.lineDashPattern = [6, 5]
        dash.isHidden = true
        layer?.addSublayer(dash)
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
        track.isHidden = true
        fill.isHidden = true

        addSubview(caption)
        addSubview(clockDot)
        addSubview(sketchPill)
        addSubview(invitation)
        addSubview(status)
        addSubview(failure)
        addSubview(capsule)
        addSubview(dropNote)
        sketchPill.isHidden = true
        invitation.isHidden = true
        status.isHidden = true
        failure.isHidden = true
        dropNote.isHidden = true
        clockDot.isHidden = true

        invitation.onPick = { [weak self] example in self?.onStarter?(example) }
        failure.onRemedy = { [weak self] remedy in self?.onRemedy?(remedy) }
        capsule.onVerb = { [weak self] verb in self?.onVerb?(verb) }
        dropNote.text = Localized.text("Edit this picture")

        registerForDraggedTypes(StudioDrop.registered)
        setAccessibilityRole(.group)
        restyle()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged), name: MacTheme.Chrome.didRepaint, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

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
            track.backgroundColor = MacTheme.Color.label.withAlphaComponent(0.18).cgColor
            fill.backgroundColor = MacTheme.Color.accent.cgColor
        }
        caption.font = MacTheme.Ramp.font(.panelFootnote)
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            link?.invalidate()
            link = nil
            stopClock()
        } else {
            refresh(.everything)
        }
    }

    func studioChanged(_ change: StudioLaneChange) {
        refresh(change)
    }

    func refresh(_ change: StudioLaneChange) {
        switch change {
        case .sketch:
            sketchDirty = true
            startLink()
            return
        case .progress:
            updateProgress()
            return
        case .tile(let id):
            guard id == studio.exhibit?.id || id == studio.newestKept?.id else { return }
        case .everything, .shelf:
            break
        }
        recompute()
    }

    private func recompute() {
        lastState = state
        let slot = studio.slot
        state = StudioStageState.read(
            slot: slot, progress: studio.progress, hasPicture: studio.exhibit != nil,
            hasWords: slot.reference != nil,
            remedy: .choose(sighting: studio.sighting, engine: slot.engine))
        let crossfading =
            lastState.isWorking && state == .done && sketchLayer.contents != nil
            && StudioTheme.motionAllowed
        pickHeld()
        if lastState.isWorking, state == .done, let exhibit = studio.exhibit {
            announce(studio.caption(of: exhibit).words)
        }
        applyState(crossfading: crossfading)
        needsLayout = true
        layoutSubtreeIfNeeded()
        if crossfading { fadeSketchIntoPicture() } else if !state.isWorking { dropSketchIfSettled() }
        syncClock()
    }

    /// A finished picture is said once, politely: a screen reader cannot see it land, and the words
    /// that made it are what it would have read from the caption.
    private func announce(_ words: String) {
        guard !words.isEmpty else { return }
        NSAccessibility.post(
            element: self, notification: .announcementRequested,
            userInfo: [
                .announcement: words, .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
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
        guard state.isWorking, let sketch = studio.sketch else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sketchLayer.contents = sketch
        sketchLayer.isHidden = false
        CATransaction.commit()
        if case .painting = state, status.isHidden == false {
            status.isHidden = true
            needsLayout = true
        }
        sketchPill.text = ImageGenPreviewWords.caption(studio.progress)
        sketchPill.isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func pickHeld() {
        let exhibit = studio.exhibit
        var bitmap: CGImage?
        var id: String?
        switch state {
        case .done:
            if let exhibit {
                bitmap = studio.stageBitmap(for: exhibit)
                id = exhibit.id
                if bitmap == nil { studio.loadBitmap(for: exhibit) }
            }
        case .drafting:
            if let path = studio.slot.reference?.path, let image = referenceBitmap(path) {
                bitmap = image
                id = "ref:" + path
            }
        case .waiting, .painting, .finishing, .failed, .stopped:
            if let exhibit, let image = studio.stageBitmap(for: exhibit) {
                bitmap = image
                id = exhibit.id
            } else if let path = studio.slot.reference?.path, let image = referenceBitmap(path) {
                bitmap = image
                id = "ref:" + path
            } else if !state.isWorking, let item = studio.newestKept {
                bitmap = heldBackdrop(item)
                id = "backdrop:" + item.id
            }
        case .empty:
            if let item = studio.newestKept {
                bitmap = heldBackdrop(item)
                id = "backdrop:" + item.id
            }
        }
        heldBitmap = bitmap
        heldID = id
    }

    private func heldBackdrop(_ item: ImageGenLibraryItem) -> CGImage? {
        backdrop(for: item)
        return backdropBitmap
    }

    private var backdropBitmap: CGImage?

    /// The machine's newest picture, from its small copy: it is held dimmed behind words, and a
    /// thumbnail stretched under an invitation is all the memory of a picture the empty stage needs.
    private func backdrop(for item: ImageGenLibraryItem) {
        guard backdropID != item.id else { return }
        backdropID = item.id
        backdropBitmap = nil
        backdropLoad?.cancel()
        let library = studio.library
        backdropLoad = Task { [weak self] in
            guard let image = await library.thumbnail(of: item),
                let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { return }
            guard let self, self.backdropID == item.id else { return }
            self.backdropBitmap = cg
            library.describe(item)
            self.recompute()
        }
    }

    private func referenceBitmap(_ path: String) -> CGImage? {
        guard !path.isEmpty else { return nil }
        if let held = referenceBitmaps[path] { return held }
        guard referenceLoads.insert(path).inserted else { return nil }
        Task { [weak self] in
            let image = await Task.detached {
                FileManager.default.contents(atPath: path).flatMap { MacImageStudio.stageBitmap($0) }
            }.value
            guard let self else { return }
            self.referenceLoads.remove(path)
            guard let image else { return }
            self.referenceBitmaps[path] = image
            if self.referenceBitmaps.count > 4, let drop = self.referenceBitmaps.keys.first(where: { $0 != path }) {
                self.referenceBitmaps[drop] = nil
            }
            self.recompute()
        }
        return nil
    }

    private func applyState(crossfading: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let dim: Float
        switch state {
        case .empty: dim = StudioTheme.dimmed
        case .failed, .stopped: dim = 0.32
        case .waiting: dim = 0.4
        case .painting: dim = 0.4
        case .finishing, .drafting, .done: dim = 1
        }
        held.contentsGravity = heldID?.hasPrefix("backdrop:") == true ? .resizeAspectFill : .resizeAspect
        if !crossfading {
            held.contents = heldBitmap
            held.opacity = heldBitmap == nil ? 0 : dim
        } else {
            held.contents = heldBitmap
        }
        let working = state.isWorking
        if !working, !crossfading {
            sketchLayer.isHidden = true
            sketchLayer.contents = nil
            sketchPill.isHidden = true
        }
        if working, let sketch = studio.sketch, sketchLayer.contents == nil {
            sketchLayer.contents = sketch
            sketchLayer.isHidden = false
        }
        if case .finishing = state, sketchLayer.contents != nil { sketchLayer.opacity = 0.6 } else { sketchLayer.opacity = 1 }
        dash.isHidden = !(state == .empty || (state == .drafting && heldBitmap == nil))
        invitation.isHidden = state != .empty
        if !invitation.isHidden { invitation.show(StudioInvitationView.examples) }

        switch state {
        case .waiting(let line):
            status.show(line: line, working: true)
            status.isHidden = false
        case .painting:
            let hasSketch = studio.sketch != nil
            status.show(line: studio.slot.waitingLine(since: nil, progress: studio.progress), working: true)
            status.isHidden = hasSketch
            if hasSketch {
                sketchPill.text = ImageGenPreviewWords.caption(studio.progress)
                sketchPill.isHidden = false
            }
        case .finishing(let line):
            status.show(line: line, working: false)
            status.isHidden = false
        default:
            status.isHidden = true
        }
        if case .failed(let reason, let remedy) = state {
            failure.show(reason: reason, remedy: remedy)
            failure.isHidden = false
        } else {
            failure.isHidden = true
        }
        updateProgress()
        updateCaption()
        updateCapsule()
        setAccessibilityLabel(spokenState)
    }

    private var spokenState: String {
        switch state {
        case .empty: return ImageGenWords.emptyTitle
        case .drafting: return studio.slot.hint
        case .waiting(let line), .finishing(let line): return line
        case .painting: return studio.slot.waitingLine(since: nil, progress: studio.progress)
        case .done:
            return studio.exhibit.map { studio.caption(of: $0).words } ?? ""
        case .failed(let reason, _): return reason
        case .stopped: return ImageGenWords.stoppedNotice
        }
    }

    private func updateProgress() {
        guard state.isWorking else {
            track.isHidden = true
            fill.isHidden = true
            return
        }
        if let fraction = studio.progress?.bar {
            track.isHidden = false
            fill.isHidden = false
            layoutProgress(fraction)
        } else {
            track.isHidden = true
            fill.isHidden = true
        }
        if case .painting = state, studio.sketch == nil {
            status.show(line: studio.slot.waitingLine(since: nil, progress: studio.progress), working: true)
        }
        if state.isWorking {
            sketchPill.text = ImageGenPreviewWords.caption(studio.progress)
        }
        updateCaption()
    }

    private func updateCaption() {
        clockDot.activity = nil
        clockDot.isHidden = true
        switch state {
        case .empty:
            if let item = studio.newestKept {
                caption.stringValue = heldNote(for: item)
            } else {
                caption.stringValue = ImageGenWords.emptyBody
            }
        case .drafting:
            caption.stringValue = studio.slot.reference.map {
                ImageGenWords.referenceHint($0)
            } ?? studio.slot.hint
        case .waiting, .painting, .finishing:
            let ahead: Int? = {
                if case .queued(let ahead)? = studio.progress?.stage { return ahead }
                return nil
            }()
            if case .painting = state {
                caption.stringValue = studio.slot.waitingLine(
                    since: studio.startedAt, progress: studio.progress)
                clockDot.activity = .working
                clockDot.isHidden = false
            } else {
                caption.stringValue = ImageGenStudioWords.clockLine(
                    since: studio.startedAt, ahead: ahead)
            }
        case .done:
            if let exhibit = studio.exhibit {
                let parts = studio.caption(of: exhibit)
                caption.stringValue = [parts.words, parts.facts].filter { !$0.isEmpty }
                    .joined(separator: "  ·  ")
            } else {
                caption.stringValue = ""
            }
        case .failed:
            if studio.exhibit == nil, let item = studio.newestKept {
                caption.stringValue = heldNote(for: item)
            } else {
                caption.stringValue = ""
            }
        case .stopped:
            caption.stringValue = ImageGenWords.stoppedNotice
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func heldNote(for item: ImageGenLibraryItem) -> String {
        let facts = studio.library.facts(of: item)
        var parts = [Localized.text("Held from %@'s shelf, dimmed", studio.endpoint.shortName)]
        if let words = facts?.recipe?.prompt, !words.isEmpty { parts.append(words.ellipsized(to: 48)) }
        if let date = facts?.modifiedAt { parts.append(ImageGenLibraryWords.ago(date)) }
        return parts.joined(separator: "  ·  ")
    }

    private func updateCapsule() {
        let kept = studio.exhibit?.isKept ?? false
        let words = studio.exhibit.map { studio.hasWords($0) } ?? false
        let verbs = StudioVerbs.faces(state: state, kept: kept, hasWords: words)
        let reserved = state.isWorking
        capsule.show(verbs, holdsRoom: reserved || verbs.isEmpty == false)
        capsule.alphaValue = verbs.isEmpty ? 0 : 1
        capsule.isHidden = verbs.isEmpty && !reserved
        capsule.setAccessibilityElement(!verbs.isEmpty)
        capsule.primaryID = ImageGenAction.reference.rawValue
    }

    private func syncClock() {
        guard state.isWorking, window != nil else { return stopClock() }
        guard clock == nil else { return }
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCaption() }
        }
        clock?.tolerance = 0.2
    }

    private func stopClock() {
        clock?.invalidate()
        clock = nil
    }

    /// The finished picture arrives under the sketch and the sketch lets go of it: one ease-out of
    /// 240 ms on the sketch's opacity, once, after which the studio drops the sketch it no longer
    /// needs. The sketch holds the rectangle while it does, so nothing moves.
    private func fadeSketchIntoPicture() {
        held.opacity = 1
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
                self.studio.settleSketch()
            }
        }
        sketchLayer.opacity = 0
        CATransaction.commit()
        sketchPill.isHidden = true
    }

    private func dropSketchIfSettled() {
        if !state.isWorking { studio.settleSketch() }
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
        pictureRect = Self.fit(aspect: frameAspect, in: area)
        for picture in [held, sketchLayer] { picture.frame = pictureRect }
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
        let note = dropNote.fittingSize
        dropNote.frame = NSRect(
            x: pictureRect.midX - note.width / 2, y: pictureRect.minY + 16, width: note.width,
            height: note.height)

        let inviteWidth = min(max(pictureRect.width - 40, 0), 720)
        let invite = invitation.fitting(width: inviteWidth)
        invitation.frame = NSRect(
            x: pictureRect.midX - invite.width / 2,
            y: pictureRect.midY - invite.height / 2 - 6, width: invite.width, height: invite.height)
        invitation.needsLayout = true

        let statusSize = status.fitting(width: min(pictureRect.width - 32, 520))
        status.frame = NSRect(
            x: pictureRect.midX - statusSize.width / 2, y: pictureRect.midY - statusSize.height / 2,
            width: statusSize.width, height: statusSize.height)
        let failureSize = failure.fitting(width: min(max(pictureRect.width - 48, 0), 520))
        failure.frame = NSRect(
            x: pictureRect.midX - failureSize.width / 2,
            y: pictureRect.midY - failureSize.height / 2, width: failureSize.width,
            height: failureSize.height)

        let capsuleSize = capsule.fitting(maxWidth: max(0, bounds.width - 2 * StudioTheme.stageMargin))
        capsule.frame = NSRect(
            x: pictureRect.midX - capsuleSize.width / 2,
            y: pictureRect.maxY - StudioTheme.capsuleLift - capsuleSize.height,
            width: capsuleSize.width, height: capsuleSize.height)
        layoutProgress(studio.progress?.bar ?? 0)
    }

    private func layoutProgress(_ fraction: Double) {
        let y = pictureRect.maxY - StudioTheme.progressThickness
        track.frame = CGRect(x: pictureRect.minX, y: y, width: pictureRect.width, height: StudioTheme.progressThickness)
        fill.frame = CGRect(
            x: pictureRect.minX, y: y, width: pictureRect.width * CGFloat(max(0, min(1, fraction))),
            height: StudioTheme.progressThickness)
    }

    /// The shape the picture rectangle is. Decided before a render starts, from what was asked for:
    /// an edit takes the shape of the picture it starts from, words take the aspect chosen, and a
    /// finished picture is its own — so the rectangle the sketch filled is the one the picture lands
    /// in.
    private var frameAspect: Double {
        let slot = studio.slot
        if state == .done, let heldBitmap, heldBitmap.height > 0 {
            return Double(heldBitmap.width) / Double(heldBitmap.height)
        }
        if let reference = slot.reference, let aspect = StudioDrops.aspect(of: reference) {
            return aspect
        }
        if state == .done || state == .stopped, let heldBitmap, heldBitmap.height > 0 {
            return Double(heldBitmap.width) / Double(heldBitmap.height)
        }
        let ratio = slot.aspect.ratio
        return Double(ratio.width) / Double(ratio.height)
    }

    static func fit(aspect: Double, in area: NSRect) -> NSRect {
        guard area.width > 0, area.height > 0, aspect > 0 else { return area }
        var width = area.width
        var height = width / aspect
        if height > area.height {
            height = area.height
            width = height * aspect
        }
        return NSRect(
            x: area.minX + (area.width - width) / 2, y: area.minY + (area.height - height) / 2,
            width: width.rounded(), height: height.rounded())
    }

    var currentPictureRect: NSRect { pictureRect }

    var showsPicture: Bool { state == .done }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2, state == .done, pictureRect.contains(convert(event.locationInWindow, from: nil)) {
            onOpen?()
        }
    }

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
        dash.isHidden = !on && !(state == .empty || (state == .drafting && heldBitmap == nil))
        if on {
            dash.strokeColor = MacTheme.Color.accent.cgColor
        } else {
            dash.strokeColor = MacTheme.Color.tertiaryLabel.cgColor
        }
        needsLayout = true
    }

    @objc func copy(_ sender: Any?) {
        guard state == .done else { return }
        onVerb?(StudioStageVerb(.copy))
    }

    override func drawFocusRingMask() {
        NSBezierPath(
            roundedRect: bounds, xRadius: StudioTheme.stageRadius, yRadius: StudioTheme.stageRadius
        ).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func accessibilityPerformPress() -> Bool {
        guard state == .done else { return false }
        onOpen?()
        return true
    }
}

extension StudioStageView: NSMenuItemValidation {
    /// Edit ▸ Copy reaches the stage through the responder chain when the stage has focus, and is
    /// available exactly when a finished picture is on it.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) { return showsPicture }
        return true
    }
}

/// A small label on a dark pill, over picture content: the sketch's caption and the drop target's
/// sentence. The fill is the scrim token, so the ink clears contrast over a bright sketch as well as
/// a dark one.
@MainActor
final class StudioPill: NSView {
    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            label.stringValue = text
            invalidateIntrinsicContentSize()
            superview?.needsLayout = true
        }
    }

    private let label = StudioTheme.label(.panelFootnote, color: MacTheme.Color.label)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        addSubview(label)
        setAccessibilityElement(false)
        restyle()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged), name: MacTheme.Chrome.didRepaint, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    @objc private func themeChanged() { restyle() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = StudioTheme.scrim.cgColor
        }
        label.font = MacTheme.Ramp.font(.panelFootnote)
    }

    override var fittingSize: NSSize {
        NSSize(
            width: ceil(label.intrinsicContentSize.width) + 28,
            height: StudioTheme.height(of: .panelFootnote) + 10)
    }

    override var intrinsicContentSize: NSSize { fittingSize }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        label.frame = NSRect(x: 10, y: 5, width: max(0, bounds.width - 20), height: bounds.height - 10)
    }
}

/// The sentence that stands for a machine working out what it was asked: a glyph that breathes on the
/// shared swell while the wait is on, and the words Core wrote for it. It holds no state of its own —
/// the stage hands it a line, and it is perfectly still the moment `working` is false.
@MainActor
final class StudioStatusView: NSView {
    private let badge = ActivityBadgeView(pointSize: 26)
    private let line = StudioTheme.label(.cardTitle, color: MacTheme.Color.label, lines: 3, alignment: .center)

    init() {
        super.init(frame: .zero)
        addSubview(badge)
        addSubview(line)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func show(line words: String, working: Bool) {
        if line.stringValue != words {
            line.stringValue = words
            line.font = MacTheme.Ramp.font(.cardTitle)
            needsLayout = true
        }
        badge.activity = working ? .working : nil
        badge.isHidden = !working
    }

    func fitting(width: CGFloat) -> NSSize {
        let text = line.attributedStringValue.boundingRect(
            with: NSSize(width: max(40, width), height: 400),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let badgeHeight: CGFloat = badge.isHidden ? 0 : 36
        return NSSize(width: ceil(min(width, text.width + 8)), height: ceil(text.height) + badgeHeight + 4)
    }

    override func layout() {
        super.layout()
        let badgeHeight: CGFloat = badge.isHidden ? 0 : 36
        badge.frame = NSRect(x: (bounds.width - 36) / 2, y: 0, width: 36, height: badgeHeight)
        line.frame = NSRect(x: 0, y: badgeHeight + 2, width: bounds.width, height: bounds.height - badgeHeight - 2)
    }
}

/// One honest sentence in the failure tone, and the one thing that fixes it. It is the only thing on
/// the stage that is about a failure, and it holds perfectly still: nothing here is animated into
/// looking busy.
@MainActor
final class StudioFailureCard: StudioRaisedView {
    var onRemedy: ((StudioRemedy) -> Void)?
    private let icon = NSImageView()
    private let sentence = StudioTheme.label(.cardBody, color: MacTheme.Color.label, lines: 6)
    private let button = NSButton(title: "", target: nil, action: nil)
    private var remedy: StudioRemedy = .retry

    init() {
        super.init(radius: StudioTheme.stageRadius)
        icon.image = StudioTheme.symbol("exclamationmark.triangle.fill", size: 18, weight: .semibold)
        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)
        addSubview(sentence)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.target = self
        button.action = #selector(pressed)
        button.keyEquivalent = ""
        button.bezelColor = MacTheme.Color.accent
        addSubview(button)
        restyle()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged), name: MacTheme.Chrome.didRepaint, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    @objc private func themeChanged() { restyle() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        icon.contentTintColor = MacTheme.Color.danger
        sentence.font = MacTheme.Ramp.font(.cardBody)
    }

    func show(reason: String, remedy: StudioRemedy) {
        self.remedy = remedy
        sentence.stringValue = reason
        button.title = remedy.title
        button.setAccessibilityLabel(remedy.title)
        setAccessibilityRole(.group)
        setAccessibilityLabel(reason)
        needsLayout = true
    }

    private static let pad: CGFloat = 20
    private static let iconSide: CGFloat = 26

    func fitting(width: CGFloat) -> NSSize {
        let textWidth = max(120, width - 2 * Self.pad - Self.iconSide - 12)
        let text = sentence.attributedStringValue.boundingRect(
            with: NSSize(width: textWidth, height: 600), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let buttonHeight: CGFloat = 28
        let height = 2 * Self.pad + ceil(text.height) + 14 + buttonHeight
        let usedWidth = min(width, ceil(text.width) + 2 * Self.pad + Self.iconSide + 12 + 4)
        return NSSize(width: max(usedWidth, min(width, 280)), height: height)
    }

    override func layout() {
        super.layout()
        let textWidth = bounds.width - 2 * Self.pad - Self.iconSide - 12
        let text = sentence.attributedStringValue.boundingRect(
            with: NSSize(width: textWidth, height: 600), options: [.usesLineFragmentOrigin, .usesFontLeading])
        icon.frame = NSRect(x: Self.pad, y: Self.pad - 2, width: Self.iconSide, height: Self.iconSide)
        sentence.frame = NSRect(
            x: Self.pad + Self.iconSide + 12, y: Self.pad, width: textWidth, height: ceil(text.height))
        let size = button.fittingSize
        button.frame = NSRect(
            x: Self.pad + Self.iconSide + 12, y: Self.pad + ceil(text.height) + 14, width: size.width,
            height: 28)
    }

    @objc private func pressed() { onRemedy?(remedy) }
}

/// The empty stage's invitation: one sentence about what the box is for and four worked examples,
/// each a brief that was actually rendered and came back right. A starter is the first half of a
/// sentence — it lands in the words box and the person finishes it; nothing is sent by touching one.
@MainActor
final class StudioInvitationView: NSView {
    static var examples: [ImageGenBrief.Example] { ImageGenBrief.examples }

    var onPick: ((ImageGenBrief.Example) -> Void)?
    private let title = StudioTheme.label(.headline, color: MacTheme.Color.label, lines: 2, alignment: .center)
    private let subtitle = StudioTheme.label(.panelFootnote, color: MacTheme.Color.secondaryLabel, alignment: .center)
    private var cards: [StudioStarterCard] = []

    init() {
        super.init(frame: .zero)
        title.stringValue = Localized.text("Describe a picture, or drop one here to edit")
        subtitle.stringValue = Localized.text("Or start from one of these")
        addSubview(title)
        addSubview(subtitle)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title.stringValue)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func show(_ examples: [ImageGenBrief.Example]) {
        guard cards.count != examples.count else { return }
        for card in cards { card.removeFromSuperview() }
        cards = examples.map { example in
            let card = StudioStarterCard(example: example)
            card.onPress = { [weak self] in self?.onPick?(example) }
            addSubview(card)
            return card
        }
        needsLayout = true
    }

    private static let cardHeight: CGFloat = 60
    private static let gap: CGFloat = 12

    func fitting(width: CGFloat) -> NSSize {
        let columns = width >= 520 ? 2 : 1
        let rows = Int((Double(max(cards.count, 1)) / Double(columns)).rounded(.up))
        let titleHeight = StudioTheme.height(of: .headline) * 2
        let height =
            titleHeight + 6 + StudioTheme.height(of: .panelFootnote) + 22
            + CGFloat(rows) * Self.cardHeight + CGFloat(max(rows - 1, 0)) * Self.gap
        return NSSize(width: width, height: height)
    }

    override func layout() {
        super.layout()
        let titleHeight = StudioTheme.height(of: .headline) * 2
        let wrapped = title.attributedStringValue.boundingRect(
            with: NSSize(width: bounds.width, height: titleHeight), options: [.usesLineFragmentOrigin])
        let used = min(titleHeight, ceil(wrapped.height))
        title.frame = NSRect(x: 0, y: titleHeight - used, width: bounds.width, height: used)
        let subtitleY = titleHeight + 6
        subtitle.frame = NSRect(x: 0, y: subtitleY, width: bounds.width, height: StudioTheme.height(of: .panelFootnote))
        let columns = bounds.width >= 520 ? 2 : 1
        let cardWidth = (bounds.width - CGFloat(columns - 1) * Self.gap) / CGFloat(columns)
        let top = subtitleY + StudioTheme.height(of: .panelFootnote) + 22
        for (index, card) in cards.enumerated() {
            let column = index % columns
            let row = index / columns
            card.frame = NSRect(
                x: CGFloat(column) * (cardWidth + Self.gap),
                y: top + CGFloat(row) * (Self.cardHeight + Self.gap), width: cardWidth,
                height: Self.cardHeight)
        }
    }
}

/// One worked example, as a raised card that answers the pointer before it is pressed.
@MainActor
final class StudioStarterCard: NSView {
    var onPress: (() -> Void)?
    private let plate = PointerPlate()
    private let glyph = NSImageView()
    private let title = StudioTheme.label(.rowTitleStrong, color: MacTheme.Color.label)
    private let detail = StudioTheme.label(.panelFootnote, color: MacTheme.Color.secondaryLabel)
    private var tracking: NSTrackingArea?
    private var pressing = false

    init(example: ImageGenBrief.Example) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        plate.radius = 12
        addSubview(plate)
        glyph.image = StudioTheme.symbol(Self.symbol(for: example.id), size: 15, weight: .medium)
        glyph.imageScaling = .scaleProportionallyDown
        glyph.contentTintColor = MacTheme.Color.secondaryLabel
        addSubview(glyph)
        title.stringValue = example.title
        detail.stringValue = example.detail
        addSubview(title)
        addSubview(detail)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(example.title). \(example.detail)")
        toolTip = example.detail
        restyle()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged), name: MacTheme.Chrome.didRepaint, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func themeChanged() { restyle() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = MacTheme.Color.canvasRaised.cgColor
            layer?.borderColor = MacTheme.Color.separator.cgColor
        }
        layer?.borderWidth = 1
        title.font = MacTheme.Ramp.font(.rowTitleStrong)
        detail.font = MacTheme.Ramp.font(.panelFootnote)
        glyph.contentTintColor = MacTheme.Color.secondaryLabel
    }

    private static func symbol(for id: String) -> String {
        switch id {
        case "menu": return "textformat"
        case "portrait": return "scope"
        case "diagram": return "square.grid.3x3"
        case "cutout": return "scissors"
        default: return "photo"
        }
    }

    override func layout() {
        super.layout()
        plate.frame = bounds
        glyph.frame = NSRect(x: 14, y: (bounds.height - 28) / 2, width: 28, height: 28)
        let x: CGFloat = 54
        let width = bounds.width - x - 12
        let titleHeight = StudioTheme.height(of: .rowTitleStrong)
        let detailHeight = StudioTheme.height(of: .panelFootnote)
        let top = (bounds.height - titleHeight - detailHeight - 2) / 2
        title.frame = NSRect(x: x, y: top, width: width, height: titleHeight)
        detail.frame = NSRect(x: x, y: top + titleHeight + 2, width: width, height: detailHeight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { plate.show(.hover) }

    override func mouseExited(with event: NSEvent) {
        pressing = false
        plate.show(.rest)
    }

    override func mouseDown(with event: NSEvent) {
        pressing = true
        plate.show(.press)
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        plate.show(inside ? .hover : .rest)
        if pressing, inside { onPress?() }
        pressing = false
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

/// The verbs a finished picture offers, in a capsule of glass floating over its foot. Regular glass
/// plus the scrim token, because this is the one piece that sits on picture content and must be read
/// at a glance whatever the picture is. It holds its room invisibly while a render is out, so the
/// stage never changes shape, and it drops its words for icons when the stage is too narrow to hold
/// them — every button keeps its label for a screen reader and its words for a tooltip.
@MainActor
final class StudioVerbsCapsule: NSView {
    var onVerb: ((StudioStageVerb) -> Void)?
    var primaryID = ""
    private var verbs: [StudioStageVerb] = []
    private var buttons: [StudioVerbButton] = []
    private let glass = NSGlassEffectView()
    private let scrim = NSView()
    private let row = NSView()
    private var iconsOnly = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        glass.cornerRadius = StudioTheme.capsuleHeight / 2
        scrim.wantsLayer = true
        scrim.layer?.cornerRadius = StudioTheme.capsuleHeight / 2
        scrim.layer?.cornerCurve = .continuous
        glass.contentView = scrim
        scrim.addSubview(row)
        addSubview(glass)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel(Localized.text("Picture actions"))
        restyle()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged), name: MacTheme.Chrome.didRepaint, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    @objc private func themeChanged() { restyle() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            scrim.layer?.backgroundColor = StudioTheme.scrim.cgColor
        }
    }

    func show(_ next: [StudioStageVerb], holdsRoom: Bool) {
        guard next != verbs || !holdsRoom else { return }
        guard !next.isEmpty else { return }
        verbs = next
        for button in buttons { button.removeFromSuperview() }
        buttons = next.map { verb in
            let button = StudioVerbButton(verb: verb)
            button.onPress = { [weak self] in self?.onVerb?(verb) }
            row.addSubview(button)
            return button
        }
        needsLayout = true
        superview?.needsLayout = true
    }

    func fitting(maxWidth: CGFloat) -> NSSize {
        guard !buttons.isEmpty else { return NSSize(width: 0, height: StudioTheme.capsuleHeight) }
        let full = buttons.reduce(CGFloat(16)) { $0 + $1.width(iconsOnly: false) + 2 }
        iconsOnly = full > maxWidth
        let width = iconsOnly ? buttons.reduce(CGFloat(16)) { $0 + $1.width(iconsOnly: true) + 2 } : full
        return NSSize(width: min(maxWidth, width), height: StudioTheme.capsuleHeight)
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        row.frame = scrim.bounds
        var x: CGFloat = 8
        for button in buttons {
            let width = button.width(iconsOnly: iconsOnly)
            button.iconsOnly = iconsOnly
            button.isPrimary = button.verb.id == primaryID
            button.frame = NSRect(x: x, y: 3, width: width, height: bounds.height - 6)
            x += width + 2
        }
    }
}

/// One verb in the capsule: its symbol and its word, ink on the glass, the primary one on the accent.
@MainActor
final class StudioVerbButton: NSView {
    let verb: StudioStageVerb
    var onPress: (() -> Void)?
    var iconsOnly = false {
        didSet { if iconsOnly != oldValue { needsDisplay = true } }
    }
    var isPrimary = false {
        didSet { if isPrimary != oldValue { needsDisplay = true } }
    }
    private let plate = PointerPlate()
    private var tracking: NSTrackingArea?
    private var pressing = false

    init(verb: StudioStageVerb) {
        self.verb = verb
        super.init(frame: .zero)
        plate.radius = 14
        addSubview(plate)
        toolTip = verb.hint
        setAccessibilityRole(.button)
        setAccessibilityLabel(verb.title)
        setAccessibilityHelp(verb.hint)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var title: String { verb.title.replacingOccurrences(of: "…", with: "") }

    func width(iconsOnly: Bool) -> CGFloat {
        iconsOnly ? 32 : 14 + 16 + 6 + StudioTheme.width(of: title, role: .control) + 14
    }

    override func layout() {
        super.layout()
        plate.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        if isPrimary {
            MacTheme.Color.accent.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        }
        let ink = isPrimary ? MacTheme.Color.onAccent : (verb.isDestructive ? MacTheme.Color.danger : MacTheme.Color.onGlass)
        if let symbol = StudioTheme.symbol(verb.symbol, size: 12, weight: .medium)?.tinted(ink) {
            let side: CGFloat = 16
            let originX = iconsOnly ? (bounds.width - side) / 2 : 14
            symbol.draw(in: NSRect(x: originX, y: (bounds.height - side) / 2, width: side, height: side))
        }
        guard !iconsOnly else { return }
        let attributes = MacTheme.Ramp.attributes(.control, color: ink)
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(
            at: NSPoint(x: 14 + 16 + 6, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { if !isPrimary { plate.show(.hover) } }

    override func mouseExited(with event: NSEvent) {
        pressing = false
        plate.show(.rest)
    }

    override func mouseDown(with event: NSEvent) {
        pressing = true
        if !isPrimary { plate.show(.press) }
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        plate.show(.rest)
        if pressing, inside { onPress?() }
        pressing = false
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

extension NSImage {
    /// The symbol drawn in one ink, for a view that draws itself — a template image takes the
    /// colour of whatever fills it.
    fileprivate func tinted(_ color: NSColor) -> NSImage {
        let result = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        result.isTemplate = false
        return result
    }
}

enum StudioDrops {
    /// The aspect of what an edit starts from, when it can be read from the file's own header.
    static func aspect(of reference: ImageGenReference) -> Double? {
        StudioDrop.aspect(ofFileAt: reference.path)
    }
}
