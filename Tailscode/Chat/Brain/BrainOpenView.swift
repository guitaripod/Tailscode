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
    let stageBand = UIView()
    let wordmark = UILabel()
    let chips = BrainFilterBar()
    var madeList: BrainStepListView?

    /// The step list of the desktop layouts, made when one needs it. A phone's open Megatron lists
    /// its steps in `compactList` and never builds this one.
    var list: BrainStepListView {
        if let madeList { return madeList }
        let made = BrainStepListView()
        made.host = self
        madeList = made
        insertSubview(made, belowSubview: compactList)
        return made
    }
    let accordionHeader = BrainListHeader()
    let compactList = BrainCompactListView()
    var madeAccount: BrainAccountView?

    /// The account, made when something first needs it: a phone's open Megatron never builds one
    /// until its sheet is asked for, because a collection view and its cells are what an open
    /// row costs the main thread most.
    var builtAccount: BrainAccountView? { madeAccount }

    var account: BrainAccountView {
        if let madeAccount { return madeAccount }
        let made = BrainAccountView(env: env)
        madeAccount = made
        return made
    }
    let footer = BrainFooterView()
    let hairline = CALayer()
    let leaderLine = CAShapeLayer()
    let leaderDot = CAShapeLayer()
    let leaderTab = CALayer()
    private let focusRing = CALayer()
    let sweepLayer = CAGradientLayer()
    let sweepMask = CAGradientLayer()
    let stageLights = BrainLightsLayer()

    weak var store: BrainStore?
    var actions: BrainActions?
    var turnID = ""
    var metrics: NeuralStageMetrics
    var extra: CGFloat = 0
    var env: BrainAccountEnv!
    var leaderStep: String?
    private var leaderRoute: [CGPoint] = []
    var hoverEnd: DispatchWorkItem?
    var isMoving = false
    private var lastCursor: String?
    var announced: String?
    var legend: BrainLegendViewController?
    private var promptMemo: String?
    var reader: BrainReaderViewController?
    var reportingSlots = false

    /// The list wants a different number of rows than the row was laid out for: the row makes its
    /// metrics again.
    var onSlotsChange: (() -> Void)?

    /// How tall the open row is for a width: the metrics' height plus what a narrow brain's account
    /// takes beyond the list it replaces.
    var openHeight: CGFloat { CGFloat(metrics.rowHeight) + extra }

    init(metrics initial: NeuralStageMetrics) {
        metrics = initial
        super.init(frame: .zero)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self, UITraitPreferredContentSizeCategory.self]) { (view: BrainOpenView, _) in view.traitsChanged() }
        clipsToBounds = true
        addSubview(stageBand)
        addSubview(stage)
        wordmark.isAccessibilityElement = false
        wordmark.isUserInteractionEnabled = false
        wordmark.lineBreakMode = .byClipping
        styleWordmark()
        addSubview(wordmark)
        addSubview(chips)
        addSubview(compactList)
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
        if !initial.isPhone { addSubview(account) }
        addSubview(footer)
        wire()
        isAccessibilityElement = false
        accessibilityContainerType = .semanticGroup
        installRotors()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func wire() {
        compactList.host = self
        compactList.onSelect = { [weak self] id in self?.selectFromCompactList(id) }
        compactList.onMore = { [weak self] in self?.openMore() }
        compactList.onLess = { [weak self] in self?.setListExpanded(false) }
        compactList.onAsk = { [weak self] in
            guard let self else { return }
            self.actions?.goToAsk(self.turnID)
        }
        accordionHeader.host = self
        accordionHeader.onCount = { [weak self] in self?.presentReader(focus: nil) }
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
            self.madeAccount?.suppressRevealOnce(id)
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

    var followedReplayStep: String?
    var lastFilterKey = ""

    override func layoutSubviews() {
        super.layoutSubviews()
        let split = metrics.arrangement == .split
        stage.frame = rect(metrics.stage)
        stageBand.frame = split ? stage.frame : CGRect(x: 0, y: stage.frame.minY, width: bounds.width, height: stage.frame.height)
        stageBand.backgroundColor = stage.backgroundColor
        stageLights.layout(in: stage.bounds)
        placeWordmark()
        if !metrics.isPhone { chips.frame = rect(metrics.filterChips ?? .zero) }
        let listRect = rect(metrics.list)
        if metrics.isPhone {
            madeList?.isHidden = true
            compactList.isHidden = false
            accordionHeader.isHidden = false
            accordionHeader.frame = rect(metrics.listHeader)
            compactList.frame = rect(metrics.listRows)
            hairline.isHidden = true
        } else if split {
            compactList.isHidden = true
            list.isHidden = false
            accordionHeader.isHidden = true
            list.frame = listRect
            account.frame = rect(metrics.readout)
            hairline.isHidden = false
            hairline.frame = CGRect(x: CGFloat(metrics.readout.x), y: 0, width: 1, height: CGFloat(metrics.brainHeight))
        } else {
            compactList.isHidden = true
            madeList?.isHidden = true
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

    override var accessibilityElements: [Any]? {
        get {
            if metrics.isPhone { return [stage, accordionHeader, compactList, footer] }
            var parts: [Any] = [stage, chips]
            parts.append(metrics.arrangement == .split ? list : accordionHeader)
            parts.append(account as UIView)
            parts.append(footer)
            return parts
        }
        set {}
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
}
