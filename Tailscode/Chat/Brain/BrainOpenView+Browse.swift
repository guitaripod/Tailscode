import TailscodeCore
import UIKit

extension BrainOpenView {
    func attach(store newStore: BrainStore, turnID newID: String, actions newActions: BrainActions) {
        store = newStore
        turnID = newID
        actions = newActions
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
        store.mutate(turnID) {
            effects = $0.browse(action)
            account = $0.drainAccountEffects()
        }
        apply(effects)
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
        let items = BrainCompactListView.items(
            for: list, expanded: listIsExpanded(list), slots: NeuralStageMetrics.phoneRowSlots)
        compactList.show(
            items: items, cursor: model.pinnedStep, hovered: model.browseState.hovered,
            query: list.filter.query, total: list.total)
        guard items.count != max(metrics.rowsShown, 1), !reportingSlots else { return }
        reportingSlots = true
        onSlotsChange?()
        reportingSlots = false
    }

    private func listIsExpanded(_ list: NeuralStepList) -> Bool {
        guard store?.interaction(for: turnID).listExpanded == true else { return false }
        return list.visibleCount > NeuralStageMetrics.phoneRowSlots
            && NeuralStageMetrics.phoneExpandsInPlace(visibleCount: list.visibleCount)
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
