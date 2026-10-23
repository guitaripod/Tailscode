import TailscodeCore
import UIKit

extension ImageStudioViewController {
    func updateVerbs() {
        let painting = studio.isPainting
        guard let exhibit = studio.exhibit, !painting, slot.failure == nil else {
            verbs.apply(
                verbs: [], more: [], holding: true,
                waiting: ImageGenSurface.dismissNote(painting: painting))
            return
        }
        let held = studio.isReference(exhibit)
        let offered = actions(for: exhibit).map { action in
            StudioVerb(
                title: action.phoneTitle, hint: action.hint,
                symbol: action == .reference && held ? "checkmark.circle.fill" : action.symbol,
                value: action == .reference && held ? String(localized: "Already the reference") : nil
            ) { [weak self] in self?.perform(action, on: exhibit) }
        }
        var more: [UIMenuElement] = [
            UIAction(
                title: ForgeWords.animateTitle, subtitle: ForgeWords.animateHint,
                image: UIImage(systemName: "film")
            ) { [weak self] _ in self?.animate(exhibit) },
            UIAction(
                title: ImageGenAction.open.title, image: UIImage(systemName: ImageGenAction.open.symbol)
            ) { [weak self] _ in self?.perform(.open, on: exhibit) },
        ]
        if case .made = exhibit {
            more.append(
                UIAction(
                    title: ImageGenAction.discard.title,
                    image: UIImage(systemName: ImageGenAction.discard.symbol),
                    attributes: .destructive
                ) { [weak self] _ in self?.perform(.discard, on: exhibit) })
        }
        verbs.apply(verbs: offered, more: more, holding: false, waiting: nil)
    }

    func applyStrip(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, StripItem>()
        snapshot.appendSections([0])
        if studio.isPainting { snapshot.appendItems([.job]) }
        if library.items.isEmpty {
            snapshot.appendItems([.note])
        } else {
            snapshot.appendItems(library.items.map { .tile($0.id) })
        }
        var refresh: [StripItem] = [.note]
        let shown = studio.exhibit?.libraryID
        if shown != shownExhibitID {
            for id in [shown, shownExhibitID].compactMap({ $0 }) { refresh.append(.tile(id)) }
            shownExhibitID = shown
        }
        snapshot.reconfigureItems(refresh.filter { snapshot.indexOfItem($0) != nil })
        stripSource.apply(snapshot, animatingDifferences: animated && view.window != nil)
        strip.accessibilityValue = library.line
    }

    /// The machine in the bar, and the menu behind the circle beside it: start over, ask the shelf
    /// again, and the machine's own sheet. Starting over says beforehand what else goes with the
    /// stage — the words — and every picture stays on the shelf.
    func updateChrome() {
        pill.apply(StudioMachineReading.image(studio.door), working: studio.isPainting)
        var items: [UIMenuElement] = []
        let promptWords = (promptView.text ?? "").trimmed()
        if studio.canStartOver || !promptWords.isEmpty {
            items.append(
                UIAction(
                    title: ImageGenWords.startOver, subtitle: ImageGenWords.startOverHint,
                    image: UIImage(systemName: "arrow.counterclockwise"), attributes: .destructive
                ) { [weak self] _ in self?.startOver() })
        }
        items.append(
            UIAction(
                title: ImageGenLibraryWords.refresh, subtitle: library.line,
                image: UIImage(systemName: "arrow.clockwise")
            ) { [weak self] _ in
                Theme.Haptics.tap()
                self?.library.refresh()
            })
        items.append(
            UIAction(
                title: ImageGenMachineWords.title, image: UIImage(systemName: "desktopcomputer")
            ) { [weak self] _ in self?.presentMachine() })
        menuItem.menu = UIMenu(
            title: ImageGenLibraryWords.heading(machine: library.machine), children: items)
    }

    /// Back to blank. The words in the box go with it, so a person who only wanted the stage gone
    /// is told beforehand what else goes — and every picture stays on the shelf.
    private func startOver() {
        Theme.Haptics.tap()
        view.endEditing(true)
        studio.startOver()
        setPrompt("")
    }

    func announceLanding() {
        guard let exhibit = studio.exhibit else { return }
        var words: String?
        if case .made(let picture) = exhibit { words = ImageGenFacts.caption(for: picture) }
        let spoken = NSAttributedString(
            string: StudioStageWords.landed(words: words),
            attributes: [.accessibilitySpeechQueueAnnouncement: true])
        UIAccessibility.post(notification: .announcement, argument: spoken)
    }

    func updateChips() {
        let sighting = studio.sighting
        let identity = ImageGenField.allCases.map { "\($0.rawValue)=\(slot.value(of: $0))" }
            .joined(separator: "|")
            + "|\(slot.references.map(\.chip).joined(separator: ","))|\(slot.isBusy)"
            + "|\(slot.aspectApplies)|\(sighting?.readyEngines.map(\.rawValue).joined() ?? "?")"
            + "|\(intake.available.count)|\(slot.cutout)|\(slot.seed.chip)|\(slot.negative)"
            + "|\(briefIsThin)|\(traitCollection.preferredContentSizeCategory.rawValue)"
            + "|\(slot.cutoutApplies)|\(slot.negativeApplies)"
        updateStartFrom()
        guard identity != appliedChips else { return }
        appliedChips = identity
        var chips: [UIView] = [engineChip(sighting: sighting), aspectChip()]
        if slot.applies(.size) { chips.append(sizeChip()) }
        if slot.applies(.detail) { chips.append(detailChip()) }
        chips.append(moreChip())
        chipFlow.set(chips)
    }

    /// Whether the words in the box are thin enough that the model would invent most of the
    /// frame. The More chip wears the answer rather than a banner taking the composer's room.
    private var briefIsThin: Bool {
        ImageGenBrief.isThin(promptView.text ?? "")
    }

    private func chip(
        _ field: ImageGenField, value: String, accessibility: String? = nil, tint: UIColor? = nil
    ) -> UIButton {
        let button = StudioChip.button(label: field.label, value: value, tint: tint)
        button.isEnabled = !slot.isBusy
        if let accessibility { button.accessibilityLabel = accessibility }
        return button
    }

    private func engineChip(sighting: ImageGenSighting?) -> UIButton {
        let unavailable = slot.engineAvailable(given: sighting) == false
        let button = chip(
            .engine, value: slot.value(of: .engine), tint: unavailable ? Theme.Color.warning : nil)
        button.accessibilityLabel = "\(ImageGenField.engine.label), \(slot.value(of: .engine))"
        if unavailable, let sighting {
            button.accessibilityValue = ImageGenWords.engineUnavailable(
                slot.engine, missing: sighting.missing(for: slot.engine).count)
        }
        button.addAction(
            UIAction { [weak self] _ in
                Theme.Haptics.selection()
                self?.studio.advance(.engine)
            }, for: .touchUpInside)
        button.menu = ImageChip.engineMenu(slot: slot, sighting: sighting) { [weak self] engine in
            Theme.Haptics.selection()
            self?.studio.choose(engine: engine)
        }
        return button
    }

    /// The aspect chip stands down while a reference is held: both editors take the size from the
    /// picture they start from, and a chip that changes nothing must not look like one that does.
    private func aspectChip() -> UIButton {
        guard slot.aspectApplies else {
            let button = chip(.aspect, value: ImageGenWords.aspectFollowsReference)
            button.isEnabled = false
            button.accessibilityLabel = ImageGenWords.aspectFollowsReference
            return button
        }
        let button = chip(.aspect, value: slot.value(of: .aspect))
        button.addAction(
            UIAction { [weak self] _ in
                Theme.Haptics.selection()
                self?.studio.advance(.aspect)
            }, for: .touchUpInside)
        button.menu = ImageChip.aspectMenu(slot: slot) { [weak self] aspect in
            Theme.Haptics.selection()
            self?.studio.choose(aspect: aspect)
        }
        return button
    }

    private func sizeChip() -> UIButton {
        let button = chip(
            .size, value: slot.value(of: .size),
            accessibility: "\(ImageGenField.size.label), \(slot.aspect.label(slot.size))")
        button.addAction(
            UIAction { [weak self] _ in
                Theme.Haptics.selection()
                self?.studio.advance(.size)
            }, for: .touchUpInside)
        button.menu = ImageChip.sizeMenu(slot: slot) { [weak self] size in
            Theme.Haptics.selection()
            self?.studio.choose(size: size)
        }
        return button
    }

    private func detailChip() -> UIButton {
        let button = chip(
            .detail, value: slot.value(of: .detail),
            accessibility: "\(ImageGenField.detail.label), \(slot.detail.detail)")
        button.addAction(
            UIAction { [weak self] _ in
                Theme.Haptics.selection()
                self?.studio.advance(.detail)
            }, for: .touchUpInside)
        button.menu = ImageChip.detailMenu(slot: slot) { [weak self] detail in
            Theme.Haptics.selection()
            self?.studio.choose(detail: detail)
        }
        return button
    }

    /// Everything the four decisions do not cover — the seed, painting on transparency, what to
    /// keep out, and the craft — in one chip that says which of them are in force, so a decision
    /// that is made is never hidden and a value is never cut to make room for it.
    private func moreChip() -> UIButton {
        var active: [String] = []
        if slot.seed.isHeld { active.append(slot.seed.chip) }
        if slot.cutout { active.append(ImageGenWords.cutoutTitle) }
        if !slot.negative.trimmed().isEmpty { active.append(ImageGenWords.avoidTitle) }
        let value = active.isEmpty ? slot.seed.chip : active.joined(separator: ", ")
        let button = StudioChip.button(
            label: ImageGenWords.moreTitle, value: value,
            tint: briefIsThin ? Theme.Color.warning : (active.isEmpty ? nil : Theme.Color.accent))
        var children: [UIMenuElement] = []
        if slot.cutoutApplies {
            children.append(
                UIAction(
                    title: ImageGenWords.cutoutTitle, subtitle: ImageGenWords.cutoutHint,
                    image: UIImage(systemName: "square.on.square.dashed"),
                    attributes: slot.isBusy ? .disabled : [], state: slot.cutout ? .on : .off
                ) { [weak self] _ in
                    guard let self else { return }
                    Theme.Haptics.selection()
                    self.studio.setCutout(!self.slot.cutout)
                })
        }
        let seedCanHold = slot.seed.isHeld || slot.seed.last != nil
        children.append(
            UIAction(
                title: ImageGenStudioWords.holdSeedTitle,
                subtitle: ImageGenStudioWords.holdSeedDetail(seed: slot.seed),
                image: UIImage(systemName: slot.seed.isHeld ? "lock.fill" : "die.face.5"),
                attributes: slot.isBusy || !seedCanHold ? .disabled : [],
                state: slot.seed.isHeld ? .on : .off
            ) { [weak self] _ in
                Theme.Haptics.selection()
                self?.studio.toggleSeedHold()
            })
        if slot.negativeApplies {
            let holding = !slot.negative.trimmed().isEmpty
            children.append(
                UIAction(
                    title: ImageGenWords.avoidTitle,
                    subtitle: holding ? slot.negative.ellipsized(to: 40) : ImageGenWords.avoidHint,
                    image: UIImage(systemName: "nosign"),
                    attributes: slot.isBusy ? .disabled : [], state: holding ? .on : .off
                ) { [weak self] _ in
                    Theme.Haptics.tap()
                    self?.presentAvoid()
                })
        }
        children.append(
            ImageChip.craftMenu { [weak self] example in
                guard let self else { return }
                Theme.Haptics.tap()
                self.studio.choose(aspect: example.aspect)
                self.setPrompt(example.prompt)
                self.studio.rememberDraft(example.prompt)
                self.updateChips()
            })
        button.menu = UIMenu(children: children)
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = "\(ImageGenWords.moreTitle), \(value)"
        button.accessibilityHint = briefIsThin ? ImageGenBrief.thinBody : nil
        return button
    }

    /// Attaching a picture is the whole of asking for an edit, so this control is never a switch:
    /// it holds one or it does not, wears the picture it holds, and opens the sources — or replace
    /// and remove — as a menu, because the doors are five and a phone has no tooltip to name them.
    func configureStartFrom() {
        startFrom.translatesAutoresizingMaskIntoConstraints = false
        startFrom.clipsToBounds = false
        startFromRing.fillColor = nil
        startFromRing.lineWidth = 1.5
        startFromRing.lineDashPattern = [4, 3]
        startFrom.layer.addSublayer(startFromRing)
        startFrom.showsMenuAsPrimaryAction = true
        updateStartFrom()
    }
}
