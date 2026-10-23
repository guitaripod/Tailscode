import TailscodeCore
import UIKit

extension BrainOpenView {
    /// While a replay plays, the cursor is the step that is firing, so the ring, the leader, the
    /// list and the account all follow the playhead.
    private func followReplay(model: NeuralBrainModel, time: Double) {
        guard model.isReplaying, let at = model.replayTime(now: time),
            let index = model.timeline.activeStep(at: at), model.steps.indices.contains(index)
        else {
            followedReplayStep = nil
            return
        }
        let id = model.steps[index].id
        guard id != followedReplayStep else { return }
        followedReplayStep = id
        Theme.Haptics.step()
        madeAccount?.suppressRevealOnce(id)
        browse(.click(id, double: false))
    }

    func footerRead(model: NeuralBrainModel, time: Double) {
        guard let store else { return }
        followReplay(model: model, time: time)
        footer.show(
            model: model, answer: store.answerText(for: turnID), now: time,
            replaying: { if case .replaying = model.mode { return true } else { return false } }())
    }

    func toggleReplay() {
        guard let store, let model = store.model(for: turnID) else { return }
        Theme.Haptics.tap()
        let now = CACurrentMediaTime()
        switch model.mode {
        case .live:
            guard model.turn.outcome != .running else { return }
            store.mutate(turnID) { $0.startReplay(now: now) }
        case .replaying:
            let fraction = model.replayFraction(now: now) ?? 0
            store.mutate(turnID) { $0.scrub(to: fraction) }
        case .scrubbing(let fraction):
            let elapsed = model.timeline.time(forFraction: fraction)
            store.mutate(turnID) { $0.startReplay(now: now - elapsed) }
        }
        refreshAll(fromBrowse: true)
    }

    func startReplay() {
        guard let store, let model = store.model(for: turnID), model.turn.outcome != .running else { return }
        store.mutate(turnID) { $0.startReplay(now: CACurrentMediaTime()) }
        refreshAll(fromBrowse: true)
    }

    func scrubBegan() {
        guard let store, let model = store.model(for: turnID) else { return }
        let fraction = model.replayFraction(now: CACurrentMediaTime()) ?? 1
        store.mutate(turnID) { $0.scrub(to: fraction) }
    }

    func scrubbed(to fraction: Double) {
        store?.mutate(turnID) { $0.scrub(to: fraction) }
        stage.refresh()
        if let model = browseModel { footerRead(model: model, time: CACurrentMediaTime()) }
    }

    func scrubEnded() {
        store?.mutate(turnID) { $0.endScrub() }
        refreshAll(fromBrowse: true)
    }

    func toggleText(_ id: String) {
        if env.interaction.expandedText.contains(id) {
            env.interaction.expandedText.remove(id)
        } else {
            env.interaction.expandedText.insert(id)
        }
        madeAccount?.restyle()
    }

    func toggleWork(_ id: String) {
        if env.interaction.unfolded.contains(id) {
            env.interaction.unfolded.remove(id)
        } else {
            env.interaction.unfolded.insert(id)
        }
        madeAccount?.restyle()
    }

    func moreRows(_ id: String) {
        let current = env.interaction.rowCaps[id] ?? 40
        env.interaction.rowCaps[id] = min(current + 40, 400)
        madeAccount?.restyle()
    }

    func setOutputExpanded(_ expanded: Bool) {
        store?.mutate(turnID) { $0.setBrowseOutputExpanded(expanded) }
        env.outputExpanded = expanded
        madeAccount?.restyle()
    }

    func diveChanged(_ zone: NeuralZone?) {
        guard let model = browseModel else { return }
        if let zone {
            if model.stepList.filter.zones != [zone] { browse(.zoneChip(zone, solo: true)) }
        } else {
            let only = model.stepList.filter.zones
            if only.count == 1, let zone = only.first { browse(.zoneChip(zone, solo: true)) }
        }
    }

    func menu(for id: String) -> [UIMenuElement] {
        guard let row = browseModel?.stepList.row(id: id) else { return [] }
        return NeuralBrowse.menuItems(for: row).map { item in
            UIAction(title: NeuralBrowse.title(of: item)) { [weak self] _ in
                self?.browse(.menu(item, id))
            }
        }
    }
}
