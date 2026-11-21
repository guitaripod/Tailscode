import CodingAgentKit
import MidgarCore
import TailscodeCore
import UIKit

/// One master's page: who it is, the bench the machine proves, its guards, notebook and journal,
/// its tasks and watches, and its charter. On a phone a column with New task at its head; on an
/// iPad held sideways two columns with the task composer along the foot, Send under the right
/// thumb.
@MainActor
final class MasterViewController: UIViewController {
    private(set) var row: MasterRow
    private let scroll = UIScrollView()
    private let columns = UIStackView()
    private let leading = UIStackView()
    private let trailing = UIStackView()
    private let composer = MasterComposerBar(surface: Theme.Color.groupedSurface)
    private var composerFloor: NSLayoutConstraint!
    private var composerKeyboard: NSLayoutConstraint!
    private var narrowConstraints: [NSLayoutConstraint] = []
    private var wideConstraints: [NSLayoutConstraint] = []
    private var isWide = false
    private var notes: [ExpertNote] = []
    private var proving = false
    private var laidOutWidth: CGFloat = 0
    private var isWatching = false

    init(row: MasterRow) {
        self.row = row
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var master: MachineExpert { row.master }
    private var backend: (any MachineExperts)? { MasterDesk.shared.masters(forProfileID: row.profileID) }
    private var modelWord: String? { ScheduleModelWord.word(master.model, profileID: row.profileID) }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: MasterWords.edit, image: nil,
            primaryAction: UIAction { [weak self] _ in self?.edit() }, menu: nil)
        configureLayout()
        composer.onSend = { [weak self] words in self?.startTask(words) }
        NotificationCenter.default.addObserver(
            self, selector: #selector(deskChanged), name: MasterDesk.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(machinesChanged), name: MachineDesk.didChange, object: nil)
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !isWatching {
            isWatching = true
            MasterDesk.shared.watch()
        }
        prove()
        loadNotes()
        MidgarLog.info("master page opened master=\(master.id) profile=\(row.profileID)", category: .ui)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isWatching else { return }
        isWatching = false
        MasterDesk.shared.unwatch()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard abs(view.bounds.width - laidOutWidth) > 1 else { return }
        laidOutWidth = view.bounds.width
        let wide = Self.isWide(view.bounds.width, traits: traitCollection)
        if wide != isWide {
            isWide = wide
            render()
        }
    }

    /// Two columns once each column can hold a row of bench without folding it twice: an iPad
    /// held sideways, or upright and given the whole window.
    static func isWide(_ width: CGFloat, traits: UITraitCollection) -> Bool {
        traits.horizontalSizeClass == .regular && width >= 820
    }

    private func configureLayout() {
        scroll.alwaysBounceVertical = true
        scroll.keyboardDismissMode = .interactive
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        columns.axis = .horizontal
        columns.alignment = .top
        columns.spacing = Theme.Spacing.xl
        columns.distribution = .fillEqually
        columns.translatesAutoresizingMaskIntoConstraints = false
        for column in [leading, trailing] {
            column.axis = .vertical
            column.spacing = Theme.Spacing.m
            columns.addArrangedSubview(column)
        }
        scroll.addSubview(columns)
        view.addSubview(composer)
        let guide = view.readableContentGuide
        let safe = view.safeAreaLayoutGuide
        composerFloor = composer.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -Theme.Spacing.m)
        composerKeyboard = composer.bottomAnchor.constraint(
            lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor, constant: -Theme.Spacing.s)
        narrowConstraints = [
            columns.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            columns.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ]
        wideConstraints = [
            columns.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: Theme.Spacing.xl),
            columns.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -Theme.Spacing.xl),
            scroll.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -Theme.Spacing.s),
            composer.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: Theme.Spacing.xl),
            composer.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -Theme.Spacing.xl),
            composerFloor, composerKeyboard,
        ]
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            columns.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Theme.Spacing.m),
            columns.bottomAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Spacing.xl),
        ])
        NSLayoutConstraint.activate(narrowConstraints)
        composer.isHidden = true
    }

    private func applyArrangement() {
        NSLayoutConstraint.deactivate(isWide ? narrowConstraints : wideConstraints)
        NSLayoutConstraint.activate(isWide ? wideConstraints : narrowConstraints)
        composer.isHidden = !isWide
        trailing.isHidden = !isWide
        composer.show(row, modelWord: modelWord)
    }

    // MARK: Rendering

    private func render() {
        title = master.name
        applyArrangement()
        MachinePage.clear(leading)
        MachinePage.clear(trailing)
        leading.addArrangedSubview(hero())
        bench().forEach(leading.addArrangedSubview)
        if isWide {
            leading.addArrangedSubview(guardsAndWatchesCard())
            notebookPreview().forEach(trailing.addArrangedSubview)
            journalPreview().forEach(trailing.addArrangedSubview)
            tasksSection().forEach(trailing.addArrangedSubview)
            charterSection().forEach(trailing.addArrangedSubview)
        } else {
            leading.addArrangedSubview(statusCard())
            tasksSection().forEach(leading.addArrangedSubview)
            watchesSection().forEach(leading.addArrangedSubview)
            charterSection().forEach(leading.addArrangedSubview)
        }
    }

    private func hero() -> UIView {
        let mark = MasterMarkView(side: 58)
        mark.show(row)
        let name = UILabel()
        name.text = master.name
        name.font = Theme.Ramp.font(.headline)
        name.textColor = Theme.Color.label
        name.adjustsFontForContentSizeCategory = true
        name.numberOfLines = 0
        name.accessibilityTraits = .header
        let purpose = UILabel()
        purpose.text = master.purpose
        purpose.font = Theme.Ramp.font(.rowDetail)
        purpose.textColor = Theme.Color.secondaryLabel
        purpose.numberOfLines = 0
        purpose.adjustsFontForContentSizeCategory = true
        purpose.isHidden = master.purpose.isEmpty
        let words = UIStackView(arrangedSubviews: [name, purpose])
        words.axis = .vertical
        words.spacing = 2
        let top = UIStackView(arrangedSubviews: [mark, words])
        top.alignment = .center
        top.spacing = Theme.Spacing.m
        let meta = MasterChipsView()
        meta.show(MasterReading.meta(master, machine: row.machine, modelWord: modelWord).map { MasterLine($0) })
        let stack = UIStackView(arrangedSubviews: [top, meta])
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.m
        if !isWide {
            let newTask = PrimaryButton(title: MasterWords.newTask)
            newTask.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                MasterRouter.newTask(self.row, from: self)
            }, for: .touchUpInside)
            stack.addArrangedSubview(newTask)
        }
        return stack
    }

    /// The bench, when the master has one. While the machine proves it again the header carries a
    /// spinner, so nothing under it moves when the proof lands.
    private func bench() -> [UIView] {
        guard !master.bench.isEmpty else { return [] }
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        spinner.accessibilityLabel = Localized.text("Checking the bench…")
        if proving { spinner.startAnimating() }
        let head = UIStackView(arrangedSubviews: [MachinePage.header(MasterWords.bench), spinner, UIView()])
        head.spacing = Theme.Spacing.s
        head.alignment = .center
        var views: [UIView] = [head]
        let card = MachineCardView()
        for item in master.bench {
            let reading = MasterReading.bench(item, machine: row.machine)
            let rowView = MachineRowView(
                title: reading.title, detail: reading.detail.text, image: MasterStyle.lamp(reading.detail.tone),
                detailColor: [.quiet, .good].contains(reading.detail.tone)
                    ? Theme.Color.secondaryLabel : MasterStyle.color(reading.detail.tone)
            ) { [weak self] in self?.openHolder(item) }
            rowView.leading.contentMode = .center
            rowView.isAccessibilityElement = true
            rowView.accessibilityLabel = reading.accessibilityLabel
            card.add(rowView)
        }
        views.append(card)
        return views
    }

    private func openHolder(_ item: ExpertBenchItem) {
        guard item.state == .held, let session = item.holder?.sessionID else { return }
        MasterRouter.openChat(sessionID: session, from: self)
    }

    private func statusCard() -> UIView {
        let card = MachineCardView()
        card.add(guardsRow())
        card.add(link(MasterWords.notebook, MasterLine(MasterReading.notebookLine(master).text)) { [weak self] in
            self?.openNotebook()
        })
        card.add(link(MasterWords.journal, MasterReading.journalLine(master)) { [weak self] in self?.openJournal() })
        return card
    }

    private func guardsAndWatchesCard() -> UIView {
        let card = MachineCardView()
        card.add(guardsRow())
        for schedule in watches {
            card.add(watchRow(schedule))
        }
        return card
    }

    private func guardsRow() -> MachineRowView {
        link(MasterWords.guards, MasterReading.guardsLine(master)) { [weak self] in self?.openGuards() }
    }

    private func link(_ title: String, _ line: MasterLine, action: @escaping () -> Void) -> MachineRowView {
        let rowView = MachineRowView(
            title: title, detail: line.text,
            detailColor: line.tone == .quiet ? Theme.Color.secondaryLabel : MasterStyle.color(line.tone), action: action)
        rowView.chevron()
        rowView.isAccessibilityElement = true
        rowView.accessibilityLabel = "\(title), \(line.text)"
        return rowView
    }

    private func notebookPreview() -> [UIView] {
        var views: [UIView] = [
            MachinePage.header("\(MasterWords.notebook) · \(MasterWords.notes(master.notebook.notes))")
        ]
        let card = MachineCardView()
        let titles = Dictionary(master.tasks.map { ($0.sessionID, $0.title) }) { first, _ in first }
        for note in notes.prefix(4) {
            card.add(MasterNotebookViewController.row(note, taskTitles: titles) { [weak self] in
                guard let self else { return }
                self.navigationController?.pushViewController(
                    MasterNoteViewController(row: self.row, note: note), animated: true)
            })
        }
        if notes.isEmpty, master.notebook.notes == 0 {
            views.append(MachinePage.footnote(MasterWords.noNotes))
        }
        card.add(link(Localized.text("All notes"), MasterLine(MasterReading.notebookLine(master).text)) { [weak self] in
            self?.openNotebook()
        })
        views.append(card)
        return views
    }

    private func journalPreview() -> [UIView] {
        var views: [UIView] = [MachinePage.header(MasterWords.journal)]
        guard !master.journal.isEmpty else {
            views.append(MachinePage.footnote(MasterWords.noJournal))
            return views
        }
        let card = MachineCardView()
        for entry in master.journal.prefix(3) {
            card.add(MasterJournalViewController.row(entry, row: row, lines: 3) { [weak self] in self?.openEntry(entry) })
        }
        card.add(link(Localized.text("The whole journal"), MasterReading.journalLine(master)) { [weak self] in
            self?.openJournal()
        })
        views.append(card)
        return views
    }

    private func tasksSection() -> [UIView] {
        let tasks = master.tasks.filter { task in !master.journal.contains { $0.sessionID == task.sessionID } || task.active || task.debrief == .open }
        guard !tasks.isEmpty else { return [] }
        let card = MachineCardView()
        for task in tasks.prefix(5) {
            let reading = MasterReading.taskRow(task)
            let rowView = MachineRowView(
                title: reading.title, detail: reading.detail.text,
                detailColor: reading.detail.tone == .quiet ? Theme.Color.secondaryLabel : MasterStyle.color(reading.detail.tone)
            ) { [weak self] in
                guard let self else { return }
                MasterRouter.openChat(sessionID: task.sessionID, from: self)
            }
            rowView.chevron()
            rowView.isAccessibilityElement = true
            rowView.accessibilityLabel = reading.accessibilityLabel
            card.add(rowView)
        }
        return [MachinePage.header(MasterWords.tasks), card]
    }

    private var watches: [ScheduleRow] {
        MachineDesk.shared.board.rows.filter { $0.profileID == row.profileID && master.watches.contains($0.schedule.id) }
    }

    private func watchesSection() -> [UIView] {
        let rows = watches
        guard !rows.isEmpty else { return [] }
        let card = MachineCardView()
        rows.forEach { card.add(watchRow($0)) }
        return [MachinePage.header(MasterWords.watches), card]
    }

    private func watchRow(_ schedule: ScheduleRow) -> UIView {
        let rowView = MachineRowView(
            title: schedule.title, detail: schedule.subtitle,
            image: UIImage(systemName: "clock", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)),
            tint: Theme.Color.accent
        ) { [weak self] in
            self?.navigationController?.pushViewController(ScheduleDetailViewController(row: schedule), animated: true)
        }
        rowView.chevron()
        rowView.isAccessibilityElement = true
        rowView.accessibilityLabel = "\(MasterWords.watches), \(schedule.title), \(schedule.subtitle)"
        return rowView
    }

    private func charterSection() -> [UIView] {
        var views: [UIView] = []
        if !master.charter.isEmpty {
            views.append(MachinePage.header(MasterWords.charter))
            let card = MachineCardView()
            let label = UILabel()
            label.text = master.charter
            label.numberOfLines = 0
            label.font = Theme.Ramp.font(.cardBody)
            label.textColor = Theme.Color.label
            label.adjustsFontForContentSizeCategory = true
            let holder = UIView()
            label.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: holder.topAnchor, constant: Theme.Spacing.m),
                label.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -Theme.Spacing.m),
                label.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: Theme.Spacing.m),
                label.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -Theme.Spacing.m),
            ])
            card.add(holder)
            views.append(card)
        }
        if !master.skills.isEmpty {
            views.append(MachinePage.header(MasterWords.skills))
            let chips = MasterChipsView()
            chips.show(master.skills.map { MasterLine(MasterWords.skill($0)) })
            views.append(chips)
        }
        let card = MachineCardView()
        card.add(link(MasterWords.showBrief, MasterLine(MasterWords.tokens(master.briefTokens))) { [weak self] in
            self?.showBrief()
        })
        views.append(card)
        return views
    }

    // MARK: Actions

    private func prove() {
        guard let backend, !proving else { return }
        proving = true
        let id = master.id
        let profileID = row.profileID
        Task { [weak self] in
            let fresh = try? await backend.machineExpert(id, prove: true)
            guard let self else { return }
            self.proving = false
            if let fresh {
                MasterDesk.shared.adopt(fresh, profileID: profileID)
            } else {
                self.render()
            }
        }
    }

    private func loadNotes() {
        guard let backend else { return }
        let id = master.id
        Task { [weak self] in
            let notes = (try? await backend.expertNotes(id, retired: false)) ?? []
            guard let self else { return }
            self.notes = notes
            if self.isWide { self.render() }
        }
    }

    @objc private func deskChanged() {
        guard let fresh = MasterDesk.shared.row(profileID: row.profileID, expertID: master.id) else {
            if MasterDesk.shared.hasLoaded, !MasterDesk.shared.board.machines.isEmpty,
                MasterDesk.shared.board.machines.contains(where: { $0.profileID == row.profileID })
            {
                navigationController?.popViewController(animated: true)
            }
            return
        }
        guard fresh != row else { return }
        row = fresh
        render()
    }

    @objc private func machinesChanged() {
        render()
    }

    private func edit() {
        MasterEditorViewController.presentEdit(row: row, from: self)
    }

    private func openGuards() {
        navigationController?.pushViewController(MasterGuardsViewController(row: row), animated: true)
    }

    private func openNotebook() {
        navigationController?.pushViewController(MasterNotebookViewController(row: row), animated: true)
    }

    private func openJournal() {
        navigationController?.pushViewController(MasterJournalViewController(row: row), animated: true)
    }

    private func openEntry(_ entry: ExpertJournalEntry) {
        guard let session = entry.sessionID else { return openJournal() }
        MasterRouter.openChat(sessionID: session, from: self)
    }

    private func showBrief() {
        guard let backend else { return }
        let id = master.id
        let viewer = MasterTextViewController(title: MasterWords.briefTitle, text: nil, monospace: true)
        navigationController?.pushViewController(viewer, animated: true)
        Task { [weak viewer] in
            do {
                let brief = try await backend.expertBrief(id)
                viewer?.show(brief.text, footnote: MasterWords.tokens(brief.tokens))
            } catch {
                viewer?.show(MasterRouter.words(error), footnote: nil)
            }
        }
    }

    private func startTask(_ words: String) {
        guard let backend else { return }
        composer.setBusy(true)
        let id = master.id
        Task { [weak self] in
            do {
                let started = try await backend.startExpertTask(id, ExpertTaskRequest(text: words))
                guard let self else { return }
                self.composer.setBusy(false)
                self.composer.text = ""
                self.view.endEditing(true)
                MidgarLog.info("master task started master=\(id) session=\(started.session.id)", category: .session)
                MasterDesk.shared.refresh(force: true)
                MasterRouter.openStarted(started.session, profileID: self.row.profileID, from: self)
            } catch {
                guard let self else { return }
                self.composer.setBusy(false)
                MasterRouter.report(error, title: MasterWords.newTask, from: self)
            }
        }
    }
}

/// Words to read: a note's body, the brief a task starts with.
@MainActor
final class MasterTextViewController: UIViewController {
    private let textView = UITextView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let monospace: Bool
    private var initial: String?

    init(title: String, text: String?, monospace: Bool) {
        self.monospace = monospace
        self.initial = text
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.groupedBackground
        textView.isEditable = false
        textView.backgroundColor = Theme.Color.groupedSurface
        textView.layer.cornerRadius = Theme.Radius.card
        textView.layer.cornerCurve = .continuous
        textView.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        textView.font = monospace ? Theme.Ramp.font(.code) : Theme.Ramp.font(.cardBody)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = Theme.Color.label
        textView.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        view.addSubview(spinner)
        let guide = view.readableContentGuide
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Theme.Spacing.m),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -Theme.Spacing.m),
            textView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        if let initial {
            textView.text = initial
        } else {
            spinner.startAnimating()
        }
    }

    func show(_ text: String, footnote: String?) {
        spinner.stopAnimating()
        textView.text = [text, footnote.map { "\n— \($0)" }].compactMap { $0 }.joined(separator: "\n")
    }
}
