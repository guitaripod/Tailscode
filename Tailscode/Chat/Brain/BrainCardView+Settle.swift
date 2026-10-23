import TailscodeCore
import UIKit

extension BrainCardView {
    struct PictureKey: Equatable {
        var frame: NeuralFrame
        var palette: Palette
        var face: NeuralFace
        var width: Int
    }

    func requestPictures() {
        guard let model, let metrics, let card, window != nil else { return }
        let scale = max(1, picture.pixelScale)
        let palette = BrainPalette.palette(for: traitCollection)
        let wholeWidth =
            CGFloat(metrics.card.picture.width * NeuralDesign.width / NeuralStageMetrics.designWidth)
        let restFrame = model.frame(time: 0, reduceMotion: true)
        let pixels = Int(wholeWidth * scale)
        let restKey = PictureKey(frame: restFrame, palette: palette, face: model.face, width: pixels)
        if restPicture != restKey || !picture.hasRest {
            restPicture = restKey
            BrainPictures.picture(
                frame: restFrame, palette: palette, face: model.face, width: wholeWidth, scale: scale
            ) { [weak self] made in
                guard let self, self.restPicture == restKey else { return }
                self.picture.setRest(made, animated: true)
            }
        }
        if let live = card.live {
            let times = BrainSwellTimes.floorAndPeak(live.motion)
            let floorFrame = model.frame(time: times.floor, reduceMotion: false)
            let peakFrame = model.frame(time: times.peak, reduceMotion: false)
            let floorKey = PictureKey(frame: floorFrame, palette: palette, face: model.face, width: pixels)
            let peakKey = PictureKey(frame: peakFrame, palette: palette, face: model.face, width: pixels)
            if livePictures?.floor != floorKey || livePictures?.peak != peakKey {
                livePictures = (floorKey, peakKey)
                var pair: [BrainPicture?] = [nil, nil]
                var arrived = 0
                for (index, frame) in [floorFrame, peakFrame].enumerated() {
                    BrainPictures.picture(
                        frame: frame, palette: palette, face: model.face, width: wholeWidth,
                        scale: scale
                    ) { [weak self] made in
                        pair[index] = made
                        arrived += 1
                        guard arrived == 2, let self, self.livePictures?.floor == floorKey,
                            self.livePictures?.peak == peakKey
                        else { return }
                        self.picture.setLive(floor: pair[0], peak: pair[1])
                        self.picture.setSwell(live.motion)
                        if self.isLive { self.picture.setLiveShare(1) }
                    }
                }
            }
        } else if livePictures != nil, !settleRunning {
            livePictures = nil
            picture.setLive(floor: nil, peak: nil)
        }
    }

    private var settleRunning: Bool { settleLink != nil }

    func startSettle() {
        guard window != nil else { return }
        if let started = memory?.settleClock.settleStartedAt, started != hapticSettle {
            hapticSettle = started
            Theme.Haptics.received()
        }
        guard !UIAccessibility.isReduceMotionEnabled, settleLink == nil else { return }
        let link = CADisplayLink(target: BrainSettleTarget(self), selector: #selector(BrainSettleTarget.step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        settleLink = link
    }

    fileprivate func settleStep() {
        guard let memory else {
            settleLink?.invalidate()
            settleLink = nil
            return
        }
        let value = memory.settleClock.settle(now: CACurrentMediaTime())
        apply(settle: value)
        layoutTexts(animated: false)
        if value.isDone {
            settleLink?.invalidate()
            settleLink = nil
            livePictures = nil
            picture.setLive(floor: nil, peak: nil)
            drawnSignature = ""
            if let model { refresh(model: model) }
        }
    }

    /// What the move between this card and the open brain does to the card, from a frame: the text
    /// fades and slides, the surface fades, the picture is the traveller's and goes, the lights stay
    /// where they are or return, and the tone edge rides the picture's left edge for a moment.
    func applyMove(frame: NeuralTransitionFrame, opening: Bool, originX: CGFloat = 0) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        textGroup.alpha = CGFloat(frame.cardTextAlpha)
        moveOffsetX = CGFloat(frame.cardTextOffsetX)
        textGroup.center = CGPoint(x: bounds.midX + moveOffsetX, y: bounds.midY)
        surface.backgroundColor = Theme.Color.secondaryBackground.withAlphaComponent(CGFloat(frame.cardSurfaceAlpha))
        surface.layer.borderColor = Theme.Color.separator.resolvedColor(with: traitCollection)
            .withAlphaComponent(CGFloat(frame.cardSurfaceAlpha)).cgColor
        picture.setMoving(
            imageAlpha: CGFloat(frame.cardPictureAlpha), lightsAlpha: CGFloat(frame.cardLightsAlpha))
        edge.isHidden = true
        moveEdge.isHidden = false
        moveEdge.strokeColor = edge.strokeColor
        let path = CGMutablePath()
        path.move(to: CGPoint(x: frame.edge.x - originX + 1.5, y: 0))
        path.addLine(to: CGPoint(x: frame.edge.x - originX + 1.5, y: bounds.height))
        moveEdge.path = path
        moveEdge.frame = bounds
        moveEdge.opacity = Float(frame.edge.alpha)
    }

    /// The card as it stands when no move is running.
    func clearMove() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        textGroup.alpha = 1
        moveOffsetX = 0
        textGroup.center = CGPoint(x: bounds.midX, y: bounds.midY)
        surface.backgroundColor = Theme.Color.secondaryBackground
        applyEmphasis()
        picture.setMoving(imageAlpha: 1, lightsAlpha: 1)
        edge.isHidden = false
        moveEdge.isHidden = true
    }
}

private final class BrainSettleTarget {
    weak var card: BrainCardView?
    init(_ card: BrainCardView) { self.card = card }

    @objc @MainActor func step(_ link: CADisplayLink) {
        guard let card else {
            link.invalidate()
            return
        }
        card.settleStep()
    }
}
