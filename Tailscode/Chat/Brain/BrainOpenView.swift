import CodingAgentKit
import TailscodeCore
import UIKit

/// What the open brain asks of the chat it is in: everything that leaves the row. The brain owns
/// no conversation state; it reads the model and, when the person does something the conversation
/// must answer (reply, go to the approval, open an agent), says so here.
struct BrainActions {
    var toggle: (String) -> Void
    var rows: (String) -> Void
    var replay: (String) -> Void
    var share: (String) -> Void
    var revealAgent: (String, String) -> Void
    var reply: (String) -> Void
    var goToAsk: (String) -> Void
    var goToAnswer: (String) -> Void
    var showInRows: (String, String) -> Void
    var openDiving: (String, NeuralZone) -> Void
    var landed: (String) -> Void
}

/// The open brain: the head as a small map with its zone chips, the step list beside it (or, on a
/// phone, the account in its place), the account, and the footer. It holds no state about the turn;
/// it draws the model the store holds and turns what a finger, a pointer or a key does into
/// `NeuralBrowse` actions, applying the effects the reducer answers with.
@MainActor
final class BrainOpenView: UIView, BrainBrowsing {
    let stage = BrainStageView()
    private let stageBand = UIView()
    let chips = BrainFilterBar()
    let list = BrainStepListView()
    let accordionHeader = BrainListHeader()
    private(set) var account: BrainAccountView!
    let footer = BrainFooterView()
    private let hairline = CALayer()
    private let leaderLine = CAShapeLayer()
    private let leaderDot = CAShapeLayer()
    private let leaderTab = CALayer()
    private let focusRing = CALayer()
    private let sweepLayer = CAGradientLayer()
    private let sweepMask = CAGradientLayer()
    private let stageLights = BrainLightsLayer()

    private weak var store: BrainStore?
    private var actions: BrainActions?
    private(set) var turnID = ""
    private(set) var metrics: NeuralStageMetrics
    private var extra: CGFloat = 0
    private var env: BrainAccountEnv!
    private var leaderStep: String?
    private var leaderRoute: [CGPoint] = []
    private var hoverEnd: DispatchWorkItem?
    private var isMoving = false
    private var lastCursor: String?
    private var announced: String?
    private var legend: BrainLegendViewController?
    private var promptMemo: String?

    /// How tall the open row is for a width: the metrics' height plus what a narrow brain's account
    /// takes beyond the list it replaces.
    var openHeight: CGFloat { CGFloat(metrics.rowHeight) + extra }

    init(metrics initial: NeuralStageMetrics) {
        metrics = initial
        super.init(frame: .zero)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) { (view: BrainOpenView, _) in view.traitsChanged() }
        clipsToBounds = true
        addSubview(stageBand)
        addSubview(stage)
        addSubview(chips)
        addSubview(list)
        addSubview(accordionHeader)
        stage.layer.addSublayer(stageLights)
        stage.layer.addSublayer(sweepLayer)
        sweepLayer.colors = [UIColor.clear.cgColor, UIColor.white.cgColor, UIColor.clear.cgColor]
        sweepLayer.locations = [0, 0.5, 1]
        sweepLayer.startPoint = CGPoint(x: 0, y: 0.5)
        sweepLayer.endPoint = CGPoint(x: 1, y: 0.5)
        sweepMask.colors = [UIColor.clear.cgColor, UIColor.white.cgColor, UIColor.white.cgColor, UIColor.clear.cgColor]
        sweepMask.locations = [0, 0.22, 0.78, 1]
        sweepMask.startPoint = CGPoint(x: 0.5, y: 0)
        sweepMask.endPoint = CGPoint(x: 0.5, y: 1)
        sweepLayer.mask = sweepMask
        sweepLayer.opacity = 0
        stage.isUserInteractionEnabled = true
        layer.addSublayer(hairline)
        leaderLine.fillColor = nil
        leaderLine.lineCap = .round
        leaderLine.lineJoin = .round
        layer.addSublayer(leaderLine)
        layer.addSublayer(leaderDot)
        layer.addSublayer(leaderTab)
        for part in [leaderLine, leaderDot, leaderTab] as [CALayer] { part.isHidden = true }
        focusRing.borderWidth = 2
        focusRing.cornerRadius = 12
        focusRing.cornerCurve = .continuous
        focusRing.isHidden = true
        layer.addSublayer(focusRing)
        let placeholder = NeuralBrainModel(turn: NeuralTurn(id: "-", steps: [], outcome: .settled))
        env = BrainAccountEnv(
            model: placeholder, interaction: BrainInteraction(), metrics: initial)
        account = BrainAccountView(env: env)
        addSubview(account)
        addSubview(footer)
        wire()
        isAccessibilityElement = false
        accessibilityContainerType = .semanticGroup
        installRotors()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func wire() {
        list.host = self
        accordionHeader.host = self
        accordionHeader.showsFailed = false
        stage.perform = { [weak self] action in self?.stageAction(action) }
        stage.onChange = { [weak self] model, time in self?.footerRead(model: model, time: time) }
        stage.menuItems = { [weak self] id in self?.menu(for: id) ?? [] }
        stage.onRevealAgent = { [weak self] step in
            guard let self else { return }
            self.actions?.revealAgent(self.turnID, step)
        }
        stage.onDive = { [weak self] zone in self?.diveChanged(zone) }
        chips.onZone = { [weak self] zone, solo in self?.browse(.zoneChip(zone, solo: solo)) }
        chips.onFailed = { [weak self] in self?.browse(.failedToggle) }
        footer.onReplay = { [weak self] in self?.toggleReplay() }
        footer.onBegan = { [weak self] in self?.scrubBegan() }
        footer.onMoved = { [weak self] fraction in self?.scrubbed(to: fraction) }
        footer.onEnded = { [weak self] in self?.scrubEnded() }
        footer.onRows = { [weak self] in
            guard let self else { return }
            self.actions?.rows(self.turnID)
        }
        footer.onShare = { [weak self] in
            guard let self else { return }
            self.actions?.share(self.turnID)
        }
        footer.onClose = { [weak self] in
            guard let self else { return }
            self.actions?.toggle(self.turnID)
        }
        footer.onChip = { [weak self] token in
            guard let self else { return }
            self.store?.mutate(self.turnID) { $0.setProvenance(token: token) }
            self.refreshAll()
        }
        env.chooseStep = { [weak self] id, double in
            guard let self else { return }
            self.account.suppressRevealOnce(id)
            self.browse(.click(id, double: double))
        }
        env.hoverStep = { [weak self] id in self?.hoverFromList(id) }
        env.copyStep = { [weak self] id in self?.copySubject(of: id) }
        env.replyStep = { [weak self] id in self?.browse(.reply(id)) }
        env.copyText = { [weak self] text in self?.copy(text) }
        env.toggleText = { [weak self] id in self?.toggleText(id) }
        env.toggleWork = { [weak self] id in self?.toggleWork(id) }
        env.moreRows = { [weak self] id in self?.moreRows(id) }
        env.toggleOutput = { [weak self] expanded in self?.setOutputExpanded(expanded) }
        env.openAgent = { [weak self] id in
            guard let self else { return }
            self.actions?.revealAgent(self.turnID, id)
        }
        env.menu = { [weak self] item, id in self?.browse(.menu(item, id)) }
        env.relationHover = { [weak self] ids in self?.relationHover(ids) }
        env.goToAnswer = { [weak self] in
            guard let self else { return }
            self.actions?.goToAnswer(self.turnID)
        }
        env.jumpHandler = { [weak self] in self?.browse(.jumpToLatest) }
        env.askHandler = { [weak self] in
            guard let self else { return }
            self.actions?.goToAsk(self.turnID)
        }
        env.scrolledHandler = { [weak self] in self?.browse(.scrolled(manual: true)) }
    }

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

    private func stageAction(_ action: NeuralBrowse.Action) {
        switch action {
        case .hover: hoverEnd?.cancel(); browse(action)
        case .hoverLeft: scheduleHoverEnd()
        default: browse(action)
        }
    }

    private func hoverFromList(_ id: String?) {
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

    private func relationHover(_ ids: [String]?) {
        guard let store else { return }
        store.mutate(turnID) { $0.setHover(ids?.first) }
        stage.refresh()
    }

    private func apply(_ effects: [NeuralBrowse.Effect]) {
        guard let model = browseModel else { return }
        for effect in effects {
            switch effect {
            case .scrollTo(let id):
                list.reveal(id, animated: true)
                account.reveal(step: id)
            case .copySubject(let id):
                if let step = model.step(id: id) { copy(NeuralBrowse.subjectText(of: step)) }
            case .copyOutput(let id):
                if let step = model.step(id: id) { copy(NeuralBrowse.outputText(of: step)) }
            case .copyMarkdown(let id):
                if let step = model.step(id: id) { copy(NeuralBrowse.markdown(of: step)) }
            case .focusReadout:
                if let id = model.pinnedStep { account.reveal(step: id) }
            case .focusList:
                list.endSearch()
                accordionHeader.endSearch()
                _ = becomeFirstResponder()
            case .focusSearch:
                if metrics.arrangement == .split { list.focusSearch() } else { accordionHeader.focusSearch() }
            case .expandOutputToggle:
                env.outputExpanded = model.browseState.outputExpanded
                account.restyle()
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

    private func copy(_ text: String) {
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
        }
        stage.refresh()
        stage.setRing(currentRing(model))
        stage.setDimmed(list.hiddenIDs)
        accessibilityLabel = Localized.text("%1$@, %2$@", Localized.text("Brain"), model.spoken)
        let filterKey = "\(list.filter.zones.map(\.rawValue).sorted())|\(list.filter.failedOnly)|\(list.filter.query)|\(list.visibleCount)"
        if fromBrowse, filterKey == lastFilterKey {
            account.restyle()
        } else {
            lastFilterKey = filterKey
            account.refresh(prompt: store.promptText(for: turnID), answer: store.answerText(for: turnID))
        }
        footerRead(model: model, time: CACurrentMediaTime())
        updateLeader(animated: true)
        let drained = store.mutateReturning(turnID) { $0.drainBrowseEffects() }
        if !drained.isEmpty { apply(drained) }
        if model.turn.outcome == .running, list.isFollowing { account.scrollToEnd(animated: false) }
    }

    /// The conversation moved without the row changing: the model is read again and the account
    /// follows it.
    func conversationChanged() {
        refreshAll()
    }

    func tick() {
        account.tick()
        refreshAll(fromBrowse: true)
    }

    private func currentRing(_ model: NeuralBrainModel) -> BrainRing? {
        guard let id = model.previewedStep, let row = model.stepList.row(id: id) else { return nil }
        return BrainRing(
            stepID: id, nodeID: model.stepList.nodeID(of: id), calloutNumber: row.number)
    }

    private var followedReplayStep: String?
    private var lastFilterKey = ""

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
        account.suppressRevealOnce(id)
        browse(.click(id, double: false))
    }

    private func footerRead(model: NeuralBrainModel, time: Double) {
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

    private func scrubBegan() {
        guard let store, let model = store.model(for: turnID) else { return }
        let fraction = model.replayFraction(now: CACurrentMediaTime()) ?? 1
        store.mutate(turnID) { $0.scrub(to: fraction) }
    }

    private func scrubbed(to fraction: Double) {
        store?.mutate(turnID) { $0.scrub(to: fraction) }
        stage.refresh()
        if let model = browseModel { footerRead(model: model, time: CACurrentMediaTime()) }
    }

    private func scrubEnded() {
        store?.mutate(turnID) { $0.endScrub() }
        refreshAll(fromBrowse: true)
    }

    private func toggleText(_ id: String) {
        if env.interaction.expandedText.contains(id) {
            env.interaction.expandedText.remove(id)
        } else {
            env.interaction.expandedText.insert(id)
        }
        account.restyle()
    }

    private func toggleWork(_ id: String) {
        if env.interaction.unfolded.contains(id) {
            env.interaction.unfolded.remove(id)
        } else {
            env.interaction.unfolded.insert(id)
        }
        account.restyle()
    }

    private func moreRows(_ id: String) {
        let current = env.interaction.rowCaps[id] ?? 40
        env.interaction.rowCaps[id] = min(current + 40, 400)
        account.restyle()
    }

    private func setOutputExpanded(_ expanded: Bool) {
        store?.mutate(turnID) { $0.setBrowseOutputExpanded(expanded) }
        env.outputExpanded = expanded
        account.restyle()
    }

    private func diveChanged(_ zone: NeuralZone?) {
        guard let model = browseModel else { return }
        if let zone {
            if model.stepList.filter.zones != [zone] { browse(.zoneChip(zone, solo: true)) }
        } else {
            let only = model.stepList.filter.zones
            if only.count == 1, let zone = only.first { browse(.zoneChip(zone, solo: true)) }
        }
    }

    private func menu(for id: String) -> [UIMenuElement] {
        guard let row = browseModel?.stepList.row(id: id) else { return [] }
        return NeuralBrowse.menuItems(for: row).map { item in
            UIAction(title: NeuralBrowse.title(of: item)) { [weak self] _ in
                self?.browse(.menu(item, id))
            }
        }
    }

    /// Lays every part out for the metrics of this width.
    func apply(metrics new: NeuralStageMetrics, viewport: CGFloat) {
        metrics = new
        extra = Self.narrowExtra(metrics: new, viewport: viewport)
        env.metrics = new
        list.configure(metrics: new)
        account.configure(metrics: new)
        footer.configure(metrics: new, running: browseModel?.turn.outcome == .running, showsRows: store?.showsRows(turnID) ?? false)
        setNeedsLayout()
    }

    /// How much taller a narrow brain is than the list it replaces: its account is as tall as the
    /// window allows, 62 percent of what the reader sees between 340 and 640.
    static func narrowExtra(metrics: NeuralStageMetrics, viewport: CGFloat) -> CGFloat {
        guard metrics.arrangement == .accordion else { return 0 }
        let wanted = min(max((viewport * 0.62).rounded(), 340), 640)
        return max(0, wanted - CGFloat(metrics.list.height))
    }

    private func rect(_ value: NeuralRect) -> CGRect {
        CGRect(x: value.x, y: value.y, width: value.width, height: value.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let split = metrics.arrangement == .split
        stage.frame = rect(metrics.stage)
        stageBand.frame = split ? stage.frame : CGRect(x: 0, y: stage.frame.minY, width: bounds.width, height: stage.frame.height)
        stageBand.backgroundColor = stage.backgroundColor
        stageLights.layout(in: stage.bounds)
        chips.frame = rect(metrics.filterChips ?? .zero)
        let listRect = rect(metrics.list)
        if split {
            list.isHidden = false
            accordionHeader.isHidden = true
            list.frame = listRect
            account.frame = rect(metrics.readout)
            hairline.isHidden = false
            hairline.frame = CGRect(x: CGFloat(metrics.readout.x), y: 0, width: 1, height: CGFloat(metrics.brainHeight))
        } else {
            list.isHidden = true
            accordionHeader.isHidden = false
            accordionHeader.frame = rect(metrics.listHeader)
            let top = CGFloat(metrics.listHeader.maxY)
            let block = CGFloat(metrics.list.height) + extra
            account.frame = CGRect(
                x: 0, y: top, width: CGFloat(metrics.width),
                height: block - CGFloat(metrics.listHeader.height))
            hairline.isHidden = true
        }
        footer.frame = rect(metrics.footer).offsetBy(dx: 0, dy: extra)
        hairline.backgroundColor = BrainCanvas.rule.resolvedColor(with: traitCollection).cgColor
        focusRing.frame = bounds.insetBy(dx: -2, dy: -2)
        focusRing.borderColor = Theme.Color.accent.wash(0.55).resolvedColor(with: traitCollection).cgColor
        placeSweep(CGRect(x: 0, y: 0, width: stage.bounds.width * 0.4, height: stage.bounds.height))
        updateLeader(animated: false)
    }

    private func traitsChanged() {
        setNeedsLayout()
        updateLeader(animated: false)
    }

    private func leaderTone(_ zone: NeuralZone) -> UIColor { BrainCanvas.zone(zone) }

    private func updateLeader(animated: Bool) {
        let parts: [CALayer] = [leaderLine, leaderDot, leaderTab]
        guard metrics.hasLeader, !isMoving, let model = browseModel,
            let id = leaderTarget(model), let step = model.step(id: id),
            let line = model.leader(forStep: id, in: metrics)
        else {
            for part in parts { part.isHidden = true }
            leaderStep = nil
            return
        }
        let tone = leaderTone(step.zone).resolvedColor(with: traitCollection)
        let route = line.route.map { metrics.point(forDesign: $0) }.map { CGPoint(x: $0.x, y: $0.y) }
        let path = CGMutablePath()
        if let first = route.first {
            path.move(to: first)
            for point in route.dropFirst() { path.addLine(to: point) }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        leaderLine.path = path
        leaderLine.lineWidth = 1.25
        leaderLine.strokeColor = tone.withAlphaComponent(0.7).cgColor
        leaderDot.path = CGPath(ellipseIn: CGRect(x: -2.5, y: -2.5, width: 5, height: 5), transform: nil)
        leaderDot.position = CGPoint(x: line.dot.x, y: line.dot.y)
        leaderDot.fillColor = tone.cgColor
        leaderTab.frame = CGRect(x: line.tab.x, y: line.tab.y, width: line.tab.width, height: line.tab.height)
        leaderTab.backgroundColor = tone.cgColor
        for part in parts { part.isHidden = false }
        CATransaction.commit()
        if animated, leaderStep != id, !UIAccessibility.isReduceMotionEnabled {
            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = 0
            draw.toValue = 1
            draw.duration = 0.12
            leaderLine.add(draw, forKey: "draw")
        }
        leaderStep = id
    }

    /// The step the leader ties to the account: the one being read, and while a turn runs with
    /// nothing chosen, the one it is on.
    private func leaderTarget(_ model: NeuralBrainModel) -> String? {
        if let id = model.previewedStep { return id }
        if model.turn.outcome == .running, model.browseState.list.isFollowing {
            return model.steps.last?.id
        }
        return nil
    }

    override var accessibilityElements: [Any]? {
        get {
            var parts: [Any] = [stage, chips]
            parts.append(metrics.arrangement == .split ? list : accordionHeader)
            parts.append(account as UIView)
            parts.append(footer)
            return parts
        }
        set {}
    }

    /// Three rotors walk the head's steps: the notes the agent said, the errors it hit (fixed and
    /// failed), and every step, each landing on the step's own node and selecting it.
    private func installRotors() {
        func rotor(_ name: String, _ keep: @escaping (NeuralStepList.Row) -> Bool) -> UIAccessibilityCustomRotor {
            UIAccessibilityCustomRotor(name: name) { [weak self] predicate in
                guard let self, let model = self.browseModel else { return nil }
                let rows = model.stepList.visibleRows.filter(keep)
                guard !rows.isEmpty else { return nil }
                let current = self.stage.stepID(of: predicate.currentItem.targetElement)
                    ?? model.pinnedStep
                let at = current.flatMap { id in model.stepList.row(id: id)?.index } ?? -1
                let forward = predicate.searchDirection == .next
                let next = forward
                    ? rows.first { $0.index > at } ?? rows.first
                    : rows.last { $0.index < at } ?? rows.last
                guard let next, let element = self.stage.element(forStep: next.id) else { return nil }
                self.browse(.click(next.id, double: false))
                return UIAccessibilityCustomRotorItemResult(targetElement: element, targetRange: nil)
            }
        }
        accessibilityCustomRotors = [
            rotor(Localized.text("Said")) { $0.isSaid },
            rotor(Localized.text("Errors")) { $0.verdict == .fixed || $0.verdict == .failed || $0.verdict == .tryingAgain },
            rotor(Localized.text("Steps")) { _ in true },
        ]
    }

    override var canBecomeFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        focusRing.isHidden = !became
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { focusRing.isHidden = true }
        return resigned
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key, let mapped = Self.map(key) else { continue }
            browse(.key(mapped.key, mapped.modifiers))
            handled = true
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    /// A hardware key as the reducer reads it.
    static func map(_ key: UIKey) -> (key: NeuralBrowse.Key, modifiers: NeuralBrowse.Modifiers)? {
        var modifiers: NeuralBrowse.Modifiers = []
        if key.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if key.modifierFlags.contains(.alternate) { modifiers.insert(.alt) }
        if key.modifierFlags.contains(.command) { modifiers.insert(.command) }
        switch key.keyCode {
        case .keyboardUpArrow: return (.up, modifiers)
        case .keyboardDownArrow: return (.down, modifiers)
        case .keyboardLeftArrow: return (.left, modifiers)
        case .keyboardRightArrow: return (.right, modifiers)
        case .keyboardPageUp: return (.pageUp, modifiers)
        case .keyboardPageDown: return (.pageDown, modifiers)
        case .keyboardHome: return (.home, modifiers)
        case .keyboardEnd: return (.end, modifiers)
        case .keyboardReturnOrEnter, .keypadEnter: return (.enter, modifiers)
        case .keyboardSpacebar: return (.space, modifiers)
        case .keyboardEscape: return (.escape, modifiers)
        case .keyboardTab: return (.tab, modifiers)
        default:
            guard let character = key.characters.first, key.characters.count == 1 else { return nil }
            return (.character(character), modifiers)
        }
    }

    private func showLegend() {
        guard legend == nil, let controller = nearestViewController() else { return }
        let page = BrainLegendViewController()
        page.onDismiss = { [weak self] in
            self?.legend = nil
            self?.store?.mutate(self?.turnID ?? "") { $0.setBrowseLegend(false) }
        }
        page.modalPresentationStyle = .popover
        if let popover = page.popoverPresentationController {
            popover.sourceView = self
            popover.sourceRect = CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
            popover.delegate = page
        }
        legend = page
        controller.present(page, animated: true)
    }

    private func hideLegend() {
        legend?.dismiss(animated: true)
        legend = nil
    }

    private func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let controller = next as? UIViewController { return controller }
            responder = next
        }
        return nil
    }

    /// What the move changes of the open parts, from the numbers of a frame. Core owns every
    /// curve; this only sets what it is handed.
    func apply(frame: NeuralTransitionFrame, from card: NeuralStageMetrics, opening: Bool, live: Bool) {
        isMoving = true
        let stageRect = rect(metrics.stage)
        let traveller = CGRect(
            x: frame.traveller.x, y: frame.traveller.y, width: frame.traveller.width,
            height: frame.traveller.height)
        let scale = stageRect.width > 0 ? traveller.width / stageRect.width : 1
        stage.alpha = CGFloat(frame.travellerAlpha)
        stageBand.alpha = 0
        stage.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        stage.transform = CGAffineTransform(
            translationX: traveller.midX - stageRect.midX, y: traveller.midY - stageRect.midY
        ).scaledBy(x: scale, y: scale)
        stageLights.opacity = Float(opening ? max(0, 1 - frame.zoneLift) : 0)
        let sweep = frame.sweepAmount
        sweepLayer.opacity = Float(min(1, sweep / NeuralTransition.sweepStrength) * 0.55)
        let travel = stage.bounds.width * 1.4
        placeSweep(
            CGRect(
                x: -stage.bounds.width * 0.4 + travel * CGFloat(frame.sweepPhase), y: 0,
                width: stage.bounds.width * 0.4, height: stage.bounds.height))
        stage.field.setReveal(model: browseModel, frame: frame)
        chips.alpha = CGFloat(frame.panelAlpha)
        list.header.alpha = CGFloat(frame.listHeaderAlpha)
        accordionHeader.alpha = CGFloat(frame.listHeaderAlpha)
        list.setReveal(frame.listRows)
        let offset = CGPoint(x: frame.readoutOffset.x, y: frame.readoutOffset.y)
        account.alpha = CGFloat(frame.readoutAlpha)
        account.transform = CGAffineTransform(translationX: offset.x, y: offset.y)
        hairline.opacity = Float(frame.readoutAlpha)
        footer.alpha = CGFloat(frame.footerAlpha)
        for part in [leaderLine, leaderDot, leaderTab] as [CALayer] { part.isHidden = true }
    }

    func finishMove() {
        isMoving = false
        stage.alpha = 1
        UIView.animate(withDuration: 0.15) { self.stageBand.alpha = 1 }
        stage.transform = .identity
        stageLights.opacity = 0
        sweepLayer.opacity = 0
        stage.field.clearReveal()
        chips.alpha = 1
        list.header.alpha = 1
        accordionHeader.alpha = 1
        list.setReveal(nil)
        account.alpha = 1
        account.transform = .identity
        hairline.opacity = 1
        footer.alpha = 1
        setNeedsLayout()
        updateLeader(animated: true)
    }

    /// Puts the sweep band where it is now, without the layer animating there.
    private func placeSweep(_ rect: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sweepLayer.frame = rect
        sweepMask.frame = sweepLayer.bounds
        CATransaction.commit()
    }

    func configureLights(card: NeuralBrainCard, ink: BrainInk) {
        stageLights.configure(card: card, ink: ink, hovered: false)
        stageLights.layout(in: stage.bounds)
        sweepLayer.colors = [
            ink.live.withAlphaComponent(0).cgColor, ink.live.cgColor, ink.live.withAlphaComponent(0).cgColor,
        ]
    }

    /// The first content of the account arriving after the move: a 90 ms cross-fade.
    func fadeInContent() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        account.alpha = 0
        UIView.animate(withDuration: NeuralTransition.contentFadeDuration) { self.account.alpha = 1 }
    }
}

/// The key legend: the table of keys the step list answers, which a hardware keyboard learns from.
@MainActor
final class BrainLegendViewController: UIViewController, UIPopoverPresentationControllerDelegate {
    var onDismiss: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.secondaryBackground
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        for entry in NeuralBrowse.legend {
            let keys = UILabel()
            keys.attributedText = NSAttributedString(
                string: entry.keys, attributes: Theme.Ramp.attributes(.toolDetail, color: Theme.Color.label))
            keys.setContentHuggingPriority(.required, for: .horizontal)
            keys.widthAnchor.constraint(equalToConstant: 118).isActive = true
            let does = UILabel()
            does.numberOfLines = 0
            does.attributedText = NSAttributedString(
                string: entry.does, attributes: Self.wrapping(Theme.Ramp.attributes(.rowDetail, color: Theme.Color.secondaryLabel)))
            let row = UIStackView(arrangedSubviews: [keys, does])
            row.spacing = 12
            row.alignment = .firstBaseline
            stack.addArrangedSubview(row)
        }
        view.addSubview(stack)
        self.stack = stack
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])
        preferredContentSize = CGSize(width: 560, height: 460)
        view.accessibilityLabel = Localized.text("Keys")
    }

    private weak var stack: UIStackView?

    /// The popover is as tall as the legend is at the width it was given, so no row is squeezed.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let stack, view.bounds.width > 0 else { return }
        let fitted = stack.systemLayoutSizeFitting(
            CGSize(width: view.bounds.width - 32, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height + 32
        if abs(preferredContentSize.height - fitted) > 1 {
            preferredContentSize = CGSize(width: preferredContentSize.width, height: fitted)
        }
    }

    /// The ramp's attributes with word wrapping, since a legend row is a sentence and may take lines.
    private static func wrapping(_ attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var result = attributes
        let style =
            (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
            ?? NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        result[.paragraphStyle] = style
        return result
    }

    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle {
        .none
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        onDismiss?()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDismiss?()
    }
}

#if DEBUG
    extension BrainOpenView {
        /// What a walk step does to the open brain in place of a finger.
        func walk(verb: String, value: String) {
            guard let model = browseModel else { return }
            func step(_ number: String) -> String? {
                Int(number).flatMap { model.steps.indices.contains($0 - 1) ? model.steps[$0 - 1].id : nil }
            }
            switch verb {
            case "click": if let id = step(value) { browse(.click(id, double: false)) }
            case "doubleclick": if let id = step(value) { browse(.click(id, double: true)) }
            case "node": if let id = step(value) { browse(.clickNode(id, double: false)) }
            case "hover": browse(step(value).map { .hover($0) } ?? .hoverLeft)
            case "key":
                for token in value.split(separator: ",") {
                    switch token {
                    case "esc": browse(.key(.escape))
                    case "enter": browse(.key(.enter))
                    case "up": browse(.key(.up))
                    case "down": browse(.key(.down))
                    case "left": browse(.key(.left))
                    case "right": browse(.key(.right))
                    case "space": browse(.key(.space))
                    case "pgdn": browse(.key(.pageDown))
                    case "pgup": browse(.key(.pageUp))
                    default:
                        for character in token { browse(.key(.character(character))) }
                    }
                }
            case "chip":
                if let digit = Int(value), (1...6).contains(digit) {
                    browse(.zoneChip(NeuralZone.filterOrder[digit - 1], solo: false))
                }
            case "solo":
                if let digit = Int(value), (1...6).contains(digit) {
                    browse(.zoneChip(NeuralZone.filterOrder[digit - 1], solo: true))
                }
            case "failed": browse(.failedToggle)
            case "search": browse(.searchText(value))
            case "dive": stage.walk(dive: value)
            case "scroll": account.scroll(by: CGFloat(Double(value) ?? 0))
            case "end": account.scrollToEnd(animated: false)
            case "unfold": account.walkUnfold(Int(value) ?? 1)
            case "legend": browse(.key(.character("?")))
            case "dump":
                func walk(_ view: UIView, _ depth: Int) {
                    let pad = String(repeating: " ", count: depth)
                    AppLogger.ui.info("dump \(pad)\(type(of: view)) f=\(NSCoder.string(for: view.frame)) a=\(view.alpha) h=\(view.isHidden)")
                    if depth < Int(value) ?? 6 { for child in view.subviews { walk(child, depth + 1) } }
                }
                walk(account, 0)
            default: break
            }
        }
    }
#endif
