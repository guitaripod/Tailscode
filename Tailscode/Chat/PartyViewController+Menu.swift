import CodingAgentKit
import TailscodeCore
import UIKit

/// What a hold, a key and a drag do on the party sheet, so the cards carry every edit in reach of a
/// finger or a keyboard without turning Edit on.
extension PartyViewController {
    /// A hold on a card: the model's own facts from the server that runs it, and one slot's worth
    /// of Edit as a menu.
    func menu(for view: PartyCardView) -> UIContextMenuConfiguration? {
        let slot = view.slot
        guard cards.indices.contains(slot), !cards[slot].isHollow else { return nil }
        let card = cards[slot]
        let reading = aim()
        let peek = PartyReading.peek(
            card, sources: currentSources, selected: reading.model, effort: reading.effort,
            agentOptions: reading.agentOptions, contextTokens: reading.contextTokens,
            quotas: UsageWidgetStore.cachedQuotas())
        let hue = card.chip.map { Theme.Color.modelIdentity($0) } ?? Theme.Color.tertiaryLabel
        return UIContextMenuConfiguration(
            identifier: slot as NSNumber,
            previewProvider: peek.map { reading in
                { ModelPeekViewController(reading: reading, hue: hue) }
            },
            actionProvider: { [weak self] _ in self?.actions(for: slot) })
    }

    private func actions(for slot: Int) -> UIMenu? {
        guard cards.indices.contains(slot), !cards[slot].isHollow else { return nil }
        let card = cards[slot]
        var primary: [UIMenuElement] = [
            UIAction(
                title: String(localized: "Use now"), image: UIImage(systemName: "checkmark.circle"),
                attributes: card.isAway ? .disabled : []
            ) { [weak self] _ in self?.take(card) }
        ]
        if let levels = levelMenu(for: slot) { primary.append(levels) }
        let arrange: [UIMenuElement] = [
            UIAction(
                title: String(localized: "Replace…"),
                image: UIImage(systemName: "arrow.triangle.2.circlepath")
            ) { [weak self] _ in self?.fill(slot: slot) },
            UIAction(title: String(localized: "Rename"), image: UIImage(systemName: "pencil")) {
                [weak self] _ in self?.startRename(slot: slot)
            },
            swapMenu(for: slot),
            UIAction(
                title: String(localized: "Copy model id"), image: UIImage(systemName: "doc.on.doc")
            ) { [weak self] _ in
                UIPasteboard.general.string = card.resolved?.selection.modelID ?? card.preset?.selection.modelID
                self?.toast(String(localized: "Copied"))
            },
        ]
        let release = UIAction(
            title: String(localized: "Release"), image: UIImage(systemName: "xmark"),
            attributes: .destructive
        ) { [weak self] _ in self?.release(slot: slot) }
        return UIMenu(children: [
            UIMenu(options: .displayInline, children: primary),
            UIMenu(options: .displayInline, children: arrange),
            UIMenu(options: .displayInline, children: [release]),
        ])
    }

    /// Every level the slot's model takes, hottest first, the one it holds ticked: a level is
    /// chosen, never stepped to.
    private func levelMenu(for slot: Int) -> UIMenu? {
        guard let held = ModelParty.slot(slot), cards[slot].takesLevels,
            let resolved = cards[slot].resolved,
            let source = currentSources.first(where: { $0.profileID == cards[slot].profileID })
        else { return nil }
        let options = ModelEffort.options(
            models: source.models, selection: resolved.selection, agentOptions: aim().agentOptions)
        let rungs = ModelDial.rungs(options: options)
        guard !rungs.isEmpty else { return nil }
        let children = rungs.map { rung -> UIAction in
            let chosen = rung.level.map(PresetEffort.level) ?? .server
            return UIAction(
                title: rung.title, subtitle: rung.caption,
                state: Self.holds(held.preset.effort, rung: rung) ? .on : .off
            ) { _ in
                ModelParty.setEffort(slot: slot, chosen)
                Theme.Haptics.notch()
            }
        }
        return UIMenu(
            title: String(localized: "Level"), image: UIImage(systemName: "slider.horizontal.3"),
            children: children)
    }

    private static func holds(_ effort: PresetEffort, rung: EffortRung) -> Bool {
        switch effort {
        case .keep: return false
        case .server: return rung.level == nil
        case .level(let level): return EffortVocabulary.same(level, rung.level)
        }
    }

    private func swapMenu(for slot: Int) -> UIMenu {
        let others = (0..<ModelParty.size).filter { $0 != slot }.map { other -> UIAction in
            let card = cards.indices.contains(other) ? cards[other] : .hollow(other)
            let title =
                card.isHollow
                ? String(localized: "Slot \(other + 1) · empty")
                : String(localized: "Slot \(other + 1) · \(card.title)")
            return UIAction(title: title) { _ in
                ModelParty.swap(slot, other)
                Theme.Haptics.success()
            }
        }
        return UIMenu(
            title: String(localized: "Move to slot"),
            image: UIImage(systemName: "arrow.left.arrow.right"), children: others)
    }

    override var keyCommands: [UIKeyCommand]? {
        var commands = (1...ModelParty.size).map { number in
            UIKeyCommand(
                title: String(localized: "Use slot \(number)"), action: #selector(keyedSlot(_:)),
                input: "\(number)", discoverabilityTitle: String(localized: "Use slot \(number)"))
        }
        commands.append(
            UIKeyCommand(
                title: isArranging ? String(localized: "Done") : String(localized: "Edit party"),
                action: #selector(keyedEdit), input: "e", modifierFlags: .command,
                discoverabilityTitle: isArranging ? String(localized: "Done") : String(localized: "Edit party")))
        commands.append(
            UIKeyCommand(
                title: String(localized: "All models…"), action: #selector(keyedBrowse), input: "o",
                modifierFlags: .command, discoverabilityTitle: String(localized: "All models…")))
        commands.append(
            UIKeyCommand(
                title: String(localized: "Close"), action: #selector(keyedClose),
                input: UIKeyCommand.inputEscape, discoverabilityTitle: String(localized: "Close")))
        return commands
    }

    @objc private func keyedSlot(_ command: UIKeyCommand) {
        guard let input = command.input, let number = Int(input), !isArranging else { return }
        tap(slot: number - 1)
    }

    @objc private func keyedEdit() { toggleEditing() }

    @objc private func keyedBrowse() { browseAll() }

    @objc private func keyedClose() { dismiss(animated: true) }
}

extension PartyViewController: UIDragInteractionDelegate {
    func dragInteraction(
        _ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession
    ) -> [UIDragItem] {
        guard let row = interaction.view as? PartyRecentRow else { return [] }
        let item = UIDragItem(
            itemProvider: NSItemProvider(object: row.recent.selection.rawValue as NSString))
        item.localObject = row.recent
        item.previewProvider = { row.dragPreview }
        Theme.Haptics.selection()
        return [item]
    }

    func dragInteraction(
        _ interaction: UIDragInteraction, sessionAllowsMoveOperation session: UIDragSession
    ) -> Bool { false }
}

extension PartyViewController: UIDropInteractionDelegate {
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        Self.recent(in: session) != nil
    }

    func dropInteraction(
        _ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession
    ) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: UIDropSession) {
        (interaction.view as? PartyCardView)?.setTargeted(true)
        Theme.Haptics.notch()
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
        (interaction.view as? PartyCardView)?.setTargeted(false)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
        (interaction.view as? PartyCardView)?.setTargeted(false)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        guard let card = interaction.view as? PartyCardView, let recent = Self.recent(in: session)
        else { return }
        let preset = Self.carried(
            recent.selection, profileID: recent.profileID, sources: currentSources, aim: aim())
        ModelParty.replace(slot: card.slot, with: preset)
        Theme.Haptics.success()
        toast(String(localized: "\(recent.word) is in slot \(card.slot + 1)"))
    }

    private static func recent(in session: UIDropSession) -> PartyRecent? {
        session.localDragSession?.items.lazy.compactMap { $0.localObject as? PartyRecent }.first
    }
}
