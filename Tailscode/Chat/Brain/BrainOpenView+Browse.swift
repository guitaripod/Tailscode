import MidgarCore
import TailscodeCore
import UIKit

extension BrainOpenView {
    func attach(store newStore: BrainStore, turnID newID: String, actions newActions: BrainActions) {
        store = newStore
        turnID = newID
        actions = newActions
        newStore.mutate(newID) { $0.startList() }
        env.interaction = newStore.interaction(for: newID)
        stage.configure(store: newStore, turnID: newID)
    }

    var browseModel: NeuralBrainModel? { store?.model(for: turnID) }
    var browseInput: ChatInput { .touch }

    func browse(_ action: NeuralBrowse.Action) {
        guard let store else { return }
        switch action {
        case .click, .clickNode, .zoneChip, .failedToggle, .jumpToLatest: _ = becomeFirstResponder()
        default: break
        }
        if case .key(.escape, _) = action, stage.isDived {
            stage.leaveDive()
            return
        }
        var effects: [NeuralBrowse.Effect] = []
        var account: [NeuralBrowse.AccountEffect] = []
        let chosenBefore = browseModel?.pinnedStep
        store.mutate(turnID) {
            effects = $0.browse(action)
            account = $0.drainAccountEffects()
        }
        apply(effects)
        gistFollow(from: chosenBefore)
        for effect in account {
            switch effect {
            case .goToAsk: actions?.goToAsk(turnID)
            case .reply(let quote): actions?.reply(quote)
            }
        }
        refreshAll(fromBrowse: true)
    }

    func stageAction(_ action: NeuralBrowse.Action) {
        switch action {
        case .hover: hoverEnd?.cancel(); browse(action)
        case .hoverLeft: scheduleHoverEnd()
        default: browse(action)
        }
    }

    func hoverFromList(_ id: String?) {
        if let id {
            hoverEnd?.cancel()
            browse(.hover(id))
        } else {
            scheduleHoverEnd()
        }
    }

    /// Leaving a node starts a 400 ms grace, so a drift across a wire does not flash the cursor's
    /// readout back; coming back to a node cancels it.
    private func scheduleHoverEnd() {
        hoverEnd?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.browse(.hoverLeft) }
        }
        hoverEnd = item
        DispatchQueue.main.asyncAfter(deadline: .now() + NeuralHoverGrace.leaveGrace, execute: item)
    }

    func relationHover(_ ids: [String]?) {
        guard let store else { return }
        store.mutate(turnID) { $0.setHover(ids?.first) }
        stage.refresh()
    }

    func apply(_ effects: [NeuralBrowse.Effect]) {
        guard let model = browseModel else { return }
        for effect in effects {
            switch effect {
            case .scrollTo(let id):
                if !metrics.isPhone { list.reveal(id, animated: true) }
                if accountIsHosted { account.reveal(step: id) }
            case .copySubject(let id):
                if let step = model.step(id: id) { copy(NeuralBrowse.subjectText(of: step)) }
            case .copyOutput(let id):
                if let step = model.step(id: id) { copy(NeuralBrowse.outputText(of: step)) }
            case .copyMarkdown(let id):
                if let step = model.step(id: id) { copy(NeuralBrowse.markdown(of: step)) }
            case .focusReadout:
                if metrics.isPhone {
                    presentReader(focus: model.pinnedStep)
                } else if let id = model.pinnedStep {
                    account.reveal(step: id)
                }
            case .focusList:
                madeList?.endSearch()
                accordionHeader.endSearch()
                _ = becomeFirstResponder()
            case .focusSearch:
                if metrics.arrangement == .split { list.focusSearch() } else { accordionHeader.focusSearch() }
            case .expandOutputToggle:
                env.outputExpanded = model.browseState.outputExpanded
                madeAccount?.restyle()
            case .showLegend: showLegend()
            case .hideLegend: hideLegend()
            case .collapseBrain: actions?.toggle(turnID)
            case .ring(let ring): stage.setRing(ring.map(BrainRing.init))
            case .dim(let ids): stage.setDimmed(ids)
            case .announce(let words):
                announced = words
                UIAccessibility.post(notification: .announcement, argument: words)
            case .showMenu: break
            case .showInRows(let id): actions?.showInRows(turnID, id)
            }
        }
    }

    func copySubject(of id: String) {
        guard let step = browseModel?.step(id: id) else { return }
        copy(NeuralBrowse.subjectText(of: step))
    }

    func copy(_ text: String) {
        UIPasteboard.general.string = text
        Theme.Haptics.tap()
        UIAccessibility.post(notification: .announcement, argument: Localized.text("Copied"))
    }

    /// Brings every part to the model as it stands.
    func refreshAll(fromBrowse: Bool = false) {
        guard let store, let model = store.model(for: turnID) else { return }
        let list = model.stepList
        env.model = model
        env.cursor = model.pinnedStep
        env.hovered = model.browseState.hovered
        env.outputExpanded = model.browseState.outputExpanded
        env.input = browseInput
        env.lastActivity = store.memory(for: turnID).lastActivity
        env.now = BrainDebug.now
        chips.configure(list: list, showsFailed: metrics.arrangement == .accordion)
        if metrics.arrangement == .split {
            self.list.redraw()
        } else {
            accordionHeader.configure(list: list, searchOpen: model.browseState.searchOpen)
            if metrics.isPhone { refreshCompactList(model: model, list: list) }
        }
        stage.refresh()
        stage.setRing(currentRing(model))
        stage.setDimmed(list.hiddenIDs)
        accessibilityLabel = Localized.text("%1$@, %2$@", Localized.text("Megatron"), model.spoken)
        if accountIsHosted {
            let filterKey = "\(list.filter.zones.map(\.rawValue).sorted())|\(list.filter.failedOnly)|\(list.filter.query)|\(list.visibleCount)"
            if fromBrowse, filterKey == lastFilterKey {
                madeAccount?.restyle()
            } else {
                lastFilterKey = filterKey
                account.refresh(prompt: store.promptText(for: turnID), answer: store.answerText(for: turnID))
            }
        }
        footerRead(model: model, time: CACurrentMediaTime())
        updateLeader(animated: true)
        let drained = store.mutateReturning(turnID) { $0.drainBrowseEffects() }
        if !drained.isEmpty { apply(drained) }
        if accountIsHosted, model.turn.outcome == .running, list.isFollowing { account.scrollToEnd(animated: false) }
    }

    /// Whether the account is on screen to be kept current: always beside the head of a wide
    /// layout and in a phone's sheet, never on a phone with the sheet shut.
    private var accountIsHosted: Bool { !metrics.isPhone || reader != nil }

    /// The rows the phone's list draws for this model, and the row made again when their number
    /// is not the one it was laid out for.
    private func refreshCompactList(model: NeuralBrainModel, list: NeuralStepList) {
        refreshGist(model: model)
        var wanted: Int
        if showsShort, let pane = gistPane {
            let fallback = Self.gistFallback(model)
            gistView.show(pane: pane, fallback: fallback)
            wanted = Self.gistSlots(pane: pane, fallback: fallback, width: bounds.width, rowHeight: CGFloat(metrics.listRowHeight))
        } else {
            let items = BrainCompactListView.items(
                for: list, expanded: listIsExpanded(list), slots: NeuralStageMetrics.phoneRowSlots,
                short: gistPane != nil)
            compactList.show(
                items: items, cursor: model.pinnedStep, hovered: model.browseState.hovered,
                query: list.filter.query, total: list.total)
            wanted = max(items.count, 1)
        }
        if compactList.isHidden != showsShort { setNeedsLayout() }
        guard wanted != max(metrics.rowsShown, 1), !reportingSlots else { return }
        reportingSlots = true
        onSlotsChange?()
        reportingSlots = false
    }

    /// Whether the turn in short stands where the steps would: a telling is held, the person
    /// has not chosen the steps, and nothing is filtering or searching them.
    var showsShort: Bool {
        guard metrics.isPhone, gistPane != nil, let model = browseModel else { return false }
        if store?.interaction(for: turnID).gistTold == true { return false }
        return !model.stepList.isNarrowed && !model.browseState.searchOpen
    }

    /// Says the turn is on screen as it stands, and takes what the desk holds for it.
    private func refreshGist(model: NeuralBrainModel) {
        guard metrics.isPhone, let store else {
            gistPane = nil
            return
        }
        NeuralGistDemo.placeIfNeeded(key: turnID, model: model)
        let answer = store.answerText(for: turnID)
        NeuralGistDesk.shared.want(
            key: turnID, model: model, answer: answer.isEmpty ? nil : answer, prompt: store.promptText(for: turnID),
            bringsWords: true)
        let next = NeuralGistDesk.shared.pane(for: turnID, model: model)
        if next?.phase != gistPane?.phase || next?.rows.count != gistPane?.rows.count {
            MidgarLog.info(
                "megatron in short: \(next.map { $0.isWriting ? "writing" : "told in \($0.rows.count) stages" } ?? "none") of \(model.steps.count) steps",
                category: .performance)
        }
        gistPane = next
    }

    func gistChanged() {
        guard window != nil, metrics.isPhone, browseModel != nil else { return }
        refreshAll(fromBrowse: true)
    }

    func setGistTold(_ told: Bool) {
        store?.interaction(for: turnID).gistTold = told
        refreshAll(fromBrowse: true)
    }

    /// A stage was pressed: the account's part of it, in the sheet.
    func openStage(_ index: Int) {
        guard let pane = gistPane, pane.rows.indices.contains(index) else { return }
        let row = pane.rows[index]
        presentReader(
            focus: browseModel?.firstVisibleStep(in: row.numbers) ?? row.firstStepID, stage: row, of: pane.rows.count)
    }

    static func gistFallback(_ model: NeuralBrainModel) -> String {
        model.account().vitals(now: Date()).counts
    }

    /// How many of the list's rows the telling is as tall as: what the row lays itself out for.
    static func gistSlots(pane: NeuralGistPane, fallback: String, width: CGFloat, rowHeight: CGFloat) -> Int {
        let height = BrainGistView.height(pane: pane, fallback: fallback, width: width)
        return max(Int((height / max(rowHeight, 1)).rounded(.up)), 1)
    }

    private func listIsExpanded(_ list: NeuralStepList) -> Bool {
        guard store?.interaction(for: turnID).listExpanded == true else { return false }
        return list.visibleCount > NeuralStageMetrics.phoneRowSlots
            && NeuralStageMetrics.phoneExpandsInPlace(visibleCount: list.visibleCount)
    }

    /// How many rows the open row is laid out for: the telling's height in rows while it stands
    /// where the steps would, and otherwise the rows the compact list draws.
    static func openSlots(
        model: NeuralBrainModel, expanded: Bool, told: Bool, width: CGFloat, rowHeight: CGFloat
    ) -> Int {
        let list = model.stepList
        let pane = NeuralGistDesk.shared.pane(for: model.turn.id, model: model)
        if let pane, !told, !list.isNarrowed, !model.browseState.searchOpen {
            return gistSlots(pane: pane, fallback: gistFallback(model), width: width, rowHeight: rowHeight)
        }
        let grown = expanded && list.visibleCount > NeuralStageMetrics.phoneRowSlots
            && NeuralStageMetrics.phoneExpandsInPlace(visibleCount: list.visibleCount)
        return max(
            BrainCompactListView.items(
                for: list, expanded: grown, slots: NeuralStageMetrics.phoneRowSlots, short: pane != nil
            ).count, 1)
    }

    /// How many rows the compact list draws for a model: what the row lays itself out for.
    static func compactSlots(model: NeuralBrainModel, expanded: Bool) -> Int {
        let list = model.stepList
        let grown = expanded && list.visibleCount > NeuralStageMetrics.phoneRowSlots
            && NeuralStageMetrics.phoneExpandsInPlace(visibleCount: list.visibleCount)
        return max(
            BrainCompactListView.items(
                for: list, expanded: grown, slots: NeuralStageMetrics.phoneRowSlots
            ).count, 1)
    }

    func setListExpanded(_ value: Bool) {
        store?.interaction(for: turnID).listExpanded = value
        Theme.Haptics.selection()
        refreshAll(fromBrowse: true)
    }

    /// A step chosen while the turn in short stands where the steps would (a node of the head is
    /// the way there) opens the sheet of the stage that holds it, at that step. The telling lists
    /// no step, so a choice made behind it showed nothing at all.
    private func gistFollow(from before: String?) {
        guard metrics.isPhone, showsShort, let model = browseModel, let chosen = model.pinnedStep,
            chosen != before, let pane = gistPane, !pane.isWriting,
            let row = pane.row(holding: chosen, in: model.stepList)
        else { return }
        presentReader(focus: chosen, stage: row, of: pane.rows.count)
    }

    /// "N more steps": a short list opens where it stands, a long one in the sheet.
    func openMore() {
        guard let model = browseModel else { return }
        if NeuralStageMetrics.phoneExpandsInPlace(visibleCount: model.stepList.visibleCount) {
            setListExpanded(true)
        } else {
            presentReader(focus: model.pinnedStep)
        }
    }

    /// A press on a step selects it; a press on the one selected opens the account at it.
    func selectFromCompactList(_ id: String) {
        if browseModel?.pinnedStep == id {
            presentReader(focus: id)
        } else {
            browse(.click(id, double: false))
        }
    }

    /// The conversation moved without the row changing: the model is read again and the account
    /// follows it.
    func conversationChanged() {
        refreshAll()
    }

    func tick() {
        if accountIsHosted { account.tick() }
        refreshAll(fromBrowse: true)
    }

    private func currentRing(_ model: NeuralBrainModel) -> BrainRing? {
        guard let id = model.previewedStep, let row = model.stepList.row(id: id) else { return nil }
        return BrainRing(
            stepID: id, nodeID: model.stepList.nodeID(of: id), calloutNumber: row.number)
    }
}
