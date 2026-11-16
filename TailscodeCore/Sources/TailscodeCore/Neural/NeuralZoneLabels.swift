import Foundation

/// Where the head's six zone names stand.
///
/// A name stands above its zone's ring and on the head, never under its glass: ACT's and SAID's
/// are on the chassis, which is where the design drew them and where a name drawn inside the dome
/// is hidden whole, and SENSE's first letter is behind the rim. A name is a word, so a client
/// never draws it smaller than it can be read, and on a small head that makes it larger than the
/// design's box: the box keeps its foot on the ring and grows upward and outward. A zone crowded
/// to its second ring has nodes where its name would be, and the name then stands above the
/// highest of them instead of across their faces.
public enum NeuralZoneLabels {
    /// The furthest a name is lifted to clear the nodes under it, in design units. A name lifted
    /// further than this has left its zone, and stays where the design put it.
    public static let liftCeiling = 34.0
    /// The air kept between a lifted name and the node it was lifted over.
    public static let clearance = 3.0
    /// No name stands nearer the picture's top edge than this.
    public static let topFloor = 8.0

    /// A zone's name where the design put it, `magnify` times the design's size: 1 on a head drawn
    /// at the design's own width, more where a client holds the words at a readable size on a
    /// smaller one.
    public static func rect(of zone: NeuralZone, magnify: Double = 1) -> NeuralRect {
        let design = zone.labelRect
        let grown = max(1, magnify)
        let width = design.width * grown
        let height = design.height * grown
        return NeuralRect(
            x: design.x + design.width / 2 - width / 2,
            y: max(topFloor, design.y + design.height - height), width: width, height: height)
    }

    /// Every zone's name, by the zone's raw value, clear of the nodes a turn has put on the head.
    public static func rects(draws: [NeuralNodeDraw], magnify: Double = 1) -> [NeuralRect] {
        rects(discs: draws.map { ($0.point, $0.radius) }, magnify: magnify)
    }

    /// The same for nodes that are all one size.
    public static func rects(
        nodes: [NeuralPoint], magnify: Double = 1, nodeRadius: Double = NeuralDesign.nodeRadius
    ) -> [NeuralRect] {
        rects(discs: nodes.map { ($0, nodeRadius) }, magnify: magnify)
    }

    private static func rects(discs: [(center: NeuralPoint, radius: Double)], magnify: Double) -> [NeuralRect] {
        NeuralZone.allCases.map { zone in
            let home = rect(of: zone, magnify: magnify)
            let under = discs.filter { covers(home, $0.center, radius: $0.radius) }
            guard let top = under.map({ $0.center.y - $0.radius }).min() else { return home }
            let lifted = NeuralRect(
                x: home.x, y: max(topFloor, top - clearance - home.height), width: home.width,
                height: home.height)
            guard home.y - lifted.y <= liftCeiling,
                !discs.contains(where: { covers(lifted, $0.center, radius: $0.radius) })
            else { return home }
            return lifted
        }
    }

    /// Whether a node's face reaches into the words of a name: the box's own middle band, because
    /// the words are a line through it and the air above and below them is not a collision.
    public static func covers(_ rect: NeuralRect, _ node: NeuralPoint, radius: Double) -> Bool {
        let band = rect.height * 0.2
        let nearestX = min(max(node.x, rect.x), rect.x + rect.width)
        let nearestY = min(max(node.y, rect.y + band), rect.y + rect.height - band)
        let dx = node.x - nearestX
        let dy = node.y - nearestY
        return dx * dx + dy * dy < radius * radius
    }
}
