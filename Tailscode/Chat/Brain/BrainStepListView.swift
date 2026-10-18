import TailscodeCore
import UIKit

/// What every part of an open brain asks of the one it belongs to: the model as it stands, and a
/// way to do something to it. The parts hold no state about the turn; they draw `model` and say
/// what the person did.
@MainActor
protocol BrainBrowsing: AnyObject {
    var browseModel: NeuralBrainModel? { get }
    func browse(_ action: NeuralBrowse.Action)
    func copySubject(of id: String)
    var browseInput: ChatInput { get }
}

/// The header of the step list: a search that is a quiet button until it is opened into a field,
/// the failed toggle, and the count, which says "29 steps" or "5 of 29" in the accent while a
/// filter narrows the list.
@MainActor
final class BrainListHeader: UIView, UITextFieldDelegate {
    weak var host: BrainBrowsing?
    var showsFailed = true

    private let searchButton = UIButton(type: .system)
    private let field = UITextField()
    private let count = UILabel()
    private let failed = BrainFailedChip()
    private let rule = UIView()
    private var searchOpen = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        var config = UIButton.Configuration.plain()
        config.image = BrainCanvas.image("magnifyingglass", size: 12)
        config.imagePadding = 6
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 8)
        config.baseForegroundColor = Theme.Color.secondaryLabel
        config.attributedTitle = AttributedString(
            NSAttributedString(
                string: Localized.text("Search"),
                attributes: Theme.Ramp.attributes(.control, color: Theme.Color.secondaryLabel)))
        searchButton.configuration = config
        searchButton.addAction(
            UIAction { [weak self] _ in
                self?.host?.browse(.key(.character("/")))
            }, for: .touchUpInside)
        searchButton.accessibilityLabel = Localized.text("Search the steps")

        field.font = Theme.Ramp.font(.control)
        field.textColor = Theme.Color.label
        field.attributedPlaceholder = NSAttributedString(
            string: Localized.text("Search the steps"),
            attributes: [.foregroundColor: Theme.Color.secondaryLabel, .font: Theme.Ramp.font(.control)])
        field.borderStyle = .none
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.returnKeyType = .search
        field.clearButtonMode = .whileEditing
        field.layer.cornerRadius = 8
        field.layer.borderWidth = 1
        field.layer.cornerCurve = .continuous
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 1))
        field.leftViewMode = .always
        field.delegate = self
        field.isHidden = true
        field.addTarget(self, action: #selector(changed), for: .editingChanged)
        field.accessibilityLabel = Localized.text("Search the steps")

        count.adjustsFontForContentSizeCategory = true
        count.textAlignment = .right
        failed.onTap = { [weak self] in self?.host?.browse(.failedToggle) }
        rule.backgroundColor = Theme.Color.separator
        for view in [rule, searchButton, field, failed, count] { addSubview(view) }
        isAccessibilityElement = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(list: NeuralStepList, searchOpen open: Bool) {
        searchOpen = open
        searchButton.isHidden = open
        field.isHidden = !open
        if field.text != list.filter.search, !field.isFirstResponder { field.text = list.filter.search }
        field.layer.borderColor = BrainCanvas.rule.resolvedColor(with: traitCollection).cgColor
        field.backgroundColor = Theme.Color.background
        let filtered = list.filter.isActive
        count.attributedText = NSAttributedString(
            string: list.countLabel,
            attributes: Theme.Ramp.attributes(
                .rowStamp, color: filtered ? Theme.Color.accent : Theme.Color.secondaryLabel,
                alignment: .right))
        failed.isHidden = !(showsFailed && list.offersFailedFilter)
        failed.configure(count: list.failedCount, isOn: list.filter.failedOnly)
        setNeedsLayout()
    }

    func focusSearch() {
        searchButton.isHidden = true
        field.isHidden = false
        field.becomeFirstResponder()
    }

    func endSearch() {
        field.resignFirstResponder()
    }

    @objc private func changed() {
        host?.browse(.searchText(field.text ?? ""))
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        host?.browse(.key(.enter))
        textField.resignFirstResponder()
        return false
    }

    func textFieldShouldClear(_ textField: UITextField) -> Bool {
        host?.browse(.searchText(""))
        return true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        rule.frame = CGRect(x: 0, y: bounds.height - 1 / UIScreen.main.scale, width: bounds.width, height: 1 / UIScreen.main.scale)
        let countSize = count.attributedText?.size() ?? .zero
        let countWidth = ceil(countSize.width) + 2
        count.frame = CGRect(
            x: bounds.width - countWidth - 4, y: (bounds.height - countSize.height) / 2, width: countWidth,
            height: ceil(countSize.height))
        var right = count.frame.minX - 8
        if !failed.isHidden {
            let size = failed.intrinsicContentSize
            failed.frame = CGRect(x: right - size.width, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            right = failed.frame.minX - 8
        }
        let size = searchButton.sizeThatFits(CGSize(width: 200, height: 30))
        searchButton.frame = CGRect(x: 0, y: (bounds.height - 30) / 2, width: size.width, height: 30)
        field.frame = CGRect(
            x: 0, y: (bounds.height - 28) / 2, width: max(80, min(240, right)), height: 28)
    }
}

/// The step list beside the head: every step the agent took, in order, one row each, with the
/// filters and the cursor applied. It is virtualized by the offsets Core keeps, so a turn of two
/// thousand steps costs the rows on screen, and it follows a running turn until the person scrolls
/// away, when a pill says so and offers the way back.
@MainActor
final class BrainStepListView: UIView, UIScrollViewDelegate {
    weak var host: BrainBrowsing? {
        didSet { header.host = host }
    }

    let header = BrainListHeader()
    private let scroll = UIScrollView()
    private let hint = UILabel()
    private let pill = UIButton(type: .system)
    private var rows: [Int: BrainStepRowView] = [:]
    private var pool: [BrainStepRowView] = []
    private var showsHint = false
    private var headerHeight: CGFloat = 36
    private var userDragging = false
    private var programmatic = false
    private var lastSignature = ""
    private(set) var realized = 0
    private(set) var created = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.delegate = self
        scroll.showsVerticalScrollIndicator = true
        scroll.alwaysBounceVertical = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.clipsToBounds = true
        addSubview(scroll)
        addSubview(header)
        hint.adjustsFontForContentSizeCategory = true
        hint.isAccessibilityElement = false
        addSubview(hint)
        var config = UIButton.Configuration.plain()
        config.background.backgroundColor = Theme.Color.secondaryBackground
        config.background.strokeColor = Theme.Color.accent
        config.background.strokeWidth = 1
        config.background.cornerRadius = 14
        config.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12)
        config.attributedTitle = AttributedString(
            NSAttributedString(
                string: Localized.text("Following paused, latest"),
                attributes: Theme.Ramp.attributes(.control, color: Theme.Color.label)))
        pill.configuration = config
        pill.isHidden = true
        pill.addAction(
            UIAction { [weak self] _ in self?.host?.browse(.jumpToLatest) }, for: .touchUpInside)
        addSubview(pill)
        isAccessibilityElement = false
        scroll.accessibilityLabel = Localized.text("Steps")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Lays the list out for the rect Core's metrics gave it.
    func configure(metrics: NeuralStageMetrics) {
        headerHeight = CGFloat(metrics.listHeader.height)
        showsHint = metrics.listHint != nil
        setNeedsLayout()
    }

    func reload(searchOpen: Bool) {
        guard let model = host?.browseModel else { return }
        let list = model.stepList
        header.configure(list: list, searchOpen: searchOpen)
        let input = host?.browseInput ?? .touch
        scroll.contentSize = CGSize(width: bounds.width, height: CGFloat(list.contentHeight(input: input)))
        pill.isHidden = !list.showsFollowPill
        hint.attributedText = NSAttributedString(
            string: NeuralBrowse.hint,
            attributes: Theme.Ramp.attributes(.hint, color: Theme.Color.secondaryLabel))
        for (_, view) in rows { recycle(view) }
        rows = [:]
        layoutRows()
    }

    /// Redraws the rows that exist, for a cursor or a hover that moved.
    func redraw() {
        guard let model = host?.browseModel else { return }
        let list = model.stepList
        let input = host?.browseInput ?? .touch
        let key = "\(list.total)|\(list.visibleCount)|\(list.filter.query)|\(Int(bounds.width))"
        if key != lastSignature {
            lastSignature = key
            reload(searchOpen: model.browseState.searchOpen)
            return
        }
        scroll.contentSize = CGSize(width: bounds.width, height: CGFloat(list.contentHeight(input: input)))
        pill.isHidden = !list.showsFollowPill
        header.configure(list: list, searchOpen: model.browseState.searchOpen)
        layoutRows(refresh: true)
    }

    private var reveal: NeuralRowReveal?

    /// A move's row reveal: each row slides in a few points and fades, a little after the one above.
    func setReveal(_ value: NeuralRowReveal?) {
        reveal = value
        applyReveal()
    }

    private func applyReveal() {
        guard let model = host?.browseModel else { return }
        let input = host?.browseInput ?? .touch
        let first = model.stepList.position(atOffset: Double(scroll.contentOffset.y), input: input)
        for (position, view) in rows {
            guard let reveal else {
                view.alpha = 1
                view.transform = .identity
                continue
            }
            let index = max(0, position - first)
            view.alpha = CGFloat(reveal.alpha(index))
            view.transform = CGAffineTransform(translationX: 0, y: CGFloat(reveal.offset(index)))
        }
        hint.alpha = reveal.map { CGFloat($0.revealed > 0 ? 1 : 0) } ?? 1
    }

    func focusSearch() { header.focusSearch() }
    func endSearch() { header.endSearch() }

    private func recycle(_ view: BrainStepRowView) {
        view.isHidden = true
        pool.append(view)
    }

    private func dequeue() -> BrainStepRowView {
        if let view = pool.popLast() {
            view.isHidden = false
            return view
        }
        let view = BrainStepRowView()
        view.onClick = { [weak self] id, double in
            self?.host?.browse(.click(id, double: double))
        }
        view.onHover = { [weak self] id in self?.host?.browse(id.map { .hover($0) } ?? .hoverLeft) }
        view.onMenu = { [weak self] item, id in self?.host?.browse(.menu(item, id)) }
        view.onCopy = { [weak self] id in self?.host?.copySubject(of: id) }
        scroll.addSubview(view)
        created += 1
        return view
    }

    private func layoutRows(refresh: Bool = false) {
        guard let model = host?.browseModel, scroll.bounds.height > 0 else { return }
        let list = model.stepList
        let input = host?.browseInput ?? .touch
        let range = list.visibleRange(
            offset: Double(scroll.contentOffset.y), height: Double(scroll.bounds.height), input: input)
        let low = max(0, range.lowerBound - 2)
        let high = min(list.visibleCount, range.upperBound + 2)
        for position in Array(rows.keys) where position < low || position >= high {
            if let view = rows.removeValue(forKey: position) { recycle(view) }
        }
        let cursor = model.pinnedStep
        let hovered = model.browseState.hovered
        let query = list.filter.query
        for position in low..<high {
            guard let row = list.row(atVisible: position) else { continue }
            let view = rows[position] ?? dequeue()
            rows[position] = view
            var context = BrainStepRowView.Context()
            context.previous = position > 0 ? list.row(atVisible: position - 1) : nil
            context.next = list.row(atVisible: position + 1)
            context.isCursor = cursor == row.id
            context.isHovered = hovered == row.id && cursor != row.id
            context.query = query
            context.input = input
            context.total = list.total
            view.configure(row: row, context: context)
            view.frame = CGRect(
                x: 0, y: CGFloat(list.offset(ofVisible: position, input: input)), width: scroll.bounds.width,
                height: CGFloat(row.height(input: input)))
        }
        realized = rows.count
        if reveal != nil { applyReveal() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        let hintHeight: CGFloat = showsHint ? CGFloat(NeuralStageMetrics.listHintHeight) : 0
        let foot: CGFloat = showsHint ? CGFloat(NeuralStageMetrics.listFootPadding) : 0
        scroll.frame = CGRect(
            x: 0, y: headerHeight, width: bounds.width,
            height: max(0, bounds.height - headerHeight - hintHeight - foot))
        hint.isHidden = !showsHint
        hint.frame = CGRect(x: 8, y: bounds.height - hintHeight, width: bounds.width - 16, height: hintHeight)
        let size = pill.sizeThatFits(CGSize(width: bounds.width, height: 30))
        pill.frame = CGRect(
            x: (bounds.width - size.width) / 2, y: scroll.frame.maxY - size.height - 10,
            width: size.width, height: size.height)
        if let model = host?.browseModel {
            let input = host?.browseInput ?? .touch
            scroll.contentSize = CGSize(
                width: bounds.width, height: CGFloat(model.stepList.contentHeight(input: input)))
        }
        layoutRows(refresh: true)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        layoutRows()
        if userDragging, !programmatic { host?.browse(.scrolled(manual: true)) }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { userDragging = true }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { userDragging = false }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { userDragging = false }

    /// Brings a step's row into view, centred when it was out of view, and held where it is when it
    /// was already shown.
    func reveal(_ id: String, animated: Bool) {
        guard let model = host?.browseModel, let position = model.stepList.visibleIndex(of: id)
        else { return }
        let list = model.stepList
        let input = host?.browseInput ?? .touch
        let top = CGFloat(list.offset(ofVisible: position, input: input))
        let height = CGFloat(list.row(atVisible: position)?.height(input: input) ?? 28)
        let visibleTop = scroll.contentOffset.y
        let visibleBottom = visibleTop + scroll.bounds.height
        guard top < visibleTop || top + height > visibleBottom else { return }
        let target = max(
            0, min(top - (scroll.bounds.height - height) / 2, scroll.contentSize.height - scroll.bounds.height))
        programmatic = true
        scroll.setContentOffset(
            CGPoint(x: 0, y: target), animated: animated && !UIAccessibility.isReduceMotionEnabled)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            MainActor.assumeIsolated { self?.programmatic = false }
        }
        if !animated || UIAccessibility.isReduceMotionEnabled { programmatic = false }
    }

    /// The list's own rows, for a check that reads what is drawn.
    var visibleRowIDs: [String] {
        rows.keys.sorted().compactMap { rows[$0]?.row?.id }
    }

    var rowFrames: [(id: String, frame: CGRect)] {
        rows.keys.sorted().compactMap { key in
            guard let view = rows[key], let row = view.row else { return nil }
            return (row.id, view.frame)
        }
    }

    var contentHeight: CGFloat { scroll.contentSize.height }
    var viewportHeight: CGFloat { scroll.bounds.height }
}
