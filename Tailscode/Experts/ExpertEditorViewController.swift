import CodingAgentKit
import MidgarCore
import TailscodeCore
import UIKit

/// Makes or changes an expert: who it is, where it works and with what model, its charter and
/// skills, where its notebook lives, its bench, its guards and when they run. A draft from a chat
/// or a skill opens here for review, with the notes it drafted ticked — a note that was only true
/// that day starts unticked — and nothing is saved until Create.
@MainActor
final class ExpertEditorViewController: UIViewController, UITextViewDelegate {
    enum Mode {
        case create(profileID: String, draft: ExpertDraft)
        case edit(ExpertRow)
    }

    private let mode: Mode
    private var profileID: String
    private var name: String
    private var glyph: String
    private var hue: ExpertHue
    private var purpose: String
    private var directory: String
    private var model: String?
    private var effort: String?
    private var charter: String
    private var skills: [String]
    private var notebookPath: String?
    private var bench: [ExpertBenchItem]
    private var guards: [ExpertGuard]
    private var guardRule: ScheduleRule?
    private var draftNotes: [ExpertDraftNote]
    private var ticks: Set<String>
    private var availableSkills: [ExpertSkill] = []
    private var saving = false

    private var scroll: UIScrollView!
    private var column: UIStackView!
    private let mark = ExpertMarkView(side: 58)
    private let charterView = UITextView()

    static func presentNew(profileID: String, draft: ExpertDraft, from controller: UIViewController) {
        let editor = ExpertEditorViewController(mode: .create(profileID: profileID, draft: draft))
        let nav = UINavigationController(rootViewController: editor)
        nav.modalPresentationStyle = .formSheet
        controller.present(nav, animated: true)
    }

    static func presentEdit(row: ExpertRow, from controller: UIViewController) {
        let nav = UINavigationController(rootViewController: ExpertEditorViewController(mode: .edit(row)))
        nav.modalPresentationStyle = .formSheet
        controller.present(nav, animated: true)
    }

    /// Asks a machine to draft an expert from a conversation, then opens the draft for review.
    static func presentDraft(profileID: String, sessionID: String, from controller: UIViewController) {
        guard let backend = ExpertDesk.shared.experts(forProfileID: profileID) else { return }
        let waiting = UIAlertController(
            title: ExpertWords.drafting,
            message: Localized.text("A fork of this chat, never saved, drafts the charter, the first notes, the bench and the skills."),
            preferredStyle: .alert)
        controller.present(waiting, animated: true)
        Task {
            do {
                let draft = try await backend.draftExpert(session: sessionID, skill: nil)
                waiting.dismiss(animated: true) {
                    presentNew(profileID: profileID, draft: draft, from: controller)
                }
            } catch {
                waiting.dismiss(animated: true) {
                    ExpertRouter.report(error, title: ExpertWords.draftFailed, from: controller)
                }
            }
        }
    }

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .create(let profileID, let draft):
            self.profileID = profileID
            name = draft.name
            glyph = draft.glyph ?? ""
            hue = ExpertHue(draft.hue ?? Self.hue(for: draft.name).rawValue)
            purpose = draft.purpose ?? ""
            directory = draft.directory ?? ""
            model = draft.model
            effort = draft.effort
            charter = draft.charter ?? ""
            skills = draft.skills ?? []
            notebookPath = draft.notebookPath
            bench = draft.bench ?? []
            guards = draft.guards ?? []
            guardRule = draft.guardRule
            draftNotes = draft.notes ?? []
            ticks = ExpertMaking.defaultTicks(draft)
        case .edit(let row):
            let expert = row.expert
            profileID = row.profileID
            name = expert.name
            glyph = expert.glyph
            hue = row.hue
            purpose = expert.purpose
            directory = expert.directory ?? ""
            model = expert.model
            effort = expert.effort
            charter = expert.charter
            skills = expert.skills
            notebookPath = expert.notebookPath
            bench = expert.bench.map(\.described)
            guards = expert.guards.map(\.described)
            guardRule = expert.guardRule
            draftNotes = []
            ticks = []
        }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// A colour for a new expert the way the machine picks one: by its name, so the same name
    /// always starts in the same colour.
    static func hue(for name: String) -> ExpertHue {
        let ordered: [ExpertHue] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .red, .yellow]
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return ordered[sum % ordered.count]
    }

    private var isCreating: Bool {
        if case .create = mode { return true }
        return false
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = isCreating ? ExpertWords.newExpert : ExpertWords.edit
        (scroll, column) = MachinePage.install(in: self)
        if navigationController?.viewControllers.first === self {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        }
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: isCreating ? ExpertWords.create : ExpertWords.save, image: nil,
            primaryAction: UIAction { [weak self] _ in self?.save() }, menu: nil)
        navigationItem.rightBarButtonItem?.style = .done
        isModalInPresentation = true
        charterView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        render()
        loadSkills()
    }

    private func loadSkills() {
        guard let backend = ExpertDesk.shared.experts(forProfileID: profileID) else { return }
        Task { [weak self] in
            let skills = (try? await backend.expertSkills()) ?? []
            guard let self else { return }
            self.availableSkills = skills
            self.render()
        }
    }

    // MARK: Form

    private func render() {
        let offset = scroll.contentOffset
        MachinePage.clear(column)
        navigationItem.rightBarButtonItem?.isEnabled = !saving && !name.trimmingCharacters(in: .whitespaces).isEmpty
        identity()
        place()
        charterSection()
        skillsSection()
        notebookSection()
        if !draftNotes.isEmpty { notesSection() }
        benchSection()
        guardsSection()
        if case .edit = mode { deleteSection() }
        view.layoutIfNeeded()
        scroll.contentOffset = offset
    }

    private func inset(_ content: UIView) -> UIView {
        let holder = UIView()
        content.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: holder.topAnchor, constant: Theme.Spacing.m),
            content.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -Theme.Spacing.m),
            content.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: Theme.Spacing.m),
            content.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -Theme.Spacing.m),
        ])
        return holder
    }

    private func field(
        _ title: String, _ text: String, placeholder: String, capitalization: UITextAutocapitalizationType = .sentences,
        onChange: @escaping (String) -> Void
    ) -> FormField {
        let field = FormField(title: title, placeholder: placeholder, capitalization: capitalization)
        field.textField.text = text
        field.textField.addAction(UIAction { action in
            onChange((action.sender as? UITextField)?.text ?? "")
        }, for: .editingChanged)
        return field
    }

    private func identity() {
        mark.show(glyph: glyph.isEmpty ? ExpertMaking.glyph(for: name) : glyph, hue: hue)
        let hues = UIStackView()
        hues.spacing = Theme.Spacing.xs
        hues.distribution = .fillEqually
        for option in ExpertHue.allCases {
            let dot = UIButton(type: .custom)
            dot.backgroundColor = ExpertStyle.color(option)
            dot.layer.cornerRadius = 13
            dot.layer.borderWidth = option == hue ? 3 : 0
            dot.layer.borderColor = Theme.Color.label.cgColor
            dot.accessibilityLabel = option.rawValue
            dot.accessibilityTraits = option == hue ? [.button, .selected] : .button
            dot.heightAnchor.constraint(equalToConstant: 26).isActive = true
            dot.addAction(UIAction { [weak self] _ in
                Theme.Haptics.selection()
                self?.hue = option
                self?.render()
            }, for: .touchUpInside)
            hues.addArrangedSubview(dot)
        }
        let nameField = field(ExpertWords.name, name, placeholder: "iPadOS") { [weak self] text in
            guard let self else { return }
            self.name = text
            self.mark.show(glyph: self.glyph.isEmpty ? ExpertMaking.glyph(for: text) : self.glyph, hue: self.hue)
            self.navigationItem.rightBarButtonItem?.isEnabled = !text.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let glyphField = field(Localized.text("Mark"), glyph, placeholder: ExpertMaking.glyph(for: name), capitalization: .none) {
            [weak self] text in
            guard let self else { return }
            self.glyph = String(text.prefix(2))
            self.mark.show(glyph: self.glyph.isEmpty ? ExpertMaking.glyph(for: self.name) : self.glyph, hue: self.hue)
        }
        glyphField.widthAnchor.constraint(equalToConstant: 84).isActive = true
        let top = UIStackView(arrangedSubviews: [mark, nameField, glyphField])
        top.alignment = .bottom
        top.spacing = Theme.Spacing.m
        let purposeField = field(ExpertWords.purpose, purpose, placeholder: Localized.text("Makes the apps excellent on iPad.")) {
            [weak self] text in self?.purpose = text
        }
        let stack = UIStackView(arrangedSubviews: [top, hues, purposeField])
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.m
        let card = MachineCardView()
        card.add(inset(stack))
        column.addArrangedSubview(card)
    }

    private func place() {
        column.addArrangedSubview(MachinePage.header(Localized.text("Where it works")))
        let card = MachineCardView()
        if isCreating, ExpertDesk.shared.board.machines.count > 1 {
            let machine = MachineRowView(
                title: Localized.text("Machine"), detail: ExpertDesk.shared.profile(profileID)?.name)
            let button = UIButton(configuration: .gray())
            button.configuration?.title = Localized.text("Change")
            button.configuration?.cornerStyle = .capsule
            button.showsMenuAsPrimaryAction = true
            button.menu = UIMenu(children: ExpertDesk.shared.board.machines.map { machine in
                UIAction(title: machine.machine, state: machine.profileID == profileID ? .on : .off) { [weak self] _ in
                    self?.move(to: machine.profileID)
                }
            })
            machine.trail(button)
            card.add(machine)
        }
        let folder = field(ExpertWords.folder, directory, placeholder: "~/Dev", capitalization: .none) { [weak self] text in
            self?.directory = text
        }
        card.add(inset(folder))
        card.add(modelRow())
        card.add(effortRow())
        column.addArrangedSubview(card)
    }

    /// Another machine for a new expert: what was the old machine's — its folder, notebook, skills,
    /// bench, guards and their clock, its model — is let go, and what belongs to the expert itself
    /// stays: its name, mark, colour, purpose, charter and the notes it drafted.
    private func move(to profileID: String) {
        guard profileID != self.profileID else { return }
        Theme.Haptics.selection()
        self.profileID = profileID
        model = nil
        directory = ""
        notebookPath = nil
        skills = []
        availableSkills = []
        bench = []
        guards = []
        guardRule = nil
        render()
        loadSkills()
    }

    private func modelRow() -> UIView {
        let catalog = ModelCatalogStore.cached(profileID).filter { $0.agentName == nil }
        let current = model.flatMap { id in catalog.first { $0.id == id }?.name ?? id }
        let rowView = MachineRowView(title: ExpertWords.model, detail: current ?? Localized.text("The machine’s default"))
        let button = UIButton(configuration: .gray())
        button.configuration?.title = Localized.text("Choose")
        button.configuration?.cornerStyle = .capsule
        button.showsMenuAsPrimaryAction = true
        var actions: [UIMenuElement] = [
            UIAction(title: Localized.text("The machine’s default"), state: model == nil ? .on : .off) { [weak self] _ in
                self?.model = nil
                self?.render()
            }
        ]
        actions += catalog.prefix(40).map { info in
            UIAction(title: info.name, subtitle: info.id, state: info.id == model ? .on : .off) { [weak self] _ in
                self?.model = info.id
                self?.render()
            }
        }
        button.menu = UIMenu(children: actions)
        rowView.trail(button)
        return rowView
    }

    private func effortRow() -> UIView {
        let levels = ["low", "medium", "high", "xhigh", "max"]
        let rowView = MachineRowView(
            title: Localized.text("Effort"), detail: effort ?? Localized.text("The machine’s default"))
        let button = UIButton(configuration: .gray())
        button.configuration?.title = Localized.text("Choose")
        button.configuration?.cornerStyle = .capsule
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(children: [
            UIAction(title: Localized.text("The machine’s default"), state: effort == nil ? .on : .off) { [weak self] _ in
                self?.effort = nil
                self?.render()
            }
        ] + levels.map { level in
            UIAction(title: level, state: level == effort ? .on : .off) { [weak self] _ in
                self?.effort = level
                self?.render()
            }
        })
        rowView.trail(button)
        return rowView
    }

    private func charterSection() {
        column.addArrangedSubview(MachinePage.header(ExpertWords.charter))
        charterView.text = charter
        charterView.font = Theme.Ramp.font(.cardBody)
        charterView.adjustsFontForContentSizeCategory = true
        charterView.backgroundColor = .clear
        charterView.textColor = Theme.Color.label
        charterView.isScrollEnabled = false
        charterView.delegate = self
        charterView.accessibilityLabel = ExpertWords.charter
        let card = MachineCardView()
        card.add(inset(charterView))
        column.addArrangedSubview(card)
        column.addArrangedSubview(
            MachinePage.footnote(Localized.text("Standing instructions for this kind of work: a map, not a manual. %d words.", charterWords)))
    }

    private var charterWords: Int {
        charter.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    func textViewDidChange(_ textView: UITextView) {
        charter = textView.text
    }

    private func skillsSection() {
        column.addArrangedSubview(MachinePage.header(ExpertWords.skills))
        let names = Array(NSOrderedSet(array: skills + availableSkills.map(\.name))) as? [String] ?? skills
        guard !names.isEmpty else {
            column.addArrangedSubview(MachinePage.footnote(Localized.text("This machine has no skills.")))
            return
        }
        let chips = ExpertChipsView()
        chips.show(names.map { ExpertLine($0) }, selected: Set(skills)) { [weak self] tapped in
            guard let self else { return }
            Theme.Haptics.selection()
            if let index = self.skills.firstIndex(of: tapped) {
                self.skills.remove(at: index)
            } else {
                self.skills.append(tapped)
            }
            self.render()
        }
        column.addArrangedSubview(chips)
        column.addArrangedSubview(MachinePage.footnote(Localized.text("Every task loads these first.")))
    }

    private func notebookSection() {
        column.addArrangedSubview(MachinePage.header(ExpertWords.notebook))
        let card = MachineCardView()
        let choice = UISegmentedControl(items: [ExpertWords.notebookOwn, Localized.text("A folder on the machine")])
        choice.selectedSegmentIndex = notebookPath == nil ? 0 : 1
        choice.addAction(UIAction { [weak self] action in
            guard let self, let control = action.sender as? UISegmentedControl else { return }
            self.notebookPath = control.selectedSegmentIndex == 0 ? nil : (self.notebookPath ?? "")
            self.render()
        }, for: .valueChanged)
        var parts: [UIView] = [choice]
        if notebookPath != nil {
            parts.append(
                field(ExpertWords.notebookFolder, notebookPath ?? "", placeholder: "~/claudememory/project", capitalization: .none) {
                    [weak self] text in self?.notebookPath = text
                })
        }
        let stack = UIStackView(arrangedSubviews: parts)
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.m
        card.add(inset(stack))
        column.addArrangedSubview(card)
        column.addArrangedSubview(
            MachinePage.footnote(Localized.text("A folder you already keep is adopted as it is: one fact per file, indexed in MEMORY.md. Notes are only written when you accept them.")))
    }

    private func notesSection() {
        column.addArrangedSubview(
            MachinePage.header(Localized.text("First notes · %d drafted", draftNotes.count)))
        let card = MachineCardView()
        for note in draftNotes {
            let ticked = ticks.contains(note.title)
            let symbol = ticked ? "checkmark.circle.fill" : "circle"
            let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold))
            let rowView = MachineRowView(
                title: note.title, detail: note.summary, image: image,
                tint: ticked ? Theme.Color.accent : Theme.Color.tertiaryLabel
            ) { [weak self] in
                guard let self else { return }
                Theme.Haptics.selection()
                if self.ticks.contains(note.title) { self.ticks.remove(note.title) } else { self.ticks.insert(note.title) }
                self.render()
            }
            if !ticked { rowView.titleLabel.textColor = Theme.Color.secondaryLabel }
            if note.lasting == false {
                let tag = UILabel()
                tag.text = " \(ExpertWords.lastingUnticked) "
                tag.font = Theme.Ramp.font(.badge)
                tag.textColor = Theme.Color.warning
                tag.backgroundColor = Theme.Color.warning.withAlphaComponent(0.16)
                tag.layer.cornerRadius = 5
                tag.layer.masksToBounds = true
                let line = UIStackView(arrangedSubviews: [tag, UIView()])
                rowView.attach(line)
            }
            rowView.isAccessibilityElement = true
            rowView.accessibilityLabel = note.title
            rowView.accessibilityTraits = ticked ? [.button, .selected] : .button
            card.add(rowView)
        }
        column.addArrangedSubview(card)
    }

    private func benchSection() {
        column.addArrangedSubview(MachinePage.header(ExpertWords.bench))
        let card = MachineCardView()
        for (index, item) in bench.enumerated() {
            let rowView = MachineRowView(title: item.name, detail: Self.describe(item)) { [weak self] in
                self?.editBench(at: index)
            }
            rowView.chevron()
            card.add(rowView)
        }
        let add = MachineRowView(
            title: ExpertWords.addBenchItem,
            image: UIImage(systemName: "plus.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18)),
            tint: Theme.Color.accent
        ) { [weak self] in self?.editBench(at: nil) }
        add.titleLabel.textColor = Theme.Color.accent
        card.add(add)
        column.addArrangedSubview(card)
    }

    static func describe(_ item: ExpertBenchItem) -> String {
        var parts: [String] = []
        switch item.kind {
        case .appleDevice: parts.append(item.identifier ?? Localized.text("A device"))
        case .command: parts.append(item.command ?? "")
        case .port: parts.append("\(item.host ?? "127.0.0.1"):\(item.port ?? 0)")
        }
        if let lock = item.lock, !lock.isEmpty { parts.append(Localized.text("lock %@", lock)) }
        return parts.joined(separator: " · ")
    }

    private func guardsSection() {
        column.addArrangedSubview(MachinePage.header(ExpertWords.guards))
        let card = MachineCardView()
        for (index, item) in guards.enumerated() {
            var detail = item.command
            if let metric = item.metric {
                detail += " · " + [metric.atMost.map { "≤ \($0.formatted())" }, metric.atLeast.map { "≥ \($0.formatted())" }]
                    .compactMap { $0 }.joined(separator: " ") + (metric.unit.map { " \($0)" } ?? "")
            }
            let rowView = MachineRowView(title: item.name, detail: detail) { [weak self] in self?.editGuard(at: index) }
            rowView.detailLabel.numberOfLines = 2
            rowView.chevron()
            card.add(rowView)
        }
        let add = MachineRowView(
            title: ExpertWords.addGuard,
            image: UIImage(systemName: "plus.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18)),
            tint: Theme.Color.accent
        ) { [weak self] in self?.editGuard(at: nil) }
        add.titleLabel.textColor = Theme.Color.accent
        card.add(add)
        card.add(ruleRow())
        column.addArrangedSubview(card)
        column.addArrangedSubview(MachinePage.footnote(ExpertWords.noGuards))
    }

    private func ruleRow() -> UIView {
        let picker = UIDatePicker()
        picker.datePickerMode = .time
        picker.preferredDatePickerStyle = .compact
        var components = DateComponents()
        components.hour = guardRule?.hour ?? 3
        components.minute = guardRule?.minute ?? 0
        picker.date = Calendar.current.date(from: components) ?? Date()
        picker.isEnabled = guardRule != nil
        picker.addAction(UIAction { [weak self] action in
            guard let self, let picker = action.sender as? UIDatePicker else { return }
            let parts = Calendar.current.dateComponents([.hour, .minute], from: picker.date)
            self.guardRule = ScheduleRule(kind: .daily, hour: parts.hour ?? 3, minute: parts.minute ?? 0)
        }, for: .valueChanged)
        let title = Localized.text("Check every night")
        picker.accessibilityLabel = title
        let toggle = UISwitch()
        toggle.accessibilityLabel = title
        toggle.isOn = guardRule != nil
        toggle.addAction(UIAction { [weak self] action in
            guard let self, let toggle = action.sender as? UISwitch else { return }
            self.guardRule = toggle.isOn ? ScheduleRule(kind: .daily, hour: 3, minute: 0) : nil
            self.render()
        }, for: .valueChanged)
        let rowView = MachineRowView(
            title: title,
            detail: guardRule == nil ? ExpertWords.guardsOnDemand : Localized.text("Quiet while everything passes"))
        rowView.trail(picker)
        rowView.trail(toggle)
        return rowView
    }

    private func deleteSection() {
        let card = MachineCardView()
        let rowView = MachineRowView(title: ExpertWords.delete, detail: ExpertWords.deleteDetail) { [weak self] in
            self?.confirmDelete()
        }
        rowView.titleLabel.textColor = Theme.Color.danger
        card.add(rowView)
        column.addArrangedSubview(card)
    }

    // MARK: Bench and guards

    private func editBench(at index: Int?) {
        let item = index.map { bench[$0] } ?? ExpertBenchItem(name: "", kind: .appleDevice)
        let editor = ExpertBenchEditorViewController(item: item, canDelete: index != nil) { [weak self] result in
            guard let self else { return }
            switch (result, index) {
            case (.some(let saved), .some(let index)): self.bench[index] = saved
            case (.some(let saved), .none): self.bench.append(saved)
            case (.none, .some(let index)): self.bench.remove(at: index)
            case (.none, .none): break
            }
            self.render()
        }
        navigationController?.pushViewController(editor, animated: true)
    }

    private func editGuard(at index: Int?) {
        let item = index.map { guards[$0] } ?? ExpertGuard(name: "", command: "")
        let editor = ExpertGuardEditorViewController(item: item, canDelete: index != nil) { [weak self] result in
            guard let self else { return }
            switch (result, index) {
            case (.some(let saved), .some(let index)): self.guards[index] = saved
            case (.some(let saved), .none): self.guards.append(saved)
            case (.none, .some(let index)): self.guards.remove(at: index)
            case (.none, .none): break
            }
            self.render()
        }
        navigationController?.pushViewController(editor, animated: true)
    }

    // MARK: Saving

    private func save() {
        guard !saving, let backend = ExpertDesk.shared.experts(forProfileID: profileID) else { return }
        view.endEditing(true)
        saving = true
        navigationItem.rightBarButtonItem?.isEnabled = false
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profileID = profileID
        switch mode {
        case .create:
            var draft = ExpertDraft(
                name: trimmedName, glyph: glyph.isEmpty ? nil : glyph, hue: hue.rawValue, purpose: purpose,
                directory: directory.isEmpty ? nil : directory, model: model, effort: effort, charter: charter,
                skills: skills, notebookPath: notebookPath?.isEmpty == false ? notebookPath : nil,
                bench: bench.map(\.described), guards: guards.map(\.described), guardRule: guardRule,
                timeZone: TimeZone.current.identifier, notes: draftNotes)
            draft = ExpertMaking.finalized(draft, keeping: ticks)
            let finalDraft = draft
            Task { [weak self] in
                do {
                    let made = try await backend.createExpert(finalDraft)
                    MidgarLog.info("expert created id=\(made.id) profile=\(profileID)", category: .session)
                    ExpertDesk.shared.adopt(made, profileID: profileID)
                    ExpertDesk.shared.refresh(force: true)
                    guard let self else { return }
                    let presenter = self.navigationController?.presentingViewController
                    self.dismiss(animated: true) {
                        guard let presenter, let row = ExpertDesk.shared.row(profileID: profileID, expertID: made.id)
                        else { return }
                        ExpertRouter.open(row, from: Self.topmost(presenter))
                    }
                } catch {
                    guard let self else { return }
                    self.saving = false
                    self.navigationItem.rightBarButtonItem?.isEnabled = true
                    ExpertRouter.report(error, title: ExpertWords.newExpert, from: self)
                }
            }
        case .edit(let row):
            let change = ExpertChange(
                name: trimmedName, glyph: glyph, hue: hue.rawValue, purpose: purpose, directory: directory,
                model: model ?? "", effort: effort ?? "", charter: charter, skills: skills,
                notebookPath: notebookPath ?? "", bench: bench, guards: guards, guardRule: guardRule,
                guardsOnDemand: guardRule == nil ? true : nil)
            Task { [weak self] in
                do {
                    let changed = try await backend.updateExpert(row.expert.id, change)
                    ExpertDesk.shared.adopt(changed, profileID: profileID)
                    self?.dismiss(animated: true)
                } catch {
                    guard let self else { return }
                    self.saving = false
                    self.navigationItem.rightBarButtonItem?.isEnabled = true
                    ExpertRouter.report(error, title: ExpertWords.save, from: self)
                }
            }
        }
    }

    private static func topmost(_ controller: UIViewController) -> UIViewController {
        if let nav = controller as? UINavigationController, let top = nav.topViewController { return top }
        if controller is UISplitViewController, let home = MachineRouter.home { return home }
        return controller
    }

    private func confirmDelete() {
        guard case .edit(let row) = mode, let backend = ExpertDesk.shared.experts(forProfileID: profileID) else { return }
        let alert = UIAlertController(title: ExpertWords.delete, message: ExpertWords.deleteDetail, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: ExpertWords.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: ExpertWords.delete, style: .destructive) { [weak self] _ in
            let profileID = row.profileID
            Task { [weak self] in
                do {
                    try await backend.deleteExpert(row.expert.id)
                    ExpertDesk.shared.forget(profileID: profileID, expertID: row.expert.id)
                    self?.dismiss(animated: true)
                } catch {
                    guard let self else { return }
                    ExpertRouter.report(error, title: ExpertWords.delete, from: self)
                }
            }
        })
        present(alert, animated: true)
    }
}

/// One device or service on an expert's bench.
@MainActor
final class ExpertBenchEditorViewController: UIViewController {
    private var item: ExpertBenchItem
    private let canDelete: Bool
    private let done: (ExpertBenchItem?) -> Void
    private var scroll: UIScrollView!
    private var column: UIStackView!

    init(item: ExpertBenchItem, canDelete: Bool, done: @escaping (ExpertBenchItem?) -> Void) {
        self.item = item
        self.canDelete = canDelete
        self.done = done
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = item.name.isEmpty ? ExpertWords.addBenchItem : item.name
        (scroll, column) = MachinePage.install(in: self)
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: ExpertWords.save, image: nil,
            primaryAction: UIAction { [weak self] _ in self?.finish() }, menu: nil)
        render()
    }

    private var canSave: Bool { !item.name.trimmingCharacters(in: .whitespaces).isEmpty }

    private func syncSave() {
        navigationItem.rightBarButtonItem?.isEnabled = canSave
    }

    private func render() {
        MachinePage.clear(column)
        syncSave()
        let kinds: [ExpertBenchItem.Kind] = [.appleDevice, .command, .port]
        let kind = UISegmentedControl(items: [Localized.text("Device"), Localized.text("Probe"), Localized.text("Port")])
        kind.selectedSegmentIndex = kinds.firstIndex(of: item.kind) ?? 0
        kind.addAction(UIAction { [weak self] action in
            guard let self, let control = action.sender as? UISegmentedControl else { return }
            self.item.kind = kinds[control.selectedSegmentIndex]
            self.render()
        }, for: .valueChanged)
        var parts: [UIView] = [kind, field(Localized.text("Name"), item.name, "iPad Pro M1") { [weak self] in self?.item.name = $0 }]
        switch item.kind {
        case .appleDevice:
            parts.append(field(Localized.text("UDID, device identifier or name"), item.identifier ?? "", "00008103-…") {
                [weak self] in self?.item.identifier = $0.isEmpty ? nil : $0
            })
        case .command:
            parts.append(field(Localized.text("Command that exits 0 when it is there"), item.command ?? "", "pg_isready") {
                [weak self] in self?.item.command = $0
            })
        case .port:
            parts.append(field(Localized.text("Host"), item.host ?? "", "127.0.0.1") { [weak self] in
                self?.item.host = $0.isEmpty ? nil : $0
            })
            let port = field(Localized.text("Port"), item.port.map(String.init) ?? "", "8443") { [weak self] in
                self?.item.port = Int($0)
            }
            port.textField.keyboardType = .numberPad
            parts.append(port)
        }
        parts.append(field(Localized.text("Lock file (optional)"), item.lock ?? "", "/tmp/ipad.lock") { [weak self] in
            self?.item.lock = $0.isEmpty ? nil : $0
        })
        let stack = UIStackView(arrangedSubviews: parts)
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.m
        let card = MachineCardView()
        let holder = UIView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: holder.topAnchor, constant: Theme.Spacing.m),
            stack.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -Theme.Spacing.m),
            stack.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: Theme.Spacing.m),
            stack.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -Theme.Spacing.m),
        ])
        card.add(holder)
        column.addArrangedSubview(card)
        column.addArrangedSubview(
            MachinePage.footnote(Localized.text("The machine proves it whenever the expert's page opens and when a task starts. A task holds the lock around anything it installs or runs there, so two tasks never share a device.")))
        if canDelete {
            column.addArrangedSubview(MachinePage.pill(Localized.text("Remove")) { [weak self] in
                self?.done(nil)
                self?.navigationController?.popViewController(animated: true)
            })
        }
    }

    private func field(_ title: String, _ text: String, _ placeholder: String, onChange: @escaping (String) -> Void) -> FormField {
        let field = FormField(title: title, placeholder: placeholder)
        field.textField.text = text
        field.textField.addAction(UIAction { [weak self] action in
            onChange((action.sender as? UITextField)?.text ?? "")
            self?.syncSave()
        }, for: .editingChanged)
        return field
    }

    private func finish() {
        guard !item.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        done(item)
        navigationController?.popViewController(animated: true)
    }
}

/// One guard: the command that has to keep passing, and — for a measured one — the number it
/// reads and its line.
@MainActor
final class ExpertGuardEditorViewController: UIViewController {
    private var item: ExpertGuard
    private let canDelete: Bool
    private let done: (ExpertGuard?) -> Void
    private var scroll: UIScrollView!
    private var column: UIStackView!

    init(item: ExpertGuard, canDelete: Bool, done: @escaping (ExpertGuard?) -> Void) {
        self.item = item
        self.canDelete = canDelete
        self.done = done
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = item.name.isEmpty ? ExpertWords.addGuard : item.name
        (scroll, column) = MachinePage.install(in: self)
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: ExpertWords.save, image: nil,
            primaryAction: UIAction { [weak self] _ in self?.finish() }, menu: nil)
        render()
    }

    private var canSave: Bool { !item.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !item.command.trimmingCharacters(in: .whitespaces).isEmpty }

    private func syncSave() {
        navigationItem.rightBarButtonItem?.isEnabled = canSave
    }

    private func render() {
        MachinePage.clear(column)
        syncSave()
        var parts: [UIView] = [
            field(Localized.text("Name"), item.name, "PadLayoutTests") { [weak self] in self?.item.name = $0 },
            field(Localized.text("Command"), item.command, "xcodebuild test …") { [weak self] in self?.item.command = $0 },
            field(ExpertWords.folder, item.directory ?? "", Localized.text("The expert's folder")) { [weak self] in
                self?.item.directory = $0.isEmpty ? nil : $0
            },
            field(Localized.text("Minutes it may run"), item.timeout.map { String($0 / 60) } ?? "", "30") { [weak self] in
                self?.item.timeout = Int($0).map { $0 * 60 }
            },
        ]
        let measures = UISwitch()
        measures.accessibilityLabel = Localized.text("Measures a number")
        measures.isOn = item.metric != nil
        measures.addAction(UIAction { [weak self] action in
            guard let self, let toggle = action.sender as? UISwitch else { return }
            self.item.metric = toggle.isOn ? ExpertGuardMetric(pattern: "([0-9.]+) ms", atMost: 100, unit: "ms") : nil
            self.render()
        }, for: .valueChanged)
        let measureRow = MachineRowView(
            title: Localized.text("Measures a number"),
            detail: Localized.text("The last match of the pattern's first group, held under or over a line."))
        measureRow.trail(measures)
        parts.append(measureRow)
        if let metric = item.metric {
            parts.append(field(Localized.text("Pattern"), metric.pattern, "first frame ([0-9.]+) ms") { [weak self] in
                self?.item.metric?.pattern = $0
            })
            parts.append(field(Localized.text("At most"), metric.atMost.map { $0.formatted() } ?? "", "100") { [weak self] in
                self?.item.metric?.atMost = Double($0.replacingOccurrences(of: ",", with: "."))
            })
            parts.append(field(Localized.text("At least"), metric.atLeast.map { $0.formatted() } ?? "", "") { [weak self] in
                self?.item.metric?.atLeast = Double($0.replacingOccurrences(of: ",", with: "."))
            })
            parts.append(field(Localized.text("Unit"), metric.unit ?? "", "ms") { [weak self] in
                self?.item.metric?.unit = $0.isEmpty ? nil : $0
            })
        }
        let stack = UIStackView(arrangedSubviews: parts)
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.m
        let holder = UIView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: holder.topAnchor, constant: Theme.Spacing.m),
            stack.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -Theme.Spacing.m),
            stack.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: Theme.Spacing.m),
            stack.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -Theme.Spacing.m),
        ])
        let card = MachineCardView()
        card.add(holder)
        column.addArrangedSubview(card)
        if canDelete {
            column.addArrangedSubview(MachinePage.pill(Localized.text("Remove")) { [weak self] in
                self?.done(nil)
                self?.navigationController?.popViewController(animated: true)
            })
        }
    }

    private func field(_ title: String, _ text: String, _ placeholder: String, onChange: @escaping (String) -> Void) -> FormField {
        let field = FormField(title: title, placeholder: placeholder)
        field.textField.text = text
        field.textField.addAction(UIAction { [weak self] action in
            onChange((action.sender as? UITextField)?.text ?? "")
            self?.syncSave()
        }, for: .editingChanged)
        return field
    }

    private func finish() {
        guard !item.name.trimmingCharacters(in: .whitespaces).isEmpty,
            !item.command.trimmingCharacters(in: .whitespaces).isEmpty
        else { return }
        done(item)
        navigationController?.popViewController(animated: true)
    }
}
