import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension BrainView {
    /// The pointer is over a node of the head, or over none for nil: the readout previews it and
    /// the list marks its row, and the cursor stays where it is.
    func stagePointer(over id: String?) {
        routeHover(id, delay: 0)
    }

    func stageFocus(_ entered: Bool) {
        stageFocused = entered
        if entered, model.browseFocus != .list { model.setBrowseFocus(.list) }
        afterSelection()
    }

    func readoutPointer(inside: Bool) {
        model.readoutPointer(inside: inside, at: BrainClock.now)
        readoutHeld = inside
        refreshReadout(animate: true)
    }

    /// A relation chip under the pointer lights the steps it names, without taking the panel.
    func relationHover(_ ids: [String]?) {
        if let ids, let first = ids.first {
            model.setHover(first)
        } else {
            model.setHover(nil)
        }
        stage?.invalidate()
        redrawNow()
    }

    func stripHover(_ id: String?) {
        routeHover(id, delay: NeuralHoverGrace.intentDelay)
    }

    func stripScrub(toStep id: String) {
        guard let index = model.steps.firstIndex(where: { $0.id == id }) else { return }
        let fires = model.timeline.fireTimes
        guard index < fires.count else { return }
        scrub(to: model.timeline.fraction(forTime: fires[index]))
    }

    func stripScrubEnded() {
        endScrub()
    }

    func hover(_ id: String?) {
        stagePointer(over: id)
    }

    /// Puts the cursor on a step: what a click on its row or its node does.
    func pin(_ id: String) {
        browse(.click(id, double: false))
    }

    func clearSelection() {
        hoverApplied = nil
        pendingHover = nil
        model.pointer(over: nil, at: BrainClock.now - 10)
        browse(.hoverLeft, grabFocus: false)
        model.clearSelection()
        model.setProvenance(token: nil)
        announcement = nil
        afterSelection()
    }

    func point(at token: String?) {
        model.setProvenance(token: token)
        afterSelection()
    }

    /// The Esc ladder, for the harness: the legend, the search, the filters, the cursor, then the
    /// brain itself.
    func escapePressed() -> Bool {
        _ = brainKey(keyval: UInt32(GDK_KEY_Escape), state: 0)
        return true
    }

    func afterSelection() {
        stage?.modelChanged()
        refreshReadout(animate: true)
        redrawNow()
        updateClock()
    }

    /// Whether a double press on this node opens a sub-agent rather than only taking the cursor.
    func opensSubagent(_ id: String) -> Bool {
        guard let step = model.step(id: id) else { return false }
        return step.isCard && step.zone == .delegate
    }

    /// The node that rings a step and the number its callout shows beside it.
    func ringed(_ id: String?) -> BrainScene.Ring? {
        guard let id, let row = model.browseState.list.row(id: id) else { return nil }
        return BrainScene.Ring(node: model.browseState.list.nodeID(of: id), number: row.number)
    }

    func openSubagent(of id: String) {
        guard let step = model.step(id: id), step.isCard, step.zone == .delegate else {
            pin(id)
            return
        }
        context?.openSubagent?(step.id)
    }

    func goToApproval() {
        host?.revealApproval?()
    }

    func diveChanged() {
        refreshReadout(animate: true)
        relayout()
    }

    func dive(into zone: NeuralZone) {
        stage?.dive(into: zone)
    }

    /// Opens the brain already diving into a zone, from the card's chip.
    func openDiving(into zone: NeuralZone) {
        host?.pendingDive[turnID] = zone
        toggleOpen()
    }

    func applyPendingDive() {
        guard let zone = host?.pendingDive.removeValue(forKey: turnID) else { return }
        stage?.dive(into: zone)
    }

    /// Opens the poster sheet for this turn as it stands at rest.
    func presentShare() {
        guard model.turn.outcome != .running, let root = gtk_widget_get_root(widget) else { return }
        BrainShareDialog.present(
            model: model, prompt: row.prompt, parent: ptr(UnsafeMutableRawPointer(root)))
    }

    func toggleRows() {
        host?.toggleRows(turnID: turnID)
    }

    func focusStage() {
        if let stage { gtk_widget_grab_focus(stage.hit) }
    }

    func walkStep(_ direction: Int) {
        browse(.key(direction < 0 ? .up : .down))
    }

    func dive(_ zone: NeuralZone?) {
        stage?.dive(into: zone)
    }

    func driveChip(_ index: Int?) {
        guard let index else {
            point(at: nil)
            return
        }
        let unique = answerChips
        guard index >= 1, index <= unique.count else { return }
        point(at: unique[index - 1])
    }

    func scrub(to fraction: Double) {
        model.scrub(to: fraction)
        afterReplayChange()
    }

    func endScrub() {
        model.endScrub()
        afterReplayChange()
    }

    func toggleReplay() {
        if model.isReplaying {
            model.stopReplay()
            afterReplayChange()
            return
        }
        guard model.turn.outcome != .running else { return }
        if !row.open {
            replayWhenOpen = true
            host?.setOpen(true, turnID: turnID)
            return
        }
        model.startReplay(now: BrainClock.now)
        afterReplayChange()
    }

    func afterReplayChange() {
        card.refresh()
        stage?.invalidate()
        refreshReadout(animate: false)
        footer?.sync(BrainClock.now)
        relayout()
        redrawNow()
        updateClock()
    }

    func toggleOpen() {
        host?.toggleOpen(turnID: turnID)
    }

    var accessibleLabel: String { announcement ?? model.spoken }

    // MARK: the clock

    /// Marks the picture stale and lets the clock draw it on its next frame, which is at most
    /// thirty a second whatever number of states arrive between.
    func redrawNow() {
        card.redraw()
        guard stage != nil else { return }
        needsDraw = true
        updateClock()
    }

    func step(_ time: Double) {
        card.tickLive(time)
        if moveState != nil {
            moveStep(time)
            return
        }
        if model.replayDone(now: time) {
            model.stopReplay()
            card.refresh()
            stage?.invalidate()
            relayout()
        }
        needsDraw = false
        var mark = DispatchTime.now().uptimeNanoseconds
        func lap(_ name: String) {
            let now = DispatchTime.now().uptimeNanoseconds
            tickCosts[name, default: 0] += now - mark
            mark = now
        }
        if let stage { stage.step(time) }
        lap("stage")
        if model.isReplaying || time - lastFooterSync > 0.5 {
            lastFooterSync = time
            footer?.sync(time)
        }
        lap("footer")
        readout?.tickPulses()
        account?.tickPulses()
        lap("pulses")
        list?.tick(time)
        account?.tick(time)
        account?.tickSecond(time)
        lap("list")
        tickLeader(time)
        lap("leader")
        if model.isReplaying || (model.turn.outcome == .running && time - lastReadoutTick > 0.25) {
            lastReadoutTick = time
            refreshReadout(animate: false)
        }
        lap("readout")
        tickCount += 1
        if contentFade != nil {
            let alpha = NeuralTransition.firstContentAlpha(after: time - contentFadeStart)
            readout?.setBodyAlpha(alpha)
            if alpha >= 1 { contentFade = nil }
        }
        updateClock()
    }

    func updateClock() {
        guard !isSuspended else {
            clock.stop()
            return
        }
        if frozen {
            clock.stop()
            return
        }
        var tempo: NeuralTempo = .stopped
        if stage != nil, BrainBudget.stageAllowed {
            tempo = model.tempo(reduceMotion: BrainBudget.reduceMotion)
            if tempo == .activity, model.turn.outcome != .running, !model.isReplaying {
                tempo = .stopped
            }
            if needsDraw, tempo == .stopped { tempo = .activity }
        }
        let busy = leaderAnimating || contentFade != nil || (list?.isAnimating ?? false) || (account?.isAnimating ?? false)
        let moving = moveState != nil || (busy && isVisible)
        let now = BrainClock.now
        if tempo == .stopped, isVisible, card.needsLiveClock(at: now) {
            tempo = card.isSettling(at: now) ? .display : .activity
        }
        if moving { tempo = .display }
        if tempo != .stopped, !moving, !isVisible { tempo = .stopped }
        clock.run(on: widget, tempo: tempo)
    }

    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        clock.stop()
        stage?.suspend()
        readoutTicket += 1
        if let move = moveState { finishMove(snapTo: move.opening) }
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        stage?.resume()
        card.refresh()
        redrawNow()
        updateClock()
    }

    // MARK: harness readings

    /// How many widgets this brain's row holds right now.
    var widgetCount: Int {
        func count(_ node: UnsafeMutablePointer<GtkWidget>) -> Int {
            var total = 1
            var child = gtk_widget_get_first_child(node)
            while let held = child {
                total += count(held)
                child = gtk_widget_get_next_sibling(held)
            }
            return total
        }
        return count(widget)
    }

    var performance: String {
        guard let stage else { return "no stage" }
        let timings = stage.timings
        return String(
            format: "full=%.0fus x%d delta=%.0fus x%d size=%dx%d surfaces=%dKB renderer=%d",
            timings.full, timings.fulls, timings.delta, timings.deltas, stage.size.width,
            stage.size.height, stage.footprint / 1024, stage.hasRenderer ? 1 : 0)
    }

    /// What each part of a clock tick has cost on average, for the harness.
    var tickReading: String {
        guard tickCount > 0 else { return "no ticks" }
        return tickCosts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value / UInt64(tickCount) / 1000)us" }.joined(separator: " ") + " ticks=\(tickCount)"
    }

    var reading: String {
        let timings = stage?.timings
        return "turn=\(turnID) open=\(row.open) phase=\(phase) stage=\(stage != nil) renderer=\(stage?.hasRenderer == true) visible=\(isVisible) mapped=\(gtk_widget_get_mapped(widget)) "
            + "clock=\(clock.isRunning)/\(clock.tempo) steps=\(model.steps.count) nodes=\(model.nodeCount) "
            + "selected=\(model.selected ?? "-") pinned=\(model.pinned ?? "-") "
            + "focus=\(stage.map { gtk_widget_has_focus($0.hit) != 0 } ?? false) "
            + "state=\(model.state.label) running=\(model.steps.filter { $0.status == .running }.count) "
            + "outcome=\(model.turn.outcome) replay=\(model.isReplaying) frames=\(stage?.frames ?? 0) fulls=\(timings?.fulls ?? 0) "
            + "deltas=\(timings?.deltas ?? 0) height=\(gtk_widget_get_height(widget)) \(card.reading) "
            + "readout=[\(readout?.reading ?? "-")] leader=\(leaderState.reading) account=[\(account?.reading ?? "-")]"
    }
}
