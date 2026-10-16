import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

typealias PreviewTouchSink = @Sendable (TouchRequest) async throws -> Void

private enum PreviewTouchLaneError: Error {
    case noHost
}

/// The one serial road a pane's touches take to the host: they leave in the order they were made,
/// one at a time, off the interface thread, and a touch that fails costs its own words and nothing
/// after it. The lane owns at most one task, which exists only while something is waiting, and
/// cancelling it forgets whatever has not gone.
final class PreviewTouchLane: @unchecked Sendable {
    private let tasks = LensTasks()
    private let lock = NSLock()
    private var queue = PreviewTouchQueue()
    private var sink: PreviewTouchSink?
    private var generation = 0
    private var draining = false
    private var inFlight: [Int] = []
    private var delivered = 0

    var onSettled: (@Sendable ([Int], Error?) -> Void)?

    var active: Int { tasks.active }

    var deliveredCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return delivered
    }

    var waiting: Int {
        lock.lock()
        defer { lock.unlock() }
        return queue.count
    }

    func setSink(_ new: PreviewTouchSink?) {
        lock.lock()
        sink = new
        lock.unlock()
    }

    /// Queues an item and returns the ids of any given up to make room.
    @discardableResult
    func submit(_ item: PreviewTouchItem) -> [Int] {
        lock.lock()
        let dropped = queue.enqueue(item)
        let starts = !draining
        draining = true
        let mine = generation
        lock.unlock()
        if starts {
            tasks.spawn(slot: "touch") { [weak self] in await self?.drain(mine) }
        }
        return dropped
    }

    /// Ends the task and forgets everything waiting. Returns the ids that will never be answered.
    @discardableResult
    func cancel() -> [Int] {
        lock.lock()
        generation += 1
        let forgotten = queue.clear() + inFlight
        inFlight = []
        draining = false
        lock.unlock()
        tasks.cancelAll()
        return forgotten
    }

    private enum Step {
        case stop
        case send(PreviewTouchItem, PreviewTouchSink?)
    }

    private func next(_ mine: Int) -> Step {
        lock.lock()
        defer { lock.unlock() }
        guard mine == generation else { return .stop }
        guard let item = queue.dequeue() else {
            draining = false
            return .stop
        }
        inFlight = item.ids
        return .send(item, sink)
    }

    private func finished(_ mine: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard mine == generation else { return false }
        inFlight = []
        delivered += 1
        return true
    }

    private func drain(_ mine: Int) async {
        while case .send(let item, let sink) = next(mine) {
            var failure: Error?
            do {
                guard let sink else { throw PreviewTouchLaneError.noHost }
                try await sink(item.request)
            } catch {
                failure = error
            }
            if Task.isCancelled || !finished(mine) { return }
            let ids = item.ids
            let verdict = failure
            let tell = onSettled
            Gtk.onMain { tell?(ids, verdict) }
        }
    }
}

/// The layer over a live preview's picture that operates it. A press and release is a tap or a
/// swipe, the wheel is a swipe a finger would make, characters and keys are forwarded, and every
/// one of them is answered on the spot: a ring at the press, a line behind a drag, a calm busy ring
/// while the host is still acting. The geometry, the timing and the rules are Core's; this class
/// only carries events in, marks out, and the lane between them.
///
/// The frame clock exists only while a ring or a trail is still moving, and a layer that has been
/// suspended owns no clock and no task.
final class PreviewTouchLayer: @unchecked Sendable {
    let widget: UnsafeMutablePointer<GtkWidget>
    var pictureSize: () -> (width: Int, height: Int)? = { nil }
    var onNote: (@Sendable (String) -> Void)?
    var onUnsupported: (@Sendable () -> Void)?

    private let lane = PreviewTouchLane()
    private var feedback = PreviewTouchFeedback()
    private var tracker: PreviewTouchTracker?
    private var scroll = PreviewScrollAccumulator()
    private var typing = PreviewTypingBuffer()
    private var pressID = 0
    private var nextID = 1
    private var pressPoint: (x: Double, y: Double)?
    private var dragging = false
    private var scrollTicket = 0
    private var typingTicket = 0
    private var tick: UInt = 0
    private var operating = false

    init() {
        widget = tailscode_touch_new(
            { raw, kind, x, y, a, b, width, height in
                guard let raw else { return }
                Unmanaged<PreviewTouchLayer>.fromOpaque(raw).takeUnretainedValue()
                    .event(Int(kind), x: x, y: y, a: a, b: b, width: width, height: height)
            }, nil)!
        g_object_ref(UnsafeMutableRawPointer(widget))
        tailscode_touch_bind(widget, Unmanaged.passUnretained(self).toOpaque())
        lane.onSettled = { [weak self] ids, error in self?.settled(ids, error) }
    }

    deinit {
        liftTick()
        tailscode_touch_detach(widget)
        g_object_unref(UnsafeMutableRawPointer(widget))
    }

    var activeTasks: Int { lane.active }
    var hasTick: Bool { tick != 0 }
    var isOperating: Bool { operating }
    var deliveredCount: Int { lane.deliveredCount }
    var waitingCount: Int { lane.waiting }
    var ringCount: Int { feedback.rippleCount }

    func setSink(_ sink: PreviewTouchSink?) {
        lane.setSink(sink)
    }

    /// Whether the pointer operates the picture. Taking it away lets go of a gesture in progress
    /// and leaves the rings already drawn to finish.
    func setOperating(_ on: Bool) {
        guard on != operating else { return }
        operating = on
        tailscode_touch_set_active(widget, on ? 1 : 0)
        if !on { abandonGesture() }
    }

    func retheme() {
        paint(feedback.frame(at: now, reducedMotion: reduced))
    }

    private var now: Double { Double(g_get_monotonic_time()) / 1_000_000 }
    private var reduced: Bool { tailscode_animations_enabled() == 0 }

    private func event(_ kind: Int, x: Double, y: Double, a: Double, b: Double, width: Double, height: Double) {
        guard operating else { return }
        switch kind {
        case 0: press(x: x, y: y, width: width, height: height)
        case 1: move(x: x, y: y, width: width, height: height)
        case 2: release(x: x, y: y)
        case 3: abandonGesture()
        case 4: wheel(dx: a, dy: b, unit: .notches, x: x, y: y, width: width, height: height)
        case 5: wheel(dx: a, dy: b, unit: .pixels, x: x, y: y, width: width, height: height)
        default: break
        }
    }

    private func press(x: Double, y: Double, width: Double, height: Double) {
        guard let picture = pictureSize() else { return }
        var next = PreviewTouchTracker(
            container: PreviewTouchSize(width: width, height: height),
            picture: PreviewTouchSize(width: Double(picture.width), height: Double(picture.height)))
        guard next.press(x: x, y: y, at: now),
            let point = PreviewTouchReading.fraction(
                x: x, y: y, container: PreviewTouchSize(width: width, height: height),
                picture: PreviewTouchSize(width: Double(picture.width), height: Double(picture.height)))
        else { return }
        tracker = next
        pressID = nextID
        nextID += 1
        pressPoint = (x, y)
        dragging = false
        feedback.press(id: pressID, at: point, now: now)
        arm()
    }

    private func move(x: Double, y: Double, width: Double, height: Double) {
        guard tracker != nil, let origin = pressPoint else { return }
        tracker?.move(x: x, y: y)
        guard hypot(x - origin.x, y - origin.y) >= PreviewTouchReading.movementThreshold || dragging,
            let picture = pictureSize()
        else { return }
        let size = PreviewTouchSize(width: Double(picture.width), height: Double(picture.height))
        let area = PreviewTouchSize(width: width, height: height)
        guard let here = PreviewTouchReading.clampedFraction(x: x, y: y, container: area, picture: size) else { return }
        if !dragging {
            dragging = true
            if let start = PreviewTouchReading.clampedFraction(x: origin.x, y: origin.y, container: area, picture: size) {
                feedback.beginDrag(at: start, now: now)
            }
        }
        feedback.drag(to: here, now: now)
        arm()
    }

    private func release(x: Double, y: Double) {
        guard var finished = tracker else { return }
        tracker = nil
        let id = pressID
        feedback.lift(id)
        if dragging { feedback.endDrag(now: now) }
        dragging = false
        pressPoint = nil
        guard let gesture = finished.release(x: x, y: y, at: now) else {
            feedback.finish([id], now: now)
            arm()
            return
        }
        send(PreviewTouchItem(ids: [id], kind: .pointer(gesture)))
        arm()
    }

    private func abandonGesture() {
        guard tracker != nil else { return }
        tracker = nil
        feedback.finish([pressID], now: now)
        if dragging { feedback.endDrag(now: now) }
        dragging = false
        pressPoint = nil
        arm()
    }

    private func wheel(
        dx: Double, dy: Double, unit: PreviewScrollAccumulator.Unit, x: Double, y: Double, width: Double, height: Double
    ) {
        let centre = scrollCentre(x: x, y: y, width: width, height: height)
        let reading = scroll.scroll(dx: dx, dy: dy, unit: unit, at: centre, now: now)
        if let gesture = reading.gesture { sendWheel(gesture) }
        if let wait = reading.flushAfter {
            scrollTicket += 1
            let ticket = scrollTicket
            Gtk.after(UInt32(max(1, (wait * 1000).rounded(.up)))) { [weak self] in
                self?.flushScroll(ticket, centre: centre)
            }
        }
    }

    private func scrollCentre(x: Double, y: Double, width: Double, height: Double) -> PreviewTouchPoint {
        guard let picture = pictureSize() else { return PreviewTouchPoint(x: 0.5, y: 0.5) }
        return PreviewTouchReading.clampedFraction(
            x: x, y: y, container: PreviewTouchSize(width: width, height: height),
            picture: PreviewTouchSize(width: Double(picture.width), height: Double(picture.height)))
            ?? PreviewTouchPoint(x: 0.5, y: 0.5)
    }

    private func flushScroll(_ ticket: Int, centre: PreviewTouchPoint) {
        guard ticket == scrollTicket, operating, let gesture = scroll.flush(at: centre, now: now) else { return }
        sendWheel(gesture)
    }

    private func sendWheel(_ gesture: PreviewTouchGesture) {
        if case .swipe(let from, let to, _) = gesture {
            feedback.beginDrag(at: from, now: now)
            feedback.drag(to: PreviewTouchPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2), now: now)
            feedback.drag(to: to, now: now)
            feedback.endDrag(now: now)
            arm()
        }
        send(PreviewTouchItem(ids: [], kind: .wheel(gesture)))
    }

    func type(_ character: Character) {
        if typing.type(character) {
            typingTicket += 1
            let ticket = typingTicket
            Gtk.after(UInt32(PreviewTypingBuffer.window * 1000)) { [weak self] in
                guard let self, ticket == self.typingTicket else { return }
                self.flushTyping()
            }
        }
    }

    func press(key name: String) {
        typingTicket += 1
        for kind in typing.key(name) { send(PreviewTouchItem(ids: [], kind: kind)) }
    }

    func pressHome() {
        send(PreviewTouchItem(ids: [], kind: .home))
    }

    func flushTypingNow() {
        typingTicket += 1
        flushTyping()
    }

    private func flushTyping() {
        if let kind = typing.flush() { send(PreviewTouchItem(ids: [], kind: kind)) }
    }

    private func send(_ item: PreviewTouchItem) {
        let dropped = lane.submit(item)
        if !dropped.isEmpty {
            feedback.finish(dropped, now: now)
            arm()
        }
    }

    private func settled(_ ids: [Int], _ error: Error?) {
        feedback.finish(ids, now: now)
        arm()
        guard let error else { return }
        if PreviewTouchReading.isUnsupported(error) { onUnsupported?() }
        onNote?(PreviewTouchReading.failure(error))
    }

    /// Lets go of everything: the gesture in hand, the touches waiting, the characters not yet
    /// sent, the rings and the clock. The pane is parked, hidden, pointed elsewhere or closing.
    func suspend() {
        scrollTicket += 1
        typingTicket += 1
        tracker = nil
        pressPoint = nil
        dragging = false
        scroll.reset()
        typing = PreviewTypingBuffer()
        _ = lane.cancel()
        feedback.clear()
        liftTick()
        paint(PreviewTouchFeedback.Frame(rings: [], trail: []))
        if operating {
            operating = false
            tailscode_touch_set_active(widget, 0)
        }
    }

    private func arm() {
        guard !feedback.isEmpty else { return }
        if tick == 0 {
            g_object_ref(UnsafeMutableRawPointer(widget))
            tick = UInt(
                tailscode_add_tick(
                    widget,
                    { raw in
                        guard let raw else { return }
                        Unmanaged<PreviewTouchLayer>.fromOpaque(raw).takeUnretainedValue().advance()
                    }, Unmanaged.passUnretained(self).toOpaque()))
            if tick == 0 { g_object_unref(UnsafeMutableRawPointer(widget)) }
        }
        paint(feedback.frame(at: now, reducedMotion: reduced))
    }

    private func liftTick() {
        guard tick != 0 else { return }
        tailscode_remove_tick(widget, guint(tick))
        tick = 0
        g_object_unref(UnsafeMutableRawPointer(widget))
    }

    /// One frame of the layer's work: forgets what has faded, draws what is left, and gives the
    /// clock back once nothing moves. The display's tick calls it; a harness with no mapped window
    /// calls it by hand.
    func advance() {
        let moment = now
        feedback.prune(now: moment)
        let frame = feedback.frame(at: moment, reducedMotion: reduced)
        paint(frame)
        if frame.settled { liftTick() }
    }

    private func paint(_ frame: PreviewTouchFeedback.Frame) {
        let rings = frame.rings.flatMap { [$0.x, $0.y, $0.radius, $0.alpha, $0.busy ? 1.0 : 0.0, $0.angle] }
        let trail = frame.trail.flatMap { [$0.x, $0.y, $0.alpha] }
        let ink = Self.ink()
        rings.withUnsafeBufferPointer { rings in
            trail.withUnsafeBufferPointer { trail in
                ink.withUnsafeBufferPointer { ink in
                    tailscode_touch_set_marks(
                        widget, rings.baseAddress, Int32(frame.rings.count), trail.baseAddress,
                        Int32(frame.trail.count), ink.baseAddress)
                }
            }
        }
    }

    private static func ink() -> [Double] {
        let rgb = PresenceRGB(hex: MatrixTheme.palette.accent) ?? PresenceRGB(red: 0.2, green: 0.8, blue: 0.4)
        return [rgb.red, rgb.green, rgb.blue]
    }

    func plan(width: Int, height: Int) -> (rings: [[Double]], trail: [[Double]]) {
        var out = [Double](repeating: 0, count: 2 + 5 * 64 + 3 * 64)
        let written = Int(tailscode_touch_plan(widget, Int32(width), Int32(height), &out, Int32(out.count)))
        guard written >= 2 else { return ([], []) }
        let ringCount = Int(out[0])
        let trailCount = Int(out[1])
        let rings = (0..<ringCount).map { Array(out[(2 + 5 * $0)..<(2 + 5 * $0 + 5)]) }
        let base = 2 + 5 * ringCount
        let trail = (0..<trailCount).map { Array(out[(base + 3 * $0)..<(base + 3 * $0 + 3)]) }
        return (rings, trail)
    }

    /// Delivers an event as if the pointer had done it, at a fraction of a layer of the given size.
    func point(kind: Int, fx: Double, fy: Double, a: Double = 0, b: Double = 0, width: Double, height: Double) {
        tailscode_touch_point(widget, Int32(kind), fx, fy, a, b, width, height)
    }
}
