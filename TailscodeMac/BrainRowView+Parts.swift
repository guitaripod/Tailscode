import AppKit
import CodingAgentKit
import TailscodeCore

extension BrainRowView {
    /// Builds every part of the open brain, without showing them.
    func makeParts() {
        var rest = schedule ?? NeuralOpenSchedule()
        schedule = nil
        for part in rest.remaining() { build(part) }
    }

    /// Builds the parts the schedule says are due on this tick of the opening move.
    func buildDueParts(frame: Int, progress: Double) {
        guard var held = schedule else { return }
        let due = held.due(frame: frame, progress: progress)
        schedule = held.isComplete ? nil : held
        for part in due { build(part, paced: true) }
    }

    /// Builds the parts the opening move has not reached yet, for a move that ends first.
    func completeParts() {
        guard var held = schedule else { return }
        schedule = nil
        for part in held.remaining() { build(part) }
    }

    private func build(_ part: NeuralOpenPart, paced: Bool = false) {
        switch part {
        case .head: buildHead()
        case .steps: buildSteps()
        case .nodes: stage?.beginOverlay()
        case .account: buildAccount(paced: paced)
        case .story: account?.refresh(immediate: true)
        case .footer: buildFooter()
        }
    }

    /// How many of the account's items are made on one frame of the move that opens it.
    private static let itemsPerFrame = 3

    private func buildHead() {
        guard stage == nil else { return }
        let made = BrainStageView(turnID: turnID, host: self)
        made.onActivity = { [weak self] in self?.stageActivity() }
        made.onDive = { [weak self] zone in self?.diveChanged(zone) }
        made.head.onReady = { [weak self] in self?.needsLayout = true }
        made.drawsOverlay = false
        carrier.addSubview(made)
        addSubview(wordmark, positioned: .above, relativeTo: nil)
        stage = made
        if !parkReasons.isEmpty { made.park() }
        made.refresh(force: true)
    }

    private func buildSteps() {
        guard list == nil else { return }
        let m = currentMetrics
        let chipView = BrainFilterChips(host: self)
        let listView = BrainListView(host: self)
        addSubview(chipView)
        addSubview(listView)
        chips = chipView
        list = listView
        chipView.configure(metrics: m)
        listView.configure(metrics: m)
        syncBrowse()
    }

    private func buildAccount(paced: Bool) {
        guard account == nil else { return }
        let accountView = BrainAccountView(host: self)
        if paced { accountView.makeCap = Self.itemsPerFrame }
        let carrier = BrainCarrierView()
        carrier.addSubview(accountView)
        addSubview(carrier)
        slide = carrier
        account = accountView
    }

    private func buildFooter() {
        guard footer == nil else { return }
        let footerView = BrainFooterView(host: self)
        addSubview(footerView)
        footer = footerView
        footerView.onReplay = { [weak self] in self?.toggleReplay() }
        footerView.onScrub = { [weak self] fraction in self?.scrub(to: fraction) }
        footerView.onScrubEnd = { [weak self] in self?.endScrub() }
        footerView.onShare = { [weak self] in self?.presentShare() }
        footerView.onRows = { [weak self] in self?.toggleRows() }
        footerView.onClose = { [weak self] in self?.collapseBrain() }
        footerView.onChipHover = { [weak self] token in self?.pointAt(token: token, hold: false) }
        footerView.onChipPress = { [weak self] token in self?.pointAt(token: token, hold: true) }
        footerView.sync(now: BrainClock.now)
    }

    /// Lets the views go one to a turn: the account's items and the head's layers cost a few
    /// milliseconds each to take down, and a move that ends by taking all of them down in the turn
    /// it ends in dropped a frame at its last step. They are hidden at once and taken out later.
    private func bury(_ views: [NSView]) {
        for view in views { view.isHidden = true }
        graveyard += views
        scheduleBurial()
    }

    private func scheduleBurial() {
        guard !burialScheduled, !graveyard.isEmpty else { return }
        burialScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.012) { [weak self] in
            guard let self else { return }
            self.burialScheduled = false
            if !self.graveyard.isEmpty { self.graveyard.removeFirst().removeFromSuperview() }
            self.scheduleBurial()
        }
    }

    func dropParts() {
        schedule = nil
        guard stage != nil else { return }
        returnFocusFromBrain()
        dismissLegend()
        bury([slide, list, chips, footer, stage].compactMap { $0 as NSView? })
        stage = nil
        chips = nil
        list = nil
        account = nil
        slide = nil
        footer = nil
        hoverApplied = nil
        pendingHover = nil
        hoverFlush?.invalidate()
        graceTimerStore?.invalidate()
        leader.clear()
        updateModel {
            $0.clearSelection()
            $0.browse(.hoverLeft)
            $0.setBrowseFocus(.list)
            $0.setProvenance(token: nil)
            $0.setDiving(false)
            $0.setDive(zone: nil)
            if $0.isReplaying { $0.stopReplay() }
        }
        announcement = nil
    }
}
