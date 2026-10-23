import TailscodeCore
import UIKit

extension BrainOpenView {
    /// Lays every part out for the metrics of this width.
    func apply(metrics new: NeuralStageMetrics) {
        metrics = new
        extra = CGFloat(new.narrowExtra)
        env.metrics = new
        if !new.isPhone { list.configure(metrics: new) }
        compactList.configure(metrics: new)
        if new.isPhone {
            accordionHeader.setLeading(chips)
            if reader == nil { madeAccount?.removeFromSuperview() }
        } else {
            accordionHeader.setLeading(nil)
            if chips.superview !== self { insertSubview(chips, aboveSubview: stage) }
            if account.superview !== self { insertSubview(account, belowSubview: footer) }
            account.configure(metrics: new)
        }
        footer.configure(metrics: new, running: browseModel?.turn.outcome == .running, showsRows: store?.showsRows(turnID) ?? false)
        setNeedsLayout()
    }

    func rect(_ value: NeuralRect) -> CGRect {
        CGRect(x: value.x, y: value.y, width: value.width, height: value.height)
    }

    /// The name the open stage wears in the row's corner, nil where it wears none.
    var wordmarkText: String? { wordmark.isHidden ? nil : wordmark.attributedText?.string }

    func styleWordmark() {
        wordmark.attributedText = NSAttributedString(
            string: NeuralReading.wordmark,
            attributes: Theme.Ramp.attributes(.sectionLabel, color: Theme.Color.secondaryLabel))
    }

    /// Megatron's name in the row's top left corner where Core's metrics say the corner is clear of
    /// the head, as wide as its words.
    func placeWordmark() {
        guard let box = metrics.stageWordmark else {
            wordmark.isHidden = true
            return
        }
        wordmark.isHidden = false
        let size = wordmark.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat(box.height)))
        wordmark.frame = CGRect(x: box.x, y: box.y, width: ceil(size.width), height: ceil(size.height))
    }

    func traitsChanged() {
        styleWordmark()
        setNeedsLayout()
        updateLeader(animated: false)
    }

    private func leaderTone(_ zone: NeuralZone) -> UIColor { BrainCanvas.zone(zone) }

    func updateLeader(animated: Bool) {
        let parts: [CALayer] = [leaderLine, leaderDot, leaderTab]
        guard metrics.hasLeader, !isMoving, let model = browseModel,
            let id = leaderTarget(model), let step = model.step(id: id),
            let line = model.leader(forStep: id, in: metrics)
        else {
            for part in parts { part.isHidden = true }
            leaderStep = nil
            return
        }
        let tone = leaderTone(step.zone).resolvedColor(with: traitCollection)
        let route = line.route.map { metrics.point(forDesign: $0) }.map { CGPoint(x: $0.x, y: $0.y) }
        let path = CGMutablePath()
        if let first = route.first {
            path.move(to: first)
            for point in route.dropFirst() { path.addLine(to: point) }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        leaderLine.path = path
        leaderLine.lineWidth = 1.25
        leaderLine.strokeColor = tone.withAlphaComponent(0.7).cgColor
        leaderDot.path = CGPath(ellipseIn: CGRect(x: -2.5, y: -2.5, width: 5, height: 5), transform: nil)
        leaderDot.position = CGPoint(x: line.dot.x, y: line.dot.y)
        leaderDot.fillColor = tone.cgColor
        leaderTab.frame = CGRect(x: line.tab.x, y: line.tab.y, width: line.tab.width, height: line.tab.height)
        leaderTab.backgroundColor = tone.cgColor
        for part in parts { part.isHidden = false }
        CATransaction.commit()
        if animated, leaderStep != id, !UIAccessibility.isReduceMotionEnabled {
            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = 0
            draw.toValue = 1
            draw.duration = 0.12
            leaderLine.add(draw, forKey: "draw")
        }
        leaderStep = id
    }

    /// The step the leader ties to the account: the one being read, and while a turn runs with
    /// nothing chosen, the one it is on.
    private func leaderTarget(_ model: NeuralBrainModel) -> String? {
        if let id = model.previewedStep { return id }
        if model.turn.outcome == .running, model.browseState.list.isFollowing {
            return model.steps.last?.id
        }
        return nil
    }
}
