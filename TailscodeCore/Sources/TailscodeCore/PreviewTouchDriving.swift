import CodingAgentKit
import Foundation

/// Whether a person's pointer operates the app on a preview or only watches it. On unless they
/// turned it off, and remembered per device. A bool is written in both directions rather than
/// removed, because a removed key does not stay removed in the Linux settings file.
public enum PreviewTouchPreference {
    public static let key = "tailscode.preview.touch"

    public static func isOn(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    public static func set(_ on: Bool, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: key)
    }
}

/// What the touch controls of a preview pane show and do, decided from the few facts that bear on
/// it, so a client only draws the answer.
public struct PreviewTouchSurface: Sendable, Equatable {
    public var showsChips: Bool
    public var pointerOperates: Bool
    public var homeEnabled: Bool
    public var keysSurvive: Bool

    /// - Parameters:
    ///   - acceptsTouch: the host's own word that it can operate the simulator.
    ///   - unsupported: the host answered a touch with "this Mac has no way to", which outranks
    ///     what it said it could do.
    public static func read(
        acceptsTouch: Bool, unsupported: Bool, phase: PreviewPhase, lens: PreviewLens, touchOn: Bool
    ) -> PreviewTouchSurface {
        let offered = acceptsTouch && !unsupported
        let live = phase == .live
        return PreviewTouchSurface(
            showsChips: offered && lens == .look,
            pointerOperates: offered && touchOn && live && lens == .look,
            homeEnabled: offered && live,
            keysSurvive: offered && lens == .look)
    }
}

/// One thing a person did to the app, waiting to be sent in the order it was done. The ids are the
/// presses that made it, so the ripple each one drew can be told how it ended.
public struct PreviewTouchItem: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case pointer(PreviewTouchGesture)
        case wheel(PreviewTouchGesture)
        case text(String)
        case key(String)
        case home
    }

    public var ids: [Int]
    public var kind: Kind

    public init(ids: [Int], kind: Kind) {
        self.ids = ids
        self.kind = kind
    }

    public var request: TouchRequest {
        switch kind {
        case .pointer(let gesture), .wheel(let gesture): return gesture.request
        case .text(let text): return .text(text)
        case .key(let name): return .key(name)
        case .home: return .button("home")
        }
    }

    static let longestText = 200
    static let longestWheel = 0.6

    /// Two neighbours that say one thing: characters typed one after another are one string, and
    /// wheel notches in the same direction from the same place are one longer swipe.
    func merged(with next: PreviewTouchItem) -> PreviewTouchItem? {
        switch (kind, next.kind) {
        case (.text(let first), .text(let second)) where first.count + second.count <= Self.longestText:
            return PreviewTouchItem(ids: ids + next.ids, kind: .text(first + second))
        case (.wheel(.swipe(let from, let to, let seconds)), .wheel(.swipe(let nextFrom, let nextTo, let nextSeconds))):
            let first = (x: to.x - from.x, y: to.y - from.y)
            let second = (x: nextTo.x - nextFrom.x, y: nextTo.y - nextFrom.y)
            let vertical = abs(first.y) >= abs(first.x)
            guard vertical == (abs(second.y) >= abs(second.x)) else { return nil }
            guard (vertical ? first.y * second.y : first.x * second.x) > 0 else { return nil }
            let centre = PreviewTouchPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
            let nextCentre = PreviewTouchPoint(x: (nextFrom.x + nextTo.x) / 2, y: (nextFrom.y + nextTo.y) / 2)
            guard hypot(centre.x - nextCentre.x, centre.y - nextCentre.y) < 0.08 else { return nil }
            let motion = (x: first.x + second.x, y: first.y + second.y)
            let gesture = PreviewScrollAccumulator.gesture(
                centre: centre, motion: motion, length: min(Self.longestWheel, hypot(motion.x, motion.y)),
                seconds: min(0.8, seconds + nextSeconds * 0.5))
            return PreviewTouchItem(ids: ids + next.ids, kind: .wheel(gesture))
        default:
            return nil
        }
    }
}

/// The touches waiting for the host, first in first out. A touch arrives from a hand much faster
/// than the host can act on one, so neighbours that say one thing are joined, and a queue that has
/// run away gives up its oldest scroll before anything else, since a scroll is the one touch a
/// person repeats until the screen has moved.
public struct PreviewTouchQueue: Sendable, Equatable {
    public static let capacity = 24

    public private(set) var pending: [PreviewTouchItem] = []

    public init() {}

    public var isEmpty: Bool { pending.isEmpty }
    public var count: Int { pending.count }

    /// Adds an item and returns the ids of any that were given up to make room.
    @discardableResult
    public mutating func enqueue(_ item: PreviewTouchItem) -> [Int] {
        if let last = pending.last, let joined = last.merged(with: item) {
            pending[pending.count - 1] = joined
            return []
        }
        pending.append(item)
        var dropped: [Int] = []
        while pending.count > Self.capacity {
            let index = pending.firstIndex { if case .wheel = $0.kind { return true } else { return false } } ?? 0
            dropped += pending.remove(at: index).ids
        }
        return dropped
    }

    public mutating func dequeue() -> PreviewTouchItem? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    @discardableResult
    public mutating func clear() -> [Int] {
        let ids = pending.flatMap(\.ids)
        pending = []
        return ids
    }
}

/// The wheel and the touchpad, turned into the swipe a finger would make. A finger that moves up
/// scrolls the content up, which is what a wheel turned toward the person does, so the swipe runs
/// against the scroll. Notches and smooth deltas are one currency, at most one swipe leaves every
/// ``minimumGap``, and what arrived in between is kept for the next one rather than lost.
public struct PreviewScrollAccumulator: Sendable {
    public enum Unit: Sendable { case notches, pixels }

    public static let threshold = 1.0
    public static let pixelsPerNotch = 40.0
    public static let minimumGap = 0.12
    public static let forgetAfter = 0.35
    public static let lengthPerNotch = 0.14
    public static let longest = 0.5
    public static let margin = 0.03

    public struct Reading: Sendable, Equatable {
        public var gesture: PreviewTouchGesture?
        public var flushAfter: Double?
    }

    private var across = 0.0
    private var down = 0.0
    private var lastEvent: Double?
    private var lastSwipe: Double?

    public init() {}

    public var isEmpty: Bool { across == 0 && down == 0 }

    public mutating func reset() {
        across = 0
        down = 0
        lastEvent = nil
    }

    public mutating func scroll(
        dx: Double, dy: Double, unit: Unit, at pointer: PreviewTouchPoint, now: Double
    ) -> Reading {
        if let lastEvent, now - lastEvent > Self.forgetAfter {
            across = 0
            down = 0
        }
        lastEvent = now
        let scale = unit == .pixels ? 1 / Self.pixelsPerNotch : 1
        across += dx * scale
        down += dy * scale
        return due(at: pointer, now: now)
    }

    /// Asked again after a ``Reading/flushAfter``: the swipe the gap held back, if it is still owed.
    public mutating func flush(at pointer: PreviewTouchPoint, now: Double) -> PreviewTouchGesture? {
        due(at: pointer, now: now).gesture
    }

    private mutating func due(at pointer: PreviewTouchPoint, now: Double) -> Reading {
        let vertical = abs(down) >= abs(across)
        let amount = vertical ? down : across
        guard abs(amount) >= Self.threshold else { return Reading() }
        if let lastSwipe, now - lastSwipe < Self.minimumGap {
            return Reading(gesture: nil, flushAfter: lastSwipe + Self.minimumGap - now)
        }
        lastSwipe = now
        across = 0
        down = 0
        return Reading(gesture: Self.swipe(notches: amount, vertical: vertical, centre: pointer), flushAfter: nil)
    }

    /// A positive amount is a wheel turned toward the person, or toward the right: the content
    /// moves up (left), so the finger does.
    static func swipe(notches: Double, vertical: Bool, centre: PreviewTouchPoint) -> PreviewTouchGesture {
        let length = min(longest, abs(notches) * lengthPerNotch)
        let travel = notches > 0 ? -length : length
        return gesture(
            centre: centre, motion: vertical ? (0, travel) : (travel, 0), length: length, seconds: 0.2 + length * 0.6)
    }

    /// A swipe of `length` along `motion`, centred on a point and slid inward if it would run off
    /// the picture, so a scroll near an edge is as long as one in the middle.
    static func gesture(
        centre: PreviewTouchPoint, motion: (x: Double, y: Double), length: Double, seconds: Double
    ) -> PreviewTouchGesture {
        let size = hypot(motion.x, motion.y)
        guard size > 0 else { return .tap(centre) }
        let unit = (x: motion.x / size * length / 2, y: motion.y / size * length / 2)
        func slide(_ low: Double, _ high: Double) -> Double {
            low < margin ? margin - low : (high > 1 - margin ? (1 - margin) - high : 0)
        }
        let shiftX = slide(centre.x - abs(unit.x), centre.x + abs(unit.x))
        let shiftY = slide(centre.y - abs(unit.y), centre.y + abs(unit.y))
        let middle = PreviewTouchPoint(x: centre.x + shiftX, y: centre.y + shiftY)
        return .swipe(
            from: PreviewTouchPoint(x: middle.x - unit.x, y: middle.y - unit.y),
            to: PreviewTouchPoint(x: middle.x + unit.x, y: middle.y + unit.y), seconds: seconds)
    }
}

/// Characters typed in a burst are sent as one string: the host spends a round trip on every
/// request, and a word typed at speed is a dozen of them otherwise. A key that is not a character
/// ends the burst, and what it ends goes first.
public struct PreviewTypingBuffer: Sendable {
    public static let window = 0.06

    private var held = ""

    public init() {}

    public var isEmpty: Bool { held.isEmpty }

    /// Holds a character. True when it began a burst, which is when the client starts the clock
    /// that will call ``flush()``.
    public mutating func type(_ character: Character) -> Bool {
        let began = held.isEmpty
        held.append(character)
        return began
    }

    public mutating func flush() -> PreviewTouchItem.Kind? {
        guard !held.isEmpty else { return nil }
        defer { held = "" }
        return .text(held)
    }

    /// A named key, with whatever was typed before it ahead of it.
    public mutating func key(_ name: String) -> [PreviewTouchItem.Kind] {
        var out: [PreviewTouchItem.Kind] = []
        if let text = flush() { out.append(text) }
        out.append(.key(name))
        return out
    }
}

/// What a key means while Keys is on. Anything with control or alt in it is the window's; a plain
/// key the simulator's US keyboard has is typed; Escape lets the keyboard go. A character the
/// keyboard has not got is taken and answered, rather than left to run a window shortcut.
public enum PreviewKeyAction: Sendable, Equatable {
    case type(Character)
    case key(String)
    case stopKeys
    case cannotType
}

public enum PreviewKeyReading {
    private static let keypad: [UInt32: Character] = [
        0xFFAA: "*", 0xFFAB: "+", 0xFFAD: "-", 0xFFAE: ".", 0xFFAF: "/", 0xFFBD: "=",
    ]

    public static func action(for chord: KeyChord) -> PreviewKeyAction? {
        guard !chord.control, !chord.alt else { return nil }
        switch chord.keyval {
        case Keymap.escape: return chord.shift ? nil : .stopKeys
        case Keymap.enter: return .key("return")
        case Keymap.backspace, 0xFFFF: return .key("delete")
        default: break
        }
        if let digit = Keymap.digit(chord.keyval), chord.keyval >= 0xFFB0 {
            return .type(Character(String(digit)))
        }
        if let mapped = keypad[chord.keyval] { return .type(mapped) }
        guard chord.keyval >= 0x20, chord.keyval < 0xFF00, let character = Keymap.scalar(chord.keyval) else { return nil }
        guard character.isASCII else { return .cannotType }
        if character.isLetter, chord.shift { return .type(Character(character.uppercased())) }
        return .type(character)
    }

    public static var cannotTypeWords: String {
        Localized.text("The simulator's keyboard types plain letters, digits and symbols only")
    }
}

/// How a touch looks the moment it is made, because the host can only show it once it has acted.
/// A ring opens at the press and settles; if the host is still working on it when the ring has
/// opened, the ring keeps its place and a light travels round it slowly, and it fades when the
/// touch is delivered or has failed. A drag leaves a line behind the pointer that fades. Everything
/// is a function of absolute time, so a client that stops asking when ``Frame/settled`` says so owns
/// no clock at all. Reduced motion keeps every fact and drops the movement: the ring stands at its
/// size and only changes light.
public struct PreviewTouchFeedback: Sendable {
    public static let openTime = 0.40
    public static let fadeTime = 0.30
    public static let trailLife = 0.5
    public static let trailFade = 0.35
    public static let abandonAfter = 20.0
    public static let smallestRadius = 0.025
    public static let largestRadius = 0.075
    public static let busyPeriod = 2.4
    public static let trailSpacing = 0.004
    public static let trailCapacity = 64

    public struct Ring: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var radius: Double
        public var alpha: Double
        public var busy: Bool
        public var angle: Double
    }

    public struct TrailPoint: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var alpha: Double
    }

    public struct Frame: Sendable, Equatable {
        public var rings: [Ring]
        public var trail: [TrailPoint]
        public var settled: Bool { rings.isEmpty && trail.isEmpty }

        public init(rings: [Ring], trail: [TrailPoint]) {
            self.rings = rings
            self.trail = trail
        }
    }

    private struct Ripple {
        var id: Int
        var x: Double
        var y: Double
        var start: Double
        var ended: Double?
        var held = true
    }

    private var ripples: [Ripple] = []
    private var points: [(x: Double, y: Double, at: Double)] = []
    private var released: Double?

    public init() {}

    public var isEmpty: Bool { ripples.isEmpty && points.isEmpty }
    public var rippleCount: Int { ripples.count }

    public mutating func press(id: Int, at point: PreviewTouchPoint, now: Double) {
        ripples.append(Ripple(id: id, x: point.x, y: point.y, start: now, ended: nil, held: true))
    }

    /// The finger came up: from here the touch is the host's to answer, and a ring that is still
    /// waiting says so. While the finger is down the ring is the person's own, and holds steady.
    public mutating func lift(_ id: Int) {
        for index in ripples.indices where ripples[index].id == id { ripples[index].held = false }
    }

    /// The touches with these ids reached the host, or were refused: either way the ring may go.
    public mutating func finish(_ ids: [Int], now: Double) {
        for index in ripples.indices where ids.contains(ripples[index].id) && ripples[index].ended == nil {
            ripples[index].ended = now
        }
    }

    public mutating func beginDrag(at point: PreviewTouchPoint, now: Double) {
        points = [(point.x, point.y, now)]
        released = nil
    }

    public mutating func drag(to point: PreviewTouchPoint, now: Double) {
        guard released == nil else { return }
        if let last = points.last, hypot(last.x - point.x, last.y - point.y) < Self.trailSpacing { return }
        points.append((point.x, point.y, now))
        if points.count > Self.trailCapacity { points.removeFirst(points.count - Self.trailCapacity) }
    }

    public mutating func endDrag(now: Double) {
        guard !points.isEmpty, released == nil else { return }
        released = now
    }

    public mutating func clear() {
        ripples = []
        points = []
        released = nil
    }

    /// Forgets what has faded out, and what was never answered.
    public mutating func prune(now: Double) {
        ripples.removeAll { ripple in
            if let ended = ripple.ended { return now - max(ended, ripple.start + Self.openTime) >= Self.fadeTime }
            return now - ripple.start >= Self.abandonAfter
        }
        if let released, now - released >= Self.trailFade {
            points = []
            self.released = nil
        }
    }

    public func frame(at now: Double, reducedMotion: Bool) -> Frame {
        Frame(
            rings: ripples.compactMap { ring(of: $0, now: now, reducedMotion: reducedMotion) },
            trail: trail(at: now))
    }

    private func ring(of ripple: Ripple, now: Double, reducedMotion: Bool) -> Ring? {
        let age = max(0, now - ripple.start)
        let opened = Self.largestRadius
        if age < Self.openTime {
            let progress = age / Self.openTime
            let eased = 1 - (1 - progress) * (1 - progress)
            let radius = reducedMotion ? opened : Self.smallestRadius + (opened - Self.smallestRadius) * eased
            let alpha = reducedMotion ? 0.7 : 0.85 - 0.35 * progress
            return Ring(x: ripple.x, y: ripple.y, radius: radius, alpha: alpha, busy: false, angle: 0)
        }
        let held = reducedMotion ? 0.7 : 0.5
        guard let ended = ripple.ended else {
            if ripple.held {
                return Ring(x: ripple.x, y: ripple.y, radius: opened, alpha: held, busy: false, angle: 0)
            }
            let turn = reducedMotion ? 0 : (age - Self.openTime).truncatingRemainder(dividingBy: Self.busyPeriod) / Self.busyPeriod * 360
            return Ring(x: ripple.x, y: ripple.y, radius: opened, alpha: held, busy: true, angle: turn)
        }
        let fading = now - max(ended, ripple.start + Self.openTime)
        guard fading < Self.fadeTime else { return nil }
        let alpha = held * (1 - fading / Self.fadeTime)
        let grown = reducedMotion ? 0 : 0.12 * (fading / Self.fadeTime)
        return Ring(x: ripple.x, y: ripple.y, radius: opened * (1 + grown), alpha: alpha, busy: false, angle: 0)
    }

    private func trail(at now: Double) -> [TrailPoint] {
        guard !points.isEmpty else { return [] }
        let after = released.map { max(0, 1 - (now - $0) / Self.trailFade) } ?? 1
        guard after > 0 else { return [] }
        return points.compactMap { point in
            let age = now - point.at
            let alpha = 0.75 * max(0, 1 - age / Self.trailLife) * after
            return alpha > 0.01 ? TrailPoint(x: point.x, y: point.y, alpha: alpha) : nil
        }
    }
}
