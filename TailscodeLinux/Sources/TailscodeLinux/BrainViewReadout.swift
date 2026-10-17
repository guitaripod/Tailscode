import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension BrainView {
    /// The subject the readout takes now: Core's rule over the pinned step, the node the pointer
    /// has rested on, the replay, the dived zone and what the turn itself calls for, with the
    /// node the keyboard is on standing in for the pointer when nothing outranks it.
    func currentSubject(at clock: Double) -> NeuralReadout.Mode {
        var mode = model.readoutSubject(now: clock)
        if let walked = focusedStep, model.step(id: walked) != nil {
            switch mode {
            case .digest, .now, .ask: mode = .step(walked)
            default: break
            }
        }
        return mode
    }

    /// What the readout says right now, as Core reads it.
    func readoutValue(at clock: Double) -> NeuralReadout {
        let metrics = currentMetrics
        return NeuralReadout.make(
            model: model, subject: currentSubject(at: clock), now: Date(), tz: .current, clock: clock,
            answer: row.answer.isEmpty ? nil : row.answer, outputLines: metrics.outputLinesShown)
    }

    /// Puts the readout, the strip and the leader on what the subject is. Only a change of
    /// subject builds anything; the same words arriving again are left alone.
    func refreshReadout(animate: Bool) {
        guard stage != nil, phase != .closed || moveState != nil || pendingOpen != nil else { return }
        let now = BrainClock.now
        let value = readoutValue(at: now)
        let metrics = currentMetrics
        let stamp = BrainReadout.Stamp(look: MatrixTheme.palette.name, lines: metrics.outputLinesShown)
        readout?.show(value, stamp: stamp, animate: animate && moveState == nil)
        strip?.show(value, inks: inks)
        if let readout { announceIfNeeded(readout) }
        updateLeader(for: value)
        let expanded = stackedExpanded
        if expanded != lastStackedExpanded {
            lastStackedExpanded = expanded
            host?.anchor?()
            relayout()
        }
        scheduleReadoutChange(after: now)
    }

    private func announceIfNeeded(_ readout: BrainReadout) {
        if let said = readout.shown?.announcement { announcement = said }
    }

    /// Wakes the readout at the next moment its subject changes by itself: a node rested on long
    /// enough, a grace that has run out. Nothing polls.
    func scheduleReadoutChange(after now: Double) {
        readoutTicket += 1
        let ticket = readoutTicket
        guard let next = model.nextReadoutChange(after: now) else { return }
        let milliseconds = UInt32(max(1, min(5000, ((next - now) * 1000).rounded(.up) + 1)))
        Gtk.after(milliseconds) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.readoutTicket == ticket, !self.isSuspended else { return }
                self.refreshReadout(animate: true)
            }
        }
    }
}
