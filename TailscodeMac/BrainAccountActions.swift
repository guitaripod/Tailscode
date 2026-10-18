import AppKit
import TailscodeCore

/// What a press, the pointer and a key do in the account, and what the header, the pins and the
/// detail say about the model: the account asks Core's reducer for every decision and draws what
/// comes back.
extension BrainAccountView {

    /// Puts the cursor on a step from the account. A press inside the account does not scroll it:
    /// the item is under the pointer already.
    func choose(_ id: String, fromAccount: Bool, double: Bool = false) {
        guard let host else { return }
        if fromAccount, model.pinnedStep != id { suppressReveal = id }
        host.browse(.click(id, double: double), grabFocus: false)
        refresh(immediate: true)
        suppressReveal = nil
        if double {
            _ = enterDetail()
        } else if !hasFocus {
            focus()
        }
    }

    func hover(_ id: String?) {
        localHover = id
        host?.hoverStep(id)
    }

    /// A relation chip under the pointer lights the steps it names, without taking the panel.
    func relationHover(_ ids: [String]?) {
        host?.relationHover(ids)
    }

    func dive(into zone: NeuralZone) {
        host?.dive(into: zone)
    }

    func scrub(toStep id: String) {
        guard let host, let index = model.steps.firstIndex(where: { $0.id == id }) else { return }
        let fires = model.timeline.fireTimes
        guard index < fires.count else { return }
        host.scrub(to: model.timeline.fraction(forTime: fires[index]))
    }

    func scrubEnded() {
        host?.endScrub()
    }

    func openSubagent(_ stepID: String) { host?.openSubagent(stepID) }

    func goToApproval() { host?.goToApproval() }

    func copyItem(_ stepID: String) {
        host?.browse(.copyItem(stepID), grabFocus: false)
    }

    func replyItem(_ stepID: String) {
        host?.browse(.reply(stepID), grabFocus: false)
    }


    /// A key while the keyboard is in the account: Up and Down walk its items, Enter goes on to
    /// the open step's detail and back, Space opens what is long, and every other key is the
    /// list's, because there is one cursor and one key table.
    func handleKey(_ event: NSEvent) -> Bool {
        guard let host, host.brainKeyApplies(event), let key = BrainRowView.browseKey(from: event) else { return false }
        if key == .tab { return false }
        let onButton = window?.firstResponder is AccountButton
        switch key {
        case .enter:
            if onButton { return false }
            return accountEnter()
        case .space:
            if onButton { return false }
            return accountSpace()
        case .up, .character("k"):
            walk(-1)
            return true
        case .down, .character("j"):
            walk(1)
            return true
        case .home, .character("g"):
            ends(first: true)
            return true
        case .end, .character("G"):
            ends(first: false)
            return true
        case .pageUp:
            walk(-3)
            return true
        case .pageDown:
            walk(3)
            return true
        default:
            let before = host.model.browseFocus
            host.updateModel { $0.setBrowseFocus(.list) }
            let used = host.handleBrainKey(event, from: self)
            if host.model.browseFocus == .list, before == .readout, hasFocus {
                host.updateModel { $0.setBrowseFocus(.readout) }
            }
            return used
        }
    }

    private func accountEnter() -> Bool {
        if enterDetail() { return true }
        host?.updateModel { $0.setBrowseFocus(.list) }
        host?.focusList()
        return true
    }

    /// Moves the keyboard to the first button the open step's card or the detail column offers.
    @discardableResult
    func enterDetail() -> Bool {
        if let cursor = model.pinnedStep, let item = account.item(containing: cursor),
            let cell = cells[item.id] as? AccountWorkCell, let page = cell.cursorPage, page.focusFirstControl()
        {
            return true
        }
        if readoutIsShown, let detail, detail.focusFirstControl() { return true }
        return false
    }

    private func accountSpace() -> Bool {
        guard let cursor = model.pinnedStep, let item = account.item(containing: cursor) else { return true }
        switch item {
        case .said, .thought:
            toggleText(item.id)
        case .work:
            if toggleCardOutput() { break }
            toggleWork(item.id)
        default:
            break
        }
        return true
    }

    /// The next or previous item the story shows: a note or a thought puts the cursor on its own
    /// step, a work line on its first, and past the last the account scrolls to its result.
    func walk(_ delta: Int) {
        let story = entries.filter(\.isStory)
        guard !story.isEmpty else { return }
        var at: Int?
        if let cursor = model.pinnedStep, let item = account.item(containing: cursor) {
            at = story.firstIndex { $0.id == item.id }
        }
        let next = at.map { $0 + delta } ?? (delta > 0 ? 0 : story.count - 1)
        guard next >= 0 else { return }
        guard next < story.count else {
            if entries.last?.isResult == true { scrollToEnd() }
            return
        }
        if let id = story[next].stepIDs.first { choose(id, fromAccount: false) }
    }

    private func ends(first: Bool) {
        let story = entries.filter(\.isStory)
        guard let entry = first ? story.first : story.last else { return }
        if let id = entry.stepIDs.first { choose(id, fromAccount: false) }
        if first {
            scrollToStart()
        } else {
            scrollToEnd()
            if model.turn.outcome == .running { host?.browse(.key(.end), grabFocus: false) }
        }
    }


    func headerContent() -> AccountHeaderView.Content {
        AccountHeaderView.Content(
            header: account.header, vitals: account.vitals(now: Date(), lastActivity: lastActivityAt),
            filterWord: filterWord, paint: paint, multiline: isAccordion, padLeft: isAccordion ? 16 : 20)
    }

    func refreshHeader() {
        if header.show(headerContent()) { needsLayout = true }
    }

    /// What the header, the pins above the story and the narrow bar say, again.
    func refreshChrome() {
        guard let host else { return }
        let list = host.model.browseState.list
        let solo = list.filter.zones == [.say] && !list.filter.failedOnly && list.filter.query.isEmpty
        filterWord = solo ? AccountWords.whatItToldYou : (list.isFiltered ? AccountWords.filtered : nil)
        noteActivity()
        refreshHeader()
        refreshPins()
        if isAccordion {
            narrowBar.configure(host: host, paint: paint, list: list, padLeft: 16)
            narrowBar.setNeedsLayoutIfNeeded()
        }
        followPill.paint = paint
        followPill.isHidden = !list.showsFollowPill || holdsBody
        footerStrip.paint = paint
        footerStrip.began = beganClock
        updateSecondTimer()
    }

    /// Notes the moment the step in flight last said something, which is when silence is counted
    /// from: the client's own clock, because the transcript's times are the machine's.
    private func noteActivity() {
        guard let live = account.live else {
            lastActivityMark = ""
            lastActivityAt = nil
            return
        }
        let mark = "\(live.stepID)|\(live.tail.count)|\(live.lastLine ?? "")|\(account.header.stepCount)"
        if !lastActivityMark.isEmpty, mark != lastActivityMark { lastActivityAt = Date() }
        lastActivityMark = mark
    }

    /// Once a second while the turn runs: the Now line's "last output 4 s ago" and the header's
    /// words move on without anything arriving.
    func updateSecondTimer() {
        let running = account.header.isRunning && window != nil
        if running, secondTimer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tickSecond() }
            }
            timer.tolerance = 0.2
            secondTimer = timer
        } else if !running {
            secondTimer?.invalidate()
            secondTimer = nil
        }
    }

    func tickSecond() {
        guard host?.isVisible == true else {
            secondTimer?.invalidate()
            secondTimer = nil
            return
        }
        guard account.header.isRunning else { return }
        refreshHeader()
        refreshPins()
    }

    func dropPins() {
        for view in [askView, nowView, planView] as [NSView?] { view?.removeFromSuperview() }
        askView = nil
        nowView = nil
        planView = nil
        askSignature = ""
        nowSignature = ""
        planSignature = ""
    }

    /// Makes the pins again when what they say changed: the ask, the Now line and a running turn's
    /// plan, each in its place above the story.
    func refreshPins() {
        let palette = paint.inks.palette.name
        let width = Int(boxWidth)
        let ask = account.askItem
        let askSig = ask.map { "\($0.id)|\($0.subject)|\($0.why?.text ?? "")|\(width)|\(palette)" } ?? ""
        if askSig != askSignature {
            askView?.removeFromSuperview()
            askView = nil
            askSignature = askSig
            if let ask {
                let view = AccountAskView(ask: ask, step: model.step(id: ask.stepID), owner: self, paint: paint)
                view.alphaValue = bodyAlpha
                addSubview(view, positioned: .above, relativeTo: scroll)
                askView = view
            }
            needsLayout = true
        }
        let vitals = account.vitals(now: Date(), lastActivity: lastActivityAt)
        var nowSig = ""
        if ask == nil, let live = account.live {
            nowSig = "\(live.stepID)|\(live.title)|\(live.argument)|\(live.tail.map(\.text).joined(separator: "\n"))|\(vitals.isSilent)|\(vitals.lastOutputWords ?? "")|\(vitals.silentWords ?? "")|\(width)|\(palette)"
        }
        if nowSig != nowSignature {
            nowView?.removeFromSuperview()
            nowView = nil
            nowSignature = nowSig
            if let live = account.live, !nowSig.isEmpty {
                let view = AccountNowView(live: live, vitals: vitals, host: host, paint: paint)
                view.alphaValue = bodyAlpha
                addSubview(view, positioned: .above, relativeTo: scroll)
                nowView = view
            }
            needsLayout = true
        }
        var planSig = ""
        var compact = false
        if account.header.isRunning, let plan = account.plan {
            compact = nowView != nil && planNeedsCompaction(plan)
            let open = planOpenOverride ?? true
            planSig = "\(plan.items.map { "\($0.text)\($0.state)" }.joined(separator: "|"))|\(compact)|\(open)|\(width)|\(palette)"
        }
        pinnedPlanCompact = compact
        if planSig != planSignature {
            planView?.removeFromSuperview()
            planView = nil
            planSignature = planSig
            if let plan = account.plan, !planSig.isEmpty {
                let view = AccountPlanView(plan: plan, compact: compact, open: planOpenOverride ?? true, paint: paint)
                view.onToggle = { [weak self] in self?.togglePlan(nil) }
                view.alphaValue = bodyAlpha
                addSubview(view, positioned: .above, relativeTo: scroll)
                planView = view
            }
            needsLayout = true
        }
    }

    /// Whether a running plan is too tall to be open beside the Now line: it then keeps its
    /// segments and the item in progress.
    private func planNeedsCompaction(_ plan: NeuralAccount.Plan) -> Bool {
        if let override = planOpenOverride { return !override }
        let available = bounds.height - headerHeight - Self.footerHeight - (askView?.frame.height ?? 0) - 150 - 160
        return CGFloat(24 + min(24, plan.items.count) * 24 + 16) > available
    }


    /// What the detail says: Core's rule over the hovered step, the cursor, the replay, the dived
    /// zone and what the turn itself calls for, with one change. A cursor on a note or a thought has
    /// no detail of its own (the words are the account's), so the detail reads what the turn itself
    /// calls for beside them.
    func currentSubject(at clock: Double) -> NeuralReadout.Mode {
        let model = model
        let mode = model.readoutSubject(now: clock)
        if case .step(let id) = mode, let step = model.step(id: id),
            NeuralReading.isNote(step) || NeuralReading.isThought(step)
        {
            return turnSubject()
        }
        return mode
    }

    private func turnSubject() -> NeuralReadout.Mode {
        let model = model
        if model.isReplaying { return .replay }
        if let zone = model.divedZone { return .zone(zone) }
        if model.turn.outcome == .running {
            if let waiting = model.steps.first(where: { $0.status == .waitingApproval || $0.status == .waitingAnswer }) {
                return .ask(waiting.id)
            }
            return .now
        }
        return .digest
    }

    func readoutValue(at clock: Double) -> NeuralReadout {
        NeuralReadout.make(
            model: model, subject: currentSubject(at: clock), now: Date(), tz: .current, clock: clock,
            answer: answerOrNil, outputLines: metrics.outputLinesShown)
    }

    /// Brings the detail beside the story, or over it for a dive or a replay, to what the model
    /// says. Only a change of subject builds anything; the same words arriving again are left
    /// alone, and a layout with no detail builds none.
    func refreshDetail(animate: Bool) {
        guard host != nil else { return }
        if readoutHoldsBody != holdsBody || readoutIsShown != (detail != nil) { needsLayout = true }
        guard readoutIsShown else {
            if let detail {
                detail.removeFromSuperview()
                self.detail = nil
            }
            return
        }
        if detail == nil {
            let page = AccountReadoutPage(owner: self, mode: .column)
            page.alphaValue = bodyAlpha
            addSubview(page, positioned: .above, relativeTo: scroll)
            detail = page
            needsLayout = true
        }
        guard let detail else { return }
        let before = detail.stepID
        detail.show(readoutValue(at: CACurrentMediaTime()), paint: paint, animate: animate)
        if detail.stepID != before { detail.resetScroll() }
    }
}

extension AccountNarrowBar {
    func setNeedsLayoutIfNeeded() { needsLayout = true }
}
