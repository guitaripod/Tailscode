import CodingAgentKit
import MidgarCore
import TailscodeCore
import UIKit

/// A master's guards: how many pass, each one's last run, and — for a failing one — its output
/// and the press that hands the failure to the master as a task.
@MainActor
final class MasterGuardsViewController: UIViewController {
    private var row: MasterRow
    private var scroll: UIScrollView!
    private var column: UIStackView!
    private let refresher = UIRefreshControl()
    private var isWatching = false

    init(row: MasterRow) {
        self.row = row
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var master: MachineExpert { row.master }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = MasterWords.guards
        (scroll, column) = MachinePage.install(in: self)
        refresher.addAction(UIAction { [weak self] _ in self?.pulled() }, for: .valueChanged)
        scroll.refreshControl = refresher
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: MasterWords.checkNow, image: nil,
            primaryAction: UIAction { [weak self] _ in self?.checkNow(only: nil) }, menu: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(deskChanged), name: MasterDesk.didChange, object: nil)
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !isWatching else { return }
        isWatching = true
        MasterDesk.shared.watch()
    }

    /// A pull reads every machine again and lets go of the spinner when the read ends, changed or not.
    private func pulled() {
        let read = MasterDesk.shared.refresh(force: true)
        Task { [weak self] in
            await read?.value
            self?.refresher.endRefreshing()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isWatching else { return }
        isWatching = false
        MasterDesk.shared.unwatch()
    }

    @objc private func deskChanged() {
        refresher.endRefreshing()
        guard let fresh = MasterDesk.shared.row(profileID: row.profileID, expertID: master.id), fresh != row else {
            return
        }
        row = fresh
        render()
    }

    private func render() {
        MachinePage.clear(column)
        navigationItem.rightBarButtonItem?.isEnabled = !master.guards.isEmpty && !master.runningGuards
        let summary = MasterReading.guardsLine(master)
        let status = MachineCardView()
        let lead = MachineRowView(
            title: summary.text, detail: MasterReading.guardRule(master),
            image: summary.tone == .quiet ? nil : MasterStyle.lamp(summary.tone, side: 12))
        lead.titleLabel.font = Theme.Ramp.font(.cardTitle)
        lead.leading.contentMode = .center
        lead.isAccessibilityElement = true
        lead.accessibilityLabel = "\(summary.text). \(MasterReading.guardRule(master))"
        status.add(lead)
        column.addArrangedSubview(status)
        guard !master.guards.isEmpty else {
            column.addArrangedSubview(MachinePage.footnote(MasterWords.noGuards))
            column.addArrangedSubview(
                MachinePage.pill(MasterWords.addGuard) { [weak self] in
                    guard let self else { return }
                    MasterEditorViewController.presentEdit(row: self.row, from: self)
                })
            return
        }
        let card = MachineCardView()
        for item in master.guards {
            card.add(guardRow(item))
        }
        column.addArrangedSubview(card)
        if let failing = master.failingGuards.first {
            let hand = MachineCardView()
            let press = MachineRowView(
                title: MasterWords.handFailure(master.name),
                detail: MasterWords.handFailureDetail,
                image: MasterStyle.mark(row), action: { [weak self] in self?.handFailure(failing) })
            press.titleLabel.textColor = Theme.Color.accent
            press.chevron()
            press.isAccessibilityElement = true
            press.accessibilityLabel = MasterWords.handFailure(master.name)
            hand.add(press)
            column.addArrangedSubview(hand)
        }
        column.addArrangedSubview(
            MachinePage.footnote(Localized.text("A guard that starts failing is the first thing the master’s next task is told.")))
    }

    private func guardRow(_ item: ExpertGuard) -> UIView {
        let reading = MasterReading.guardRow(item)
        let tone: MasterTone = item.running == true ? .active : item.last.map { $0.passed ? .good : .failing } ?? .quiet
        weak var pressed: MachineRowView?
        let rowView = MachineRowView(
            title: reading.title, detail: reading.detail.text, image: MasterStyle.lamp(tone),
            detailColor: reading.detail.tone == .failing ? Theme.Color.danger : Theme.Color.secondaryLabel
        ) { [weak self] in self?.guardMenu(item, from: pressed) }
        pressed = rowView
        rowView.leading.contentMode = .center
        if let trailing = reading.trailing {
            let label = UILabel()
            label.text = trailing
            label.font = Theme.Ramp.font(.rowMeta)
            label.textColor = Theme.Color.secondaryLabel
            rowView.trail(label)
        }
        if item.isFailing, let output = item.last?.output, !output.isEmpty {
            rowView.attach(Self.console(CommandText.tail(output, lines: 8)))
        }
        rowView.isAccessibilityElement = true
        rowView.accessibilityLabel = reading.accessibilityLabel
        return rowView
    }

    /// The end of a failing guard's output, on a plate of its own with room around the words.
    private static func console(_ text: String) -> UIView {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.font = Theme.Ramp.font(.toolOutput)
        label.textColor = Theme.Color.secondaryLabel
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        let plate = UIView()
        plate.backgroundColor = Theme.Color.codeBackground
        plate.layer.cornerRadius = 8
        plate.layer.cornerCurve = .continuous
        plate.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: plate.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: plate.bottomAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: plate.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: plate.trailingAnchor, constant: -10),
        ])
        plate.isAccessibilityElement = true
        plate.accessibilityLabel = text
        return plate
    }

    private func guardMenu(_ item: ExpertGuard, from source: UIView?) {
        let sheet = UIAlertController(title: item.name, message: item.command, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: MasterWords.checkNow, style: .default) { [weak self] _ in
            self?.checkNow(only: item.id)
        })
        if item.isFailing {
            sheet.addAction(
                UIAlertAction(title: MasterWords.handFailure(master.name), style: .default) {
                    [weak self] _ in self?.handFailure(item)
                })
        }
        sheet.addAction(UIAlertAction(title: MasterWords.cancel, style: .cancel))
        let anchor = source ?? view
        sheet.popoverPresentationController?.sourceView = anchor
        sheet.popoverPresentationController?.sourceRect = anchor?.bounds ?? .zero
        present(sheet, animated: true)
    }

    private func checkNow(only: String?) {
        guard let backend = MasterDesk.shared.masters(forProfileID: row.profileID) else { return }
        Theme.Haptics.tap()
        let id = master.id
        let profileID = row.profileID
        Task { [weak self] in
            do {
                let fresh = try await backend.runExpertGuards(id, guardID: only)
                MasterDesk.shared.adopt(fresh, profileID: profileID)
            } catch {
                guard let self else { return }
                MasterRouter.report(error, title: MasterWords.checkNow, from: self)
            }
        }
    }

    private func handFailure(_ item: ExpertGuard) {
        MasterRouter.newTask(row, text: MasterMaking.failureTask(item, machine: row.machine), from: self)
    }
}

/// The last lines of a command's output.
enum CommandText {
    static func tail(_ text: String, lines: Int) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A master's notebook: every note, newest first, searchable, with the retired ones folded at the
/// foot with their reasons.
@MainActor
final class MasterNotebookViewController: UIViewController, UISearchResultsUpdating {
    private let row: MasterRow
    private var scroll: UIScrollView!
    private var column: UIStackView!
    private var notes: [ExpertNote] = []
    private var retired: [ExpertNote] = []
    private var showsRetired = false
    private var query = ""
    private var loaded = false
    private var failed = false
    private var counted: ExpertNotebookFacts
    private let refresher = UIRefreshControl()
    private let search = UISearchController(searchResultsController: nil)

    init(row: MasterRow) {
        self.row = row
        self.counted = row.master.notebook
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = MasterWords.notebook
        (scroll, column) = MachinePage.install(in: self)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = Localized.text("Search %d notes", row.master.notebook.notes)
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        refresher.addAction(UIAction { [weak self] _ in self?.load() }, for: .valueChanged)
        scroll.refreshControl = refresher
        NotificationCenter.default.addObserver(
            self, selector: #selector(deskChanged), name: MasterDesk.didChange, object: nil)
        render()
        load()
    }

    /// A note accepted in a debrief, or written in a terminal, changes what the machine counts:
    /// the list is read again then, so it never shows a notebook older than the shelf's.
    @objc private func deskChanged() {
        guard let fresh = MasterDesk.shared.row(profileID: row.profileID, expertID: row.master.id)?.master.notebook,
            fresh != counted
        else { return }
        counted = fresh
        load()
    }

    func updateSearchResults(for searchController: UISearchController) {
        query = searchController.searchBar.text ?? ""
        render()
    }

    private func load() {
        guard let backend = MasterDesk.shared.masters(forProfileID: row.profileID) else { return }
        let id = row.master.id
        failed = false
        Task { [weak self] in
            async let live = backend.expertNotes(id, retired: false)
            async let gone = backend.expertNotes(id, retired: true)
            do {
                let notes = try await live
                let retired = try await gone
                guard let self else { return }
                self.notes = notes
                self.retired = retired
                self.loaded = true
                self.refresher.endRefreshing()
                self.search.searchBar.placeholder = Localized.text("Search %d notes", notes.count)
                self.render()
            } catch {
                MidgarLog.info("master notebook read failed master=\(id): \(error)", category: .session)
                guard let self else { return }
                self.refresher.endRefreshing()
                self.failed = true
                self.render()
            }
        }
    }

    private func matches(_ note: ExpertNote) -> Bool {
        let wanted = query.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return true }
        return note.title.localizedCaseInsensitiveContains(wanted) || note.summary.localizedCaseInsensitiveContains(wanted)
    }

    private func render() {
        MachinePage.clear(column)
        if failed, !loaded {
            column.addArrangedSubview(MachinePage.footnote(Localized.text("The notebook could not be read.")))
            column.addArrangedSubview(MachinePage.pill(MasterWords.tryAgain) { [weak self] in
                guard let self else { return }
                self.failed = false
                self.render()
                self.load()
            })
            return
        }
        guard loaded else {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            column.addArrangedSubview(spinner)
            return
        }
        let titles = Dictionary(row.master.tasks.map { ($0.sessionID, $0.title) }) { first, _ in first }
        let shown = notes.filter(matches)
        if shown.isEmpty {
            column.addArrangedSubview(MachinePage.footnote(notes.isEmpty ? MasterWords.noNotes : Localized.text("No notes match.")))
        } else {
            let card = MachineCardView()
            for note in shown {
                card.add(Self.row(note, taskTitles: titles) { [weak self] in self?.open(note) })
            }
            column.addArrangedSubview(card)
        }
        let gone = retired.filter(matches)
        guard !gone.isEmpty else { return }
        let toggle = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.title = "\(MasterWords.retired.uppercased(with: .current)) · \(gone.count)"
        config.image = UIImage(
            systemName: showsRetired ? "chevron.down" : "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        config.imagePlacement = .trailing
        config.imagePadding = 6
        config.baseForegroundColor = Theme.Color.secondaryLabel
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 0, trailing: 4)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var updated = attributes
            updated.font = Theme.Ramp.font(.sectionLabel)
            return updated
        }
        toggle.configuration = config
        toggle.contentHorizontalAlignment = .leading
        toggle.accessibilityValue = showsRetired ? Localized.text("Open") : Localized.text("Folded")
        toggle.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            Theme.Haptics.selection()
            self.showsRetired.toggle()
            self.render()
        }, for: .touchUpInside)
        column.addArrangedSubview(toggle)
        guard showsRetired else { return }
        let card = MachineCardView()
        for note in gone {
            let view = Self.row(note, taskTitles: titles) { [weak self] in self?.open(note) }
            view.titleLabel.attributedText = NSAttributedString(
                string: note.title,
                attributes: [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: Theme.Color.secondaryLabel,
                    .font: Theme.Ramp.font(.rowTitle),
                ])
            card.add(view)
        }
        column.addArrangedSubview(card)
    }

    private func open(_ note: ExpertNote) {
        navigationController?.pushViewController(MasterNoteViewController(row: row, note: note), animated: true)
    }

    static func row(_ note: ExpertNote, taskTitles: [String: String], action: @escaping () -> Void) -> MachineRowView {
        let reading = MasterReading.noteRow(note, taskTitles: taskTitles)
        let view = MachineRowView(title: reading.title, detail: reading.detail.text, action: action)
        view.detailLabel.numberOfLines = 3
        let trailing = (reading.trailing ?? "").split(separator: "\n").map(String.init)
        if trailing.count > 1 {
            let source = UILabel()
            source.text = trailing.dropFirst().joined(separator: " · ")
            source.font = Theme.Ramp.font(.rowStamp)
            source.textColor = Theme.Color.tertiaryLabel
            source.adjustsFontForContentSizeCategory = true
            view.attach(source)
        }
        if let tag = reading.tag {
            let label = UILabel()
            label.text = " \(tag.text) "
            label.font = Theme.Ramp.font(.badge)
            label.textColor = MasterStyle.color(tag.tone)
            label.backgroundColor = MasterStyle.color(tag.tone).withAlphaComponent(0.16)
            label.layer.cornerRadius = 5
            label.layer.masksToBounds = true
            label.setContentHuggingPriority(.required, for: .horizontal)
            let line = UIStackView(arrangedSubviews: [label, UIView()])
            line.axis = .horizontal
            view.attach(line)
        }
        if let when = trailing.first {
            let label = UILabel()
            label.text = when
            label.font = Theme.Ramp.font(.rowStamp)
            label.textColor = Theme.Color.tertiaryLabel
            label.adjustsFontForContentSizeCategory = true
            view.trail(label)
            view.trailBesideTitle()
        }
        view.isAccessibilityElement = true
        view.accessibilityLabel = reading.accessibilityLabel
        return view
    }
}

/// One note: its words, when it was written or confirmed, which task it came from, and — for a
/// retired note — why it was retired.
@MainActor
final class MasterNoteViewController: UIViewController {
    private let row: MasterRow
    private var note: ExpertNote
    private var scroll: UIScrollView!
    private var column: UIStackView!

    init(row: MasterRow, note: ExpertNote) {
        self.row = row
        self.note = note
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = note.title
        navigationItem.largeTitleDisplayMode = .never
        (scroll, column) = MachinePage.install(in: self)
        render()
        guard note.body == nil, let backend = MasterDesk.shared.masters(forProfileID: row.profileID) else { return }
        let id = row.master.id
        let noteID = note.id
        Task { [weak self] in
            guard let full = try? await backend.expertNote(id, note: noteID), let self else { return }
            self.note = full
            self.render()
        }
    }

    private func render() {
        MachinePage.clear(column)
        let title = UILabel()
        title.text = note.title
        title.font = Theme.Ramp.font(.headline)
        title.numberOfLines = 0
        title.textColor = note.retired == nil ? Theme.Color.label : Theme.Color.secondaryLabel
        title.adjustsFontForContentSizeCategory = true
        column.addArrangedSubview(title)
        if !note.summary.isEmpty {
            let summary = UILabel()
            summary.text = note.summary
            summary.font = Theme.Ramp.font(.rowDetail)
            summary.textColor = Theme.Color.secondaryLabel
            summary.numberOfLines = 0
            column.addArrangedSubview(summary)
        }
        let facts = MachineCardView()
        let reading = MasterReading.noteRow(note, taskTitles: Dictionary(row.master.tasks.map { ($0.sessionID, $0.title) }) { first, _ in first })
        if note.retired != nil {
            facts.add(MachineRowView(title: MasterWords.retired, detail: reading.detail.text, detailColor: Theme.Color.secondaryLabel))
        }
        if let touched = note.lastTouched {
            facts.add(
                MachineRowView(
                    title: note.confirmed != nil ? Localized.text("Confirmed") : Localized.text("Written"),
                    detail: MasterReading.day(touched)))
        }
        if let session = note.sourceSession {
            let taskTitle = row.master.tasks.first { $0.sessionID == session }?.title ?? Localized.text("Open the task")
            let source = MachineRowView(title: Localized.text("From the task"), detail: taskTitle) { [weak self] in
                guard let self else { return }
                MasterRouter.openChat(sessionID: session, from: self)
            }
            source.chevron()
            facts.add(source)
        }
        if !facts.isEmpty { column.addArrangedSubview(facts) }
        if let body = note.body, !body.isEmpty {
            let card = MachineCardView()
            let label = UILabel()
            label.attributedText = Self.body(body)
            label.numberOfLines = 0
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
            column.addArrangedSubview(card)
        }
    }

    /// A note's body with its **bold** spans bold, the way the notebook writes "**Why:**".
    static func body(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let regular = Theme.Ramp.font(.cardBody)
        let bold = UIFont(
            descriptor: regular.fontDescriptor.withSymbolicTraits(.traitBold) ?? regular.fontDescriptor, size: 0)
        for (index, piece) in text.components(separatedBy: "**").enumerated() {
            result.append(
                NSAttributedString(
                    string: piece,
                    attributes: [.font: index % 2 == 1 ? bold : regular, .foregroundColor: Theme.Color.label]))
        }
        return result
    }
}

/// Everything a master has done: one entry per finished task, newest first, each opening its task.
@MainActor
final class MasterJournalViewController: UIViewController {
    private let row: MasterRow
    private var scroll: UIScrollView!
    private var column: UIStackView!
    private var entries: [ExpertJournalEntry]

    init(row: MasterRow) {
        self.row = row
        self.entries = row.master.journal
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = MasterWords.journal
        (scroll, column) = MachinePage.install(in: self)
        render()
        guard let backend = MasterDesk.shared.masters(forProfileID: row.profileID) else { return }
        let id = row.master.id
        Task { [weak self] in
            guard let entries = try? await backend.expertJournal(id), let self else { return }
            self.entries = entries
            self.render()
        }
    }

    private func render() {
        MachinePage.clear(column)
        guard !entries.isEmpty else {
            column.addArrangedSubview(MachinePage.footnote(MasterWords.noJournal))
            return
        }
        let card = MachineCardView()
        for entry in entries {
            card.add(Self.row(entry, row: row) { [weak self] in
                guard let self, let session = entry.sessionID else { return }
                MasterRouter.openChat(sessionID: session, from: self)
            })
        }
        column.addArrangedSubview(card)
    }

    /// One entry. The journal's own page says all of it; a preview elsewhere keeps to `lines`.
    static func row(_ entry: ExpertJournalEntry, row: MasterRow, lines: Int = 0, action: @escaping () -> Void)
        -> MachineRowView
    {
        let reading = MasterReading.journalRow(entry)
        let view = MachineRowView(title: reading.title, detail: reading.detail.text, action: entry.sessionID == nil ? nil : action)
        view.detailLabel.numberOfLines = lines
        if !entry.commits.isEmpty {
            let commits = UILabel()
            commits.text = entry.commits.prefix(3).joined(separator: "\n")
            commits.numberOfLines = 0
            commits.font = Theme.Ramp.font(.toolDetail)
            commits.textColor = Theme.Color.tertiaryLabel
            view.attach(commits)
        }
        if let trailing = reading.trailing {
            let label = UILabel()
            label.text = trailing
            label.font = Theme.Ramp.font(.rowStamp)
            label.textColor = Theme.Color.tertiaryLabel
            label.adjustsFontForContentSizeCategory = true
            view.trail(label)
            view.trailBesideTitle()
        }
        view.isAccessibilityElement = true
        view.accessibilityLabel = reading.accessibilityLabel
        return view
    }
}
