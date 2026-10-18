import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// What the account asks of the brain it belongs to, and what the brain asks of it: a press on an
/// item sets the cursor, a key walks the items, Reply and Copy act on a note, and every change of
/// the model is brought to the story.
extension BrainView {
    /// A dive or a replay that takes the whole body of a layout with one column: the readout
    /// stands where the story was, because a zone's steps and a replay's log are not a story.
    var readoutHoldsBody: Bool {
        guard phase != .closed || moveState != nil else { return false }
        let m = currentMetrics
        guard m.accountLayout != .split || m.arrangement == .accordion else { return false }
        return model.isReplaying || stage?.diveZone != nil
    }

    /// Whether the readout is drawn at all: beside the story when the account has two columns,
    /// over the body for a dive or a replay, and nowhere otherwise.
    var readoutIsShown: Bool {
        let m = currentMetrics
        return (m.arrangement == .split && m.accountLayout == .split) || readoutHoldsBody
    }

    /// The step that stands for what the right side is about, which the leader ties to the head:
    /// the hovered step, the cursor, or the step a running turn is on.
    func leaderStep(for value: NeuralReadout?) -> String? {
        if let id = model.previewedStep, model.step(id: id) != nil { return id }
        return value?.leaderStepID
    }


    /// Puts the cursor on a step from the account. A press inside the account does not scroll it:
    /// the item is under the pointer already.
    func accountChooseStep(_ id: String, fromAccount: Bool, double: Bool = false) {
        guard !disposed, let account else { return }
        if fromAccount, model.pinnedStep != id { account.suppressReveal = id }
        browse(.click(id, double: double), grabFocus: false)
        if double { focusReadoutOrAccount() }
        else if account.hasFocus == false { account.focus() }
    }

    func accountHover(_ stepID: String?) {
        guard !disposed else { return }
        if let stepID {
            routeHover(stepID, delay: NeuralHoverGrace.intentDelay)
        } else {
            routeHover(nil, delay: 0)
        }
    }

    func accountToggleText(_ id: String) {
        guard let account else { return }
        if account.expandedText.contains(id) { account.expandedText.remove(id) } else { account.expandedText.insert(id) }
        account.scheduleRealize()
    }

    /// A press on a work line folds it or opens it. A line holding the cursor is open for that
    /// reason, so folding it lets go of the cursor.
    func accountToggleWork(_ id: String) {
        guard let account, let at = account.entryIndex[id], case .work(let work) = account.entries[at].kind else { return }
        if account.isOpen(account.entries[at], work: work) {
            account.unfolded.remove(id)
            if let cursor = model.pinnedStep, work.stepIDs.contains(cursor) {
                clearSelection()
            }
        } else {
            account.unfolded.insert(id)
        }
        account.refresh(immediate: true)
    }

    func accountMoreRows(_ id: String) {
        guard let account else { return }
        account.rowCaps[id] = min(NeuralAccountRows.maximum, account.rowCap(id) + BrainAccount.rowStride)
        account.scheduleRealize()
    }

    func accountCopy(_ stepID: String) {
        browse(.copyItem(stepID), grabFocus: false)
        account?.flashCopied(stepID)
    }

    func accountReply(_ stepID: String) {
        browse(.reply(stepID), grabFocus: false)
    }

    func accountJumpToLatest() {
        browse(.jumpToLatest, grabFocus: false)
        account?.scrollToEnd()
    }

    /// A press on a plan's header folds it or opens it: the plan pinned above a running turn's
    /// story, or the one a settled turn keeps in it.
    func accountTogglePlan(_ entryID: String?) {
        guard let account else { return }
        if let entryID {
            let at = account.entryIndex[entryID]
            var shown = false
            if let at, case .plan(let plan) = account.entries[at].kind { shown = account.planStoryOpen(account.entries[at], plan) }
            account.planStoryOverride[entryID] = !shown
        } else {
            let shown = account.planOpenOverride ?? !account.pinnedPlanCompact
            account.planOpenOverride = !shown
        }
        account.refresh(immediate: true)
    }

    func accountGoToAnswer() {
        host?.revealAnswer?(turnID)
    }

    func accountGoToAsk() {
        goToApproval()
    }

    func accountFocusChanged(_ entered: Bool) {
        if entered {
            if model.browseFocus != .readout { model.setBrowseFocus(.readout) }
        } else if model.browseFocus == .readout, account?.hasFocus != true, readout.map({ !self.focusInside($0.widget) }) ?? true {
            model.setBrowseFocus(.list)
        }
        account?.invalidateFocus()
        stage?.invalidate()
        redrawNow()
    }

    private func focusInside(_ widget: UnsafeMutablePointer<GtkWidget>) -> Bool {
        guard let window = gtk_widget_get_root(self.widget),
            let focused = gtk_root_get_focus(OpaquePointer(UnsafeMutableRawPointer(window)))
        else { return false }
        return focused == widget || gtk_widget_is_ancestor(focused, widget) != 0
    }

    /// Moves the keyboard to the right side: the account, which is where Enter on the list goes, and
    /// the detail beside it only on a second Enter.
    func focusReadoutOrAccount() {
        if let account {
            account.focus()
        } else if readout?.focusFirstControl() != true {
            returnFocusToListFromReadout()
        }
    }

    private func returnFocusToListFromReadout() {
        model.setBrowseFocus(.list)
        focusList()
    }

    /// The effects the reducer left for the account: a quote for the composer and the scroll to
    /// the card that carries the ask.
    func drainAccountEffects() {
        for effect in model.drainAccountEffects() {
            switch effect {
            case .reply(let quote):
                host?.reply?(quote)
            case .goToAsk:
                host?.revealApproval?()
            }
        }
    }


    /// A key while the keyboard is in the account: Up and Down walk its items, Enter goes on to
    /// the open step's detail and back, Space opens what is long, and every other key is the
    /// list's, because there is one cursor and one key table.
    func accountKey(keyval: UInt32, state: UInt32) -> Bool {
        guard !disposed, phase == .open, stage != nil, let account, account.hasFocus else { return false }
        let reserved = GDK_CONTROL_MASK.rawValue | GDK_ALT_MASK.rawValue | GDK_SUPER_MASK.rawValue
        guard state & reserved == 0, let key = Self.browseKey(keyval) else { return false }
        if key == .tab { return false }
        let onButton = account.focusIsButton
        switch key {
        case .enter:
            if onButton { return false }
            return accountEnter()
        case .space:
            if onButton { return false }
            return accountSpace()
        case .up, .character("k"):
            accountWalk(-1)
            return true
        case .down, .character("j"):
            accountWalk(1)
            return true
        case .home, .character("g"):
            accountEnd(first: true)
            return true
        case .end, .character("G"):
            accountEnd(first: false)
            return true
        case .pageUp:
            accountWalk(-3)
            return true
        case .pageDown:
            accountWalk(3)
            return true
        default:
            let before = model.browseFocus
            model.setBrowseFocus(.list)
            let used = brainKey(keyval: keyval, state: state)
            if model.browseFocus == .list, before == .readout, account.hasFocus { model.setBrowseFocus(.readout) }
            return used
        }
    }

    private func accountEnter() -> Bool {
        guard let account else { return false }
        if readoutIsShown, let readout, account.hasFocus, readout.focusFirstControl() { return true }
        model.setBrowseFocus(.list)
        focusList()
        return true
    }

    private func accountSpace() -> Bool {
        guard let account else { return false }
        guard let cursor = model.pinnedStep, let item = account.account.item(containing: cursor) else { return true }
        switch item {
        case .said, .thought:
            accountToggleText(item.id)
        case .work:
            if account.toggleCardOutput() { break }
            if readoutIsShown { readout?.toggleOutput(); break }
            accountToggleWork(item.id)
        default:
            break
        }
        return true
    }

    /// The items a walk visits: the ones that stand for a step, and the result, which has the end
    /// of the story. The ask above the story is not walked over.
    private var walkables: [AccountEntry] {
        account?.entries.filter { $0.isStory || $0.isResult } ?? []
    }

    /// The next or previous item the story shows: a note or a thought puts the cursor on its own
    /// step, a work line on its first, and the result scrolls to the end.
    func accountWalk(_ delta: Int) {
        guard let account else { return }
        let entries = walkables
        guard !entries.isEmpty else { return }
        var at: Int?
        if let cursor = model.pinnedStep, let item = account.account.item(containing: cursor),
            let found = entries.firstIndex(where: { $0.id == item.id })
        {
            at = found
        }
        let next: Int
        if let at { next = at + delta } else { next = delta > 0 ? 0 : entries.count - 1 }
        guard next >= 0, next < entries.count else { return }
        let entry = entries[next]
        if let id = entry.stepIDs.first {
            accountChooseStep(id, fromAccount: false)
        } else {
            account.scrollToEnd()
        }
    }

    private func accountEnd(first: Bool) {
        guard let account else { return }
        let entries = walkables
        guard !entries.isEmpty else { return }
        let entry = first ? entries[0] : entries[entries.count - 1]
        if let id = entry.stepIDs.first {
            accountChooseStep(id, fromAccount: false)
        } else if first {
            account.scrollToStart()
        } else {
            account.scrollToEnd()
        }
        if !first, model.turn.outcome == .running { browse(.key(.end), grabFocus: false) }
    }
}

enum NeuralAccountRows {
    static let maximum = BrainAccount.rowMax
}
