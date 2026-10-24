import TailscodeCore
import UIKit

extension ModelPickerViewController {
    /// The machine first, as a strip of tabs under the search field, and under the strip the one
    /// sentence a tab that is not this chat's server owes: that a pick there is a new chat. The
    /// strip is a row of capsules that scrolls sideways rather than a segmented control, because
    /// a server's name is a word somebody chose and a segment truncates it to nothing.
    func configureMachines() {
        above.axis = .vertical
        above.backgroundColor = Theme.Color.groupedBackground
        above.spacing = Theme.Spacing.xs
        above.translatesAutoresizingMaskIntoConstraints = false
        above.onResize = { [weak self] in self?.fitBand() }
        machineStrip.onPick = { [weak self] index in self?.pickMachine(index) }
        doorStrip.onPick = { [weak self] index in self?.pickDoor(index) }
        machineStrip.onInfo = { [weak self] index in self?.briefMachine(index) }
        doorStrip.onInfo = { [weak self] index in self?.briefDoor(index) }
        consequence.numberOfLines = 0
        consequence.adjustsFontForContentSizeCategory = true
        consequence.isAccessibilityElement = true
        let line = UIView()
        line.addSubview(consequence)
        consequence.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            consequence.topAnchor.constraint(equalTo: line.topAnchor),
            consequence.bottomAnchor.constraint(equalTo: line.bottomAnchor),
            consequence.leadingAnchor.constraint(equalTo: line.leadingAnchor, constant: Theme.Spacing.l),
            consequence.trailingAnchor.constraint(equalTo: line.trailingAnchor, constant: -Theme.Spacing.l),
        ])
        if let dial {
            effortStrip.render(
                modelName: dial.modelName, chip: dial.chip,
                context: context == .composer ? String(localized: "Next chat") : String(localized: "This chat"),
                options: dial.options, effort: dial.effort)
            effortStrip.onSet = { [weak self] level in
                guard let self else { return }
                self.dial?.effort = level
                self.dial?.onEffort(level)
                self.chooser.setAim(
                    self.dial.map { ChooserAim(effort: $0.effort, agentOptions: $0.agentOptions) })
                self.applySnapshot(keepingScroll: true)
            }
            above.addArrangedSubview(effortStrip)
        }
        above.addArrangedSubview(machineStrip)
        above.addArrangedSubview(doorStrip)
        above.addArrangedSubview(line)
        aboveClip.clipsToBounds = true
        aboveClip.translatesAutoresizingMaskIntoConstraints = false
        aboveClip.addSubview(above)
        view.addSubview(aboveClip)
        NSLayoutConstraint.activate([
            aboveClip.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            aboveClip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            aboveClip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            aboveClip.bottomAnchor.constraint(equalTo: above.bottomAnchor),
            above.topAnchor.constraint(equalTo: aboveClip.topAnchor),
            above.leadingAnchor.constraint(equalTo: aboveClip.leadingAnchor),
            above.trailingAnchor.constraint(equalTo: aboveClip.trailingAnchor),
        ])
        syncMachines()
    }

    func syncMachines() {
        let shown = chooser.showsMachines
        machineStrip.isHidden = !shown
        machineStrip.render(chooser.machines.map(ChipStripView.Chip.init), selected: chooser.machineIndex)
        syncDoors()
        let line = chooser.shownMachine?.consequence(for: context.chooser)
        consequence.superview?.isHidden = !(shown || context == .branch) || line == nil
        consequence.attributedText = line.map {
            NSAttributedString(
                string: $0, attributes: Theme.Ramp.attributes(.rowNote, color: Theme.Color.warning))
        }
        consequence.accessibilityLabel = line
        view.setNeedsLayout()
        view.layoutIfNeeded()
        fitBand()
    }

    /// The doors under the machine: every door first, then each provider the machine reaches its
    /// models through, biggest first. Drawn only past one door.
    private func syncDoors() {
        let shown = chooser.showsDoors
        doorStrip.isHidden = !shown
        guard shown else { return }
        let every = ChipStripView.Chip(
            title: String(localized: "All"), count: chooser.allDoorsCount,
            detail: String(localized: "Every provider this server reaches"), dot: nil)
        doorStrip.render(
            [every] + chooser.doors.map(ChipStripView.Chip.init), selected: chooser.doorIndex)
    }

    private func briefMachine(_ index: Int) {
        guard chooser.machines.indices.contains(index),
            let card = chooser.briefing(machine: chooser.machines[index].profileID)
        else { return }
        ChooserBriefingViewController.present(card, from: self)
    }

    private func briefDoor(_ index: Int) {
        guard index > 0, let door = chooser.doors[safe: index - 1],
            let card = chooser.briefing(door: door.providerID)
        else { return }
        ChooserBriefingViewController.present(card, from: self)
    }

    func pickMachine(_ index: Int) {
        guard chooser.machines.indices.contains(index),
            chooser.setMachine(chooser.machines[index].profileID)
        else { return }
        Theme.Haptics.selection()
        syncMachines()
        applySnapshot()
        scrollToFocused()
    }

    func pickDoor(_ index: Int) {
        let door = index == 0 ? nil : chooser.doors[safe: index - 1]?.providerID
        guard index == 0 || door != nil, chooser.setDoor(door) else { return }
        Theme.Haptics.selection()
        syncDoors()
        applySnapshot()
        scrollToFocused()
    }

    private func scrollToFocused() {
        guard let focused = chooser.focused, let indexPath = dataSource.indexPath(for: focused.id)
        else { return }
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
    }

    @objc func doorKey(_ command: UIKeyCommand) {
        guard let input = command.input, let digit = Int(input),
            let chord = KeyChord.canonical(keyval: UInt32(0x30 + digit), state: KeyChord.altMask),
            case .door(let index) = ModelChooser.command(for: chord)
        else { return }
        pickDoor(index.map { $0 + 1 } ?? 0)
    }

    @objc func machineKey(_ command: UIKeyCommand) {
        guard let input = command.input, let digit = Int(input),
            let chord = KeyChord.canonical(
                keyval: UInt32(0x30 + digit), state: KeyChord.controlMask),
            case .machine(let index) = ModelChooser.command(for: chord)
        else { return }
        pickMachine(index)
    }

    /// The band above the list is real chrome of a height nobody here knows ahead — the effort card,
    /// two strips of chips and a sentence that wraps — so the list leaves room for what it measured
    /// *now*, and again whenever the band changes size: a tab that turns a line on used to leave
    /// the list one line short, with the sentence drawn over the first heading.
    func fitBand() {
        guard isViewLoaded else { return }
        let height =
            above.isHidden
            ? 0
            : above.systemLayoutSizeFitting(
                CGSize(width: view.bounds.width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
            ).height
        let inset =
            machineStrip.isHidden && doorStrip.isHidden && effortStrip.isHidden
            ? 0 : height + Theme.Spacing.xs
        let was = collectionView.contentInset.top
        defer { scrollBand() }
        guard abs(was - inset) > 0.5 else { return }
        let atTop = collectionView.contentOffset.y <= -collectionView.adjustedContentInset.top + 1
        collectionView.contentInset.top = inset
        collectionView.verticalScrollIndicatorInsets.top = inset
        if atTop { collectionView.contentOffset.y = -collectionView.adjustedContentInset.top }
    }

    /// At the accessibility text sizes the band alone would fill the screen, so it stops being
    /// chrome and becomes the head of the list: it scrolls away with it.
    func scrollBand() {
        guard isViewLoaded, traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        else {
            above.transform = .identity
            return
        }
        let lift = max(0, collectionView.contentOffset.y + collectionView.adjustedContentInset.top)
        above.transform = CGAffineTransform(translationX: 0, y: -lift)
    }
}
