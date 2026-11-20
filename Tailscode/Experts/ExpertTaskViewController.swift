import CodingAgentKit
import MidgarCore
import TailscodeCore
import UIKit

/// A new task for an expert: always a fresh conversation. Over an empty page the facts the session
/// starts with — its charter, skills, notes, last tasks, bench and guards, and how many tokens the
/// brief holds outside the conversation — and, when a chat is handed over, which chat travels with
/// it as a brief.
@MainActor
final class ExpertTaskViewController: UIViewController {
    private var row: ExpertRow
    private let carry: ConversationBrief?
    private let draft: String?
    private let composer = ExpertComposerBar()
    private let chips = ExpertChipsView()
    private let tokens = UILabel()
    private let content = UIStackView()

    init(row: ExpertRow, carry: ConversationBrief?, draft: String?) {
        self.row = row
        self.carry = carry
        self.draft = draft
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var modelWord: String? { ScheduleModelWord.word(row.expert.model, profileID: row.profileID) }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = ExpertWords.newTask
        view.backgroundColor = Theme.Color.background
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        let mark = ExpertMarkView(side: 58)
        mark.show(row)
        let name = UILabel()
        name.text = ExpertWords.startsWith(row.expert.name)
        name.font = Theme.Ramp.font(.cardTitle)
        name.textColor = Theme.Color.label
        name.textAlignment = .center
        name.numberOfLines = 0
        name.adjustsFontForContentSizeCategory = true
        chips.centered = true
        tokens.font = Theme.Ramp.font(.rowMeta)
        tokens.textColor = Theme.Color.tertiaryLabel
        tokens.textAlignment = .center
        tokens.numberOfLines = 0
        content.axis = .vertical
        content.alignment = .center
        content.spacing = Theme.Spacing.m
        content.addArrangedSubview(mark)
        content.addArrangedSubview(name)
        content.addArrangedSubview(chips)
        content.addArrangedSubview(tokens)
        if let carry {
            let note = UILabel()
            note.text = ExpertWords.handOverNote(carry.source)
            note.font = Theme.Ramp.font(.panelFootnote)
            note.textColor = Theme.Color.label
            note.numberOfLines = 0
            note.textAlignment = .center
            note.adjustsFontForContentSizeCategory = true
            let card = UIView()
            card.backgroundColor = Theme.Color.accent.withAlphaComponent(0.14)
            card.layer.cornerRadius = 12
            card.layer.cornerCurve = .continuous
            note.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(note)
            NSLayoutConstraint.activate([
                note.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
                note.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
                note.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
                note.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            ])
            content.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        chips.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        view.addSubview(content)
        view.addSubview(composer)
        composer.show(row, modelWord: modelWord)
        composer.text = draft ?? ""
        composer.onSend = { [weak self] words in self?.send(words) }
        let guide = view.readableContentGuide
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: Theme.Spacing.m),
            content.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -Theme.Spacing.m),
            content.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -Theme.Spacing.xl),
            content.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: Theme.Spacing.m),
            composer.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -Theme.Spacing.s),
        ])
        render()
        NotificationCenter.default.addObserver(
            self, selector: #selector(deskChanged), name: ExpertDesk.didChange, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        composer.textView.becomeFirstResponder()
    }

    @objc private func deskChanged() {
        guard let fresh = ExpertDesk.shared.row(profileID: row.profileID, expertID: row.expert.id) else { return }
        row = fresh
        render()
    }

    private func render() {
        chips.show(ExpertReading.startsWith(row.expert))
        tokens.text = ExpertWords.tokens(row.expert.briefTokens)
    }

    private func send(_ words: String) {
        guard let backend = ExpertDesk.shared.experts(forProfileID: row.profileID) else { return }
        composer.setBusy(true)
        let text = carry.map { $0.wrapped(with: words) } ?? words
        let id = row.expert.id
        Task { [weak self] in
            do {
                let started = try await backend.startExpertTask(id, ExpertTaskRequest(text: text))
                MidgarLog.info(
                    "expert task started expert=\(id) session=\(started.session.id) carried=\(self?.carry != nil)",
                    category: .session)
                ExpertDesk.shared.refresh(force: true)
                guard let self else { return }
                ExpertRouter.openStarted(started.session, profileID: self.row.profileID, from: self)
            } catch {
                guard let self else { return }
                self.composer.setBusy(false)
                ExpertRouter.report(error, title: ExpertWords.newTask, from: self)
            }
        }
    }
}

/// The skills on a machine, to start an expert from one: picking one asks the machine for a draft
/// and opens it for review.
@MainActor
final class ExpertSkillPickerViewController: UITableViewController {
    private let profileID: String
    private var skills: [ExpertSkill] = []
    private var loading = true
    private var drafting: String?

    static func present(profileID: String, from controller: UIViewController) {
        let picker = ExpertSkillPickerViewController(profileID: profileID)
        let nav = UINavigationController(rootViewController: picker)
        nav.modalPresentationStyle = .formSheet
        controller.present(nav, animated: true)
    }

    init(profileID: String) {
        self.profileID = profileID
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = ExpertWords.makeFromSkill
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "skill")
        guard let backend = ExpertDesk.shared.experts(forProfileID: profileID) else { return }
        Task { [weak self] in
            let skills = (try? await backend.expertSkills()) ?? []
            guard let self else { return }
            self.skills = skills
            self.loading = false
            self.tableView.reloadData()
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        loading ? 1 : max(skills.count, 1)
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        Localized.text("The expert loads the skill first in every task, and its charter is drafted from it.")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "skill", for: indexPath)
        var content = UIListContentConfiguration.subtitleCell()
        cell.accessoryView = nil
        if loading {
            content.text = Localized.text("Reading the machine’s skills…")
            content.textProperties.color = Theme.Color.secondaryLabel
        } else if skills.isEmpty {
            content.text = Localized.text("This machine has no skills.")
            content.textProperties.color = Theme.Color.secondaryLabel
        } else {
            let skill = skills[indexPath.row]
            content.text = skill.name
            content.secondaryText = skill.description
            content.secondaryTextProperties.numberOfLines = 3
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            if drafting == skill.name {
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.startAnimating()
                cell.accessoryView = spinner
            }
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !loading, skills.indices.contains(indexPath.row), drafting == nil,
            let backend = ExpertDesk.shared.experts(forProfileID: profileID)
        else { return }
        let skill = skills[indexPath.row]
        drafting = skill.name
        tableView.reloadRows(at: [indexPath], with: .none)
        Task { [weak self] in
            do {
                let draft = try await backend.draftExpert(session: nil, skill: skill.name)
                guard let self else { return }
                self.drafting = nil
                let editor = ExpertEditorViewController(mode: .create(profileID: self.profileID, draft: draft))
                self.navigationController?.pushViewController(editor, animated: true)
                self.tableView.reloadData()
            } catch {
                guard let self else { return }
                self.drafting = nil
                self.tableView.reloadData()
                ExpertRouter.report(error, title: ExpertWords.draftFailed, from: self)
            }
        }
    }
}
