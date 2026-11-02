import CodingAgentKit
import CodingAgentKitApple
import MidgarCore
import TailscodeCore
import UIKit

/// One schedule: what it asks, when, the two switches, a run now, pause and delete, and the
/// history that says every run — the quiet ones and the ones the machine slept through included.
@MainActor
final class ScheduleDetailViewController: UIViewController {
    private var row: ScheduleRow
    private var column: UIStackView!
    private var scroll: UIScrollView!
    private var busy = false

    init(row: ScheduleRow) {
        self.row = row
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var schedule: MachineSchedule { row.schedule }
    private var profile: ConnectionProfile? { MachineDesk.shared.profile(row.profileID) }
    private var scheduling: (any MachineScheduling)? {
        MachineDesk.shared.backend(forProfileID: row.profileID) as? any MachineScheduling
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: Localized.text("Edit"), primaryAction: UIAction { [weak self] _ in self?.edit() })
        (scroll, column) = MachinePage.install(in: self)
        NotificationCenter.default.addObserver(
            self, selector: #selector(deskChanged), name: MachineDesk.didChange, object: nil)
        render()
    }

    @objc private func deskChanged() {
        guard let fresh = MachineDesk.shared.board.rows.first(where: { $0.id == row.id }) else { return }
        row = fresh
        render()
    }

    private func render() {
        title = schedule.title
        MachinePage.clear(column)
        let calendar = Self.calendar(schedule)

        let words = MachineCardView()
        let text = UILabel()
        text.text = schedule.text
        text.font = Theme.Ramp.font(.cardBody)
        text.textColor = Theme.Color.label
        text.numberOfLines = 0
        let facts = MachinePage.footnote(factsLine(calendar: calendar))
        let block = UIStackView(arrangedSubviews: [text, facts])
        block.axis = .vertical
        block.spacing = Theme.Spacing.s
        block.isLayoutMarginsRelativeArrangement = true
        block.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Theme.Spacing.m, leading: Theme.Spacing.m, bottom: Theme.Spacing.m, trailing: Theme.Spacing.m)
        words.add(block)
        column.addArrangedSubview(words)

        let runNow = PrimaryButton(title: ScheduleWords.runNow)
        runNow.isEnabled = !busy
        runNow.addAction(UIAction { [weak self] _ in self?.runNow() }, for: .touchUpInside)
        var pauseConfig = UIButton.Configuration.gray()
        pauseConfig.title = schedule.paused ? ScheduleWords.resume : ScheduleWords.pause
        pauseConfig.cornerStyle = .large
        pauseConfig.buttonSize = .large
        pauseConfig.baseForegroundColor = Theme.Color.accent
        let pause = UIButton(configuration: pauseConfig)
        pause.isEnabled = !busy && !schedule.isFinished
        pause.addAction(UIAction { [weak self] _ in self?.togglePause() }, for: .touchUpInside)
        let presses = UIStackView(arrangedSubviews: [runNow, pause])
        presses.distribution = .fillEqually
        presses.spacing = Theme.Spacing.s
        column.addArrangedSubview(presses)

        if schedule.rule.isRepeating {
            let switches = MachineCardView()
            switches.add(
                toggle(
                    ScheduleWords.oneConversation, detail: ScheduleWords.oneConversationDetail,
                    isOn: schedule.thread == .continue
                ) { [weak self] on in self?.change(ScheduleChange(thread: on ? .continue : .fresh)) })
            switches.add(
                toggle(ScheduleWords.quiet, detail: ScheduleWords.quietDetail, isOn: schedule.quiet) {
                    [weak self] on in self?.change(ScheduleChange(quiet: on))
                })
            column.addArrangedSubview(switches)
        }

        if let sessionID = schedule.sessionID {
            let open = MachineCardView()
            let openRow = MachineRowView(
                title: ScheduleWords.openConversation, image: UIImage(systemName: "bubble.left.and.bubble.right")
            ) { [weak self] in
                guard let self else { return }
                MachineRouter.openChat(sessionID: sessionID, from: self)
            }
            openRow.chevron()
            open.add(openRow)
            column.addArrangedSubview(open)
        }

        column.addArrangedSubview(MachinePage.header(ScheduleWords.history))
        let history = MachineCardView()
        if schedule.runs.isEmpty {
            history.add(MachineRowView(title: ScheduleWords.noHistory))
        }
        for run in schedule.runs {
            let reading = ScheduleWords.run(run, machine: row.machine, calendar: calendar)
            let symbol = UIImage(
                systemName: reading.mark.symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))?
                .withTintColor(reading.mark.color, renderingMode: .alwaysOriginal)
            let sessionID = run.sessionID
            let runRow = MachineRowView(
                title: reading.title, detail: reading.detail, image: symbol,
                action: sessionID.map { id in { [weak self] in
                    guard let self else { return }
                    MachineRouter.openChat(sessionID: id, from: self)
                } })
            if sessionID != nil { runRow.chevron() }
            history.add(runRow)
        }
        column.addArrangedSubview(history)

        var delete = UIButton.Configuration.plain()
        delete.title = ScheduleWords.delete
        delete.baseForegroundColor = Theme.Color.danger
        let deleteButton = UIButton(configuration: delete)
        deleteButton.addAction(UIAction { [weak self] _ in self?.confirmDelete() }, for: .touchUpInside)
        column.addArrangedSubview(deleteButton)
    }

    private func factsLine(calendar: Calendar) -> String {
        var facts: [String] = []
        if schedule.isFinished {
            facts.append(ScheduleWords.done)
        } else {
            facts.append(ScheduleWords.when(schedule.rule, calendar: calendar))
        }
        facts.append(row.machine)
        if let model = ScheduleModelWord.word(schedule.model, profileID: row.profileID) { facts.append(model) }
        if schedule.rule.isRepeating {
            if schedule.thread == .continue { facts.append(ScheduleWords.oneConversation.lowercased(with: .current)) }
            if schedule.quiet { facts.append(Localized.text("quiet")) }
        }
        if schedule.paused { facts.append(ScheduleWords.paused) }
        if let next = schedule.next, !schedule.paused {
            facts.append(ScheduleWords.next(next, calendar: calendar))
        }
        return facts.joined(separator: " · ")
    }

    private func toggle(_ title: String, detail: String, isOn: Bool, change: @escaping (Bool) -> Void)
        -> MachineRowView
    {
        let row = MachineRowView(title: title, detail: detail)
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.addAction(UIAction { [weak toggle] _ in change(toggle?.isOn ?? isOn) }, for: .valueChanged)
        row.trail(toggle)
        return row
    }

    private func change(_ change: ScheduleChange) {
        guard let scheduling else { return }
        let id = schedule.id
        Task { [weak self] in
            do {
                let updated = try await scheduling.updateSchedule(id, change)
                self?.adopt(updated)
            } catch {
                self?.say(AgentCardViewController.words(error))
                self?.render()
            }
        }
    }

    private func adopt(_ updated: MachineSchedule) {
        row = ScheduleBoard.make(
            [ScheduleBoard.Source(profileID: row.profileID, machine: row.machine, schedules: [updated])]
        ).rows.first ?? row
        render()
        MachineDesk.shared.refresh(force: true)
    }

    private func runNow() {
        guard let scheduling else { return }
        busy = true
        render()
        Theme.Haptics.tap()
        let id = schedule.id
        Task { [weak self] in
            do {
                let updated = try await scheduling.runSchedule(id)
                guard let self else { return }
                self.busy = false
                self.adopt(updated)
                Theme.Haptics.success()
                self.say(Localized.text("Asked on %@", self.row.machine))
            } catch {
                guard let self else { return }
                self.busy = false
                self.render()
                self.say(AgentCardViewController.words(error))
            }
        }
    }

    private func togglePause() {
        Theme.Haptics.tap()
        change(ScheduleChange(paused: !schedule.paused))
    }

    private func edit() {
        guard let profile, let backend = MachineDesk.shared.backend(for: profile) else { return }
        AskLaterViewController.present(
            from: self,
            context: AskLaterViewController.Context(
                profile: profile, backend: backend, text: schedule.text, selection: nil, effort: nil,
                directory: schedule.directory, sessionID: nil, editing: schedule))
    }

    private func confirmDelete() {
        let alert = UIAlertController(
            title: Localized.text("Delete \u{201C}%@\u{201D}?", schedule.title), message: ScheduleWords.deleteDetail,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Localized.text("Cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: Localized.text("Delete"), style: .destructive) { [weak self] _ in
                guard let self, let scheduling = self.scheduling else { return }
                let id = self.schedule.id
                Task { [weak self] in
                    do {
                        try await scheduling.deleteSchedule(id)
                        Theme.Haptics.warning()
                        MachineDesk.shared.refresh(force: true)
                        self?.navigationController?.popViewController(animated: true)
                    } catch {
                        self?.say(AgentCardViewController.words(error))
                    }
                }
            })
        present(alert, animated: true)
    }

    private func say(_ message: String) {
        ToastView(message: message).flash(in: view, above: view.safeAreaLayoutGuide.bottomAnchor)
    }

    static func calendar(_ schedule: MachineSchedule) -> Calendar {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: schedule.timeZone) ?? .current
        return calendar
    }
}
