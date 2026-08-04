import Foundation

/// A chat in flight between the list and the panes: what the pointer carries, where inside a pane
/// letting go means what, and the rectangle that says so before the drop happens.
///
/// The chooser answers "which chat" with the keyboard; this answers it with the hand, and answers
/// a second question the chooser cannot — *where*. Dropping in the middle of a pane fills it;
/// dropping against an edge splits that pane and gives the arriving chat that side, which is the
/// whole arrangement made in one gesture instead of `ctrl+w v` followed by a chooser.
///
/// Toolkit-free on purpose: the bands, the tie-breaks, the refusal to halve a pane too narrow to
/// hold two, and the highlight geometry all live here, so GTK and AppKit feel like one app.
public struct PaneDragPayload: Sendable, Equatable {
    /// What the drag advertises itself as. A private type rather than plain text: a chat dropped
    /// on a prompt box must not arrive as pasted words.
    public static let identifier = "application/x-tailscode-chat"
    private static let tag = "tailscode-chat"

    public let profileID: String
    public let sessionID: String

    public init(profileID: String, sessionID: String) {
        self.profileID = profileID
        self.sessionID = sessionID
    }

    public var encoded: String { [Self.tag, profileID, sessionID].joined(separator: "\t") }

    public static func decode(_ text: String) -> PaneDragPayload? {
        let fields = text.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 3, fields[0] == tag, !fields[1].isEmpty, !fields[2].isEmpty else {
            return nil
        }
        return PaneDragPayload(profileID: fields[1], sessionID: fields[2])
    }
}

/// Which side of a pane a chat was dropped against, and what that means to the tree.
public enum PaneDropEdge: String, Sendable, Equatable, CaseIterable {
    case left
    case right
    case top
    case bottom

    public var axis: SplitAxis {
        switch self {
        case .left, .right: return .horizontal
        case .top, .bottom: return .vertical
        }
    }

    /// Whether the arriving chat takes the first half of the split it makes — dropping against the
    /// left edge must put the chat on the left, which the plain split verb never needs to do.
    public var placesArrivalFirst: Bool {
        self == .left || self == .top
    }
}

/// What letting go right here would do.
public enum PaneDropZone: Sendable, Equatable {
    /// The pane shows the dropped chat instead of what it holds now.
    case fill
    /// The pane halves along that edge and the dropped chat takes the new half.
    case split(PaneDropEdge)

    /// The region the arriving chat would occupy, in the pane's own unit square — what the
    /// highlight draws, so the picture is the promise.
    public var rect: SplitRect {
        switch self {
        case .fill: return .unit
        case .split(.left): return SplitRect(x: 0, y: 0, width: 0.5, height: 1)
        case .split(.right): return SplitRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .split(.top): return SplitRect(x: 0, y: 0, width: 1, height: 0.5)
        case .split(.bottom): return SplitRect(x: 0, y: 0.5, width: 1, height: 0.5)
        }
    }

    public var verb: String {
        switch self {
        case .fill: return Localized.text("Open here")
        case .split(.left): return Localized.text("Split left")
        case .split(.right): return Localized.text("Split right")
        case .split(.top): return Localized.text("Split above")
        case .split(.bottom): return Localized.text("Split below")
        }
    }

    /// The verb with the chat it applies to, for the label inside the highlight. A drag that has
    /// not said which chat it carries yet is still worth captioning with what the zone would do.
    public func caption(_ title: String?) -> String {
        guard let title, !title.isEmpty else { return verb }
        return "\(verb) · \(title)"
    }
}

public enum PaneDropTarget {
    /// How deep into a pane an edge reaches. Wide enough to aim at without care, narrow enough
    /// that the middle of a pane is unambiguously the middle.
    public static let edgeBand = 0.28

    /// The narrowest a pane may end up. A pane thinner than a phone's worth of transcript is not a
    /// pane, so a pane with no room to halve only ever offers to fill — matching the 280pt minimum
    /// the clients give a conversation surface.
    public static let minimumPaneExtent: Double = 280

    /// What a pointer at `x`, `y` inside a pane of `width` × `height` pixels would do. Nearest edge
    /// wins inside the band; ties resolve toward the horizontal, because screens are wide.
    public static func zone(x: Double, y: Double, width: Double, height: Double) -> PaneDropZone {
        guard width > 0, height > 0, x.isFinite, y.isFinite else { return .fill }
        let u = min(max(x / width, 0), 1)
        let v = min(max(y / height, 0), 1)
        var candidates: [(edge: PaneDropEdge, depth: Double)] = []
        if width >= 2 * minimumPaneExtent {
            candidates += [(.left, u), (.right, 1 - u)]
        }
        if height >= 2 * minimumPaneExtent {
            candidates += [(.top, v), (.bottom, 1 - v)]
        }
        guard let nearest = candidates.min(by: { $0.depth < $1.depth }),
            nearest.depth < edgeBand
        else { return .fill }
        return .split(nearest.edge)
    }

    /// The highlight in pixels inside a pane of that size — the same rectangle every client draws.
    public static func highlight(
        for zone: PaneDropZone, width: Double, height: Double
    ) -> SplitRect {
        let rect = zone.rect
        return SplitRect(
            x: rect.x * width, y: rect.y * height,
            width: rect.width * width, height: rect.height * height)
    }
}
