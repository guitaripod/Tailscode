import AppKit
import CodingAgentKit
import TailscodeCore

/// What the party's panel reads each time it draws: the six cards, the recent models, the levels a
/// card's model takes and whether a turn is running. The owner answers from the chat it is aimed
/// at, so the panel never knows which machine or conversation it is standing in.
@MainActor
struct PartyPanelModel {
    var cards: () -> [PartyCard]
    var recents: () -> [PartyRecent]
    var levels: (PartyCard) -> [String]
    var isRunning: () -> Bool
}

/// What a press on the panel asks of its owner.
@MainActor
struct PartyPanelActions {
    var take: (PartyCard) -> Void
    var fill: (Int) -> Void
    var replace: (Int) -> Void
    var recent: (PartyRecent) -> Void
    var addRecent: (PartyRecent) -> Void
    var browse: () -> Void
}

/// A recent model as a chip in the footer: its house colour and its word, wrapped rather than cut.
@MainActor
final class PartyRecentChip: NSView {
    let recent: PartyRecent
    var onPress: ((PartyRecent) -> Void)?
    var onAdd: ((PartyRecent) -> Void)?
    private let dot = CALayer()
    private let label = NSTextField(wrappingLabelWithString: "")
    private var hovered = false

    init(recent: PartyRecent) {
        self.recent = recent
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(dot)
        label.isSelectable = false
        label.font = PartyMetrics.chipFont
        label.textColor = MacTheme.Color.label
        label.maximumNumberOfLines = 3
        label.stringValue = recent.machine.map { recent.word + " · " + $0 } ?? recent.word
        label.toolTip = label.stringValue
        addSubview(label)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self, userInfo: nil))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(
            recent.machine.map { Localized.text("%@ on %@", recent.word, $0) } ?? recent.word)
        restyle()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private static var dotSize: CGFloat { 9 * PartyMetrics.scale }
    private static var sidePad: CGFloat { 9 * PartyMetrics.scale }

    /// The chip as wide as its words need, up to `limit`, and as tall as they are when they wrap.
    func fitted(limit: CGFloat) -> NSSize {
        let text = label.stringValue
        let room = limit - 2 * Self.sidePad - Self.dotSize - 6 * PartyMetrics.scale
        let natural = ceil((text as NSString).size(withAttributes: [.font: PartyMetrics.chipFont]).width)
        let width = min(natural, max(room, 40))
        let height = PartyMetrics.height(
            of: text, font: PartyMetrics.chipFont, width: width, maxLines: 3)
        return NSSize(
            width: width + 2 * Self.sidePad + Self.dotSize + 6 * PartyMetrics.scale,
            height: max(height + 8 * PartyMetrics.scale, 26 * PartyMetrics.scale))
    }

    override func layout() {
        super.layout()
        let size = Self.dotSize
        dot.frame = CGRect(
            x: Self.sidePad, y: (bounds.height - size) / 2, width: size, height: size)
        dot.cornerRadius = size / 2
        let x = Self.sidePad + size + 6 * PartyMetrics.scale
        let width = bounds.width - x - Self.sidePad
        let height = PartyMetrics.height(
            of: label.stringValue, font: PartyMetrics.chipFont, width: width, maxLines: 3)
        label.frame = NSRect(x: x, y: (bounds.height - height) / 2, width: width, height: height)
        layer?.cornerRadius = bounds.height / 2
        restyle()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let hue = recent.chip.map(MacTheme.Color.modelIdentity) ?? MacTheme.Color.secondaryLabel
            dot.backgroundColor = hue.cgColor
            layer?.backgroundColor =
                NSColor.labelColor.withAlphaComponent(hovered ? 0.14 : 0.08).cgColor
        }
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        restyle()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        restyle()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?(recent)
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 36 || event.keyCode == 49 || event.keyCode == 76 else {
            super.keyDown(with: event)
            return
        }
        onPress?(recent)
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?(recent)
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(
            title: Localized.text("Add to party"), action: #selector(addToParty), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func addToParty() {
        onAdd?(recent)
    }
}

private final class PartyGridView: NSView {
    override var isFlipped: Bool { true }
}

private final class PartyBadgeLayer: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// The release badge on a held card in edit mode: a small disc with a cross that puts the model
/// back in the box. It stands over the card's corner, so it lives in a layer of its own above the
/// grid and never clips to the card.
@MainActor
private final class PartyBadgeButton: NSButton {
    init(slot: Int) {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        imagePosition = .imageOnly
        image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: Localized.text("Release slot %d", slot + 1))
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        contentTintColor = MacTheme.Color.label
        wantsLayer = true
        layer?.cornerRadius = PartyBadgeButton.size / 2
        layer?.borderWidth = 1
        setAccessibilityLabel(Localized.text("Release slot %d", slot + 1))
        toolTip = Localized.text("Release slot %d", slot + 1)
        restyle()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    static var size: CGFloat { 24 * PartyMetrics.scale }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = MacTheme.Color.canvasRaised.cgColor
            layer?.borderColor = MacTheme.Color.separator.cgColor
        }
    }
}

/// The party as a popover's content: the title and its count, the six cards in three columns by
/// two rows, and under them the models used lately and the way into the whole catalog.
///
/// Everything is placed by frame from the measures of the words in it, because a card is as tall as
/// the longest name needs and no label may be cut to keep the grid tidy. It redraws from the
/// party's own change notification, so a rename, a release or a swap made anywhere reads at once.
@MainActor
final class PartyPanelView: NSView {
    enum Mode {
        case party
        case makeRoom
    }

    let mode: Mode
    private let model: PartyPanelModel
    private let actions: PartyPanelActions
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let editButton = NSButton()
    private let grid = PartyGridView()
    private let badges = PartyBadgeLayer()
    private let rule = NSView()
    private let recentLabel = NSTextField(labelWithString: "")
    private let browseButton = NSButton()
    private let browseHint = NSTextField(labelWithString: "⌘K")
    private(set) var cardViews: [PartyCardView] = []
    private var badgeButtons: [PartyBadgeButton] = []
    private var recentChips: [PartyRecentChip] = []
    private var cards: [PartyCard] = []
    private var rowHeight: CGFloat = PartyMetrics.baseHeight
    private var recentSignature: [String] = []
    private var dragged: PartyCardView?
    private var dragGrab = NSPoint.zero
    private var dropTarget: PartyCardView?
    private(set) var isEditing = false
    var onResize: ((NSSize) -> Void)?
    private var observer: NSObjectProtocol?

    init(mode: Mode, model: PartyPanelModel, actions: PartyPanelActions) {
        self.mode = mode
        self.model = model
        self.actions = actions
        super.init(frame: .zero)
        titleLabel.font = .systemFont(ofSize: 15 * PartyMetrics.scale, weight: .semibold)
        titleLabel.textColor = MacTheme.Color.label
        countLabel.font = .systemFont(ofSize: 12 * PartyMetrics.scale)
        countLabel.textColor = MacTheme.Color.secondaryLabel
        editButton.bezelStyle = .rounded
        editButton.controlSize = .small
        editButton.target = self
        editButton.action = #selector(toggleEditing)
        editButton.keyEquivalent = "e"
        editButton.keyEquivalentModifierMask = .command
        editButton.isHidden = mode == .makeRoom
        rule.wantsLayer = true
        recentLabel.font = .systemFont(ofSize: 12 * PartyMetrics.scale)
        recentLabel.textColor = MacTheme.Color.secondaryLabel
        recentLabel.stringValue = Localized.text("Recent")
        browseButton.isBordered = false
        browseButton.target = self
        browseButton.action = #selector(browse)
        browseButton.keyEquivalent = "k"
        browseButton.keyEquivalentModifierMask = .command
        browseButton.attributedTitle = NSAttributedString(
            string: Localized.text("All models…"),
            attributes: [
                .font: NSFont.systemFont(ofSize: 12.5 * PartyMetrics.scale, weight: .medium),
                .foregroundColor: MacTheme.Color.accent,
            ])
        browseHint.font = .monospacedSystemFont(ofSize: 11 * PartyMetrics.scale, weight: .regular)
        browseHint.textColor = MacTheme.Color.tertiaryLabel
        for view in [titleLabel, countLabel, editButton, grid, badges, rule] as [NSView] {
            addSubview(view)
        }
        if mode == .party {
            for view in [recentLabel, browseButton, browseHint] as [NSView] { addSubview(view) }
        }
        for slot in 0..<ModelParty.size {
            let view = PartyCardView(card: .hollow(slot))
            view.onPress = { [weak self] card in self?.press(card) }
            view.onStepLevel = { [weak self] card in self?.stepLevel(card) }
            view.onRename = { [weak self] card, name in self?.rename(card, to: name) }
            view.onDrag = { [weak self] card, step in self?.drag(card, step) }
            view.onKey = { [weak self] card, event in self?.key(card, event) ?? false }
            view.onMenu = { [weak self] card in self?.menu(for: card) }
            grid.addSubview(view)
            cardViews.append(view)
            let badge = PartyBadgeButton(slot: slot)
            badge.target = self
            badge.action = #selector(releaseBadge(_:))
            badge.tag = slot
            badge.isHidden = true
            badges.addSubview(badge)
            badgeButtons.append(badge)
        }
        observer = NotificationCenter.default.addObserver(
            forName: ModelParty.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override var isFlipped: Bool { true }

    /// The panel's size for what it holds now.
    var preferredSize: NSSize { NSSize(width: PartyMetrics.width, height: height()) }

    private var headerHeight: CGFloat { 28 * PartyMetrics.scale }

    /// Where the Edit button stands, for the check that it sits inside the header.
    var editFrame: NSRect { editButton.frame }
    var recentFrames: [NSRect] { recentChips.map(\.frame) }
    var titleFrame: NSRect { titleLabel.frame.union(countLabel.frame) }

    private func footerHeight() -> CGFloat {
        guard mode == .party else { return 0 }
        let chips = recentChips.map { $0.fitted(limit: chipLimit).height }.max() ?? 0
        return max(chips, 28 * PartyMetrics.scale)
    }

    /// The room each recent chip has: what the footer leaves between the label and the way into
    /// the catalog, shared by the chips there are, so a long model name wraps instead of being cut.
    private var chipLimit: CGFloat {
        let scale = PartyMetrics.scale
        let label = ceil(recentLabel.intrinsicContentSize.width)
        let browse =
            ceil(browseButton.intrinsicContentSize.width) + 4 * scale
            + ceil(browseHint.intrinsicContentSize.width)
        let room = PartyMetrics.width - 2 * PartyMetrics.inset - label - 10 * scale - browse - 16 * scale
        let count = CGFloat(max(recentChips.count, 1))
        return max(120 * scale, (room - (count - 1) * 8 * scale) / count)
    }

    private func gridHeight() -> CGFloat {
        2 * rowHeight + PartyMetrics.gap
    }

    private func height() -> CGFloat {
        let inset = PartyMetrics.inset
        var total = inset + headerHeight + PartyMetrics.gap + gridHeight() + inset
        if mode == .party { total += PartyMetrics.gap + 1 + 10 * PartyMetrics.scale + footerHeight() }
        return ceil(total)
    }

    /// Redraws from the party: the cards, the count, the edit state and the recents. A rename in
    /// flight is dropped, because what is kept is what the cards say.
    func reload() {
        cards = model.cards()
        let needed = cards.map { PartyMetrics.measure($0).height }.max() ?? PartyMetrics.baseHeight
        rowHeight = max(PartyMetrics.baseHeight, needed)
        let running = model.isRunning()
        for (view, card) in zip(cardViews, cards) {
            view.apply(card, editing: isEditing && mode == .party)
            view.setBreathing(running)
        }
        let filled = cards.filter { !$0.isHollow }.count
        countLabel.stringValue = Localized.text("%d of %d", filled, ModelParty.size)
        titleLabel.stringValue =
            mode == .makeRoom
            ? Localized.text("Which one makes room?")
            : isEditing ? Localized.text("Edit party") : Localized.text("Party")
        editButton.title = isEditing ? Localized.text("Done") : Localized.text("Edit")
        countLabel.isHidden = mode == .makeRoom
        reloadRecents()
        for (index, badge) in badgeButtons.enumerated() {
            badge.isHidden = !(isEditing && mode == .party && !cards[index].isHollow)
        }
        needsLayout = true
        let size = preferredSize
        if frame.size != size { onResize?(size) }
    }

    private func reloadRecents() {
        guard mode == .party else { return }
        let recents = model.recents()
        let signature = recents.map(\.id)
        guard signature != recentSignature else { return }
        recentSignature = signature
        recentChips.forEach { $0.removeFromSuperview() }
        recentChips = recents.map { recent in
            let chip = PartyRecentChip(recent: recent)
            chip.onPress = { [weak self] recent in self?.actions.recent(recent) }
            chip.onAdd = { [weak self] recent in self?.actions.addRecent(recent) }
            addSubview(chip)
            return chip
        }
        recentLabel.isHidden = recents.isEmpty
    }

    override func layout() {
        super.layout()
        let inset = PartyMetrics.inset
        let width = bounds.width
        titleLabel.sizeToFit()
        countLabel.sizeToFit()
        let headerMid = inset + headerHeight / 2
        titleLabel.setFrameOrigin(
            NSPoint(x: inset, y: headerMid - titleLabel.frame.height / 2))
        countLabel.setFrameOrigin(
            NSPoint(
                x: titleLabel.frame.maxX + 8 * PartyMetrics.scale,
                y: headerMid - countLabel.frame.height / 2))
        editButton.sizeToFit()
        let editWidth = max(editButton.frame.width, 56 * PartyMetrics.scale)
        editButton.frame = NSRect(
            x: width - inset - editWidth, y: headerMid - editButton.frame.height / 2,
            width: editWidth, height: editButton.frame.height)
        let gridTop = inset + headerHeight + PartyMetrics.gap
        grid.frame = NSRect(x: inset, y: gridTop, width: width - 2 * inset, height: gridHeight())
        badges.frame = bounds
        for (index, view) in cardViews.enumerated() where view !== dragged {
            view.frame = slotFrame(index)
        }
        for (index, badge) in badgeButtons.enumerated() {
            let corner = slotFrame(index).origin
            let size = PartyBadgeButton.size
            badge.frame = NSRect(
                x: grid.frame.minX + corner.x - 8 * PartyMetrics.scale,
                y: grid.frame.minY + corner.y - 8 * PartyMetrics.scale,
                width: size, height: size)
        }
        guard mode == .party else {
            rule.isHidden = true
            return
        }
        let ruleY = grid.frame.maxY + PartyMetrics.gap
        rule.isHidden = false
        rule.frame = NSRect(x: inset, y: ruleY, width: width - 2 * inset, height: 1)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            rule.layer?.backgroundColor = MacTheme.Color.separator.cgColor
        }
        layoutFooter(top: ruleY + 1 + 10 * PartyMetrics.scale)
    }

    private func layoutFooter(top: CGFloat) {
        let inset = PartyMetrics.inset
        let height = footerHeight()
        let mid = top + height / 2
        browseButton.sizeToFit()
        browseHint.sizeToFit()
        let right = bounds.width - inset
        browseHint.setFrameOrigin(
            NSPoint(x: right - browseHint.frame.width, y: mid - browseHint.frame.height / 2))
        browseButton.setFrameOrigin(
            NSPoint(
                x: browseHint.frame.minX - 4 * PartyMetrics.scale - browseButton.frame.width,
                y: mid - browseButton.frame.height / 2))
        recentLabel.sizeToFit()
        recentLabel.setFrameOrigin(NSPoint(x: inset, y: mid - recentLabel.frame.height / 2))
        var x = recentLabel.frame.maxX + 10 * PartyMetrics.scale
        for chip in recentChips {
            let size = chip.fitted(limit: chipLimit)
            chip.frame = NSRect(x: x, y: mid - size.height / 2, width: size.width, height: size.height)
            x += size.width + 8 * PartyMetrics.scale
        }
    }

    /// Where slot `index` stands in the grid: three columns, two rows, filled in reading order.
    func slotFrame(_ index: Int) -> NSRect {
        let column = CGFloat(index % 3)
        let row = CGFloat(index / 3)
        return NSRect(
            x: column * (PartyMetrics.cardWidth + PartyMetrics.gap),
            y: row * (rowHeight + PartyMetrics.gap), width: PartyMetrics.cardWidth,
            height: rowHeight)
    }

    /// The card frames as the popover shows them, in the panel's own coordinates.
    func cardFrames() -> [NSRect] {
        cardViews.map { grid.convert($0.frame, to: self) }
    }

    func focusInitial() {
        let target = cards.firstIndex(where: \.isInUse) ?? cards.firstIndex(where: { !$0.isHollow }) ?? 0
        window?.makeFirstResponder(cardViews[target])
    }

    func setEditing(_ on: Bool) {
        guard mode == .party, isEditing != on else { return }
        isEditing = on
        reload()
        layoutSubtreeIfNeeded()
    }

    @objc private func toggleEditing() {
        setEditing(!isEditing)
    }

    @objc private func browse() {
        actions.browse()
    }

    @objc private func releaseBadge(_ sender: NSButton) {
        ModelParty.release(slot: sender.tag)
    }

    private func press(_ view: PartyCardView) {
        let card = view.card
        guard mode == .party else {
            actions.take(card)
            return
        }
        if card.isHollow {
            actions.fill(card.slot)
        } else if !isEditing {
            actions.take(card)
        }
    }

    private func rename(_ view: PartyCardView, to name: String) {
        ModelParty.rename(slot: view.card.slot, to: name)
        reload()
    }

    /// One press of the ball's button: the next of the model's own levels, cold to hot, then the
    /// server's own choice, then round again from the coldest.
    func stepLevel(_ view: PartyCardView) {
        let card = view.card
        guard let preset = ModelParty.slot(card.slot)?.preset ?? card.preset, card.takesLevels
        else { return }
        let ladder = ModelDial.ascending(options: model.levels(card))
        guard !ladder.isEmpty else { return }
        let next: PresetEffort
        switch preset.effort {
        case .keep, .server:
            next = .level(ladder[0])
        case .level(let level):
            let at = ladder.firstIndex { EffortVocabulary.same($0, level) }
            if let at, at + 1 < ladder.count {
                next = .level(ladder[at + 1])
            } else if at != nil {
                next = .server
            } else {
                next = .level(ladder[0])
            }
        }
        ModelParty.setEffort(slot: card.slot, next)
    }

    private func menu(for view: PartyCardView) -> NSMenu? {
        guard mode == .party, !view.card.isHollow else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(
            title: Localized.text("Replace…"), action: #selector(replaceFromMenu(_:)),
            keyEquivalent: "")
        item.target = self
        item.tag = view.card.slot
        menu.addItem(item)
        return menu
    }

    @objc private func replaceFromMenu(_ sender: NSMenuItem) {
        actions.replace(sender.tag)
    }

    private func key(_ view: PartyCardView, _ event: NSEvent) -> Bool {
        let slot = view.card.slot
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        guard flags.isEmpty else { return false }
        switch event.keyCode {
        case 123: return moveFocus(from: slot, column: -1, row: 0)
        case 124: return moveFocus(from: slot, column: 1, row: 0)
        case 125: return moveFocus(from: slot, column: 0, row: 1)
        case 126: return moveFocus(from: slot, column: 0, row: -1)
        case 36, 76:
            if isEditing, !view.card.isHollow {
                view.focusRename()
            } else {
                press(view)
            }
            return true
        case 49:
            if isEditing, !view.card.isHollow {
                stepLevel(view)
            } else {
                press(view)
            }
            return true
        case 51, 117:
            guard isEditing, !view.card.isHollow else { return false }
            ModelParty.release(slot: slot)
            return true
        case 120:
            if mode == .party, !view.card.isHollow {
                setEditing(true)
                cardViews[slot].focusRename()
            }
            return true
        default:
            return false
        }
    }

    private func moveFocus(from slot: Int, column: Int, row: Int) -> Bool {
        let next = slot + column + row * 3
        let sameRow = column == 0 || next / 3 == slot / 3
        guard cardViews.indices.contains(next), sameRow else { return true }
        window?.makeFirstResponder(cardViews[next])
        return true
    }

    private func drag(_ view: PartyCardView, _ step: PartyDrag) {
        switch step {
        case .began(let start):
            dragged = view
            let point = grid.convert(start, from: nil)
            dragGrab = NSPoint(x: point.x - view.frame.minX, y: point.y - view.frame.minY)
            view.setLifted(true)
            grid.addSubview(view, positioned: .above, relativeTo: nil)
        case .moved(let location):
            let point = grid.convert(location, from: nil)
            view.setFrameOrigin(NSPoint(x: point.x - dragGrab.x, y: point.y - dragGrab.y))
            let over = card(under: point, excluding: view)
            if over !== dropTarget {
                dropTarget?.isDropTarget = false
                dropTarget = over
                dropTarget?.isDropTarget = true
            }
        case .ended(let location):
            let target = card(under: grid.convert(location, from: nil), excluding: view)
            dropTarget?.isDropTarget = false
            dropTarget = nil
            dragged = nil
            view.setLifted(false)
            grid.subviews = cardViews
            view.frame = slotFrame(view.card.slot)
            if let target { ModelParty.swap(view.card.slot, target.card.slot) }
        }
    }

    private func card(under point: NSPoint, excluding: PartyCardView) -> PartyCardView? {
        cardViews.first { $0 !== excluding && slotFrame($0.card.slot).contains(point) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }
}

/// The party opened from the model pill: a transient popover over `PartyPanelView`. It is the pill's
/// click, and the chat's whole quick answer to which model and how hard.
@MainActor
final class PartyPopover: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    let panel: PartyPanelView
    private let onClosed: @MainActor () -> Void

    @discardableResult
    static func present(
        from anchor: NSView, mode: PartyPanelView.Mode = .party, model: PartyPanelModel,
        actions: PartyPanelActions, onClosed: @escaping @MainActor () -> Void
    ) -> PartyPopover {
        let controller = PartyPopover(
            mode: mode, model: model, actions: actions, onClosed: onClosed)
        controller.show(from: anchor)
        return controller
    }

    private init(
        mode: PartyPanelView.Mode, model: PartyPanelModel, actions: PartyPanelActions,
        onClosed: @escaping @MainActor () -> Void
    ) {
        panel = PartyPanelView(mode: mode, model: model, actions: actions)
        self.onClosed = onClosed
        super.init()
        panel.onResize = { [weak self] size in self?.resize(to: size) }
    }

    var isShown: Bool { popover.isShown }

    func close() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    private func show(from anchor: NSView) {
        popover.behavior = .transient
        popover.delegate = self
        let size = panel.preferredSize
        panel.frame = NSRect(origin: .zero, size: size)
        let host = NSViewController()
        host.view = panel
        host.preferredContentSize = size
        popover.ground(host)
        popover.contentSize = size
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        panel.layoutSubtreeIfNeeded()
        panel.focusInitial()
    }

    private func resize(to size: NSSize) {
        guard popover.isShown, popover.contentSize != size else { return }
        popover.contentSize = size
    }

    func popoverDidClose(_ notification: Notification) {
        onClosed()
    }
}
