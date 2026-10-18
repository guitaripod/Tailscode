import TailscodeCore
import UIKit

/// The right side of an open brain, and on a phone its whole body: the agent talking to you. The
/// entity's header, whatever it is waiting on you for and the step it is on now stay pinned above a
/// scrolling story of what it was asked, its plan, what it said, what it thought, the work between
/// two utterances folded to a line, and what came of the turn. The step under the cursor is opened
/// inside the story, or, from an account wide enough for two columns, beside it.
///
/// The story is a list that exists only near the viewport, so a turn of two thousand steps costs a
/// screenful, and it follows a running turn until the reader scrolls away.
@MainActor
final class BrainAccountView: UIView, UICollectionViewDelegate {
    let env: BrainAccountEnv

    private let header = BrainAccountHeaderView()
    private let askCard = BrainAskCardView()
    private let nowView = BrainNowView()
    private let rule = UIView()
    private var collection: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private let detailScroll = UIScrollView()
    private let detailEmpty = UILabel()
    private var detailCard: BrainStepCard?
    private let pill = UIButton(type: .system)

    private var items: [BrainAccountItem] = []
    private var keys: [String: Int] = [:]
    private var account: NeuralAccount?
    private var arrivals: [String: CFTimeInterval] = [:]
    private var knownIDs = Set<String>()
    private var seeded = false
    private var userDragging = false
    private var lastCursor: String?
    private var suppressReveal: String?
    private var lastWidth: CGFloat = 0
    private var layoutPass = 0
    private var twoColumns = false
    private var detailStep: String?
    private var detailKey = ""
    private var storyWidth: CGFloat = 0
    private(set) var refreshes = 0
    private(set) var snapshots = 0

    init(env newEnv: BrainAccountEnv) {
        env = newEnv
        super.init(frame: .zero)
        var config = UICollectionLayoutListConfiguration(appearance: .plain)
        config.showsSeparators = false
        config.backgroundColor = .clear
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collection.backgroundColor = .clear
        collection.delegate = self
        collection.alwaysBounceVertical = true
        collection.contentInsetAdjustmentBehavior = .never
        collection.allowsSelection = false
        collection.selfSizingInvalidation = .disabled
        for kind in ["asked", "plan", "said", "thought", "work", "result"] {
            collection.register(BrainItemCell.self, forCellWithReuseIdentifier: kind)
        }
        dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collection) {
            [weak self] collection, indexPath, id in
            self?.cell(collection, indexPath: indexPath, id: id)
        }
        rule.backgroundColor = BrainCanvas.rule
        addSubview(collection)
        addSubview(detailScroll)
        addSubview(header)
        addSubview(askCard)
        addSubview(nowView)
        detailScroll.addSubview(detailEmpty)
        detailScroll.alwaysBounceVertical = true
        detailScroll.contentInsetAdjustmentBehavior = .never
        detailEmpty.numberOfLines = 0
        detailEmpty.textAlignment = .left
        askCard.isHidden = true
        nowView.isHidden = true
        var pillConfig = UIButton.Configuration.plain()
        pillConfig.background.backgroundColor = Theme.Color.secondaryBackground
        pillConfig.background.strokeColor = Theme.Color.accent
        pillConfig.background.strokeWidth = 1
        pillConfig.background.cornerRadius = 14
        pillConfig.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12)
        pillConfig.attributedTitle = AttributedString(
            NSAttributedString(
                string: Localized.text("Following paused: jump to latest"),
                attributes: Theme.Ramp.attributes(.control, color: Theme.Color.label)))
        pill.configuration = pillConfig
        pill.isHidden = true
        pill.addAction(
            UIAction { [weak self] _ in
                self?.env.jumpToLatest()
            }, for: .touchUpInside)
        addSubview(pill)
        addSubview(rule)
        isAccessibilityElement = false
        collection.accessibilityLabel = Localized.text("The agent's account of this turn")
        askCard.onGo = { [weak self] in self?.env.goToAsk() }
        askCard.onShow = { [weak self] id in self?.env.chooseStep(id, false) }
        nowView.onTap = { [weak self] id in self?.env.chooseStep(id, false) }
        env.heightChanged = { [weak self] in self?.relayout() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func cell(_ collection: UICollectionView, indexPath: IndexPath, id: String) -> UICollectionViewCell? {
        guard let item = items.first(where: { $0.id == id }) else { return nil }
        let cell = collection.dequeueReusableCell(withReuseIdentifier: item.reuseID, for: indexPath) as! BrainItemCell
        switch item.kind {
        case .said(let said):
            let view = (cell.content as? BrainSaidView) ?? BrainSaidView()
            if cell.content !== view { cell.install(view) }
            view.configure(item: item, said: said, env: env)
        case .thought(let thought):
            let view = (cell.content as? BrainThoughtView) ?? BrainThoughtView()
            if cell.content !== view { cell.install(view) }
            view.configure(item: item, thought: thought, env: env)
        case .work(let work):
            let view = (cell.content as? BrainWorkView) ?? BrainWorkView()
            if cell.content !== view { cell.install(view) }
            view.configure(item: item, work: work, env: env)
        case .asked(let asked):
            let view = (cell.content as? BrainAskedView) ?? BrainAskedView()
            if cell.content !== view { cell.install(view) }
            view.configure(asked: asked, env: env)
        case .plan(let plan):
            let view = (cell.content as? BrainPlanView) ?? BrainPlanView()
            if cell.content !== view { cell.install(view) }
            view.configure(plan: plan, env: env)
        case .result(let result):
            let view = (cell.content as? BrainResultView) ?? BrainResultView()
            if cell.content !== view { cell.install(view) }
            view.configure(result: result, env: env)
        }
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard let id = dataSource.itemIdentifier(for: indexPath), let start = arrivals[id],
            !UIAccessibility.isReduceMotionEnabled
        else { return }
        arrivals[id] = nil
        guard CACurrentMediaTime() - start < 0.5 else { return }
        cell.contentView.alpha = 0.55
        cell.contentView.transform = CGAffineTransform(translationX: 0, y: 12)
        UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseOut]) {
            cell.contentView.alpha = 1
            cell.contentView.transform = .identity
        }
    }

    /// What an item was made for: when this changes the item is drawn again, and while it does not
    /// the cell stays as it is.
    private func key(for item: BrainAccountItem) -> Int {
        var hasher = Hasher()
        hasher.combine(Int(storyWidth))
        hasher.combine(env.inlineCards)
        hasher.combine(env.input == .touch)
        switch item.kind {
        case .said(let said):
            hasher.combine(said.text.utf8.count)
            hasher.combine(said.showsSpeaker)
            hasher.combine(env.cursor == said.stepID)
            hasher.combine(env.hovered == said.stepID)
            hasher.combine(env.interaction.expandedText.contains(item.id))
            hasher.combine(env.justNow.contains(item.id))
        case .thought(let thought):
            hasher.combine(thought.text.utf8.count)
            hasher.combine(env.cursor == thought.stepID)
            hasher.combine(env.hovered == thought.stepID)
            hasher.combine(env.interaction.expandedText.contains(item.id))
        case .work(let work):
            hasher.combine(env.isOpen(item.id, work: work))
            hasher.combine(work.stepIDs.count)
            hasher.combine(env.interaction.rowCaps[item.id])
            hasher.combine(env.list.filter.query)
            for id in work.stepIDs {
                guard let step = env.model.step(id: id) else { continue }
                hasher.combine(step.status)
                hasher.combine(step.outputLines.count)
                hasher.combine(step.call?.call.output?.utf8.count ?? 0)
            }
            if let cursor = env.cursor, work.stepIDs.contains(cursor) { hasher.combine(cursor) }
            if let hovered = env.hovered, work.stepIDs.contains(hovered) { hasher.combine(hovered) }
            hasher.combine(env.outputExpanded)
            hasher.combine(env.isRunning)
        case .asked(let asked):
            hasher.combine(asked.text.utf8.count)
            hasher.combine(env.interaction.askedExpanded)
        case .plan(let plan):
            hasher.combine(plan.done)
            hasher.combine(plan.total)
            hasher.combine(plan.items.map { $0.text.count + ($0.isCurrent ? 1 : 0) })
            hasher.combine(env.interaction.planExpanded)
        case .result(let result):
            hasher.combine(result.changes.count)
            hasher.combine(result.checks.count)
            hasher.combine(result.unfixed.count)
            hasher.combine(result.answer)
        }
        return hasher.finalize()
    }

    /// Reads the model again and brings what is on screen to it.
    func refresh(prompt: String?, answer: String, animated: Bool = true) {
        refreshes += 1
        let model = env.model
        let next = model.account(answer: answer.isEmpty ? nil : answer, prompt: prompt)
        account = next
        let list = model.stepList
        let made = BrainAccountItems.make(model: model, account: next, list: list)
        let live = model.turn.outcome == .running
        let fresh = made.filter { !knownIDs.contains($0.id) }
        if seeded, live, list.isFollowing, !UIAccessibility.isReduceMotionEnabled {
            for item in fresh {
                arrivals[item.id] = CACurrentMediaTime()
                if item.isSaid { env.justNow.insert(item.id) }
            }
            scheduleJustNowExpiry()
        }
        knownIDs.formUnion(made.map(\.id))
        seeded = true
        items = made
        env.now = Date()
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(made.map(\.id), toSection: 0)
        var changed: [String] = []
        var nextKeys: [String: Int] = [:]
        for item in made {
            let value = key(for: item)
            nextKeys[item.id] = value
            if let old = keys[item.id], old != value { changed.append(item.id) }
        }
        keys = nextKeys
        let present = Set(dataSource.snapshot().itemIdentifiers)
        let reconfigure = changed.filter { present.contains($0) }
        if !reconfigure.isEmpty { snapshot.reconfigureItems(reconfigure) }
        snapshots += 1
        let wasAtEnd = isAtEnd
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            if !reconfigure.isEmpty { self.collection.collectionViewLayout.invalidateLayout() }
            self.afterApply(wasAtEnd: wasAtEnd, live: live)
        }
        refreshPinned()
        refreshDetail()
        pill.isHidden = !list.showsFollowPill
        header.isHidden = false
    }

    private func afterApply(wasAtEnd: Bool, live: Bool) {
        followCursor()
        if live, env.list.isFollowing { scrollToEnd(animated: seeded && !UIAccessibility.isReduceMotionEnabled && !wasAtEnd == false) }
    }

    private var isAtEnd: Bool {
        collection.contentOffset.y >= collection.contentSize.height - collection.bounds.height - 4
    }

    private var justNowTicket = 0

    private func scheduleJustNowExpiry() {
        justNowTicket += 1
        let ticket = justNowTicket
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.justNowTicket == ticket, !self.env.justNow.isEmpty else { return }
                let expired = self.env.justNow
                self.env.justNow = []
                var snapshot = self.dataSource.snapshot()
                snapshot.reconfigureItems(expired.filter { snapshot.itemIdentifiers.contains($0) })
                self.keys = self.keys.merging(expired.map { ($0, -1) }) { _, new in new }
                self.dataSource.apply(snapshot, animatingDifferences: false)
            }
        }
    }

    /// The cursor, the pointer or something unfolded changed without the story's words changing:
    /// what shows it is drawn again.
    func restyle() {
        var changed: [String] = []
        for item in items {
            let value = key(for: item)
            if keys[item.id] != value {
                keys[item.id] = value
                changed.append(item.id)
            }
        }
        if !changed.isEmpty {
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems(changed.filter { snapshot.itemIdentifiers.contains($0) })
            dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
                self?.collection.collectionViewLayout.invalidateLayout()
            }
        }
        followCursor()
        refreshDetail()
        pill.isHidden = !env.list.showsFollowPill
    }

    private func relayout() {
        collection.collectionViewLayout.invalidateLayout()
        let ids = dataSource.snapshot().itemIdentifiers
        if !ids.isEmpty {
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems(ids)
            keys = [:]
            dataSource.apply(snapshot, animatingDifferences: false)
        }
        refreshDetail()
    }

    private func followCursor() {
        let cursor = env.cursor
        defer { lastCursor = cursor }
        guard let cursor, cursor != lastCursor else { return }
        if suppressReveal == cursor {
            suppressReveal = nil
            return
        }
        reveal(step: cursor)
    }

    /// Notes that the next cursor move came from the account itself, which already shows it.
    func suppressRevealOnce(_ id: String) { suppressReveal = id }

    func reveal(step id: String, animated: Bool = true) {
        guard let account, let item = account.item(containing: id) else { return }
        var itemID = item.id
        if case .work = item, let index = items.firstIndex(where: { $0.id == itemID }), index > 0,
            items[index - 1].isSaid
        {
            itemID = items[index - 1].id
        }
        guard let index = dataSource.snapshot().indexOfItem(itemID) else { return }
        collection.scrollToItem(
            at: IndexPath(item: index, section: 0), at: .top,
            animated: animated && !UIAccessibility.isReduceMotionEnabled)
    }

    func scrollToEnd(animated: Bool) {
        collection.layoutIfNeeded()
        let target = max(0, collection.contentSize.height - collection.bounds.height)
        collection.setContentOffset(
            CGPoint(x: 0, y: target), animated: animated && !UIAccessibility.isReduceMotionEnabled)
    }

    func scrollToStart() {
        collection.setContentOffset(.zero, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    func scroll(by points: CGFloat) {
        let target = min(
            max(0, collection.contentOffset.y + points),
            max(0, collection.contentSize.height - collection.bounds.height))
        collection.setContentOffset(CGPoint(x: 0, y: target), animated: false)
    }

    private func refreshPinned() {
        guard let account else { return }
        let model = env.model
        let vitals = account.vitals(now: env.now, lastActivity: env.lastActivity)
        header.configure(header: account.header, vitals: vitals)
        if let ask = account.askItem {
            askCard.configure(ask: ask, step: model.step(id: ask.stepID))
            askCard.isHidden = false
        } else {
            askCard.isHidden = true
        }
        if let live = account.live, account.askItem == nil {
            nowView.configure(live: live, vitals: vitals, face: model.face)
            nowView.isHidden = false
        } else {
            nowView.isHidden = true
        }
        setNeedsLayout()
    }

    /// The clock moved: the header's and the Now line's words that depend on it are written again.
    func tick() {
        guard account != nil else { return }
        env.now = Date()
        refreshPinned()
    }

    private func refreshDetail() {
        guard twoColumns else {
            detailScroll.isHidden = true
            return
        }
        detailScroll.isHidden = false
        let model = env.model
        let step = model.previewedStep
        let key = "\(step ?? "-")|\(model.revision)|\(env.outputExpanded)|\(Int(detailScroll.bounds.width))|\(model.turn.outcome == .running ? env.model.steps.last?.outputLines.count ?? 0 : 0)"
        guard key != detailKey else { return }
        detailKey = key
        detailCard?.removeFromSuperview()
        detailCard = nil
        detailEmpty.isHidden = step != nil
        guard let step else {
            detailEmpty.attributedText = NSAttributedString(
                string: Localized.text("Select a step to read it here."),
                attributes: Theme.Ramp.attributes(.cardBody, color: Theme.Color.secondaryLabel))
            setNeedsLayout()
            return
        }
        let running = env.isRunningStep(step)
        let spec = BrainAccountEnv.CardSpec(stepID: step, preview: model.browseState.hovered == step && model.pinnedStep != step, live: running)
        guard let card = env.makeCard(for: spec) else { return }
        card.layer.borderWidth = 0
        card.onLayoutChange = { [weak self] in
            self?.detailKey = ""
            self?.refreshDetail()
        }
        detailScroll.addSubview(card)
        detailCard = card
        setNeedsLayout()
    }

    /// Sets the account's parts for the rect Core's metrics gave it.
    func configure(metrics: NeuralStageMetrics) {
        env.metrics = metrics
        twoColumns = metrics.arrangement == .split && metrics.accountLayout == .split
        env.inlineCards = !twoColumns
        storyWidth = CGFloat(metrics.story.width)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let metrics = env.metrics
        let split = metrics.arrangement == .split
        let story = twoColumns ? CGFloat(metrics.story.width) : width
        storyWidth = story
        var y: CGFloat = 0
        let headerHeight = header.height(forWidth: story)
        header.frame = CGRect(x: 0, y: y, width: story, height: headerHeight)
        y += headerHeight
        if !askCard.isHidden {
            let inset: CGFloat = split ? 20 : 12
            let askWidth = story - inset - 12
            let height = askCard.height(forWidth: askWidth)
            askCard.frame = CGRect(x: inset, y: y + 6, width: askWidth, height: height)
            y += height + 12
        }
        if !nowView.isHidden {
            let height = nowView.height(forWidth: story)
            nowView.frame = CGRect(x: 0, y: y, width: story, height: height)
            y += height
        }
        let collectionWidth = twoColumns ? story : min(width, split ? CGFloat(NeuralStageMetrics.storyMax) : width)
        collection.frame = CGRect(x: 0, y: y, width: collectionWidth, height: max(0, bounds.height - y))
        collection.contentInset = UIEdgeInsets(top: 4, left: 0, bottom: 12, right: 0)
        if twoColumns, let detail = metrics.detail {
            let x = CGFloat(detail.x - metrics.account.x)
            detailScroll.frame = CGRect(x: x, y: 0, width: CGFloat(detail.width), height: bounds.height)
            detailEmpty.frame = CGRect(x: 4, y: 20, width: detailScroll.bounds.width - 20, height: 40)
            if let card = detailCard {
                let cardWidth = detailScroll.bounds.width - 16
                let height = card.fittedHeight(width: cardWidth)
                card.frame = CGRect(x: 0, y: 8, width: cardWidth, height: height)
                detailScroll.contentSize = CGSize(width: detailScroll.bounds.width, height: height + 24)
            }
            rule.isHidden = true
        } else {
            detailScroll.isHidden = true
            rule.isHidden = true
        }
        let size = pill.sizeThatFits(CGSize(width: bounds.width, height: 30))
        pill.frame = CGRect(
            x: (collection.frame.width - size.width) / 2, y: collection.frame.maxY - size.height - 12,
            width: size.width, height: size.height)
        if abs(lastWidth - collection.frame.width) > 0.5 {
            lastWidth = collection.frame.width
            collection.collectionViewLayout.invalidateLayout()
            if !items.isEmpty {
                var snapshot = dataSource.snapshot()
                snapshot.reconfigureItems(snapshot.itemIdentifiers)
                keys = [:]
                dataSource.apply(snapshot, animatingDifferences: false)
            }
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { userDragging = true }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if userDragging, scrollView === collection, env.model.turn.outcome == .running {
            env.scrolledByHand()
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { userDragging = false }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { userDragging = false }

    #if DEBUG
        /// Unfolds the nth work line, for a debug walk.
        func walkUnfold(_ number: Int) {
            let works = items.filter { $0.isWork }
            guard works.indices.contains(number - 1) else { return }
            env.toggleWork(works[number - 1].id)
        }
    #endif

    var itemCount: Int { items.count }
    var realizedCells: Int { collection.visibleCells.count }
    var contentHeight: CGFloat { collection.contentSize.height }
    var offset: CGFloat { collection.contentOffset.y }
    var visibleText: String {
        var words: [String] = []
        func walk(_ view: UIView) {
            if let label = view as? UILabel, let text = label.attributedText?.string, !text.isEmpty {
                words.append(text)
            }
            for child in view.subviews { walk(child) }
        }
        for view in [header, askCard, nowView] where !view.isHidden { walk(view) }
        for cell in collection.visibleCells { walk(cell) }
        return words.joined(separator: "\n")
    }
    var pinnedFrames: (header: CGRect, ask: CGRect?, now: CGRect?, collection: CGRect, detail: CGRect?) {
        (
            header.frame, askCard.isHidden ? nil : askCard.frame, nowView.isHidden ? nil : nowView.frame,
            collection.frame, detailScroll.isHidden ? nil : detailScroll.frame
        )
    }
}

extension BrainAccountEnv {
    func jumpToLatest() { jumpHandler() }
    func goToAsk() { askHandler() }
    func scrolledByHand() { scrolledHandler() }
}
