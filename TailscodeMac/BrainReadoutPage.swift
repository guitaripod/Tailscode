import AppKit
import TailscodeCore

/// The top row of a card or of the detail column: what is read (a pulse and a word for a running
/// turn), the zone's shape and name, the status in its tone, a pin mark, and where the step stands
/// in the turn at the right.
@MainActor
final class AccountPageHeader: NSView {
    struct Content {
        var leadWord: String?
        var leadMotion: NeuralMotion = .breath
        var leadWarn = false
        var zone: NeuralZone?
        var zoneWord: String
        var chipWord: String?
        var chipTone: NeuralTone = .quiet
        var chipVerdict: NeuralVerdict.Step?
        var pinned = false
        var counter: String?
        var extraChip: (word: String, tone: NeuralTone)?
    }

    private var content = Content(zoneWord: "")
    private var paint: AccountPaint
    private let pulse = AccountPulseDot()
    private let chip = AccountPill()
    private let extra = AccountPill()
    private var leadWidth: CGFloat = 0

    init(paint: AccountPaint) {
        self.paint = paint
        super.init(frame: .zero)
        addSubview(pulse)
        addSubview(chip)
        addSubview(extra)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ next: Content, paint: AccountPaint) {
        content = next
        self.paint = paint
        pulse.isHidden = next.leadWord == nil
        if next.leadWord != nil {
            pulse.configure(
                color: next.leadWarn ? paint.warn : paint.accent, motion: next.leadMotion, diameter: 7)
        }
        chip.isHidden = next.chipWord == nil
        if let word = next.chipWord {
            chip.role = .badge
            chip.height = 18
            chip.color = paint.tone(next.chipTone)
            chip.verdict = next.chipVerdict
            chip.word = word
        }
        extra.isHidden = next.extraChip == nil
        if let extraChip = next.extraChip {
            extra.height = 18
            extra.color = paint.tone(extraChip.tone)
            extra.verdict = nil
            extra.word = extraChip.word
        }
        setAccessibilityLabel(
            [next.leadWord, next.zoneWord, next.chipWord, next.counter].compactMap { $0 }.joined(separator: ", "))
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        if let word = content.leadWord {
            pulse.frame.origin = CGPoint(x: 0, y: (bounds.height - pulse.frame.height) / 2)
            x = pulse.frame.maxX + 6
            x += AccountType.width(word, .sectionLabel) + 10
        }
        leadWidth = x
        if content.zone != nil { x += 18 + 8 }
        x += AccountType.width(content.zoneWord, .sectionLabel) + 10
        if !chip.isHidden {
            chip.frame.origin = CGPoint(x: x, y: (bounds.height - chip.frame.height) / 2)
            x = chip.frame.maxX + 10
        }
        if !extra.isHidden {
            extra.frame.origin = CGPoint(x: x, y: (bounds.height - extra.frame.height) / 2)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let mid = bounds.midY
        var x: CGFloat = 0
        if let word = content.leadWord {
            x = pulse.frame.maxX + 6
            let used = AccountType.draw(
                word, .sectionLabel, content.leadWarn ? paint.warn : paint.accent, x: x, midY: mid)
            x += used + 10
        }
        if let zone = content.zone {
            AccountGlyphs.zone(zone, cx: x + 9, cy: mid, color: paint.zone(zone))
            x += 18 + 8
        }
        let used = AccountType.draw(content.zoneWord, .sectionLabel, paint.text.withAlphaComponent(0.85), x: x, midY: mid)
        x += used + 10
        var cursor = x
        if !chip.isHidden { cursor = chip.frame.maxX + 10 }
        if !extra.isHidden { cursor = extra.frame.maxX + 10 }
        var right = bounds.width
        if let counter = content.counter {
            let width = AccountType.draw(
                counter, .rowStamp, paint.dim, x: right, midY: mid, maxWidth: max(right - cursor, 1),
                rightAligned: true)
            right -= width + 10
        }
        if content.pinned {
            let word = "\u{25CF} " + Localized.text("Pinned").lowercased()
            AccountType.draw(word, .rowNote, paint.dim, x: cursor, midY: mid, maxWidth: max(right - cursor, 1))
        }
    }
}

/// The two facts at the foot of a card or the column, in the quiet ink: where the step stands in
/// the transcript, and when it began; the second is the one left out when they do not fit.
@MainActor
final class AccountPageFoot: NSView {
    var left = "" { didSet { needsDisplay = true } }
    var right = "" { didSet { needsDisplay = true } }
    var paint: AccountPaint { didSet { needsDisplay = true } }
    var ruled = false { didSet { needsDisplay = true } }

    init(paint: AccountPaint) {
        self.paint = paint
        super.init(frame: .zero)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        if ruled {
            paint.rule.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        }
        let mid = bounds.midY + (ruled ? 0.5 : 0)
        let leftWidth = AccountType.width(left, .rowStamp)
        let rightWidth = AccountType.width(right, .rowStamp)
        let fits = leftWidth + rightWidth + 12 + 32 <= bounds.width
        AccountType.draw(left, .rowStamp, paint.dim, x: 0, midY: mid, maxWidth: bounds.width)
        if fits, !right.isEmpty {
            AccountType.draw(right, .rowStamp, paint.dim, x: bounds.width, midY: mid, rightAligned: true)
        }
    }
}

/// A soft fade of the canvas, drawn over the foot of a scroll region that has more below it.
@MainActor
final class AccountFadeView: NSView {
    var color = NSColor.windowBackgroundColor { didSet { needsDisplay = true } }

    nonisolated override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let gradient = NSGradient(colors: [color.withAlphaComponent(0), color]) else { return }
        gradient.draw(in: bounds, angle: 90)
    }
}

/// A step's parts as the page draws them, whether they came from a step that was read or from
/// the one a running turn is on.
struct AccountStepParts {
    let stepID: String
    let header: NeuralReadout.Header
    let subject: NeuralReadout.Subject
    let relations: [NeuralReadout.Relation]
    let why: NeuralReadout.Why?
    let result: NeuralReadout.Result?
    let facts: NeuralReadout.Facts

    init(
        stepID: String, header: NeuralReadout.Header, subject: NeuralReadout.Subject,
        relations: [NeuralReadout.Relation], why: NeuralReadout.Why?, result: NeuralReadout.Result?,
        facts: NeuralReadout.Facts
    ) {
        self.stepID = stepID
        self.header = header
        self.subject = subject
        self.relations = relations
        self.why = why
        self.result = result
        self.facts = facts
    }

    init(_ step: NeuralReadout.Step) {
        self.init(
            stepID: step.stepID, header: step.header, subject: step.subject, relations: step.relations,
            why: step.why, result: step.result, facts: step.facts)
    }
}

/// What the account's right side says about the step or the turn it is about: a card unfolded
/// under a row, or the detail column beside the story. It is one component with several
/// subjects, built entirely from `NeuralReadout`'s plain values; every word is Core's and this
/// decides only how a rectangle is painted.
@MainActor
final class AccountReadoutPage: NSView {
    enum Mode {
        case card
        case column
    }

    let mode: Mode
    unowned let owner: BrainAccountView
    var paint: AccountPaint
    var isPreview = false { didSet { needsDisplay = true } }
    var isLive = false
    private(set) var zone: NeuralZone?
    let header: AccountPageHeader
    let foot: AccountPageFoot
    let flow = AccountStack()
    private(set) var scroll: HandoffScrollView?
    private let document = AccountDocumentView()
    private let fade = AccountFadeView()
    private(set) var shown: NeuralReadout?
    private(set) var stepID: String?
    var onHeight: (() -> Void)?
    var copyText: String?
    var outputs: [AccountOutputBlock] = []
    var diffs: [AccountDiffBlock] = []
    var expandedDiffStep: String?
    private var scrolledFrom: CGFloat?
    var expandedSubject = false
    var copyButton: AccountButton?
    var nowTail: AccountOutputBlock?
    private var boundsObserver: NSObjectProtocol?
    private(set) var swaps = 0

    static let columnLeft: CGFloat = 19
    static let columnRight: CGFloat = 12
    static let headerHeight: CGFloat = 40
    static let footHeight: CGFloat = 32

    init(owner: BrainAccountView, mode: Mode) {
        self.owner = owner
        self.mode = mode
        paint = owner.paint
        header = AccountPageHeader(paint: owner.paint)
        foot = AccountPageFoot(paint: owner.paint)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(header)
        flow.onHeight = { [weak self] in self?.flowChanged() }
        if mode == .column {
            let scrolling = HandoffScrollView()
            scrolling.documentView = document
            document.addSubview(flow)
            addSubview(scrolling)
            scroll = scrolling
            addSubview(fade)
            foot.ruled = true
            scrolling.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scrolling.contentView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateFade() }
            }
        } else {
            addSubview(flow)
        }
        addSubview(foot)
        setAccessibilityElement(false)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }

    nonisolated override var isFlipped: Bool { true }

    var zoneTone: NSColor { zone.map { paint.zone($0) } ?? paint.rule2 }

    func retheme() {
        paint = owner.paint
        shown = nil
        needsDisplay = true
    }


    /// Brings the page to `value`. The same words arriving again leave it alone.
    func show(_ value: NeuralReadout, paint next: AccountPaint, animate: Bool) {
        if let shown, shown == value, next.inks.palette.name == paint.inks.palette.name { return }
        paint = next
        let previous = shown?.step?.stepID
        let sameStep = previous != nil && previous == value.step?.stepID
        shown = value
        swaps += 1
        rebuild(value)
        if animate, !owner.reduceMotion, !sameStep { fadeIn() }
        if !sameStep { resetScroll() }
    }

    /// A running step's compact card: no relations and no reason, because the note above it has
    /// said why; its output tail streams under it with a caret.
    func showLive(_ step: NeuralReadout.Step, tail: NeuralReadout.Tail) {
        shown = nil
        flow.removeAll()
        outputs = []
        diffs = []
        copyButton = nil
        stepID = step.stepID
        forgetDiffIfMoved()
        zone = step.header.zone
        header.show(stepHeader(step.header), paint: paint)
        buildStep(
            AccountStepParts(
                stepID: step.stepID, header: step.header, subject: step.subject, relations: [], why: nil,
                result: nil, facts: step.facts))
        if !tail.lines.isEmpty {
            let box = AccountStack()
            let label = AccountLabelRow(AccountWords.output, paint: paint)
            label.rightWords = AccountWords.lastLines(tail.lines.count)
            box.add(label)
            let block = AccountOutputBlock(
                lines: tail.lines.map { AccountOutputBlock.Line(text: $0.text, tone: $0.tone) }, hidden: 0,
                moreLabel: nil, failed: false, caret: true, allLines: nil, host: owner.host, paint: paint)
            box.add(block, before: 6)
            flow.add(box, before: 16)
        }
        foot.left = Self.factsLeft(step.facts)
        foot.right = step.facts.started ?? ""
        foot.paint = paint
        needsLayout = true
        needsDisplay = true
        onHeight?()
    }

    private func fadeIn() {
        guard let layer else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.0
        animation.toValue = 1.0
        animation.duration = 0.09
        layer.add(animation, forKey: "swap")
    }

    private func rebuild(_ value: NeuralReadout) {
        flow.removeAll()
        outputs = []
        diffs = []
        nowTail = nil
        copyText = nil
        expandedSubject = false
        copyButton = nil
        stepID = value.step?.stepID
        forgetDiffIfMoved()
        header.show(headerContent(value), paint: paint)
        switch value.body {
        case .step(let step):
            zone = step.header.zone
            buildStep(AccountStepParts(step))
            foot.left = Self.factsLeft(step.facts)
            foot.right = step.facts.turnBegan ?? ""
        case .digest(let digest):
            zone = nil
            buildDigest(digest)
            foot.left = NeuralNoticeLine.countText(tools: 0, steps: digest.ticks.count)
            foot.right = owner.beganClock ?? ""
        case .now(let now):
            zone = now.step?.header.zone
            buildNow(now)
            foot.left = now.step.map { Self.factsLeft($0.facts) } ?? ""
            foot.right = now.step?.facts.started ?? ""
        case .ask(let ask):
            zone = ask.step.header.zone
            buildAsk(ask)
            foot.left = Self.factsLeft(ask.step.facts)
            foot.right = ask.step.facts.clock.map { Localized.text("asked %@", $0) } ?? ""
        case .zone(let list):
            zone = list.zone
            buildZone(list)
            foot.left = Localized.text("%1$lld of %2$lld steps", list.rows.count, owner.model.steps.count)
            foot.right = ""
        case .replay(let replay):
            zone = replay.current?.header.zone
            buildReplay(replay)
            foot.left = replay.current.map { Self.factsLeft($0.facts) } ?? NeuralReading.replayLabel
            foot.right = ""
        }
        foot.paint = paint
        needsLayout = true
        needsDisplay = true
        onHeight?()
    }

    static func factsLeft(_ facts: NeuralReadout.Facts) -> String {
        [facts.message, facts.clock].compactMap { $0 }.joined(separator: "  ")
    }

    private func verdictOf(_ kind: NeuralReadout.ChipKind) -> NeuralVerdict.Step? {
        switch kind {
        case .done: return nil
        case .failed: return .failed
        case .running: return .running
        case .waiting: return .waiting
        case .stalled: return .stalled
        case .stopped: return .stopped
        case .retried, .fixed: return .fixed
        case .hitError: return .tryingAgain
        }
    }

    func stepHeader(_ header: NeuralReadout.Header, lead: String? = nil, warn: Bool = false)
        -> AccountPageHeader.Content
    {
        AccountPageHeader.Content(
            leadWord: lead, leadMotion: warn ? .heartbeat : .breath, leadWarn: warn, zone: header.zone,
            zoneWord: header.label, chipWord: header.chip.word, chipTone: header.chip.tone,
            chipVerdict: verdictOf(header.chip.kind), pinned: header.isPinned, counter: header.counter)
    }

    private func headerContent(_ value: NeuralReadout) -> AccountPageHeader.Content {
        switch value.body {
        case .step(let step): return stepHeader(step.header)
        case .digest(let digest):
            let turn = owner.model.turn
            let (word, tone): (String, NeuralTone) = {
                switch turn.outcome {
                case .settled, .running: return (AccountWords.settled.uppercased(), .live)
                case .failed: return (NeuralReading.chipWord(.failed), .danger)
                case .stopped, .interrupted, .answerless: return (NeuralReading.chipWord(.stopped), .quiet)
                }
            }()
            return AccountPageHeader.Content(
                zone: nil, zoneWord: AccountWords.turn, chipWord: word, chipTone: tone,
                counter: NeuralNoticeLine.countText(tools: 0, steps: digest.ticks.count))
        case .now(let now):
            if let step = now.step { return stepHeader(step.header, lead: now.label) }
            return AccountPageHeader.Content(leadWord: now.label, zone: nil, zoneWord: "")
        case .ask(let ask): return stepHeader(ask.step.header, lead: AccountWords.needsYou, warn: true)
        case .zone(let list):
            let verdicts = list.rows.compactMap { owner.model.verdict(ofStep: $0.stepID)?.verdict }
            let failed = verdicts.filter { $0 == .failed }.count
            let fixed = verdicts.filter { $0 == .fixed }.count
            let extra: (word: String, tone: NeuralTone)? =
                failed > 0
                ? (Localized.text("%lld FAILED", failed), .danger)
                : (fixed > 0 ? (Localized.text("%lld FIXED", fixed), .attention) : nil)
            return AccountPageHeader.Content(
                zone: list.zone, zoneWord: list.label,
                chipWord: NeuralNoticeLine.countText(tools: 0, steps: list.rows.count).uppercased(),
                chipTone: .live, counter: nil, extraChip: extra)
        case .replay(let replay):
            if let current = replay.current {
                return stepHeader(current.header, lead: "\u{25B6} " + AccountWords.replaying)
            }
            return AccountPageHeader.Content(
                leadWord: "\u{25B6} " + AccountWords.replaying, leadMotion: .still, zone: nil, zoneWord: "")
        }
    }


    func flowChanged() {
        needsLayout = true
        onHeight?()
    }

    /// The height a card needs at `width`.
    func fitCard(width: CGFloat) -> CGFloat {
        let inner = max(width - 33, 40)
        let headerHeight: CGFloat = isLive ? 32 : 36
        let body = flow.fit(width: inner)
        let total = headerHeight + body + 8 + 28 + 6
        setFrameSize(NSSize(width: width, height: total))
        placeCard(width: width, headerHeight: headerHeight, body: body)
        return total
    }

    private func placeCard(width: CGFloat, headerHeight: CGFloat, body: CGFloat) {
        let inner = max(width - 33, 40)
        header.frame = CGRect(x: 18, y: 0, width: inner, height: headerHeight)
        flow.frame = CGRect(x: 18, y: headerHeight, width: inner, height: body)
        foot.frame = CGRect(x: 18, y: headerHeight + body + 8, width: inner, height: 28)
    }

    override func layout() {
        super.layout()
        switch mode {
        case .card:
            let headerHeight: CGFloat = isLive ? 32 : 36
            if bounds.width > 1 {
                let inner = max(bounds.width - 33, 40)
                let body = flow.fit(width: inner)
                placeCard(width: bounds.width, headerHeight: headerHeight, body: body)
            }
        case .column:
            layoutColumn()
        }
    }

    private func layoutColumn() {
        let left = Self.columnLeft
        let right = Self.columnRight
        let width = bounds.width
        let inner = max(width - left - right, 80)
        header.frame = CGRect(x: left, y: 0, width: inner, height: Self.headerHeight)
        foot.frame = CGRect(x: left, y: bounds.height - Self.footHeight, width: inner, height: Self.footHeight)
        let region = CGRect(
            x: 0, y: Self.headerHeight, width: width,
            height: max(0, bounds.height - Self.headerHeight - Self.footHeight))
        scroll?.frame = region
        let body = flow.fit(width: inner)
        flow.frame = CGRect(x: left, y: 4, width: inner, height: body)
        let documentHeight = max(body + 16, region.height)
        document.frame = CGRect(x: 0, y: 0, width: width, height: documentHeight)
        fade.frame = CGRect(x: 0, y: region.maxY - NeuralStageMetrics.readoutFade, width: width, height: NeuralStageMetrics.readoutFade)
        fade.color = paint.canvas
        updateFade()
    }

    private func updateFade() {
        guard let scroll else { return }
        let clip = scroll.contentView.bounds
        let more = clip.maxY < document.frame.height - 1
        fade.isHidden = !more
    }

    var moreBelow: Bool { !fade.isHidden }

    /// Scrolls the column to the top, for a new subject.
    func resetScroll() {
        scroll?.contentView.scroll(to: .zero)
        scroll?.reflectScrolledClipView(scroll!.contentView)
    }

    override func draw(_ dirtyRect: NSRect) {
        switch mode {
        case .card:
            let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
            let shape = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            paint.canvas.setFill()
            shape.fill()
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            zoneTone.setFill()
            NSRect(x: 0, y: 0, width: 3.5, height: bounds.height).fill()
            NSGraphicsContext.restoreGraphicsState()
            paint.rule2.setStroke()
            shape.lineWidth = 1
            if isPreview { shape.setLineDash([3, 2.4], count: 2, phase: 0) }
            shape.stroke()
        case .column:
            zoneTone.setFill()
            NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
        }
    }


    /// The first control the page offers, for Enter on the account.
    func focusFirstControl() -> Bool {
        func find(_ view: NSView) -> AccountButton? {
            if view.isHidden { return nil }
            if let button = view as? AccountButton { return button }
            for child in view.subviews {
                if let found = find(child) { return found }
            }
            return nil
        }
        guard let button = find(self), let window else { return false }
        button.keyboardEngaged = true
        return window.makeFirstResponder(button)
    }

    func toggleOutput() -> Bool {
        if let block = outputs.first(where: { $0.canExpand }) {
            block.toggle()
            return true
        }
        guard let diff = diffs.first(where: { $0.canExpand }) else { return false }
        diff.toggle()
        return true
    }

    /// A reader left open belongs to the step it was opened on: another step starts closed.
    private func forgetDiffIfMoved() {
        guard expandedDiffStep != stepID else { return }
        expandedDiffStep = nil
        scrolledFrom = nil
    }

    /// How tall a reader of a whole file may be: where the page scrolls on its own, what its
    /// region shows less the label above and the bar under the file, so the file and both of its
    /// buttons are in view together; in a card inside the story, four fifths of what the story
    /// shows.
    func readerHeight() -> CGFloat {
        if mode == .column, let scroll, scroll.bounds.height > 160 {
            return max(200, min(640, scroll.bounds.height - 82))
        }
        let shown = owner.viewHeight > 0 ? owner.viewHeight : (owner.window?.contentView?.bounds.height ?? 800)
        return max(300, min(640, (shown * 0.8).rounded()))
    }

    /// A reader opened or closed: the model learns the output is out, and the page scrolls until
    /// the file leads, then puts itself back where it was when the file is put away.
    func diffToggled(_ block: AccountDiffBlock, expanded: Bool, stepID: String) {
        expandedDiffStep = expanded ? stepID : nil
        owner.host?.updateModel { $0.setBrowseOutputExpanded(expanded) }
        for (delay, first) in [(0.06, true), (0.35, false)] {
            Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self, weak block] _ in
                MainActor.assumeIsolated {
                    guard let self, let block, block.expanded == expanded else { return }
                    self.placeDiff(block, opening: expanded, first: first)
                }
            }
        }
    }

    private(set) var placements = 0
    var documentHeight: CGFloat { document.frame.height }

    /// Brings the file to the top, once when the reader opens and again after the story has
    /// measured the card's new height, which a first look at a story that is still the old height
    /// cannot scroll as far as the file needs.
    private func placeDiff(_ block: AccountDiffBlock, opening: Bool, first: Bool) {
        placements += 1
        layoutSubtreeIfNeeded()
        if let scroll {
            let clip = scroll.contentView
            if opening {
                let top = block.convert(block.bounds, to: document).minY
                if first { scrolledFrom = clip.bounds.minY }
                moveScroll(to: top - 28)
            } else if let back = scrolledFrom, first {
                moveScroll(to: back)
                scrolledFrom = nil
            }
            return
        }
        if opening {
            let top = block.convert(block.bounds, to: owner.document).minY
            if first { scrolledFrom = owner.scrollY }
            owner.scrollTo(top - 28, animated: first)
        } else if let back = scrolledFrom {
            owner.scrollTo(back, animated: first)
            if !first { scrolledFrom = nil }
        }
    }

    private func moveScroll(to y: CGFloat) {
        guard let scroll else { return }
        let clip = scroll.contentView
        let limit = max(0, document.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(y, 0), limit)))
        scroll.reflectScrolledClipView(clip)
    }

    var visibleText: String {
        var words: [String] = []
        func walk(_ view: NSView) {
            if view.isHidden { return }
            if let label = view as? AccountLabelRow { words.append(label.label) }
            if let text = view as? AccountTextView { words.append(text.string) }
            if let button = view as? AccountButton { words.append(button.title) }
            if let pill = view as? AccountPill { words.append(pill.word) }
            for child in view.subviews { walk(child) }
        }
        walk(self)
        words.append(header.accessibilityLabel() ?? "")
        words.append(foot.left)
        return words.joined(separator: "\n")
    }
}
