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
        wordmark.alpha = stage.alpha
        stageBand.alpha = 0
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
        UIView.animate(withDuration: 0.15) { self.stageBand.alpha = 1 }
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
