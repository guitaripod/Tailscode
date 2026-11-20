import QuartzCore
import UIKit

/// A motion stepped from the display's own clock, one frame at a time, for as long as `step` says
/// there is more of it. Used where a toolkit animation would only lay out the frame it ends on.
@MainActor
final class FrameStepper: NSObject {
    private var link: CADisplayLink?
    private var began: CFTimeInterval?
    private let step: (TimeInterval) -> Bool

    init(step: @escaping (TimeInterval) -> Bool) {
        self.step = step
        super.init()
        let link = CADisplayLink(target: FrameStepperTarget(self), selector: #selector(FrameStepperTarget.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    var isRunning: Bool { link != nil }

    fileprivate func tick(_ link: CADisplayLink) {
        let started = began ?? link.timestamp
        began = started
        if !step(link.targetTimestamp - started) { stop() }
    }
}

/// Holds the stepper weakly, so the display link's strong hold on its target never keeps a
/// motion alive past the screen that wanted it.
private final class FrameStepperTarget: NSObject {
    weak var stepper: FrameStepper?

    init(_ stepper: FrameStepper) {
        self.stepper = stepper
    }

    @MainActor @objc func tick(_ link: CADisplayLink) {
        guard let stepper else {
            link.invalidate()
            return
        }
        stepper.tick(link)
    }
}
