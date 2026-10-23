import AppKit
import TailscodeCore

/// One move between the card and the stage, in either direction: Core's `NeuralTransition` and the
/// clock that runs it. Core owns every number (where the head is, how tall the row is, how far each
/// node has come in); the mover holds the transition, when it began, the frame it last read, and the
/// gaps between the frames it drew, which a check reads to prove the move did not stutter.
@MainActor
final class BrainMover {
    var transition: NeuralTransition
    private(set) var begun: Double
    private(set) var frame: NeuralTransitionFrame
    let metricsWidth: Double
    var clock: BrainClock?
    private(set) var gaps: [Double] = []
    private var last: Double?
    var onFinish: (() -> Void)?

    init(transition: NeuralTransition, now: Double, metricsWidth: Double) {
        self.transition = transition
        begun = now
        self.metricsWidth = metricsWidth
        frame = transition.frame(at: 0, clock: now)
    }

    var isOpening: Bool { transition.direction.isOpening }
    var rowHeight: Double { frame.rowHeight }
    var duration: TimeInterval { transition.duration }
    var maxGap: Double { gaps.max() ?? 0 }

    /// The progress of the move at `now`, `0...1`.
    func progress(at now: Double) -> Double {
        NeuralTransition.clamp((now - begun) / max(transition.duration, 0.001))
    }

    /// Reads the frame for `now` and notes how long it was since the last one.
    func step(at now: Double) -> Bool {
        if let last { gaps.append(now - last) }
        last = now
        let u = progress(at: now)
        frame = transition.frame(at: u, clock: now)
        return u >= 1
    }

    /// Turns the move round where it is: the new move starts exactly on this frame.
    func reverse(at now: Double) {
        let u = progress(at: now)
        transition = transition.reversed(from: u)
        begun = now
        last = nil
        frame = transition.frame(at: 0, clock: now)
    }

    /// Reads the frame at progress `u` and stops there.
    func hold(at u: Double) {
        frame = transition.frame(at: u, clock: 0)
    }

    func jumpToEnd(now: Double) {
        frame = transition.frame(at: 1, clock: now)
    }
}

extension BrainRowView {
    var motionHeight: CGFloat? {
        phase == .moving ? mover.map { CGFloat($0.rowHeight) } : nil
    }

    /// The row keeps the frame it will rest at for the whole of its move and shows itself through
    /// a mask that grows or shrinks with Core's height, so nothing above it or inside it changes
    /// size on any frame of the move: the page asks to be drawn again when a view's frame changes
    /// and a move that resized the row on each frame drew it all again on each of them.
    private func beginMotion() {
        let mask = CALayer()
        mask.backgroundColor = NSColor.black.cgColor
        moveMask = mask
        layer?.mask = mask
        invalidateIntrinsicContentSize()
        needsLayout = true
        syncMotion()
    }

    func syncMotion() {
        guard let mover, let mask = moveMask else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = CGRect(x: 0, y: 0, width: bounds.width, height: CGFloat(mover.rowHeight))
        CATransaction.commit()
        enclosingColumn?.rowMoved()
    }

    private func endMotion() {
        guard moveMask != nil else { return }
        layer?.mask = nil
        moveMask = nil
        invalidateIntrinsicContentSize()
        needsLayout = true
        enclosingColumn?.rowMoved()
    }

    private var enclosingColumn: TranscriptColumn? {
        var view = superview
        while let held = view {
            if let column = held as? TranscriptColumn { return column }
            view = held.superview
        }
        return nil
    }

    /// Begins the card becoming the stage, or the stage the card. The parts of the open brain are
    /// built already; the move only places them.
    func startMove(opening: Bool, swapped: Bool) {
        let m = currentMetrics
        let live = model.turn.outcome == .running
        let direction: NeuralTransition.Direction =
            opening ? (swapped ? .swap : .open) : (swapped ? .swapClose : .close)
        let transition = NeuralTransition.make(
            direction, metrics: m, nodeCount: model.nodeCount,
            reduceMotion: reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            level: MotionBudget.level, live: live)
        let now = BrainClock.now
        let made = BrainMover(transition: transition, now: now, metricsWidth: m.width)
        mover = made
        moveContent = moveCardContent(for: m)
        movesRun += 1
        maxFrameGap = 0
        setPhase(.moving)
        list?.configure(metrics: m)
        chips?.configure(metrics: m)
        if opening { footer?.sync(now: now) }
        leader.clear()
        stage?.alphaValue = 1
        let clock = BrainClock(view: self) { [weak self] time in self?.moveTick(time) }
        made.clock = clock
        clock.run()
        if !clock.isRunning {
            made.jumpToEnd(now: now)
            finishMove(snapOpen: opening)
            return
        }
        applyMoveFrame(m)
        markRestated()
        beginMotion()
    }

    func reverseMove() {
        guard let mover else { return }
        let now = BrainClock.now
        mover.reverse(at: now)
        applyMoveFrame(currentMetrics)
        syncMotion()
    }

    private func moveTick(_ time: Double) {
        guard let mover else { return }
        let done = mover.step(at: time)
        if mover.isOpening {
            movedFrames += 1
            if movedFrames == 1 { context?.revealAhead?(self, restingHeight) }
            buildDueParts(frame: movedFrames, progress: mover.progress(at: time))
            account?.continueRealize()
        }
        maxFrameGap = max(maxFrameGap, mover.maxGap)
        applyMoveFrame(currentMetrics)
        syncMotion()
        if done { finishMove(snapOpen: mover.isOpening) }
    }

    func finishMove(snapOpen opening: Bool) {
        guard let held = mover else { return }
        held.clock?.stop()
        maxFrameGap = max(maxFrameGap, held.maxGap)
        mover = nil
        moveContent = nil
        movedFrames = 0
        endMotion()
        if opening {
            completeParts()
            account?.finishRealize()
        }
        stage?.reveal = nil
        list?.setReveal(rows: nil, headerAlpha: 1)
        account?.setBodyAlpha(1)
        for view in [chips, footer] as [NSView?] { view?.alphaValue = 1 }
        stage?.alphaValue = 1
        picture.sweep(phase: 0, amount: 0, tone: .clear)
        if opening {
            card.presentation = .rest
            setPhase(.open)
            carrier.setTravel(.identity)
            relayout()
            leader.clear()
            updateLeader()
            refresh()
            applyPendingDive()
            let fromFind = store?.pendingFind[turnID] != nil
            applyPendingFind()
            if phase == .open, !fromFind, focusOnLanding { window?.makeFirstResponder(list ?? stage) }
            focusOnLanding = false
            context?.revealRow?(self)
        } else {
            hideStage()
        }
        invalidateIntrinsicContentSize()
        store?.moveLanded()
    }

    /// Puts every part where the move's frame says: the card's words and surface fading, the head
    /// travelling with its nodes inside it, the list, the account and the footer coming in.
    func applyMoveFrame(_ m: NeuralStageMetrics) {
        guard let mover else { return }
        let f = mover.frame
        let opening = mover.isOpening
        let stageRect = rect(m.stage)
        card.isHidden = false
        card.presentation = BrainCardView.Presentation(
            surfaceAlpha: f.cardSurfaceAlpha, textAlpha: f.cardTextAlpha,
            textOffsetX: f.cardTextOffsetX, edgeX: f.edge.x, edgeAlpha: f.edge.alpha)
        let traveller = rect(f.traveller)
        applyCarrier(rect: traveller, stage: stageRect)
        let travelScale = traveller.width / CGFloat(NeuralStageMetrics.designWidth)
        picture.setCornerRadius(CGFloat(8 * (1 - f.progress)), designScale: travelScale)
        picture.container.isHidden = false
        picture.container.opacity = Float(f.travellerAlpha)
        let content = moveContent ?? moveCardContent(for: m)
        if let content {
            let lift = opening ? 1 - f.zoneLift : f.cardLightsAlpha
            let ringLift = opening ? pow(max(0, 1 - f.zoneLift * 1.6), 3) : lift
            picture.show(
                card: content.card, inks: inks, hovered: false, lift: lift, ringLift: ringLift,
                liveZone: content.card.live?.activeZone,
                liveMotion: content.card.live?.motion ?? .still)
        }
        picture.sweep(
            phase: f.sweepPhase, amount: f.sweepAmount, tone: inks.page(.live, face: model.face))
        if let stage {
            stage.isHidden = false
            stage.frame = stageRect
            stage.alphaValue = CGFloat(stage.head.isReady ? max(f.zoneLift, 0.0) : 0)
            stage.reveal = BrainReveal(nodes: f.nodes, wireDraw: f.wireDraw, tieDraw: f.tieDraw)
        }
        chips?.alphaValue = CGFloat(f.panelAlpha)
        list?.alphaValue = 1
        list?.setReveal(rows: f.listRows, headerAlpha: f.listHeaderAlpha)
        let target = opening ? m.stageGeometry : m.stageGeometry
        placeBrowse(m, readout: target.readout.offsetBy(dx: f.readoutOffset.x, dy: f.readoutOffset.y))
        account?.alphaValue = CGFloat(f.readoutAlpha)
        footer?.frame = rect(target.footer)
        footer?.alphaValue = CGFloat(f.footerAlpha)
    }

    private func moveCardContent(for m: NeuralStageMetrics) -> BrainCardView.Content? {
        guard let entry = store?.entry(turnID) else { return nil }
        let model = entry.model
        return BrainCardView.Content(
            card: model.brainCard(now: Date()), showsRows: row.showsRows, isReplaying: false,
            canReplay: false, inks: inks, density: density, width: m.width,
            geometry: m.card, face: model.face, reduceMotion: reduceMotion)
    }
}

extension BrainRowView {
    /// Stands a move at one frame with no clock, for a harness that photographs the frames: the
    /// parts are built, the move is begun, and the frame at `u` is applied and held. A move begun
    /// from `reversedFrom` is that opening or closing turned round at that progress.
    func holdMove(direction: NeuralTransition.Direction, at u: Double, reversedFrom: Double? = nil) {
        let opening = direction.isOpening
        if mover == nil {
            if opening {
                guard phase == .closed else { return }
                makeParts()
            } else {
                guard phase == .open else { return }
            }
            let m = currentMetrics
            let live = model.turn.outcome == .running
            var transition = NeuralTransition.make(
                direction, metrics: m, nodeCount: model.nodeCount, reduceMotion: false, level: .calm,
                live: live)
            if let reversedFrom { transition = transition.reversed(from: reversedFrom) }
            mover = BrainMover(transition: transition, now: BrainClock.now, metricsWidth: m.width)
            moveContent = moveCardContent(for: m)
            setPhase(.moving)
            leader.clear()
        }
        guard let held = mover else { return }
        held.hold(at: u)
        applyMoveFrame(currentMetrics)
        if moveMask == nil { beginMotion() } else { syncMotion() }
        layoutSubtreeIfNeeded()
    }
}
