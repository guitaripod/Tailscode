import Foundation

/// The parts of an open Megatron in the order a person needs them: the head the card turns into,
/// the filter chips and the step list, the head's nodes and wires, the account beside them and
/// its story, and the footer's controls.
public enum NeuralOpenPart: Int, CaseIterable, Sendable, Comparable {
    case head
    case steps
    case nodes
    case account
    case story
    case footer

    public static func < (lhs: NeuralOpenPart, rhs: NeuralOpenPart) -> Bool { lhs.rawValue < rhs.rawValue }

    /// How far into the move, `0...1`, the part starts to show: the head's first lift at 40 ms of
    /// Core's 320, the panel and the list at 90, the nodes at 120, the account and its story at 130,
    /// the footer at 240. A part has to exist before then, whatever frame the clock is on.
    var showsAt: Double {
        switch self {
        case .head: return 40.0 / NeuralTransition.openMs
        case .steps: return 90.0 / NeuralTransition.openMs
        case .nodes: return 120.0 / NeuralTransition.openMs
        case .account, .story: return 130.0 / NeuralTransition.openMs
        case .footer: return 240.0 / NeuralTransition.openMs
        }
    }
}

/// Which part of an opening Megatron is built on which frame of the move.
///
/// Building all four on the press costs one main-thread turn of 25 to 40 ms, two to four dropped
/// frames before the first picture moves. The card turning into the stage needs only the head at
/// first and the rest does not show for a tenth of a second or more, so the press builds nothing,
/// each tick of the move from the second builds the next part, and a part that is about to show builds on the
/// frame that reaches it whatever came before. Pure arithmetic over the frame count and the
/// move's progress; the client builds.
public struct NeuralOpenSchedule: Sendable, Equatable {
    /// Frames to leave between the parts: one part to a frame keeps each frame's share of the work
    /// to a part's own cost.
    public static let framesPerPart = 1
    /// The tick the first part is built on: the first tick of the move is left empty because the
    /// rows are rebuilt for the press at about that time, and the two never share a frame.
    public static let firstFrame = 2
    /// How much earlier than it shows a part is built, as a share of the move, so its first layout
    /// and drawing never land on the frame that is meant to fade it in.
    public static let lead = 0.04

    public private(set) var built: Int = 0

    public init() {}

    public var isComplete: Bool { built >= NeuralOpenPart.allCases.count }

    public var next: NeuralOpenPart? { NeuralOpenPart(rawValue: built) }

    /// The parts to build on this tick, in order. `frame` counts the ticks of the move from 1;
    /// `progress` is how far through the move it is, `0...1`.
    public mutating func due(frame: Int, progress: Double) -> [NeuralOpenPart] {
        var parts: [NeuralOpenPart] = []
        while let part = next {
            let byFrame = frame >= part.rawValue * Self.framesPerPart + Self.firstFrame
            let late = progress + Self.lead >= part.showsAt
            guard byFrame || late else { break }
            if byFrame, !parts.isEmpty, !late { break }
            parts.append(part)
            built += 1
        }
        return parts
    }

    /// Everything not yet built, for a move that ends early or a harness that wants the whole
    /// brain at once.
    public mutating func remaining() -> [NeuralOpenPart] {
        defer { built = NeuralOpenPart.allCases.count }
        return NeuralOpenPart.allCases.filter { $0.rawValue >= built }
    }
}
