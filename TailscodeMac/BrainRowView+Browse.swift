import AppKit
import TailscodeCore

/// What keys and the pointer do to the brain, on this desk: every event is mapped to one of Core's
/// `NeuralBrowse.Action`s, the model runs the reducer, and the effects that come back are the only
/// things this file performs (scroll the list, copy to the pasteboard, move the keyboard, show the
/// legend or a menu, ring a node). The key table, the mouse rules and the order Esc undoes things
/// in exist once, in Core.
extension BrainRowView {
    func browse(_ action: NeuralBrowse.Action, grabFocus: Bool) {
        guard phase != .closed || mover != nil else { return }
        let effects = updateModel { $0.browse(action) }
        applyBrowse(effects, grabFocus: grabFocus)
    }

    func applyBrowse(_ effects: [NeuralBrowse.Effect], grabFocus: Bool = true) {
        for effect in effects {
            switch effect {
            case .scrollTo(let id):
                list?.scrollTo(id)
                account?.revealStep(id)
            case .copySubject(let id):
                copyText(id) { NeuralBrowse.subjectText(of: $0) }
            case .copyOutput(let id):
                copyText(id) { NeuralBrowse.outputText(of: $0) }
            case .copyMarkdown(let id):
                copyText(id) { NeuralBrowse.markdown(of: $0) }
            case .focusReadout:
                if grabFocus { account?.focus() }
            case .focusList:
                if grabFocus { focusList() }
            case .focusSearch:
                focusSearchField()
            case .expandOutputToggle:
                _ = account?.toggleCardOutput()
            case .showLegend:
                presentLegend()
            case .hideLegend:
                dismissLegend()
            case .collapseBrain:
                collapseBrain()
            case .ring, .dim:
                break
            case .announce(let words):
                announce(words)
            case .showMenu(let id, let items):
                presentMenu(for: id, items: items, event: NSApp.currentEvent, in: list ?? self)
            case .showInRows(let id):
                showInRows(id)
            }
        }
        drainAccountEffects()
        afterBrowse()
    }

    private func afterBrowse() {
        list?.modelChanged()
        chips?.invalidate()
        account?.refresh()
        stage?.refresh(force: true)
        footer?.sync(now: BrainClock.now)
        updateLeader()
        if phase == .closed { syncCard() }
        relayout()
    }

    private func copyText(_ id: String, _ text: (NeuralStep) -> String) {
        guard let step = model.step(id: id) else { return }
        let value = text(step)
        guard !value.isEmpty else {
            announce(NeuralBrowse.noRelatedWords)
            return
        }
        copyToPasteboard(value)
        list?.flashCopied(id)
        account?.flashCopied(id)
    }

    /// The effects the reducer left for the account: a quote for the composer and the scroll to
    /// the card that carries the ask.
    func drainAccountEffects() {
        for effect in updateModel({ $0.drainAccountEffects() }) {
            switch effect {
            case .reply(let quote): replyWithQuote(quote)
            case .goToAsk: goToApproval()
            }
        }
    }


    /// The least time between two hovers the brain acts on. A pointer moving over the rows and the
    /// head reports a thousand positions a second and each one that changed what is under it would
    /// rebuild a reading of the turn: the first is acted on at once, the ones that follow within
    /// this time are folded into the newest.
    static let hoverSpacing = 0.012

    /// The pointer is over a step (a list row, a node, a relation chip) or none: the account
    /// previews it and the head rings its node, and the cursor stays where it is.
    func hoverStep(_ id: String?) {
        let delay = id == nil ? 0 : NeuralHoverGrace.intentDelay
        pendingHover = (id, delay)
        let now = BrainClock.now
        if now - lastHoverApplyTime >= Self.hoverSpacing {
            flushHover()
            return
        }
        guard hoverFlush == nil else { return }
        hoverFlush = Timer.scheduledTimer(withTimeInterval: Self.hoverSpacing, repeats: false) {
            [weak self] _ in
            MainThread.call {
                self?.hoverFlush = nil
                self?.flushHover()
            }
        }
    }

    private func flushHover() {
        guard let (id, delay) = pendingHover, stage != nil else {
            pendingHover = nil
            return
        }
        pendingHover = nil
        lastHoverApplyTime = BrainClock.now
        if let id {
            updateModel { $0.pointer(over: id, at: BrainClock.now - delay) }
            browse(.hover(id), grabFocus: false)
        } else {
            updateModel { $0.pointer(over: nil, at: BrainClock.now) }
            browse(.hoverLeft, grabFocus: false)
        }
        scheduleGraceRefresh()
    }

    /// The account's subject changes without the pointer moving when the grace of a node the
    /// pointer left runs out; a one-shot timer brings it back to what it should say.
    private func scheduleGraceRefresh() {
        graceTimerStore?.invalidate()
        let clock = BrainClock.now
        guard let next = model.nextReadoutChange(after: clock) else { return }
        let wait = max(0.01, next - clock + 0.01)
        graceTimerStore = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            MainThread.call {
                self?.account?.refresh()
                self?.updateLeader()
            }
        }
    }


    /// Points the leader at the step the right side is about: the previewed step, the cursor, or
    /// the step a running turn is on.
    func updateLeader() {
        guard phase == .open, let stage else {
            leader.clear()
            return
        }
        let model = model
        var wanted = model.previewedStep
        if wanted == nil, model.turn.outcome == .running { wanted = model.liveCard?.flight?.stepID }
        if let id = wanted, model.step(id: id) == nil { wanted = nil }
        leader.update(
            stepID: wanted, model: model, metrics: currentMetrics, inks: inks,
            nodes: stage.nodeCentres, reduceMotion: reduceMotion)
    }


    var hasBrainFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    static func browseKey(from event: NSEvent) -> NeuralBrowse.Key? {
        switch event.keyCode {
        case 126: return .up
        case 125: return .down
        case 116: return .pageUp
        case 121: return .pageDown
        case 115: return .home
        case 119: return .end
        case 123: return .left
        case 124: return .right
        case 36, 76: return .enter
        case 49: return .space
        case 53: return .escape
        case 48: return .tab
        default:
            guard let text = event.characters, text.count == 1, let scalar = text.unicodeScalars.first,
                scalar.value >= 0x21, scalar.value < 0x7F
            else { return nil }
            return .character(Character(scalar))
        }
    }

    func brainKeyApplies(_ event: NSEvent) -> Bool {
        guard phase == .open, stage != nil, hasBrainFocus else { return false }
        let reserved: NSEvent.ModifierFlags = [.command, .control, .option]
        guard event.modifierFlags.intersection(reserved).isEmpty else { return false }
        return Self.browseKey(from: event) != nil
    }

    func handleBrainKey(_ event: NSEvent, from view: NSView) -> Bool {
        guard brainKeyApplies(event), let key = Self.browseKey(from: event) else { return false }
        if key == .tab {
            if event.modifierFlags.contains(.shift) {
                window?.selectPreviousKeyView(view)
            } else {
                window?.selectNextKeyView(view)
            }
            return true
        }
        var modifiers: NeuralBrowse.Modifiers = []
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if key == .escape, stage?.divedZone != nil || stage?.isDiving == true,
            !model.stepList.filter.isActive, model.pinnedStep == nil
        {
            stage?.surface()
            return true
        }
        let hadCursor = model.pinnedStep != nil
        browse(.key(key, modifiers), grabFocus: true)
        if key == .escape, hadCursor, model.pinnedStep == nil {
            hoverApplied = nil
            updateModel { $0.pointer(over: nil, at: BrainClock.now - 10) }
            stage?.refresh(force: true)
            updateLeader()
        }
        return true
    }


    func presentLegend() {
        dismissLegend()
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = true
        let controller = NSViewController()
        controller.view = BrainLegendView(inks: inks)
        controller.view.setFrameSize((controller.view as? BrainLegendView)?.fittingSize ?? .zero)
        popover.contentViewController = controller
        popover.contentSize = controller.view.frame.size
        legend = popover
        let anchor: NSView = (currentMetrics.arrangement == .accordion ? account : list) ?? self
        popover.show(
            relativeTo: NSRect(x: anchor.bounds.midX, y: anchor.bounds.minY + 24, width: 1, height: 1),
            of: anchor, preferredEdge: .maxY)
    }

    func dismissLegend() {
        guard let legend else { return }
        legend.close()
        self.legend = nil
        if model.browseState.legend { updateModel { $0.setBrowseLegend(false) } }
    }

    func presentMenu(forStep id: String, event: NSEvent, in view: NSView) {
        guard let row = model.browseState.list.row(id: id) else { return }
        presentMenu(for: id, items: NeuralBrowse.menuItems(for: row), event: event, in: view)
    }

    func presentMenu(
        for id: String, items: [NeuralBrowse.MenuItem], event: NSEvent?, in view: NSView
    ) {
        guard model.browseState.list.row(id: id) != nil else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            let entry = NSMenuItem(
                title: NeuralBrowse.title(of: item), action: #selector(menuChosen(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = BrainMenuChoice(item: item, id: id)
            menu.addItem(entry)
        }
        if let event {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        } else {
            menu.popUp(positioning: nil, at: NSPoint(x: 8, y: 8), in: view)
        }
    }

    @objc private func menuChosen(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? BrainMenuChoice else { return }
        browse(.menu(choice.item, choice.id), grabFocus: true)
    }

    var pointerOverRow: Bool { card.hovered }
}

/// What a context-menu entry stands for.
final class BrainMenuChoice: NSObject {
    let item: NeuralBrowse.MenuItem
    let id: String

    init(item: NeuralBrowse.MenuItem, id: String) {
        self.item = item
        self.id = id
    }
}

/// The key legend: Core's table in two columns, in a popover.
@MainActor
final class BrainLegendView: NSView {
    private let entries = NeuralBrowse.legend

    init(inks: BrainInks) {
        super.init(frame: .zero)
        let perColumn = (entries.count + 1) / 2
        var maxKeys: [CGFloat] = [0, 0]
        let keyFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        let doesFont = MacTheme.Ramp.font(.rowDetail)
        for (index, entry) in entries.enumerated() {
            let column = index / perColumn
            let width = (entry.keys as NSString).size(withAttributes: [.font: keyFont]).width
            maxKeys[column] = max(maxKeys[column], ceil(width))
        }
        var widths: [CGFloat] = [0, 0]
        for (index, entry) in entries.enumerated() {
            let column = index / perColumn
            let width = (entry.does as NSString).size(withAttributes: [.font: doesFont]).width
            widths[column] = max(widths[column], ceil(width))
        }
        let rowHeight: CGFloat = 22
        let gap: CGFloat = 12
        let padding: CGFloat = 16
        var x = padding
        var columnX: [CGFloat] = []
        for column in 0..<2 {
            columnX.append(x)
            x += maxKeys[column] + gap + widths[column] + (column == 0 ? 28 : 0)
        }
        for (index, entry) in entries.enumerated() {
            let column = index / perColumn
            let y = padding + CGFloat(index % perColumn) * rowHeight
            let keys = NSTextField(labelWithString: entry.keys)
            keys.font = keyFont
            keys.textColor = NSColor(hex: inks.palette.accent) ?? .labelColor
            keys.frame = CGRect(x: columnX[column], y: y, width: maxKeys[column], height: 18)
            let does = NSTextField(labelWithString: entry.does)
            does.font = doesFont
            does.textColor = .labelColor
            does.frame = CGRect(
                x: columnX[column] + maxKeys[column] + gap, y: y, width: widths[column] + 2, height: 18)
            addSubview(keys)
            addSubview(does)
        }
        frame = CGRect(x: 0, y: 0, width: x + padding - 28 + 28, height: padding * 2 + CGFloat(perColumn) * rowHeight)
        setAccessibilityLabel(Localized.text("Keys"))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    override var fittingSize: NSSize { frame.size }
}
