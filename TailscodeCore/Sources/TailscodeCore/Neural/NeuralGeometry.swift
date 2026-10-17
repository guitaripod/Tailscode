import CodingAgentKit
import Foundation

/// A point in the head's design space: 640 by 420, y down, the same on every client.
public struct NeuralPoint: Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

public enum NeuralDesign {
    public static let width: Double = 640
    public static let height: Double = 420
    public static let nodeRadius: Double = 10
}

/// What a zone draws its steps as. The kind of work is carried by shape first and colour second,
/// so a tint is never the only signal.
public enum NeuralShape: Sendable, Hashable {
    case circle
    case diamond
    case chip
    case hexagon
    case octagon
    case bubble
}

/// The head's fixed anatomy: where each kind of work lives. A step takes the next free slot of its
/// zone in the order it happened, so the shape of a turn reads before a word of it does.
public enum NeuralZone: Int, CaseIterable, Sendable, Hashable {
    case think
    case sense
    case act
    case shell
    case delegate
    case say

    public var label: String {
        switch self {
        case .think: return Localized.text("PLAN")
        case .sense: return Localized.text("SENSE")
        case .act: return Localized.text("ACT")
        case .shell: return Localized.text("SHELL")
        case .delegate: return Localized.text("DELEGATE")
        case .say: return Localized.text("SAY")
        }
    }

    public var center: NeuralPoint {
        switch self {
        case .think: return NeuralPoint(456, 150)
        case .act: return NeuralPoint(348, 104)
        case .sense: return NeuralPoint(204, 162)
        case .shell: return NeuralPoint(240, 284)
        case .delegate: return NeuralPoint(396, 250)
        case .say: return NeuralPoint(520, 306)
        }
    }

    /// The half-axes of the ring drawn around the zone.
    public var well: (rx: Double, ry: Double) {
        self == .say ? (56, 38) : (66, 58)
    }

    public var shape: NeuralShape {
        switch self {
        case .think: return .circle
        case .sense: return .diamond
        case .act: return .chip
        case .shell: return .hexagon
        case .delegate: return .octagon
        case .say: return .bubble
        }
    }

    public var slotSpacing: Double { self == .say ? 24 : 28 }

    /// How many hex-spiral positions a zone is offered before the dome clips them.
    var candidateCount: Int { self == .say ? 7 : 19 }

    /// Where steps sit, in design space and in the order they are taken. Only the positions whose
    /// node lies wholly inside the dome (the jaw's window for `say`) are usable, which is what
    /// makes a zone's capacity a fact of the head rather than a number someone chose.
    public var slots: [NeuralPoint] { Self.usableSlots[rawValue] }

    public var capacity: Int { slots.count }

    public static func zone(for kind: ToolCallSummary.Kind) -> NeuralZone {
        switch kind {
        case .fileRead, .fileSearch, .webSearch, .webFetch, .other: return .sense
        case .fileEdit, .fileWrite: return .act
        case .shell: return .shell
        case .subagent, .workflow, .skill: return .delegate
        case .taskTracking, .question: return .think
        }
    }

    static func spiralOffset(_ index: Int, spacing: Double) -> NeuralPoint {
        if index == 0 { return NeuralPoint(0, 0) }
        var ring = 1
        var count = 6
        var remaining = index - 1
        while remaining >= count {
            remaining -= count
            ring += 1
            count = 6 * ring
        }
        let turn = Double(remaining) / Double(count) * 2 * Double.pi
        let angle = turn + (ring % 2 == 1 ? Double.pi / 6 : 0) - Double.pi / 2
        return NeuralPoint(cos(angle) * Double(ring) * spacing, sin(angle) * Double(ring) * spacing)
    }

    private static let usableSlots: [[NeuralPoint]] = NeuralZone.allCases.map { zone in
        var list: [NeuralPoint] = []
        for index in 0..<zone.candidateCount {
            let offset = spiralOffset(index, spacing: zone.slotSpacing)
            let point = NeuralPoint(zone.center.x + offset.x, zone.center.y + offset.y)
            let fits: Bool
            if zone == .say {
                fits = NeuralDome.jawContains(point, margin: 10)
            } else {
                fits = NeuralDome.contains(point, margin: NeuralDesign.nodeRadius)
            }
            if fits { list.append(point) }
        }
        return list
    }
}

/// The glass dome the interior sits behind, and the jaw's window, as the renderer's own outlines.
public enum NeuralDome {
    static let path =
        "M128,212 C112,132 176,72 268,54 C366,38 462,52 512,108 C540,142 534,196 512,234 "
        + "C494,260 452,268 420,270 L334,298 C296,314 254,322 214,314 C168,302 134,266 128,212 Z"

    public static let outline: [NeuralPoint] = sample(path)

    public static let jawCenter = NeuralPoint(520, 306)
    public static let jawRadii = (rx: 58.0, ry: 40.0)

    /// The jaw window as a polygon of 48 points.
    public static let jawOutline: [NeuralPoint] = (0..<48).map { step in
        let angle = 2 * Double.pi * Double(step) / 48
        return NeuralPoint(
            jawCenter.x + jawRadii.rx * cos(angle), jawCenter.y + jawRadii.ry * sin(angle))
    }

    /// Whether a node of `margin` radius centred on `point` lies inside the dome.
    public static func contains(_ point: NeuralPoint, margin: Double = 0) -> Bool {
        let probes = [(0.0, 0.0), (margin, 0.0), (-margin, 0.0), (0.0, margin), (0.0, -margin)]
        return probes.allSatisfy { insidePolygon(outline, x: point.x + $0.0, y: point.y + $0.1) }
    }

    public static func jawContains(_ point: NeuralPoint, margin: Double = 0) -> Bool {
        let rx = jawRadii.rx - margin
        let ry = jawRadii.ry - margin
        guard rx > 0, ry > 0 else { return false }
        let dx = (point.x - jawCenter.x) / rx
        let dy = (point.y - jawCenter.y) / ry
        return dx * dx + dy * dy <= 1
    }

    /// The dome as a triangle fan about its centroid, in design space: the mesh a renderer draws
    /// instead of the whole screen. Three points per triangle.
    public static var triangleFan: [NeuralPoint] {
        let count = Double(outline.count)
        let cx = outline.reduce(0) { $0 + $1.x } / count
        let cy = outline.reduce(0) { $0 + $1.y } / count
        var out: [NeuralPoint] = []
        out.reserveCapacity(outline.count * 3)
        for index in outline.indices {
            out.append(NeuralPoint(cx, cy))
            out.append(outline[index])
            out.append(outline[(index + 1) % outline.count])
        }
        return out
    }

    static func insidePolygon(_ polygon: [NeuralPoint], x: Double, y: Double) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i]
            let b = polygon[j]
            if (a.y > y) != (b.y > y), x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Samples an absolute `M`, `L`, `C`, `Z` path, 24 steps to a curve.
    static func sample(_ path: String) -> [NeuralPoint] {
        var tokens: [String] = []
        var number = ""
        for character in path {
            if "MLCZ".contains(character) {
                if !number.isEmpty { tokens.append(number); number = "" }
                tokens.append(String(character))
            } else if character == " " || character == "," {
                if !number.isEmpty { tokens.append(number); number = "" }
            } else {
                number.append(character)
            }
        }
        if !number.isEmpty { tokens.append(number) }
        var points: [NeuralPoint] = []
        var current = NeuralPoint(0, 0)
        var index = 0
        func value(_ offset: Int) -> Double { Double(tokens[index + offset]) ?? 0 }
        while index < tokens.count {
            switch tokens[index] {
            case "M", "L":
                current = NeuralPoint(value(1), value(2))
                points.append(current)
                index += 3
            case "C":
                let c1 = NeuralPoint(value(1), value(2))
                let c2 = NeuralPoint(value(3), value(4))
                let end = NeuralPoint(value(5), value(6))
                for step in 1...24 {
                    let u = Double(step) / 24
                    let v = 1 - u
                    points.append(
                        NeuralPoint(
                            v * v * v * current.x + 3 * v * v * u * c1.x + 3 * v * u * u * c2.x
                                + u * u * u * end.x,
                            v * v * v * current.y + 3 * v * v * u * c1.y + 3 * v * u * u * c2.y
                                + u * u * u * end.y))
                }
                current = end
                index += 7
            default:
                index += 1
            }
        }
        return points
    }
}
