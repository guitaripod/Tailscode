import Foundation
import UIKit

/// The one clock every visible live card shares. A running turn's card counts seconds, learns
/// that it has been silent for forty of them, and lets a note go after it has held the line; none
/// of that is animation, so none of it asks for a display link. One timer ticks once a second while
/// at least one live card is in a window and stops when the last one leaves, and a settled card
/// never registers at all.
@MainActor
final class BrainLiveClock {
    static let shared = BrainLiveClock()

    private final class Entry {
        weak var owner: AnyObject?
        let tick: () -> Void
        init(owner: AnyObject, tick: @escaping () -> Void) {
            self.owner = owner
            self.tick = tick
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var timer: Timer?
    private(set) var ticks = 0

    var isRunning: Bool { timer != nil }
    var registered: Int { entries.count }

    func register(_ owner: AnyObject, tick: @escaping () -> Void) {
        entries[ObjectIdentifier(owner)] = Entry(owner: owner, tick: tick)
        start()
    }

    func unregister(_ owner: AnyObject) {
        entries[ObjectIdentifier(owner)] = nil
        if entries.isEmpty { stop() }
    }

    private func start() {
        guard timer == nil else { return }
        let made = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        made.tolerance = 0.1
        RunLoop.main.add(made, forMode: .common)
        timer = made
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func fire() {
        ticks += 1
        for (id, entry) in entries {
            guard entry.owner != nil else {
                entries[id] = nil
                continue
            }
            entry.tick()
        }
        if entries.isEmpty { stop() }
    }
}
