import TailscodeCore
import UIKit

extension BrainOpenView {
    /// What the move changes of the open parts, from the numbers of a frame. Core owns every
    /// curve; this only sets what it is handed.
    func apply(frame: NeuralTransitionFrame, from card: NeuralStageMetrics, opening: Bool, live: Bool) {
        isMoving = true
        let stageRect = rect(metrics.stage)
        let traveller = CGRect(
            x: frame.traveller.x, y: frame.traveller.y, width: frame.traveller.width,
            height: frame.traveller.height)
        let scale = stageRect.width > 0 ? traveller.width / stageRect.width : 1
        stage.alpha = CGFloat(frame.travellerAlpha)
        placeStandIn(traveller, alpha: CGFloat(frame.travellerAlpha) * (1 - stageArrival()))
        wordmark.alpha = CGFloat(NeuralTransition.smoothstep(0.7, 1, frame.progress))
        stageBand.alpha = CGFloat(frame.stageBandAlpha)
        morphBand(progress: CGFloat(frame.progress))
        stage.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        stage.transform = CGAffineTransform(
            translationX: traveller.midX - stageRect.midX, y: traveller.midY - stageRect.midY
        ).scaledBy(x: scale, y: scale)
        stageLights.opacity = Float(opening ? max(0, 1 - frame.zoneLift) : 0)
        let sweep = frame.sweepAmount
        sweepLayer.opacity = Float(min(1, sweep / NeuralTransition.sweepStrength) * 0.55)
        let travel = stage.bounds.width * 1.4
        placeSweep(
            CGRect(
                x: -stage.bounds.width * 0.4 + travel * CGFloat(frame.sweepPhase), y: 0,
                width: stage.bounds.width * 0.4, height: stage.bounds.height))
        stage.field.setReveal(model: browseModel, frame: frame)
        chips.alpha = CGFloat(frame.panelAlpha)
        madeList?.header.alpha = CGFloat(frame.listHeaderAlpha)
        accordionHeader.alpha = CGFloat(frame.listHeaderAlpha)
        madeList?.setReveal(frame.listRows)
        compactList.setReveal(frame.listRows)
        let offset = CGPoint(x: frame.readoutOffset.x, y: frame.readoutOffset.y)
        madeAccount?.alpha = CGFloat(frame.readoutAlpha)
        madeAccount?.transform = CGAffineTransform(translationX: offset.x, y: offset.y)
        hairline.opacity = Float(frame.readoutAlpha)
        footer.alpha = CGFloat(frame.footerAlpha)
        for part in [leaderLine, leaderDot, leaderTab] as [CALayer] { part.isHidden = true }
    }

    func finishMove() {
        isMoving = false
        stage.alpha = 1
        wordmark.alpha = 1
        if stageArrivedAt == nil, !standIn.isHidden {
            placeStandIn(rect(metrics.stage), alpha: 1)
        } else {
            releaseStandIn()
        }
        if stageBand.alpha < 1 {
            UIView.animate(withDuration: 0.15) { self.stageBand.alpha = 1 }
        }
        stage.transform = .identity
        stageLights.opacity = 0
        sweepLayer.opacity = 0
        stage.field.clearReveal()
        chips.alpha = 1
        madeList?.header.alpha = 1
        accordionHeader.alpha = 1
        madeList?.setReveal(nil)
        compactList.setReveal(nil)
        madeAccount?.alpha = 1
        madeAccount?.transform = .identity
        hairline.opacity = 1
        footer.alpha = 1
        setNeedsLayout()
        updateLeader(animated: true)
    }

    /// The backdrop as the card's shape grown toward its own: the card's rectangle and corners at
    /// the start, the stage's band at the end, on the head's own progress.
    private func morphBand(progress: CGFloat) {
        let to = restingBand
        guard bandOrigin.width > 0 else {
            stageBand.frame = to
            return
        }
        let t = min(max(progress, 0), 1)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        stageBand.frame = CGRect(
            x: mix(bandOrigin.minX, to.minX), y: mix(bandOrigin.minY, to.minY),
            width: mix(bandOrigin.width, to.width), height: mix(bandOrigin.height, to.height))
        stageBand.layer.cornerCurve = .continuous
        stageBand.layer.cornerRadius = Self.cardCorner * (1 - t)
    }

    /// The card's corner, which the backdrop starts from and returns to.
    static let cardCorner: CGFloat = 12

    /// How far the stage's own picture has taken over from the stand-in: none until it has a frame,
    /// then all of it over 90 ms, so the head never goes blank and never jumps.
    private func stageArrival() -> CGFloat {
        guard !standIn.isHidden else { return 1 }
        guard let arrivedAt = stageArrivedAt else { return 0 }
        return CGFloat(min(1, (CACurrentMediaTime() - arrivedAt) / Self.standInHandover))
    }

    static let standInHandover: CFTimeInterval = 0.09

    /// Lets the stand-in travel: the card's picture now, and the sharp one made for the stage's
    /// width when the press already asked for it.
    func holdStandIn(_ contents: Any?) {
        guard let contents else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        standIn.contents = contents
        standIn.isHidden = false
        CATransaction.commit()
        stageArrivedAt = nil
    }

    /// The stage's picture has its first frame. Mid-move the stand-in hands over on the move's
    /// own frames; after it the stand-in that held the place fades on its own.
    func stageArrived() {
        guard !standIn.isHidden, stageArrivedAt == nil else { return }
        stageArrivedAt = CACurrentMediaTime()
        guard !isMoving else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.standInHandover)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.releaseStandIn() }
        }
        standIn.opacity = 0
        CATransaction.commit()
    }

    private func placeStandIn(_ rect: CGRect, alpha: CGFloat) {
        guard !standIn.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        standIn.frame = rect
        standIn.opacity = Float(alpha)
        CATransaction.commit()
    }

    func releaseStandIn() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        standIn.isHidden = true
        standIn.contents = nil
        standIn.opacity = 1
        CATransaction.commit()
        stageArrivedAt = nil
    }

    /// Puts the sweep band where it is now, without the layer animating there.
    func placeSweep(_ rect: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sweepLayer.frame = rect
        sweepMask.frame = sweepLayer.bounds
        CATransaction.commit()
    }

    func configureLights(card: NeuralBrainCard, ink: BrainInk) {
        stageLights.configure(card: card, ink: ink, hovered: false)
        stageLights.layout(in: stage.bounds)
        sweepLayer.colors = [
            ink.live.withAlphaComponent(0).cgColor, ink.live.cgColor, ink.live.withAlphaComponent(0).cgColor,
        ]
    }

    /// The first content of the account arriving after the move: a 90 ms cross-fade.
    func fadeInContent() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        guard let account = madeAccount else { return }
        account.alpha = 0
        UIView.animate(withDuration: NeuralTransition.contentFadeDuration) { account.alpha = 1 }
    }
}
