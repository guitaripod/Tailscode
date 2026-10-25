import CodingAgentKit
import TailscodeCore
import UIKit

/// What a surface is aiming with when it opens the party: the model and level its next send runs
/// at, the levels the agent offers where a model names none, and whether a turn is running.
struct PartyAim {
    var model: ModelSelection?
    var effort: String?
    var agentOptions: [String]
    var isBusy: Bool
}

/// The six models a person carries, as the sheet the model pill opens: six cards, the two models
/// used lately that none of them holds, and the road to the whole catalog. *Edit* turns the same
/// cards into the place the party is arranged.
///
/// The sheet decides nothing about what a take does. A slot on this machine is handed back as a
/// resolved preset; a slot on another is handed back as the pick it would be in the chooser, so
/// the chat asks before it carries and Home re-aims, exactly as they do for any pick elsewhere.
@MainActor
final class PartyViewController: UIViewController {
    struct Actions {
        var take: (ModelPreset) -> Void
        var takeModel: (ModelSelection) -> Void
        var takeElsewhere: (ModelPick) -> Void
        var browseAll: () -> Void
        var fill: (UIViewController, @escaping (ModelPick) -> Void) -> Void
        var followServer: (() -> Void)? = nil
    }

    private static let detent = UISheetPresentationController.Detent.Identifier("party.sheet")
    private static let margin: CGFloat = 20

    private let sources: () -> [ModelSource]
    private let aim: () -> PartyAim
    private let actions: Actions
    private(set) var isArranging: Bool
    private var cards: [PartyCard] = []
    private var currentSources: [ModelSource] = []
    private var recents: [PartyRecent] = []

    private let scroll = UIScrollView()
    private let column = UIStackView()
    private let titleLabel = UILabel()
    private let countLabel = UILabel()
    private let editButton = UIButton(type: .system)
    private let grid = UIStackView()
    private var cardViews: [PartyCardView] = []
    private let browseFooter = UIStackView()
    private let recentRow = UIStackView()
    private let recentLabel = UILabel()
    private let recentChips = UIStackView()
    private let editFooter = UILabel()
    private var dragOrigin: CGPoint = .zero
    private var dragTarget: PartyCardView?

    init(
        sources: @escaping () -> [ModelSource], aim: @escaping () -> PartyAim, actions: Actions,
        editing: Bool
    ) {
        self.sources = sources
        self.aim = aim
        self.actions = actions
        self.isArranging = editing
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    static func present(
        from presenter: UIViewController, sources: @escaping () -> [ModelSource],
        aim: @escaping () -> PartyAim, actions: Actions, editing: Bool = false
    ) {
        let party = PartyViewController(
            sources: sources, aim: aim, actions: actions, editing: editing)
        party.modalPresentationStyle = .pageSheet
        party.loadViewIfNeeded()
        let fallbackWidth = presenter.view.bounds.width
        if let sheet = party.sheetPresentationController {
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 32
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
            sheet.detents = [
                .custom(identifier: detent) { [weak party] context in
                    guard let party else { return context.maximumDetentValue }
                    let width = party.view.bounds.width > 0 ? party.view.bounds.width : fallbackWidth
                    return min(context.maximumDetentValue, party.fittingHeight(width: width))
                },
                .large(),
            ]
            sheet.selectedDetentIdentifier = detent
        }
        presenter.present(party, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if #available(iOS 26.0, *) {
            view.backgroundColor = .clear
        } else {
            view.backgroundColor = Theme.Color.groupedBackground
        }
        buildGrid()
        buildFooter()
        buildScroll()
        NotificationCenter.default.addObserver(
            self, selector: #selector(partyChanged), name: ModelParty.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(partyChanged), name: ModelCatalog.didChange, object: nil)
        NotificationCenter.default.addObserver(
            forName: ModelCatalogStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (party: PartyViewController, _) in party.fitRecentRow()
        }
        reload()
        syncMode()
    }

    @objc private func partyChanged() { reload() }

    func fittingHeight(width: CGFloat) -> CGFloat {
        let fit = column.systemLayoutSizeFitting(
            CGSize(width: width - 2 * Self.margin, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        return ceil(fit.height) + Self.topInset + Theme.Spacing.s
    }

    private static let topInset: CGFloat = 26

    private func buildScroll() {
        scroll.alwaysBounceVertical = false
        scroll.keyboardDismissMode = .interactive
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = Theme.Spacing.m
        column.translatesAutoresizingMaskIntoConstraints = false
        [headerRow(), grid, browseFooter, editFooter].forEach(column.addArrangedSubview)
        scroll.addSubview(column)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Self.topInset),
            column.bottomAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Spacing.s),
            column.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Self.margin),
            column.trailingAnchor.constraint(
                equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Self.margin),
        ])
    }

    private func headerRow() -> UIView {
        titleLabel.font = PartyCardView.font(22, .bold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityTraits = .header
        countLabel.font = PartyCardView.font(13, .regular)
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.textColor = Theme.Color.secondaryLabel
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 0)
        editButton.configuration = config
        editButton.contentHorizontalAlignment = .trailing
        editButton.setContentHuggingPriority(.required, for: .horizontal)
        editButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        editButton.addAction(UIAction { [weak self] _ in self?.toggleEditing() }, for: .touchUpInside)
        editButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            editButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            editButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        let row = UIStackView(arrangedSubviews: [titleLabel, countLabel, UIView(), editButton])
        row.axis = .horizontal
        row.alignment = .firstBaseline
        row.spacing = Theme.Spacing.s
        return row
    }

    private func buildGrid() {
        grid.axis = .vertical
        grid.spacing = 10
        grid.alignment = .fill
        grid.distribution = .fill
        for slot in 0..<ModelParty.size {
            let card = PartyCardView(slot: slot)
            wire(card)
            cardViews.append(card)
        }
        for first in stride(from: 0, to: ModelParty.size, by: 2) {
            let row = UIStackView(arrangedSubviews: [cardViews[first], cardViews[first + 1]])
            row.axis = .horizontal
            row.spacing = 10
            row.distribution = .fillEqually
            row.alignment = .fill
            grid.addArrangedSubview(row)
        }
    }

    private func wire(_ card: PartyCardView) {
        let slot = card.slot
        card.onTake = { [weak self] in self?.tap(slot: slot) }
        card.onRelease = { [weak self] in self?.release(slot: slot) }
        card.onRename = { name in ModelParty.rename(slot: slot, to: name) }
        card.onStep = { [weak self] in self?.stepLevel(slot: slot) }
        card.onReplace = { [weak self] in self?.fill(slot: slot) }
        card.onMove = { delta in
            ModelParty.swap(slot, slot + delta)
            Theme.Haptics.selection()
        }
        card.onStartRename = { [weak self] in self?.startRename(slot: slot) }
        card.onNameFocus = { [weak self] focused in self?.nameFocus(slot: slot, focused: focused) }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        pan.delegate = self
        card.addGestureRecognizer(pan)
    }

    private func buildFooter() {
        browseFooter.axis = .vertical
        browseFooter.spacing = Theme.Spacing.xs
        recentLabel.text = String(localized: "Recent")
        recentLabel.font = PartyCardView.font(13, .regular)
        recentLabel.adjustsFontForContentSizeCategory = true
        recentLabel.textColor = Theme.Color.secondaryLabel
        recentLabel.setContentHuggingPriority(.required, for: .horizontal)
        recentChips.axis = .horizontal
        recentChips.spacing = 10
        recentChips.alignment = .center
        recentChips.distribution = .fill
        recentRow.axis = .horizontal
        recentRow.alignment = .center
        recentRow.spacing = Theme.Spacing.m
        [recentLabel, recentChips, UIView()].forEach(recentRow.addArrangedSubview)
        browseFooter.addArrangedSubview(recentRow)
        browseFooter.setCustomSpacing(Theme.Spacing.s, after: recentRow)
        browseFooter.addArrangedSubview(
            PartyRowView(title: String(localized: "All models…"), symbol: "chevron.right") {
                [weak self] in self?.browseAll()
            })
        if let follow = actions.followServer {
            browseFooter.addArrangedSubview(
                PartyRowView(
                    title: String(localized: "Follow this server"), symbol: "arrow.uturn.backward"
                ) { [weak self] in
                    self?.dismiss(animated: true) { follow() }
                })
        }
        editFooter.numberOfLines = 0
        editFooter.adjustsFontForContentSizeCategory = true
        editFooter.attributedText = Self.hint()
    }

    private static func hint() -> NSAttributedString {
        let font = PartyCardView.font(13, .regular)
        let bold = UIFont.systemFont(ofSize: font.pointSize, weight: .semibold)
        let text = NSMutableAttributedString()
        let parts = [
            AttributedString(
                localized:
                    "**Tap a name** to rename it. **Tap the button** on a ball to change its level."),
            AttributedString(localized: "**Drag** onto another to swap. ✕ puts it back in the box."),
        ]
        for (index, part) in parts.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "\n\n")) }
            let styled = NSMutableAttributedString(
                attributedString: (try? NSAttributedString(part, including: \.foundation))
                    ?? NSAttributedString(string: String(part.characters)))
            let whole = NSRange(location: 0, length: styled.length)
            styled.addAttributes(
                [.font: font, .foregroundColor: Theme.Color.secondaryLabel], range: whole)
            styled.enumerateAttribute(.inlinePresentationIntent, in: whole) { value, range, _ in
                guard let raw = (value as? NSNumber)?.uintValue,
                    InlinePresentationIntent(rawValue: raw).contains(.stronglyEmphasized)
                else { return }
                styled.addAttributes([.font: bold, .foregroundColor: Theme.Color.label], range: range)
            }
            text.append(styled)
        }
        return text
    }

    private func fitRecentRow() {
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        recentRow.axis = large ? .vertical : .horizontal
        recentRow.alignment = large ? .leading : .center
        recentChips.axis = large ? .vertical : .horizontal
        recentChips.alignment = large ? .leading : .center
    }

    func reload() {
        let slots = ModelParty.slots()
        let reading = aim()
        currentSources = sources()
        cards = PartyReading.cards(
            slots: slots, sources: currentSources, model: reading.model, effort: reading.effort,
            agentOptions: reading.agentOptions)
        for (view, card) in zip(cardViews, cards) {
            view.render(card, editing: isArranging, busy: reading.isBusy)
        }
        let held = slots.compactMap { $0 }.count
        countLabel.text = String(localized: "\(held) of \(ModelParty.size)")
        countLabel.accessibilityLabel = countLabel.text
        recents = PartyReading.recents(slots: slots, sources: currentSources)
        rebuildRecents()
    }

    private func rebuildRecents() {
        recentChips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for recent in recents {
            let chip = PartyPillView(
                font: PartyCardView.font(15, .regular),
                insets: UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 14))
            chip.text = recent.word
            chip.dotColor = recent.chip.map { Theme.Color.modelIdentity($0) }
            chip.accessibilityLabel =
                recent.machine.map { String(localized: "\(recent.word), on \($0)") } ?? recent.word
            chip.accessibilityTraits = .button
            chip.addAction(UIAction { [weak self] _ in self?.take(recent: recent) }, for: .touchUpInside)
            chip.addInteraction(
                UIContextMenuInteraction(
                    delegate: RecentMenu { [weak self] in self?.addToParty(recent: recent) }))
            recentChips.addArrangedSubview(chip)
        }
        recentRow.isHidden = recents.isEmpty
        fitRecentRow()
    }

    private func syncMode() {
        titleLabel.text = isArranging ? String(localized: "Edit party") : String(localized: "Party")
        countLabel.isHidden = isArranging
        var config = editButton.configuration ?? .plain()
        var title = AttributedString(isArranging ? String(localized: "Done") : String(localized: "Edit"))
        title.font = PartyCardView.font(17, isArranging ? .semibold : .regular)
        config.attributedTitle = title
        config.baseForegroundColor = Theme.Color.accent
        editButton.configuration = config
        browseFooter.isHidden = isArranging
        editFooter.isHidden = !isArranging
        for (view, card) in zip(cardViews, cards) {
            view.render(card, editing: isArranging, busy: aim().isBusy)
        }
    }

    private func toggleEditing() {
        cardViews.forEach { $0.endNaming() }
        isArranging.toggle()
        Theme.Haptics.selection()
        UIView.animate(withDuration: 0.2) { self.syncMode() }
        sheetPresentationController?.animateChanges { sheetPresentationController?.invalidateDetents() }
        UIAccessibility.post(notification: .layoutChanged, argument: titleLabel)
    }

    private func startRename(slot: Int) {
        if !isArranging {
            isArranging = true
            syncMode()
            sheetPresentationController?.invalidateDetents()
        }
        cardViews[slot].focusName()
    }

    private func nameFocus(slot: Int, focused: Bool) {
        guard let sheet = sheetPresentationController else { return }
        if focused {
            sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
            let card = cardViews[slot]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self else { return }
                let frame = card.convert(card.bounds, to: self.scroll).insetBy(dx: 0, dy: -16)
                self.scroll.scrollRectToVisible(frame, animated: true)
            }
        } else {
            sheet.animateChanges { sheet.selectedDetentIdentifier = Self.detent }
        }
    }

    private func release(slot: Int) {
        Theme.Haptics.selection()
        ModelParty.release(slot: slot)
    }

    func toast(_ message: String) {
        ToastView(message: message).flash(
            in: view, above: view.safeAreaLayoutGuide.bottomAnchor, duration: 2)
    }
}

extension PartyViewController {
    private func tap(slot: Int) {
        guard cards.indices.contains(slot) else { return }
        let card = cards[slot]
        guard !card.isHollow else { return fill(slot: slot) }
        guard !isArranging else { return }
        take(card)
    }

    private func take(_ card: PartyCard) {
        guard !card.isAway, let resolved = card.resolved else {
            Theme.Haptics.warning()
            toast(
                card.machine.map { String(localized: "\($0) is not answering") } ?? card.subtitle)
            return
        }
        guard let machine = card.machine, let profileID = card.profileID else {
            Theme.Haptics.success()
            actions.take(resolved)
            dismiss(animated: true)
            return
        }
        let pick = ModelPick(
            profileID: profileID, selection: resolved.selection, isElsewhere: true,
            serverName: machine, modelName: card.modelWord, preset: resolved)
        Theme.Haptics.tap()
        dismiss(animated: true) { [actions] in actions.takeElsewhere(pick) }
    }

    private func take(recent: PartyRecent) {
        guard let machine = recent.machine else {
            Theme.Haptics.success()
            actions.takeModel(recent.selection)
            dismiss(animated: true)
            return
        }
        let pick = ModelPick(
            profileID: recent.profileID, selection: recent.selection, isElsewhere: true,
            serverName: machine, modelName: recent.word)
        Theme.Haptics.tap()
        dismiss(animated: true) { [actions] in actions.takeElsewhere(pick) }
    }

    private func browseAll() {
        Theme.Haptics.tap()
        dismiss(animated: true) { [actions] in actions.browseAll() }
    }

    private func addToParty(recent: PartyRecent) {
        let preset = Self.carried(
            recent.selection, profileID: recent.profileID, sources: currentSources, aim: aim())
        PartyAdding.add(
            preset, cards: { [weak self] in self?.cards ?? [] }, from: self,
            say: { [weak self] in self?.toast($0) })
    }

    private func fill(slot: Int) {
        Theme.Haptics.tap()
        actions.fill(self) { [weak self] pick in self?.place(pick, in: slot) }
    }

    private func place(_ pick: ModelPick, in slot: Int) {
        guard let selection = pick.selection else {
            toast(String(localized: "A slot holds a model, not the server's own choice"))
            return
        }
        let preset =
            pick.preset
            ?? Self.carried(selection, profileID: pick.profileID, sources: sources(), aim: aim())
        ModelParty.replace(slot: slot, with: preset)
        Theme.Haptics.success()
    }

    /// A model at the level the aim holds, carried onto that model's own levels, which is what a
    /// pick of it would run at; the server's own choice where the model has none.
    static func carried(
        _ selection: ModelSelection, profileID: String, sources: [ModelSource], aim: PartyAim
    ) -> ModelPreset {
        let models = sources.first { $0.profileID == profileID }?.models ?? []
        let options = ModelEffort.options(
            models: models, selection: selection, agentOptions: aim.agentOptions)
        let level = ModelEffort.carry(aim.effort, options: options).level
        return ModelPreset(selection: selection, effort: level.map(PresetEffort.level) ?? .server)
    }

    /// The level after this one on the model's own ladder, wrapping through the server's own choice.
    static func nextLevel(after current: PresetEffort, options: [String]) -> PresetEffort? {
        let ladder = ModelDial.ascending(options: options)
        guard let first = ladder.first else { return nil }
        guard case .level(let level) = current,
            let spelled = ModelEffort.surviving(level, options: ladder),
            let index = ladder.firstIndex(of: spelled)
        else { return .level(first) }
        return index + 1 < ladder.count ? .level(ladder[index + 1]) : .server
    }

    private func stepLevel(slot: Int) {
        guard let held = ModelParty.slot(slot), cards.indices.contains(slot),
            cards[slot].takesLevels, let resolved = cards[slot].resolved,
            let source = currentSources.first(where: {
                ModelPresetCycle.resolve(held.preset, on: $0) != nil
            })
        else { return }
        let options = ModelEffort.options(
            models: source.models, selection: resolved.selection, agentOptions: aim().agentOptions)
        guard let next = Self.nextLevel(after: held.preset.effort, options: options) else { return }
        ModelParty.setEffort(slot: slot, next)
        Theme.Haptics.notch()
    }
}

extension PartyViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
            let card = pan.view as? PartyCardView
        else { return true }
        return isArranging && !card.card.isHollow && !card.isNameFocused
            && card.ballFrame.contains(pan.location(in: card))
    }

    @objc private func dragged(_ pan: UIPanGestureRecognizer) {
        guard let card = pan.view as? PartyCardView else { return }
        switch pan.state {
        case .began:
            dragOrigin = Self.middle(of: card, in: grid)
            card.layer.zPosition = 10
            card.superview?.layer.zPosition = 10
            Theme.Haptics.selection()
            UIView.animate(withDuration: 0.15) { card.lift(by: .zero) }
        case .changed:
            card.lift(by: pan.translation(in: grid))
            retarget(at: pan.location(in: grid), excluding: card)
        case .ended:
            drop(card)
        default:
            reset(card)
        }
    }

    private static func middle(of view: UIView, in space: UIView) -> CGPoint {
        let frame = view.convert(view.bounds, to: space)
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private func retarget(at point: CGPoint, excluding card: PartyCardView) {
        let hit = cardViews.first {
            $0 !== card && $0.convert($0.bounds, to: grid).contains(point)
        }
        guard hit !== dragTarget else { return }
        dragTarget?.setTargeted(false)
        dragTarget = hit
        hit?.setTargeted(true)
        if hit != nil { Theme.Haptics.notch() }
    }

    private func drop(_ card: PartyCardView) {
        guard let target = dragTarget else { return reset(card) }
        let there = Self.middle(of: target, in: grid)
        let delta = CGPoint(x: there.x - dragOrigin.x, y: there.y - dragOrigin.y)
        UIView.animate(
            withDuration: 0.18, delay: 0, options: .curveEaseOut,
            animations: { card.lift(by: delta) },
            completion: { [weak self] _ in
                ModelParty.swap(card.slot, target.slot)
                Theme.Haptics.success()
                self?.dragTarget?.setTargeted(false)
                self?.dragTarget = nil
                card.settle()
                card.layer.zPosition = 0
                card.superview?.layer.zPosition = 0
            })
    }

    private func reset(_ card: PartyCardView) {
        dragTarget?.setTargeted(false)
        dragTarget = nil
        UIView.animate(
            withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0,
            options: [],
            animations: { card.settle() },
            completion: { _ in
                card.layer.zPosition = 0
                card.superview?.layer.zPosition = 0
            })
    }
}

/// The hold on a recent chip: put it in the party.
@MainActor
private final class RecentMenu: NSObject, UIContextMenuInteractionDelegate {
    private let add: () -> Void

    init(add: @escaping () -> Void) { self.add = add }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [add] _ in
            UIMenu(children: [
                UIAction(
                    title: String(localized: "Add to party"), image: UIImage(systemName: "plus.circle")
                ) { _ in add() }
            ])
        }
    }
}

/// One full-width row under the grid: words on the left and a symbol on the right, at least a
/// finger tall.
@MainActor
final class PartyRowView: UIControl {
    init(title: String, symbol: String, action: @escaping () -> Void) {
        super.init(frame: .zero)
        let label = UILabel()
        label.text = title
        label.font = PartyCardView.font(17, .regular)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.Color.label
        label.numberOfLines = 0
        let image = UIImageView(
            image: UIImage(
                systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)))
        image.tintColor = Theme.Color.tertiaryLabel
        image.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [label, image])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Spacing.m
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        let rule = UIView()
        rule.backgroundColor = Theme.Color.separator
        rule.isUserInteractionEnabled = false
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        addSubview(rule)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 0.5),
        ])
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .button
        addAction(UIAction { _ in action() }, for: .touchUpInside)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }
}
