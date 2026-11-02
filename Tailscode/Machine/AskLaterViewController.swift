import CodingAgentKit
import CodingAgentKitApple
import MidgarCore
import TailscodeCore
import UIKit

/// "Ask later": five times said the way people say them, a field that reads the rest, and what
/// was understood always shown as a date before anything is saved. The machine keeps the clock,
/// so the question is asked whether or not this phone is on.
@MainActor
final class AskLaterViewController: UIViewController, UITextViewDelegate {
    struct Context {
        let profile: ConnectionProfile
        let backend: any CodingAgentBackend
        let text: String
        let selection: ModelSelection?
        let effort: String?
        let directory: String?
        /// The conversation a schedule made from a chat keeps running into.
        let sessionID: String?
        /// Set when this sheet edits a schedule rather than making one.
        var editing: MachineSchedule? = nil
    }

    static func present(from presenter: UIViewController, context: Context, phrase: String? = nil) {
        let sheet = AskLaterViewController(context: context)
        if let phrase { sheet.initialPhrase = phrase }
        let nav = UINavigationController(rootViewController: sheet)
        if let presentation = nav.sheetPresentationController {
            presentation.detents = [.large()]
            presentation.prefersGrabberVisible = true
        }
        presenter.present(nav, animated: true)
    }

    private let context: Context
    private var sheet: AskLaterSheet
    private var initialPhrase = ""
    private var column: UIStackView!
    private var scroll: UIScrollView!
    private let textView = UITextView()
    private let phraseField = UITextField()
    private var chipButtons: [AskLaterSheet.Chip: UIButton] = [:]
    private let understoodCard = UIView()
    private let understoodHeadline = UILabel()
    private let understoodDetail = UILabel()
    private let switches = MachineCardView()
    private let threadSwitch = UISwitch()
    private let quietSwitch = UISwitch()
    private let confirm = PrimaryButton(title: ScheduleWords.askLater)
    private let cannotKeepLabel = MachinePage.footnote("")
    private var saving = false

    init(context: Context) {
        self.context = context
        sheet = AskLaterSheet(
            text: context.text, machine: context.profile.name,
            modelWord: context.selection.map {
                ModelBadge.word(for: $0, in: ModelCatalogStore.cached(context.profile.id))
            })
        if let editing = context.editing {
            sheet.oneConversation = editing.thread == .continue
            sheet.quiet = editing.quiet
        }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = context.editing == nil ? ScheduleWords.askLater : Localized.text("Edit schedule")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        (scroll, column) = MachinePage.install(in: self)
        build()
        if !initialPhrase.isEmpty {
            phraseField.text = initialPhrase
            sheet.type(initialPhrase)
        }
        update()
        Task { [weak self] in
            guard let self else { return }
            let keeps = await MachineDesk.keepsSchedules(self.context.backend)
            self.sheet.machineKeepsSchedules = keeps
            self.update()
        }
    }

    private func build() {
        let words = MachineCardView()
        textView.text = context.text
        textView.font = Theme.Ramp.font(.cardBody)
        textView.textColor = Theme.Color.label
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.delegate = self
        textView.textContainerInset = UIEdgeInsets(
            top: Theme.Spacing.m, left: Theme.Spacing.s, bottom: Theme.Spacing.m, right: Theme.Spacing.s)
        textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        words.add(textView)
        column.addArrangedSubview(words)

        let chips = ChipFlowView()
        for chip in AskLaterSheet.Chip.allCases {
            let button = UIButton(configuration: .gray())
            button.addAction(UIAction { [weak self] _ in self?.pick(chip) }, for: .touchUpInside)
            chipButtons[chip] = button
            chips.addSubview(button)
        }
        column.addArrangedSubview(chips)

        phraseField.placeholder = ScheduleWords.sayWhen
        phraseField.font = Theme.Ramp.font(.option)
        phraseField.backgroundColor = Theme.Color.groupedSurface
        phraseField.layer.cornerRadius = Theme.Radius.control
        phraseField.layer.cornerCurve = .continuous
        phraseField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: Theme.Spacing.m, height: 1))
        phraseField.leftViewMode = .always
        phraseField.clearButtonMode = .whileEditing
        phraseField.autocorrectionType = .no
        phraseField.autocapitalizationType = .none
        phraseField.returnKeyType = .done
        phraseField.heightAnchor.constraint(equalToConstant: 46).isActive = true
        phraseField.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                self.sheet.type(self.phraseField.text ?? "")
                self.update()
            }, for: .editingChanged)
        phraseField.addAction(UIAction { [weak self] _ in self?.phraseField.resignFirstResponder() }, for: .editingDidEndOnExit)
        column.addArrangedSubview(phraseField)

        understoodCard.backgroundColor = Theme.Color.accent.withAlphaComponent(0.14)
        understoodCard.layer.cornerRadius = Theme.Radius.control
        understoodCard.layer.cornerCurve = .continuous
        let clock = UIImageView(
            image: UIImage(
                systemName: "clock", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)))
        clock.tintColor = Theme.Color.accent
        clock.setContentHuggingPriority(.required, for: .horizontal)
        understoodHeadline.font = Theme.Ramp.font(.rowTitleStrong)
        understoodHeadline.textColor = Theme.Color.label
        understoodHeadline.numberOfLines = 0
        understoodDetail.font = Theme.Ramp.font(.rowDetail)
        understoodDetail.textColor = Theme.Color.label
        understoodDetail.numberOfLines = 0
        let lines = UIStackView(arrangedSubviews: [understoodHeadline, understoodDetail])
        lines.axis = .vertical
        lines.spacing = 2
        let line = UIStackView(arrangedSubviews: [clock, lines])
        line.spacing = Theme.Spacing.s
        line.alignment = .firstBaseline
        line.translatesAutoresizingMaskIntoConstraints = false
        understoodCard.addSubview(line)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: understoodCard.topAnchor, constant: Theme.Spacing.s + 2),
            line.bottomAnchor.constraint(equalTo: understoodCard.bottomAnchor, constant: -(Theme.Spacing.s + 2)),
            line.leadingAnchor.constraint(equalTo: understoodCard.leadingAnchor, constant: Theme.Spacing.m),
            line.trailingAnchor.constraint(equalTo: understoodCard.trailingAnchor, constant: -Theme.Spacing.m),
        ])
        column.addArrangedSubview(understoodCard)

        threadSwitch.isOn = sheet.oneConversation
        threadSwitch.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                self.sheet.oneConversation = self.threadSwitch.isOn
            }, for: .valueChanged)
        quietSwitch.isOn = sheet.quiet
        quietSwitch.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                self.sheet.quiet = self.quietSwitch.isOn
            }, for: .valueChanged)
        let thread = MachineRowView(title: ScheduleWords.oneConversation, detail: ScheduleWords.oneConversationDetail)
        thread.trail(threadSwitch)
        let quiet = MachineRowView(title: ScheduleWords.quiet, detail: ScheduleWords.quietDetail)
        quiet.trail(quietSwitch)
        switches.add(thread)
        switches.add(quiet)
        column.addArrangedSubview(switches)

        cannotKeepLabel.textColor = Theme.Color.warning
        column.addArrangedSubview(cannotKeepLabel)

        confirm.addAction(UIAction { [weak self] _ in self?.save() }, for: .touchUpInside)
        column.addArrangedSubview(confirm)
        column.addArrangedSubview(MachinePage.footnote(ScheduleWords.reach(context.profile.name)))
    }

    func textViewDidChange(_ textView: UITextView) {
        sheet.text = textView.text
        update()
    }

    private func pick(_ chip: AskLaterSheet.Chip) {
        Theme.Haptics.selection()
        sheet.pick(chip)
        phraseField.text = nil
        phraseField.resignFirstResponder()
        update()
    }

    private func update() {
        for (chip, button) in chipButtons {
            let words = AskLaterSheet.words(chip)
            let selected = sheet.chip == chip
            var config: UIButton.Configuration = selected ? .filled() : .gray()
            config.cornerStyle = .capsule
            config.buttonSize = .medium
            config.baseBackgroundColor = selected ? Theme.Color.accent : nil
            config.baseForegroundColor = selected ? Theme.Color.onAccent : Theme.Color.label
            var title = AttributedString(words.title)
            title.font = Theme.Ramp.font(.option)
            if let time = words.time {
                var small = AttributedString(" " + time)
                small.font = Theme.Ramp.font(.rowMeta)
                small.foregroundColor = selected ? Theme.Color.onAccent.withAlphaComponent(0.75) : Theme.Color.secondaryLabel
                title += small
            }
            config.attributedTitle = title
            button.configuration = config
        }
        let line = sheet.understoodLine()
        understoodCard.isHidden = line == nil
        understoodHeadline.text = line?.headline
        understoodDetail.text = line?.detail
        understoodDetail.isHidden = line?.detail.isEmpty ?? true
        let failed = line?.headline == ScheduleWords.notUnderstood
        understoodCard.backgroundColor =
            (failed ? Theme.Color.warning : Theme.Color.accent).withAlphaComponent(0.14)
        switches.isHidden = !sheet.showsRepeatSwitches()
        cannotKeepLabel.text = sheet.machineKeepsSchedules ? nil : ScheduleWords.cannotKeep(context.profile.name)
        cannotKeepLabel.isHidden = sheet.machineKeepsSchedules
        let understood = sheet.understanding()
        let title = context.editing != nil && understood == nil ? Localized.text("Save") : sheet.confirmTitle()
        confirm.configuration?.title = title
        confirm.isEnabled =
            !saving && sheet.canSave && (understood != nil || context.editing != nil)
    }

    private func save() {
        guard let scheduling = context.backend as? any MachineScheduling else { return }
        saving = true
        update()
        let wire = MachineDesk.wireModel(context.selection, profileID: context.profile.id, backend: context.backend)
        let device = UIDevice.current.name
        let editing = context.editing
        let draft = sheet.draft(
            model: context.selection, wireModel: wire, effort: context.effort, directory: context.directory,
            sessionID: context.sessionID, device: device)
        let understood = sheet.understanding()
        let text = sheet.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let machine = context.profile.name
        let presenter = presentingViewController
        Task { [weak self] in
            do {
                if let editing {
                    var change = ScheduleChange(text: text)
                    if let understood {
                        change.rule = understood.rule
                        change.timeZone = TimeZone.current.identifier
                        change.thread = draft?.thread
                        change.quiet = draft?.quiet
                    }
                    _ = try await scheduling.updateSchedule(editing.id, change)
                } else {
                    guard let draft else { return }
                    _ = try await scheduling.createSchedule(draft)
                }
                MidgarLog.info("scheduled on \(machine)", category: .session)
                Theme.Haptics.success()
                MachineDesk.shared.refresh(force: true)
                self?.dismiss(animated: true) {
                    guard let host = presenter?.view else { return }
                    ToastView(message: Localized.text("Scheduled on %@", machine))
                        .flash(in: host, above: host.safeAreaLayoutGuide.bottomAnchor)
                }
            } catch {
                guard let self else { return }
                self.saving = false
                self.update()
                let alert = UIAlertController(
                    title: Localized.text("Not scheduled"), message: AgentCardViewController.words(error),
                    preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: Localized.text("OK"), style: .default))
                self.present(alert, animated: true)
            }
        }
    }
}

/// Buttons laid out in rows that wrap, as tall as their rows.
final class ChipFlowView: UIView {
    private let gap: CGFloat = 7
    private var measuredHeight: CGFloat = 0

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: max(measuredHeight, 34))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
            let width = min(size.width, bounds.width)
            if x > 0, x + width > bounds.width {
                x = 0
                y += rowHeight + gap
                rowHeight = 0
            }
            view.frame = CGRect(x: x, y: y, width: width, height: size.height)
            x += width + gap
            rowHeight = max(rowHeight, size.height)
        }
        let height = y + rowHeight
        if abs(height - measuredHeight) > 0.5 {
            measuredHeight = height
            invalidateIntrinsicContentSize()
        }
    }
}
