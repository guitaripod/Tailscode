import UIKit

/// Runs `work` once, when the display next asks for a frame: the first moment at which whatever
/// was committed in this turn of the run loop is on its way to the glass. Held by whoever asks,
/// and dropped to cancel.
@MainActor
final class NextFrame {
    nonisolated(unsafe) private var link: CADisplayLink?
    private let work: () -> Void

    init(_ work: @escaping () -> Void) {
        self.work = work
        let link = CADisplayLink(target: self, selector: #selector(fire))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    deinit { link?.invalidate() }

    @objc private func fire() {
        link?.invalidate()
        link = nil
        work()
    }
}
