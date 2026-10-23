import TailscodeCore
import UIKit

extension VideoForgeViewController {
    func updateVerbs() {
        let rendering = runner.isRendering
        guard !rendering, let entry = stageEntry, entry.isPlayable, stageClip != nil else {
            verbs.apply(
                verbs: [], more: [], holding: true,
                waiting: ForgeSurface.dismissNote(rendering: rendering))
            return
        }
        var offered: [StudioVerb] = [
            StudioVerb(
                title: String(localized: "Play"), hint: nil, symbol: "play.fill"
            ) { [weak self] in self?.openStageClip() },
            StudioVerb(
                title: String(localized: "Share"), hint: nil, symbol: "square.and.arrow.up"
            ) { [weak self] in
                guard let entry = self?.stageEntry else { return }
                self?.share(entry)
            },
            StudioVerb(
                title: ForgeWords.extendTitle, hint: ForgeWords.extendHint, symbol: "forward.end.fill"
            ) { [weak self] in
                guard let entry = self?.stageEntry else { return }
                self?.continueIt(entry)
            },
        ]
        offered.append(
            StudioVerb(
                title: muted ? String(localized: "Play sound") : String(localized: "Mute"), hint: nil,
                symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
            ) { [weak self] in self?.toggleSound() })
        let more: [UIMenuElement] = [
            UIAction(
                title: String(localized: "Use these settings"),
                image: UIImage(systemName: "arrow.uturn.backward")
            ) { [weak self] _ in
                guard let entry = self?.stageEntry else { return }
                self?.reuse(entry)
            },
            UIAction(
                title: String(localized: "Remove"), image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [weak self] _ in
                guard let entry = self?.stageEntry else { return }
                self?.forget(entry)
            },
        ]
        verbs.apply(verbs: offered, more: more, holding: false, waiting: nil)
    }

    func applyStrip(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, StripItem>()
        snapshot.appendSections([0])
        if runner.isRendering { snapshot.appendItems([.job]) }
        if board.history.isEmpty {
            snapshot.appendItems([.note])
        } else {
            snapshot.appendItems(board.history.map { .clip($0.id) })
        }
        var refresh: [StripItem] = [.job]
        let stamp = stripFacts
        if stamp != stripStamp {
            stripStamp = stamp
            refresh += [.note] + board.history.map { .clip($0.id) }
        }
        snapshot.reconfigureItems(refresh.filter { snapshot.indexOfItem($0) != nil })
        stripSource.apply(snapshot, animatingDifferences: animated && view.window != nil) {
            [weak self] in self?.revealStageClip()
        }
    }

    /// Everything a clip tile or the note draws from, in one string: a tile is reconfigured when
    /// one of these changed and not on every frame the socket sends, because a reconfigure
    /// restarts the tile's poster and a render sends a frame every moment.
    private var stripFacts: String {
        let clips = board.history.map(\.id).joined(separator: ",")
        let gone = runner.missingClips.sorted().joined(separator: ",")
        let machine = runner.endpoint.map { "\($0.host):\($0.port)" } ?? ""
        return [stageEntry?.id ?? "", clips, gone, machine, historyNote ?? ""].joined(separator: "|")
    }

    /// The clip on the stage is the one selected on the shelf, and the shelf scrolls to it when it
    /// first becomes the stage's — a clip that just landed is the newest, which can sit off the
    /// screen's edge after a long wait.
    private func revealStageClip() {
        guard let id = stageEntry?.id, id != revealed,
            let path = stripSource.indexPath(for: .clip(id))
        else { return }
        revealed = id
        strip.scrollToItem(at: path, at: .centeredHorizontally, animated: view.window != nil)
    }

    /// The renderer in the bar, and the menu behind the circle beside it: the renderer's own
    /// screen and where its address is changed.
    func updateChrome() {
        pill.apply(StudioMachineReading.forge(board), working: runner.isRendering)
        menuItem.menu = UIMenu(
            children: [
                UIAction(
                    title: ForgeField.endpoint.label, image: UIImage(systemName: "desktopcomputer")
                ) { [weak self] _ in self?.openRenderer() }
            ])
        if runner.endpoint == nil { pill.apply(nil, working: false) }
    }

    func announceLanding() {
        let spoken = NSAttributedString(
            string: StudioStageWords.clipLanded(words: board.job.recipe.prompt),
            attributes: [.accessibilitySpeechQueueAnnouncement: true])
        UIAccessibility.post(notification: .announcement, argument: spoken)
    }

    func updateChips() {
        let identity = ForgeStudio.chips.map { "\($0.rawValue)=\(board.value(of: $0))" }
            .joined(separator: "|")
            + "|\(board.isBusy)|\(board.recipe.negative)|\(board.recipe.sound)"
            + "|\(traitCollection.preferredContentSizeCategory.rawValue)"
        updateStartFrom()
        guard identity != appliedChips else { return }
        appliedChips = identity
        var chips: [UIView] = []
        for field in ForgeStudio.chips where field != .seed {
            chips.append(chip(for: field))
        }
        chips.append(moreChip())
        chipFlow.set(chips)
    }

    private func chip(for field: ForgeField) -> UIButton {
        let value = board.value(of: field)
        let button = StudioChip.button(label: field.label, value: value)
        button.isEnabled = !board.isBusy
        button.accessibilityLabel = "\(field.label), \(value)"
        if let row = board.rows.first(where: { $0.kind == .field(field) }) {
            button.addAction(
                UIAction { [weak self] _ in
                    Theme.Haptics.selection()
                    _ = self?.runner.activate(row)
                }, for: .touchUpInside)
        }
        button.menu = UIMenu(
            title: field.label,
            children: board.choices(of: field).map { choice in
                UIAction(
                    title: choice.title, subtitle: choice.detail.isEmpty ? nil : choice.detail,
                    state: choice.selected ? .on : .off
                ) { [weak self] _ in
                    Theme.Haptics.selection()
                    self?.runner.pick(field, id: choice.id)
                }
            })
        return button
    }

    /// The seed, what to keep out and what is heard, in one chip that says which of them are in
    /// force, so a decision that is made is never hidden and a value is never cut to make room.
    private func moreChip() -> UIButton {
        var active: [String] = []
        if !board.recipe.negative.trimmed().isEmpty { active.append(ForgeField.negative.label) }
        if !board.recipe.sound.trimmed().isEmpty { active.append(ForgeField.sound.label) }
        let value = active.isEmpty ? board.value(of: .seed) : active.joined(separator: ", ")
        let button = StudioChip.button(
            label: ImageGenWords.moreTitle, value: value,
            tint: active.isEmpty ? nil : Theme.Color.accent)
        let busy = board.isBusy
        var children: [UIMenuElement] = []
        children.append(
            UIAction(
                title: ForgeField.sound.label, subtitle: soundSubtitle,
                image: UIImage(systemName: ForgeField.sound.symbol),
                attributes: busy ? .disabled : [],
                state: board.recipe.sound.trimmed().isEmpty ? .off : .on
            ) { [weak self] _ in self?.presentWords(for: .sound) })
        children.append(
            UIAction(
                title: ForgeField.negative.label, subtitle: avoidSubtitle,
                image: UIImage(systemName: ForgeField.negative.symbol),
                attributes: busy ? .disabled : [],
                state: board.recipe.negative.trimmed().isEmpty ? .off : .on
            ) { [weak self] _ in self?.presentWords(for: .negative) })
        children.append(
            UIAction(
                title: ForgeField.seed.label, subtitle: board.value(of: .seed),
                image: UIImage(systemName: "die.face.5"), attributes: busy ? .disabled : []
            ) { [weak self] _ in
                Theme.Haptics.selection()
                self?.runner.pick(.seed, id: "reroll")
            })
        button.menu = UIMenu(children: children)
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = "\(ImageGenWords.moreTitle), \(value)"
        return button
    }

    private var soundSubtitle: String {
        let heard = board.recipe.sound.trimmed()
        return heard.isEmpty ? ForgeWords.soundUnset : heard.ellipsized(to: 40)
    }

    private var avoidSubtitle: String {
        let avoid = board.recipe.negative.trimmed()
        return avoid.isEmpty ? ForgeWords.negativeIgnoredHint : avoid.ellipsized(to: 40)
    }

    /// A small box for the two lines that are not the clip's words — what is heard and what to
    /// keep out — because a phone has nowhere to keep a second field open under the composer
    /// without taking the stage's room.
    private func presentWords(for field: ForgeField) {
        let sound = field == .sound
        let alert = UIAlertController(
            title: field.label, message: sound ? ForgeWords.soundHint : ForgeWords.negativeIgnoredHint,
            preferredStyle: .alert)
        alert.addTextField { text in
            text.text = sound ? self.board.recipe.sound : self.board.recipe.negative
            text.placeholder = sound ? ForgeWords.soundPlaceholder : ImageGenWords.avoidPlaceholder
            text.autocapitalizationType = .none
            text.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: ImageGenWords.cancelTitle, style: .cancel))
        alert.addAction(
            UIAlertAction(title: ImageGenWords.applyTitle, style: .default) { [weak self] _ in
                let words = alert.textFields?.first?.text ?? ""
                if sound { self?.runner.hear(words) } else { self?.runner.avoid(words) }
            })
        present(alert, animated: true)
    }
}
