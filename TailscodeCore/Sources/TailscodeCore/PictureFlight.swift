import Foundation

/// A picture opening out of the tile it was pressed in, and going back to it: the geometry and the
/// clock, once, for the three clients that draw it.
///
/// What a reader pressed is the thing that moves. The tile's own pixels are drawn filling a frame
/// that travels from the tile to the rectangle the viewer fits the picture into; as the frame's
/// shape nears the picture's own, filling stops cropping, so a strip's square crop opens into the
/// whole picture and the last frame is exactly what the viewer draws. Everything around it only
/// fades: the backdrop first and the viewer's words last on the way out, the words first and the
/// backdrop across the rest on the way home.
///
/// A flight is told by two numbers. `time` is how present the viewer is on a straight clock (0 in
/// the tile, 1 at rest), which the fades around the picture follow; `travel` is how far the
/// picture has gone along its eased path. A client that is handed frames by its toolkit's own
/// animations asks for the curve and the fades' windows instead of sampling them.
public enum PictureFlight {
    public struct Rect: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public var midX: Double { x + width / 2 }
        public var midY: Double { y + height / 2 }
        public var isDrawable: Bool {
            x.isFinite && y.isFinite && width.isFinite && height.isFinite && width > 0 && height > 0
        }
    }

    /// One instant of a flight: where the picture is, how round its corners are, and how much of
    /// what surrounds it is there.
    public struct Moment: Sendable, Equatable {
        public let frame: Rect
        public let cornerRadius: Double
        /// The dark behind the picture, 0…1 of its resting strength.
        public let backdrop: Double
        /// The viewer's words and buttons, 0…1.
        public let chrome: Double
    }

    /// A cubic Bézier through (0,0) and (1,1), as a toolkit's timing function takes it.
    public struct Curve: Sendable, Equatable {
        public let x1: Double
        public let y1: Double
        public let x2: Double
        public let y2: Double
    }

    public static let openDuration: Double = 0.280
    public static let closeDuration: Double = 0.220
    public static let reducedDuration: Double = 0.120
    /// How long a picture with no tile to go home to takes to fade where it stands.
    public static let fadeDuration: Double = 0.160
    /// How much smaller a picture with no home gets as it fades.
    public static let fadeShrink: Double = 0.04

    /// The share of the flight by which the backdrop is fully in.
    public static let backdropEnd: Double = 0.45
    /// The share of the flight at which the viewer's words begin to appear.
    public static let chromeStart: Double = 0.55
    /// The share of a homeward flight the viewer's words take to go.
    public static let chromeLeave: Double = 0.30
    /// The share of a homeward flight that passes before the backdrop starts to lift. It lifts
    /// across the rest, so the reader sees where the picture is going while it goes.
    public static let backdropHold: Double = 0.15

    /// The phone's spring out of the tile, which it keeps: its length and its damping.
    public static let springDuration: Double = 0.42
    public static let springDamping: Double = 0.86

    public static func duration(opening: Bool, reduced: Bool) -> Double {
        if reduced { return reducedDuration }
        return opening ? openDuration : closeDuration
    }

    /// Ease-out cubic leaving the tile, ease-in-out cubic going home.
    public static func curve(opening: Bool) -> Curve {
        opening
            ? Curve(x1: 0.215, y1: 0.61, x2: 0.355, y2: 1)
            : Curve(x1: 0.645, y1: 0.045, x2: 0.355, y2: 1)
    }

    /// The rectangle a picture of this shape is fitted into, centred in the room it is given.
    public static func stage(aspect: Double, in room: Rect) -> Rect {
        guard room.isDrawable, aspect.isFinite, aspect > 0 else { return room }
        let width = min(room.width, room.height * aspect)
        let height = width / aspect
        return Rect(
            x: room.x + (room.width - width) / 2, y: room.y + (room.height - height) / 2,
            width: width, height: height)
    }

    /// Where a flight starts: the part of a tile its picture's pixels cover. A cropped tile is
    /// covered whole; a tile its picture is fitted inside is covered by the fitted picture alone,
    /// so a lone picture leaves from its own edges and not from its letterbox.
    public static func origin(tile: Rect, aspect: Double, fitted: Bool) -> Rect {
        fitted ? stage(aspect: aspect, in: tile) : tile
    }

    /// The whole picture's rectangle when it is drawn filling `frame`: at least as large as the
    /// frame on both sides and centred on it. A client that clips to the frame and draws the
    /// picture here has drawn an aspect fill.
    public static func fill(aspect: Double, frame: Rect) -> Rect {
        guard frame.isDrawable, aspect.isFinite, aspect > 0 else { return frame }
        let width = max(frame.width, frame.height * aspect)
        let height = width / aspect
        return Rect(
            x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
    }

    /// How present the viewer is `elapsed` seconds into a flight, on a straight clock.
    public static func time(elapsed: Double, opening: Bool, reduced: Bool) -> Double {
        let span = duration(opening: opening, reduced: reduced)
        let done = unit(elapsed.isFinite ? elapsed / span : 1)
        return opening ? done : 1 - done
    }

    /// How far along its path the picture is at this `time`: the flight's curve leaving the tile,
    /// and the homeward curve run backwards on the way back.
    public static func travel(time: Double, opening: Bool) -> Double {
        let clamped = unit(time)
        return opening
            ? eased(clamped, curve(opening: true))
            : 1 - eased(1 - clamped, curve(opening: false))
    }

    /// How dark the backdrop is at this `time`: in before the words on the way out of the tile,
    /// held for a moment and then lifted across the rest of the way home.
    public static func backdrop(time: Double, opening: Bool = true) -> Double {
        opening ? unit(unit(time) / backdropEnd) : unit(unit(time) / (1 - backdropHold))
    }

    /// How present the viewer's words are at this `time`: last to arrive, first to go.
    public static func chrome(time: Double, opening: Bool = true) -> Double {
        opening
            ? unit((unit(time) - chromeStart) / (1 - chromeStart))
            : unit((unit(time) - (1 - chromeLeave)) / chromeLeave)
    }

    /// The picture and its surroundings at one instant of a flight between `origin` and `stage`.
    public static func moment(
        time: Double, opening: Bool, origin: Rect, stage: Rect, tileRadius: Double,
        stageRadius: Double = 0
    ) -> Moment {
        let share = travel(time: time, opening: opening)
        return Moment(
            frame: between(origin, stage, share),
            cornerRadius: tileRadius + (stageRadius - tileRadius) * share,
            backdrop: backdrop(time: time, opening: opening),
            chrome: chrome(time: time, opening: opening))
    }

    /// A picture with nowhere to go home to, `time` of the way gone: a little smaller about its
    /// own centre, and that much fainter.
    public static func fading(time: Double, stage: Rect) -> (frame: Rect, opacity: Double) {
        let present = unit(time)
        let scale = 1 - fadeShrink * (1 - present)
        let width = stage.width * scale
        let height = stage.height * scale
        return (
            Rect(x: stage.midX - width / 2, y: stage.midY - height / 2, width: width, height: height),
            present
        )
    }

    public static func between(_ a: Rect, _ b: Rect, _ share: Double) -> Rect {
        Rect(
            x: a.x + (b.x - a.x) * share, y: a.y + (b.y - a.y) * share,
            width: a.width + (b.width - a.width) * share,
            height: a.height + (b.height - a.height) * share)
    }

    /// The curve's height at `x`, solved for the parameter by halving: twenty steps is past the
    /// precision of a pixel on any screen and has no slope to divide by.
    public static func eased(_ x: Double, _ curve: Curve) -> Double {
        let target = unit(x)
        if target <= 0 { return 0 }
        if target >= 1 { return 1 }
        var low = 0.0
        var high = 1.0
        var parameter = target
        for _ in 0..<20 {
            let at = bezier(parameter, curve.x1, curve.x2)
            if abs(at - target) < 1e-6 { break }
            if at < target { low = parameter } else { high = parameter }
            parameter = (low + high) / 2
        }
        return bezier(parameter, curve.y1, curve.y2)
    }

    private static func bezier(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let inverse = 1 - t
        return 3 * inverse * inverse * t * p1 + 3 * inverse * t * t * p2 + t * t * t
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }
}
