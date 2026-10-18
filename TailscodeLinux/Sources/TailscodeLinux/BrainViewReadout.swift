import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension BrainView {
    /// The subject the readout takes now, which is the account's detail: Core's rule over the
    /// hovered step, the cursor, the replay, the dived zone and what the turn itself calls for, with
    /// one change. A cursor on a note or a thought has no detail of its own (the words are the
    /// account's), so the detail reads what the turn itself calls for beside them.
    func currentSubject(at clock: Double) -> NeuralReadout.Mode {
        let mode = model.readoutSubject(now: clock)
        if case .step(let id) = mode, let step = model.step(id: id),
            NeuralReading.isNote(step) || NeuralReading.isThought(step)
        {
            return turnSubject()
        }
        return mode
    }

    /// What the detail says when no step is the subject: the replay, the dived zone, the ask, what
    /// is happening now, or the digest of a settled turn.
    private func turnSubject() -> NeuralReadout.Mode {
        if model.isReplaying { return .replay }
        if let zone = model.divedZone { return .zone(zone) }
        if model.turn.outcome == .running {
            if let waiting = model.steps.first(where: {
                $0.status == .waitingApproval || $0.status == .waitingAnswer
            }) {
                return .ask(waiting.id)
            }
            return .now
        }
        return .digest
    }

    /// What the readout says right now, as Core reads it.
    func readoutValue(at clock: Double) -> NeuralReadout {
        let metrics = currentMetrics
        return NeuralReadout.make(
            model: model, subject: currentSubject(at: clock), now: Date(), tz: .current, clock: clock,
            answer: row.answer.isEmpty ? nil : row.answer, outputLines: metrics.outputLinesShown)
    }

    /// Brings the account and the detail beside it to what the model says, and puts the leader on
    /// the step they are about. Only a change of subject builds anything in the detail; the same
    /// words arriving again are left alone, and a layout with no detail builds none.
    func refreshReadout(animate: Bool) {
        guard stage != nil, phase != .closed || moveState != nil || pendingOpen != nil else { return }
        account?.refresh()
        let now = BrainClock.now
        let metrics = currentMetrics
        guard readoutIsShown else {
            updateLeader(stepID: metrics.hasLeader ? leaderStep(for: nil) : nil)
            scheduleReadoutChange(after: now)
            return
        }
        let value = readoutValue(at: now)
        let stamp = BrainReadout.Stamp(look: MatrixTheme.palette.name, lines: metrics.outputLinesShown)
        readout?.show(value, stamp: stamp, animate: animate && moveState == nil)
        if let readout { announceIfNeeded(readout) }
        updateLeader(stepID: leaderStep(for: value))
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
                guard let self, !self.disposed, self.readoutTicket == ticket, !self.isSuspended else { return }
                self.refreshReadout(animate: true)
            }
        }
    }
}
