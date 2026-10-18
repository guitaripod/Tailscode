import AppKit
import TailscodeCore

/// The line from the node being read to the account beside the head: a thin printed trace on the
/// 45 degree roads the wires use, ending in a dot and a tab on the account's hairline at the
/// node's own row. It is drawn along its length in 120 ms and faded in 120 ms, by animations the
/// render server runs, so it costs the app nothing per frame, and it is never there in an
/// accordion row, which has no account beside it.
@MainActor
final class BrainLeaderLayer {
    static let drawTime: CFTimeInterval = 0.120
    static let fadeTime: CFTimeInterval = 0.120

    let layer = CALayer()
    private var current: Leg?
    private(set) var searches = 0

    private final class Leg {
        let id: String
        let width: Double
        let revision: Int
        let group = CALayer()
        let stroke = CAShapeLayer()
        let halo = CAShapeLayer()
        let dot = CAShapeLayer()
        let tab = CAShapeLayer()
        let route: [NeuralPoint]

        init(id: String, width: Double, revision: Int, route: [NeuralPoint]) {
            self.id = id
            self.width = width
            self.revision = revision
            self.route = route
            for shape in [stroke, halo, dot, tab] {
                shape.fillColor = nil
                group.addSublayer(shape)
            }
        }
    }

    init() {
        layer.zPosition = 20
    }

    var isShown: Bool { current != nil }
    var stepID: String? { current?.id }
    var routePoints: Int { current?.route.count ?? 0 }
    var isAnimating: Bool { current?.stroke.animation(forKey: "draw") != nil }

    /// Points the leader at `stepID`, or at nothing. A leader already pointing at that step at
    /// this width and revision is left as it is.
    func update(
        stepID: String?, model: NeuralBrainModel, metrics: NeuralStageMetrics, inks: BrainInks,
        nodes: [NeuralPoint], reduceMotion: Bool
    ) {
        let wanted: String? = metrics.hasLeader ? stepID : nil
        if let held = current, held.id == wanted, held.width == metrics.width,
            held.revision == model.revision
        {
            return
        }
        retire(reduceMotion: reduceMotion)
        guard let wanted, let step = model.step(id: wanted),
            let node = model.point(of: model.layout.representative(of: wanted)),
            let line = NeuralLeader.line(forNodeAt: node, in: metrics, around: nodes)
        else { return }
        searches += 1
        let leg = Leg(id: wanted, width: metrics.width, revision: model.revision, route: line.route)
        let tone = inks.page(step.zone)
        let path = CGMutablePath()
        for (index, point) in line.route.enumerated() {
            let at = metrics.point(forDesign: point)
            let cg = CGPoint(x: at.x, y: at.y)
            if index == 0 { path.move(to: cg) } else { path.addLine(to: cg) }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        leg.stroke.path = path
        leg.stroke.strokeColor = tone.withAlphaComponent(0.7).cgColor
        leg.stroke.lineWidth = 1.25
        leg.stroke.lineCap = .round
        leg.stroke.lineJoin = .round
        let start = metrics.point(forDesign: node)
        let reach = CGFloat(NeuralDesign.nodeRadius + 5) * CGFloat(metrics.designScale)
        leg.halo.path = CGPath(
            ellipseIn: CGRect(x: start.x - reach, y: start.y - reach, width: reach * 2, height: reach * 2),
            transform: nil)
        leg.halo.strokeColor = tone.withAlphaComponent(0.8).cgColor
        leg.halo.lineWidth = 1
        let end = CGPoint(x: line.dot.x, y: line.dot.y)
        leg.dot.path = CGPath(
            ellipseIn: CGRect(x: end.x - 2.5, y: end.y - 2.5, width: 5, height: 5), transform: nil)
        leg.dot.fillColor = tone.cgColor
        leg.tab.path = CGPath(
            roundedRect: CGRect(x: line.tab.x, y: line.tab.y, width: line.tab.width, height: line.tab.height),
            cornerWidth: 1, cornerHeight: 1, transform: nil)
        leg.tab.fillColor = tone.cgColor
        layer.addSublayer(leg.group)
        CATransaction.commit()
        current = leg
        if reduceMotion {
            leg.dot.opacity = 1
            leg.tab.opacity = 1
            return
        }
        leg.dot.opacity = 0
        leg.tab.opacity = 0
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = Self.drawTime
        draw.timingFunction = CAMediaTimingFunction(controlPoints: 0.33, 1, 0.68, 1)
        leg.stroke.add(draw, forKey: "draw")
        let land = CABasicAnimation(keyPath: "opacity")
        land.fromValue = 0
        land.toValue = 1
        land.beginTime = CACurrentMediaTime() + Self.drawTime * 0.85
        land.duration = 0.04
        land.fillMode = .backwards
        for part in [leg.dot, leg.tab] {
            part.add(land, forKey: "land")
            part.opacity = 1
        }
    }

    private func retire(reduceMotion: Bool) {
        guard let gone = current else { return }
        current = nil
        guard !reduceMotion else {
            gone.group.removeFromSuperlayer()
            return
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = Self.fadeTime
        CATransaction.begin()
        CATransaction.setCompletionBlock { gone.group.removeFromSuperlayer() }
        gone.group.opacity = 0
        gone.group.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    func clear(reduceMotion: Bool = true) { retire(reduceMotion: reduceMotion) }
}
