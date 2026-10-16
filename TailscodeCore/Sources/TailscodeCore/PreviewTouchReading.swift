import CodingAgentKit
import Foundation

public struct PreviewTouchPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct PreviewTouchSize: Sendable, Equatable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    var isEmpty: Bool { !(width > 0 && height > 0) }
}

/// Where the picture sits inside the pane that shows it: the picture is drawn as large as fits and
/// centred, so a press has to be measured from the picture's own corner and not the pane's.
public struct PreviewTouchFrame: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
}

/// One finger's whole gesture, decided when it lifts.
public enum PreviewTouchGesture: Sendable, Equatable {
    case tap(PreviewTouchPoint)
    case swipe(from: PreviewTouchPoint, to: PreviewTouchPoint, seconds: Double)

    public var request: TouchRequest {
        switch self {
        case .tap(let point): return .tap(x: point.x, y: point.y)
        case .swipe(let from, let to, let seconds):
            return .swipe(x: from.x, y: from.y, toX: to.x, toY: to.y, seconds: seconds)
        }
    }
}

/// The toolkit-free half of operating a preview with a pointer: where a press lands on the
/// picture, whether a drag was a tap or a swipe, what a failed touch is called, and what a typed
/// character becomes. A client only reports positions and times.
public enum PreviewTouchReading {
    /// A pointer that moves less than this many view units between press and release was a tap;
    /// a hand never holds perfectly still.
    public static let movementThreshold = 10.0
    public static let shortestSwipe = 0.12
    public static let longestSwipe = 2.0
    public static let keyNames = ["return", "delete", "escape", "tab", "space", "up", "down", "left", "right"]

    public static func pictureFrame(in container: PreviewTouchSize, picture: PreviewTouchSize) -> PreviewTouchFrame? {
        guard !container.isEmpty, !picture.isEmpty else { return nil }
        let scale = min(container.width / picture.width, container.height / picture.height)
        let width = picture.width * scale
        let height = picture.height * scale
        return PreviewTouchFrame(x: (container.width - width) / 2, y: (container.height - height) / 2, width: width, height: height)
    }

    /// A press as fractions of the picture, or nothing when it landed on the empty margin around it.
    public static func fraction(
        x: Double, y: Double, container: PreviewTouchSize, picture: PreviewTouchSize
    ) -> PreviewTouchPoint? {
        guard let frame = pictureFrame(in: container, picture: picture) else { return nil }
        let across = (x - frame.x) / frame.width
        let down = (y - frame.y) / frame.height
        guard (0...1).contains(across), (0...1).contains(down) else { return nil }
        return PreviewTouchPoint(x: across, y: down)
    }

    /// The same, held to the picture's edge: the end of a drag that ran off the picture is the edge.
    public static func clampedFraction(
        x: Double, y: Double, container: PreviewTouchSize, picture: PreviewTouchSize
    ) -> PreviewTouchPoint? {
        guard let frame = pictureFrame(in: container, picture: picture) else { return nil }
        return PreviewTouchPoint(
            x: min(1, max(0, (x - frame.x) / frame.width)), y: min(1, max(0, (y - frame.y) / frame.height)))
    }

    /// A typed string, kept to what the simulator's keyboard can take: printable ASCII.
    public static func text(typed: String) -> TouchRequest? {
        let kept = String(typed.unicodeScalars.filter { $0.isASCII && $0.value >= 0x20 && $0.value != 0x7F }.map(Character.init))
        return kept.isEmpty ? nil : .text(kept)
    }

    public static func key(named name: String) -> TouchRequest? {
        keyNames.contains(name.lowercased()) ? .key(name.lowercased()) : nil
    }

    /// What a failed touch is called. The host's own reasons are English, so the client says its
    /// own for the cases a person can act on.
    public static func failure(_ error: Error) -> String {
        guard case AgentError.http(let status, _) = error else { return Localized.text("The Mac is not answering") }
        switch status {
        case 401, 403: return Localized.text("The preview host wants its password")
        case 404: return Localized.text("This preview has ended")
        case 409: return Localized.text("The app is not showing yet, so there is nothing to touch")
        case 501: return Localized.text("This Mac has no way to touch the simulator yet")
        case 400: return Localized.text("The Mac could not make sense of that touch")
        default: return Localized.text("The Mac could not deliver that touch")
        }
    }

    public static func isUnsupported(_ error: Error) -> Bool {
        if case AgentError.http(let status, _) = error { return status == 501 }
        return false
    }
}

/// Follows one finger from press to release over the picture. Positions are in the pane's own
/// units and are measured against the picture the pane shows.
public struct PreviewTouchTracker: Sendable {
    private let container: PreviewTouchSize
    private let picture: PreviewTouchSize
    private var start: (point: PreviewTouchPoint, view: PreviewTouchPoint, time: Double)?
    private var farthest = 0.0

    public init(container: PreviewTouchSize, picture: PreviewTouchSize) {
        self.container = container
        self.picture = picture
    }

    public var isDown: Bool { start != nil }

    /// Starts a gesture. A press outside the picture starts nothing.
    @discardableResult
    public mutating func press(x: Double, y: Double, at time: Double) -> Bool {
        guard let point = PreviewTouchReading.fraction(x: x, y: y, container: container, picture: picture) else {
            start = nil
            return false
        }
        start = (point, PreviewTouchPoint(x: x, y: y), time)
        farthest = 0
        return true
    }

    public mutating func move(x: Double, y: Double) {
        guard let start else { return }
        farthest = max(farthest, Self.distance(start.view, PreviewTouchPoint(x: x, y: y)))
    }

    public mutating func cancel() {
        start = nil
    }

    /// Ends the gesture. A drag that stayed within the movement threshold the whole time is a tap
    /// where it began, however long it was held; anything else is a swipe from where it began to
    /// where it ended, over the time it took.
    public mutating func release(x: Double, y: Double, at time: Double) -> PreviewTouchGesture? {
        guard let began = start else { return nil }
        start = nil
        let end = PreviewTouchPoint(x: x, y: y)
        let travelled = max(farthest, Self.distance(began.view, end))
        guard travelled >= PreviewTouchReading.movementThreshold,
            let finish = PreviewTouchReading.clampedFraction(x: x, y: y, container: container, picture: picture)
        else { return .tap(began.point) }
        let seconds = min(PreviewTouchReading.longestSwipe, max(PreviewTouchReading.shortestSwipe, time - began.time))
        return .swipe(from: began.point, to: finish, seconds: seconds)
    }

    private static func distance(_ a: PreviewTouchPoint, _ b: PreviewTouchPoint) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }
}
