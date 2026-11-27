import Foundation

/// The chats one pane has shown, in the order it showed them, with a place in that order: what a
/// mouse's Back and Forward buttons walk.
///
/// A trail holds each chat once. Opening a chat the trail already holds moves it to the end rather
/// than adding a second copy, so hopping between two chats from the list leaves exactly those two,
/// and Back and Forward are the hop. Opening a chat from the middle of the trail ends what lay
/// ahead of it, the way a browser does.
///
/// A step moves the place at once and the pane catches up once: `shown` is what the pane draws,
/// `settle()` says where it should go, and several steps taken before a frame ask for one chat, the
/// last, so a burst of presses never builds a chat it walked past.
public struct ChatTrail: Sendable, Equatable {
    public enum Direction: Sendable, Equatable {
        case back
        case forward
    }

    /// Far more than anyone walks back through, and small enough that the scan a step makes is
    /// never the cost.
    public static let limit = 64

    /// How long after a step the background work that would only matter to a chat that is being
    /// stayed in — the backfill of older rows, a redraw of the list — keeps out of the way. A hand
    /// hopping back and forth is on its next press well inside it, and the chat it leaves was
    /// never going to be read further up.
    public static let quiet: TimeInterval = 0.3

    public private(set) var visited: [ChatTarget] = []
    public private(set) var place = -1
    public private(set) var shown: ChatTarget?

    public init() {}

    public var current: ChatTarget? { visited.indices.contains(place) ? visited[place] : nil }
    public var canGoBack: Bool { place > 0 }
    public var canGoForward: Bool { place >= 0 && place < visited.count - 1 }

    /// The pane has opened `target`. Where the trail already stands on it, the visit is a step the
    /// trail made itself and changes nothing.
    public mutating func visit(_ target: ChatTarget) {
        shown = target
        if current == target { return }
        if place < visited.count - 1 { visited.removeSubrange((place + 1)...) }
        visited.removeAll { $0 == target }
        visited.append(target)
        if visited.count > Self.limit { visited.removeFirst(visited.count - Self.limit) }
        place = visited.count - 1
    }

    /// Moves the place one chat in `direction`, past any chat `reaching` refuses (one that is
    /// deleted, or already on screen in another pane), and answers where it landed. The chats
    /// passed over stay in the trail: a server that is only briefly out of the listing has not
    /// lost its chats.
    @discardableResult
    public mutating func step(
        _ direction: Direction, reaching: (ChatTarget) -> Bool
    ) -> ChatTarget? {
        guard let index = neighbourIndex(direction, reaching: reaching) else { return nil }
        place = index
        return visited[index]
    }

    /// The chat a step in `direction` would land on, without taking it: what is worth having ready
    /// before the next press.
    public func neighbour(_ direction: Direction, reaching: (ChatTarget) -> Bool) -> ChatTarget? {
        neighbourIndex(direction, reaching: reaching).map { visited[$0] }
    }

    /// The chat the pane should now be drawing, when it is not drawing it already. Taking it is
    /// what makes the pane's next draw the trail's own.
    public mutating func settle() -> ChatTarget? {
        guard let target = current, target != shown else { return nil }
        shown = target
        return target
    }

    /// A chat that is gone, from every place it was.
    public mutating func forget(_ target: ChatTarget) {
        guard let index = visited.firstIndex(of: target) else { return }
        visited.remove(at: index)
        if index <= place { place -= 1 }
        if place < 0 && !visited.isEmpty { place = 0 }
        if shown == target { shown = nil }
    }

    private func neighbourIndex(
        _ direction: Direction, reaching: (ChatTarget) -> Bool
    ) -> Int? {
        let stride = direction == .back ? -1 : 1
        var index = place + stride
        while visited.indices.contains(index) {
            if reaching(visited[index]) { return index }
            index += stride
        }
        return nil
    }
}

extension ChatTrail.Direction {
    /// What a button on a GDK pointer asks. GDK numbers the thumb buttons 8 and 9 for the side
    /// pair most mice carry, and 10 and 11 for the forward and back keys the kernel names apart
    /// from them; a mouse that reports either pair is read the way a browser reads it.
    public init?(gdkButton: Int) {
        switch gdkButton {
        case 8, 11: self = .back
        case 9, 10: self = .forward
        default: return nil
        }
    }

    /// What a button on an AppKit pointer asks: `NSEvent.buttonNumber` counts from zero, so the
    /// side pair is 3 and 4.
    public init?(cocoaButton: Int) {
        switch cocoaButton {
        case 3: self = .back
        case 4: self = .forward
        default: return nil
        }
    }
}
