import AppKit
import CodingAgentKit
import TailscodeCore

extension BrainRowView {
    struct MetricsKey: Equatable {
        let width: Double
        let density: ChatDensity
        let zones: Int
        let bucket: Int
    }

    /// How many zones have steps, which sets the stage's height. The chips are read from the
    /// model once for each of its revisions, not once for each time a part asks where it goes.
    private var zonesWithSteps: Int {
        let model = model
        if let memo = zonesMemo, memo.revision == model.revision { return memo.count }
        let count = model.browseState.list.zoneChips.count
        zonesMemo = (model.revision, count)
        return count
    }

    func metrics(forWidth width: Double) -> NeuralStageMetrics {
        let zones = zonesWithSteps
        let viewport = store?.viewportHeight?().map { Double($0) }
        let key = MetricsKey(
            width: width, density: density, zones: zones, bucket: Int(viewport ?? 0))
        if let memo = metricsMemo, memo.key == key { return memo.value }
        let made = NeuralStageMetrics.make(
            width: width, density: density, zonesWithSteps: max(zones, 1), viewportHeight: viewport)
        metricsMemo = (key, made)
        return made
    }

    var currentMetrics: NeuralStageMetrics {
        let width = Double(bounds.width > 0 ? bounds.width : (lastWidth > 0 ? lastWidth : 600))
        return metrics(forWidth: width)
    }

    var restingHeight: CGFloat {
        let m = currentMetrics
        switch phase {
        case .closed: return CGFloat(m.card.height)
        case .open: return CGFloat(m.openHeight.rounded())
        case .moving: return CGFloat(max(m.card.height, m.openHeight).rounded())
        }
    }

    func widthChanged() {
        metricsMemo = nil
        invalidateIntrinsicContentSize()
        if let mover, abs(mover.metricsWidth - Double(lastWidth)) > 0.5 { finishMove(snapOpen: mover.isOpening) }
        syncCard()
        stage?.needsLayout = true
        list?.configure(metrics: currentMetrics)
        chips?.configure(metrics: currentMetrics)
        account?.geometryChanged()
        footer?.needsLayout = true
    }

    /// Every part at the rectangle Core gives it for this width and phase.
    func place() {
        let m = currentMetrics
        let width = bounds.width
        card.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        carrier.frame = bounds
        let stageRect = rect(m.stage)
        switch phase {
        case .closed:
            placeClosed(m)
        case .open:
            placeOpen(m, stageRect: stageRect)
        case .moving:
            applyMoveFrame(m)
        }
        picture.place(m.stage)
        if phase != .moving {
            applyCarrier(rect: phase == .closed ? rect(m.card.picture) : stageRect, stage: stageRect)
        }
    }

    func rect(_ r: NeuralRect) -> CGRect { CGRect(x: r.x, y: r.y, width: r.width, height: r.height) }

    private func placeClosed(_ m: NeuralStageMetrics) {
        card.isHidden = false
        card.presentation = .rest
        picture.container.isHidden = false
        picture.container.opacity = 1
        carrier.isHidden = false
        picture.show(
            card: cardInput?.card ?? model.brainCard(now: Date()), inks: inks, hovered: card.hovered,
            lift: 1, liveZone: liveZone, liveMotion: liveMotion)
        stage?.isHidden = true
        placeWordmark(m, alpha: 0)
    }

    /// The name the open stage wears in the row's corner, nil where it wears none.
    var wordmarkText: String? {
        wordmark.isHidden ? nil : wordmark.words?.string
    }

    /// Megatron's name in the row's top left corner where Core's metrics say the corner is clear of
    /// the head, at the stage's own opacity: one small view of the row standing over the head,
    /// made with its words once per look and only moved after that.
    func placeWordmark(_ m: NeuralStageMetrics, alpha: CGFloat) {
        guard alpha > 0.01, let box = m.stageWordmark else {
            if !wordmark.isHidden { wordmark.isHidden = true }
            return
        }
        let font = MacTheme.Ramp.font(.sectionLabel)
        var hasher = Hasher()
        hasher.combine(effectiveAppearance.name.rawValue)
        hasher.combine(font.pointSize)
        let key = hasher.finalize()
        if key != wordmarkKey {
            wordmarkKey = key
            wordmark.words = NSAttributedString(
                string: NeuralReading.wordmark,
                attributes: MacTheme.Ramp.attributes(.sectionLabel, color: inks.textDim))
        }
        wordmark.isHidden = false
        wordmark.alphaValue = alpha
        wordmark.frame = rect(box)
    }

    private func placeOpen(_ m: NeuralStageMetrics, stageRect: CGRect) {
        card.isHidden = true
        picture.container.opacity = stage?.head.isReady == true ? 0 : 1
        picture.container.isHidden = stage == nil
        let extra = m.narrowExtra
        stage?.isHidden = false
        stage?.frame = stageRect
        footer?.frame = rect(m.footer).offsetBy(dx: 0, dy: extra)
        placeWordmark(m, alpha: stage == nil ? 0 : 1)
        placeBrowse(m, readout: nil)
        placeLeader(m)
    }

    func placeBrowse(_ m: NeuralStageMetrics, readout moved: NeuralRect?) {
        let narrow = m.arrangement == .accordion
        if let rect = m.filterChips { chips?.frame = self.rect(rect) }
        if narrow {
            list?.isHidden = true
        } else {
            list?.isHidden = false
            list?.frame = rect(m.list)
        }
        let rest =
            narrow
            ? NeuralRect(x: 0, y: m.list.y, width: m.width, height: m.narrowAccountHeight) : m.readout
        var target = rest
        if let moved { target = narrow ? rest.offsetBy(dx: moved.x, dy: moved.y) : moved }
        slide?.frame = rect(rest)
        account?.frame = CGRect(origin: .zero, size: rect(rest).size)
        slide?.setTravel(
            CGAffineTransform(translationX: CGFloat(target.x - rest.x), y: CGFloat(target.y - rest.y)))
    }

    private func placeLeader(_ m: NeuralStageMetrics) {
        leader.layer.frame = bounds
        updateLeader()
    }

    /// The carrier moves the picture and the stage together: a transform about the carrier's own
    /// anchor that puts the head's bounds (`stage`) where `rect` is, which is the card's picture on
    /// a card, the stage on an open brain, and anywhere between during the move.
    func applyCarrier(rect target: CGRect, stage stageRect: CGRect) {
        let k = stageRect.width > 0 ? target.width / stageRect.width : 1
        let held = carrier.layer?.anchorPoint ?? .zero
        let anchor = CGPoint(x: held.x * carrier.bounds.width, y: held.y * carrier.bounds.height)
        let tx = target.minX - k * stageRect.minX - (1 - k) * anchor.x
        let ty = target.minY - k * stageRect.minY - (1 - k) * anchor.y
        carrier.setTravel(CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: tx, ty: ty))
        let radius = phase == .closed ? 8 : 0
        picture.setCornerRadius(CGFloat(radius), designScale: target.width / CGFloat(NeuralStageMetrics.designWidth))
    }
}
