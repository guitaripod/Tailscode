import TailscodeCore
import UIKit

/// What a phone's compact list is made of, row by row: a step, or one of the rows that stand for
/// the steps that are not shown or for the one the turn is stopped on.
enum BrainCompactItem: Equatable {
    case step(NeuralStepList.Row)
    case ask(NeuralStepList.Row)
    case earlier(Int)
    case more(Int)
    case less
}

/// The step list as a phone shows it: a short column of rows that never scrolls. A turn of forty
/// steps shows the few that matter (the head, the newest while it runs, the ones around the cursor)
/// and a row that says how many more, which opens them; the transcript underneath is what scrolls,
/// so a finger that lands on this list is always a finger on the page.
@MainActor
final class BrainCompactListView: UIView {
    weak var host: BrainBrowsing?
    var onSelect: ((String) -> Void)?
    var onMore: (() -> Void)?
    var onLess: (() -> Void)?
    var onAsk: (() -> Void)?

    private var rowHeight: CGFloat = CGFloat(NeuralStageMetrics.phoneRowHeight)
    private var scale: CGFloat = 1
    private var items: [BrainCompactItem] = []
    private var stepViews: [BrainStepRowView] = []
    private var linkViews: [BrainLinkRow] = []
    private var reveal: NeuralRowReveal?
    private var placed: [UIView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        clipsToBounds = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(metrics: NeuralStageMetrics) {
        let height = CGFloat(metrics.listRowHeight)
        let next = max(height / CGFloat(NeuralStageMetrics.phoneRowHeight), 1)
        guard height != rowHeight || next != scale else { return }
        rowHeight = height
        scale = next
        setNeedsLayout()
    }

    /// How many rows the list draws for a model: the slots of its window, or every step and the
    /// row that shuts them again.
    static func items(
        for list: NeuralStepList, expanded: Bool, slots: Int
    ) -> [BrainCompactItem] {
        if expanded {
            return list.rows(in: 0..<list.visibleCount).map { .step($0) } + [.less]
        }
        return list.compactWindow(slots: slots).slots.compactMap { slot in
            switch slot {
            case .ask(let id): return list.row(id: id).map { .ask($0) }
            case .earlier(let count): return .earlier(count)
            case .step(let id): return list.row(id: id).map { .step($0) }
            case .more(let count): return .more(count)
            }
        }
    }

    func show(items next: [BrainCompactItem], cursor: String?, hovered: String?, query: String, total: Int) {
        items = next
        var stepIndex = 0
        var linkIndex = 0
        var views: [UIView] = []
        for (position, item) in items.enumerated() {
            switch item {
            case .step(let row):
                let view = stepView(stepIndex)
                stepIndex += 1
                var context = BrainStepRowView.Context()
                context.previous = previousStep(before: position)
                context.next = nextStep(after: position)
                context.isCursor = cursor == row.id
                context.isHovered = hovered == row.id && cursor != row.id
                context.query = query
                context.input = .touch
                context.total = total
                context.compact = true
                context.scale = scale
                view.configure(row: row, context: context)
                views.append(view)
            case .ask, .earlier, .more, .less:
                let view = linkView(linkIndex)
                linkIndex += 1
                view.configure(item: item)
                views.append(view)
            }
        }
        for view in stepViews[stepIndex...] { view.isHidden = true }
        for view in linkViews[linkIndex...] { view.isHidden = true }
        for view in views { view.isHidden = false }
        placed = views
        setNeedsLayout()
        if reveal != nil { applyReveal() }
    }

    private func previousStep(before position: Int) -> NeuralStepList.Row? {
        guard position > 0, case .step(let row) = items[position - 1] else { return nil }
        return row
    }

    private func nextStep(after position: Int) -> NeuralStepList.Row? {
        guard position + 1 < items.count, case .step(let row) = items[position + 1] else { return nil }
        return row
    }

    private func stepView(_ index: Int) -> BrainStepRowView {
        if stepViews.indices.contains(index) { return stepViews[index] }
        let view = BrainStepRowView()
        view.onClick = { [weak self] id, _ in self?.onSelect?(id) }
        view.onHover = { [weak self] id in self?.host?.browse(id.map { .hover($0) } ?? .hoverLeft) }
        view.onMenu = { [weak self] item, id in self?.host?.browse(.menu(item, id)) }
        view.onCopy = { [weak self] id in self?.host?.copySubject(of: id) }
        addSubview(view)
        stepViews.append(view)
        return view
    }

    private func linkView(_ index: Int) -> BrainLinkRow {
        if linkViews.indices.contains(index) { return linkViews[index] }
        let view = BrainLinkRow()
        view.onTap = { [weak self, weak view] in
            guard let self, let item = view?.item else { return }
            switch item {
            case .ask: self.onAsk?()
            case .earlier, .more: self.onMore?()
            case .less: self.onLess?()
            case .step: break
            }
        }
        addSubview(view)
        linkViews.append(view)
        return view
    }

    func setReveal(_ value: NeuralRowReveal?) {
        reveal = value
        applyReveal()
    }

    private func applyReveal() {
        for (index, view) in placed.enumerated() {
            guard let reveal else {
                view.alpha = 1
                view.transform = .identity
                continue
            }
            view.alpha = CGFloat(reveal.alpha(index))
            view.transform = CGAffineTransform(translationX: 0, y: CGFloat(reveal.offset(index)))
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for (index, view) in placed.enumerated() {
            view.frame = CGRect(
                x: 0, y: CGFloat(index) * rowHeight, width: bounds.width, height: rowHeight)
        }
    }

    var visibleRowIDs: [String] {
        items.compactMap { if case .step(let row) = $0 { return row.id } else { return nil } }
    }

    var itemCount: Int { items.count }

    var linkTitles: [String] {
        items.compactMap { BrainLinkRow.title(for: $0) }
    }
}

/// A row of the compact list that is not a step: how many steps lie beyond the ones shown, the way
/// to shut an opened list, or the step the turn is stopped on. A whole row is the target.
@MainActor
final class BrainLinkRow: UIControl {
    var onTap: (() -> Void)?
    private(set) var item: BrainCompactItem?
    private let label = UILabel()
    private let glyph = UIImageView()
    private let edge = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) { (view: BrainLinkRow, _) in view.restyle() }
        label.isUserInteractionEnabled = false
        label.lineBreakMode = .byTruncatingTail
        glyph.contentMode = .center
        glyph.isUserInteractionEnabled = false
        edge.isUserInteractionEnabled = false
        for view in [edge, glyph, label] { addSubview(view) }
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() {
        Theme.Haptics.selection()
        onTap?()
    }

    static func title(for item: BrainCompactItem) -> String? {
        switch item {
        case .more(let count): return NeuralReading.moreSteps(count)
        case .earlier(let count): return NeuralReading.earlierSteps(count)
        case .less: return NeuralReading.showFewerSteps
        case .ask(let row): return "\(NeuralReading.verdictWaiting): \(row.title)"
        case .step: return nil
        }
    }

    func configure(item new: BrainCompactItem) {
        item = new
        restyle()
    }

    private func restyle() {
        guard let item else { return }
        let asking: Bool
        let symbol: String
        switch item {
        case .ask: (asking, symbol) = (true, "pause.fill")
        case .more: (asking, symbol) = (false, "chevron.down")
        case .earlier: (asking, symbol) = (false, "chevron.up")
        case .less: (asking, symbol) = (false, "chevron.up")
        case .step: (asking, symbol) = (false, "")
        }
        let ink: UIColor = asking ? Theme.Color.label : Theme.Color.accent
        label.attributedText = NSAttributedString(
            string: Self.title(for: item) ?? "",
            attributes: Theme.Ramp.attributes(asking ? .rowTitleStrong : .control, color: ink))
        glyph.image = BrainCanvas.image(symbol, size: 11, weight: .semibold)?
            .withTintColor(asking ? Theme.Color.warning : Theme.Color.accent, renderingMode: .alwaysOriginal)
        edge.backgroundColor = asking ? Theme.Color.warning : .clear
        backgroundColor = asking ? Theme.Color.warning.wash(0.1) : .clear
        accessibilityLabel = Self.title(for: item)
        accessibilityHint = asking ? NeuralReading.goToApprovalLabel : nil
        setNeedsLayout()
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        edge.frame = CGRect(x: 0, y: 0, width: 3, height: bounds.height)
        glyph.frame = CGRect(x: 27, y: 0, width: 14, height: bounds.height)
        let size = label.attributedText?.size() ?? .zero
        label.frame = CGRect(
            x: BrainStepRowView.titleX, y: (bounds.height - size.height) / 2,
            width: max(0, bounds.width - BrainStepRowView.titleX - 12), height: ceil(size.height))
    }
}
