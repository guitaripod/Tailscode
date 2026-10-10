import Foundation
import TailscodeCore

/// When a rail's plate opens and when it goes, with no toolkit in it: a pointer that rests on a
/// rail for ``restDelay`` opens the plate, one that has left both the rail and the plate takes it
/// down ``leaveDelay`` later, and escape takes it down at once and keeps it down until the pointer
/// has been somewhere else. The clock is handed in, so the same arithmetic is proven here with a
/// fake one and drives the transcript with the real one.
final class RailHoverMachine: @unchecked Sendable {
    /// What the pointer is over. The id is the rail's own, so a plate that belongs to one rail is
    /// never kept open by another.
    enum Target: Equatable {
        case rail(Int)
        case plate(Int)
    }

    static let restDelay: UInt32 = 120
    static let leaveDelay: UInt32 = 250

    var onOpen: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?

    private let schedule: (UInt32, @escaping @Sendable () -> Void) -> Void
    private(set) var open: Int?
    private(set) var dwelling: Int?
    private var held: Int?
    private var openToken: UInt = 0
    private var closeToken: UInt = 0
    private var closePending = false
    private var suspended = false

    init(schedule: @escaping (UInt32, @escaping @Sendable () -> Void) -> Void) {
        self.schedule = schedule
    }

    /// While a menu belonging to the plate is up, the pointer is on the menu, which is neither rail
    /// nor plate, and the plate must not be taken down from under it.
    func suspend(_ on: Bool) {
        suspended = on
        guard !on else {
            closeToken &+= 1
            closePending = false
            return
        }
    }

    /// Reports where the pointer is, on every move.
    func move(over target: Target?) {
        switch target {
        case .rail(let id):
            cancelClose()
            if held == id { return }
            if open == id { dwelling = nil; return }
            if dwelling == id { return }
            openToken &+= 1
            dwelling = id
            let token = openToken
            schedule(Self.restDelay) { [weak self] in
                guard let self, self.openToken == token, self.dwelling == id else { return }
                self.dwelling = nil
                self.show(id)
            }
        case .plate(let id):
            cancelClose()
            openToken &+= 1
            dwelling = nil
            if open != id { return }
        case nil:
            held = nil
            openToken &+= 1
            dwelling = nil
            guard open != nil, !closePending, !suspended else { return }
            closePending = true
            let token = closeToken
            schedule(Self.leaveDelay) { [weak self] in
                guard let self, self.closeToken == token, self.closePending else { return }
                self.closePending = false
                self.hide()
            }
        }
    }

    /// A click or a key on the rail: opens at once, or closes if it was open, and does not reopen
    /// the moment the pointer is still resting on it.
    func toggle(_ id: Int) {
        if open == id {
            held = id
            hide()
        } else {
            held = nil
            show(id)
        }
    }

    /// Escape: down at once, and kept down while the pointer stays where it is.
    func escape() {
        guard let id = open ?? dwelling else { return }
        held = id
        openToken &+= 1
        dwelling = nil
        hide()
    }

    /// The rail went away (its row was rebuilt, its chat left).
    func forget(_ id: Int) {
        if dwelling == id { dwelling = nil; openToken &+= 1 }
        if held == id { held = nil }
        if open == id { hide() }
    }

    private func show(_ id: Int) {
        if let current = open, current != id { hide() }
        cancelClose()
        guard open != id else { return }
        open = id
        onOpen?(id)
    }

    private func hide() {
        cancelClose()
        guard let id = open else { return }
        open = nil
        onClose?(id)
    }

    private func cancelClose() {
        closeToken &+= 1
        closePending = false
    }
}

/// Where the plate of a rail goes, in the transcript overlay's own coordinates: below the rail when
/// the viewport has room, above it when it has not (the tail of a live conversation always has not,
/// and the plate must not sit over the line that is still working), and when neither side holds it
/// the side with more room. Pulled sideways to stay inside the overlay.
enum LinkRailPlacement {
    struct Spot: Equatable {
        let x: Double
        let y: Double
        let upward: Bool
    }

    static let gap: Double = 2

    static func place(
        railX: Double, railY: Double, railHeight: Double, overlayWidth: Double,
        overlayHeight: Double, plateWidth: Double, plateHeight: Double
    ) -> Spot {
        let roomBelow = overlayHeight - (railY + railHeight)
        let roomAbove = railY
        var upward = LinkRailPlate.opensUpward(roomBelow: roomBelow, plateHeight: plateHeight + gap)
        if upward, roomAbove < plateHeight + gap, roomAbove < roomBelow { upward = false }
        let y = upward ? railY - plateHeight - gap : railY + railHeight + gap
        let x = max(0, min(railX, overlayWidth - plateWidth))
        return Spot(x: x, y: max(0, y), upward: upward)
    }
}
