import CodingAgentKit
import TailscodeCore
import UIKit

/// The packet form. Three fields matter and the form says so; the rest are defaults the daemon's
/// own table already knows. What stops a packet from going and what is merely worth saying before
/// it goes are two different lists, and both are `DelegateDraft`'s.
@MainActor
final class DelegateComposerViewController: UIViewController, UITextViewDelegate {
    var onStarted: ((String) -> Void)?

    private let host: String
    private let serverName: String
    private let desk = DelegateGate.desk
    private var draft: DelegateDraft
    private var board: DelegateBoard { desk.board(host: host, serverName: serverName) }

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let classButton = UIButton(configuration: .tinted())
    private let repo = FormField(title: DelegateComposerWords.repoLabel, placeholder: DelegateComposerWords.repoPlaceholder, keyboard: .URL)
    private let goal = UITextView()
    private let paths = UITextView()
    private let verify = FormField(title: DelegateComposerWords.verifyLabel, placeholder: DelegateComposerWords.verifyPlaceholder)
    private let suggestions = UIStackView()
    private let read = FormField(title: DelegateComposerWords.readLabel, placeholder: "README.md")
    private let notes = UITextView()
    private let ladder = TierLadderControl()
    private let modeControl = UISegmentedControl(items: DelegateMode.allCases.map(DelegateWords.mode))
    private let effortControl = UISegmentedControl(items: [DelegateComposerWords.effortDefault] + DelegateEffort.allCases.map(DelegateWords.effort))
    private let cautions = UILabel()
    private let problems = UILabel()
    private let send = PrimaryButton(title: DelegateComposerWords.sendTitle)
    private var sending = false

    init(host: String, serverName: String, draft: DelegateDraft? = nil) {
        self.host = host
        self.serverName = serverName
        let board = DelegateGate.desk.board(host: host, serverName: serverName)
        self.draft = draft ?? DelegateDraft(capabilities: board.capabilities, repo: DelegateComposerViewController.lastRepo(host: host))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = DelegateComposerWords.title
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        build()
        fill()
        render()
    }

    private static func lastRepo(host: String) -> String {
        DelegateGate.desk.board(host: host, serverName: "").runs.first?.repo ?? ""
    }

    private func build() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        view.addSubview(scroll)
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.l
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Theme.Spacing.l),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Spacing.xxl),
        ])

        stack.addArrangedSubview(labelled(DelegateComposerWords.classLabel, classButton))
        classButton.showsMenuAsPrimaryAction = true
        classButton.contentHorizontalAlignment = .leading
        classButton.menu = classMenu()

        stack.addArrangedSubview(repo)
        repo.textField.text = draft.repo
        repo.textField.addAction(UIAction { [weak self] _ in self?.draftChanged() }, for: .editingChanged)

        stack.addArrangedSubview(labelled(DelegateComposerWords.goalLabel, editor(goal, minHeight: 120, placeholder: DelegateComposerWords.goalPlaceholder)))
        stack.addArrangedSubview(labelled(DelegateComposerWords.pathsLabel, editor(paths, minHeight: 72, placeholder: DelegateComposerWords.pathsPlaceholder), help: DelegateComposerWords.pathsHelp))
        paths.font = Theme.Ramp.font(.code)

        stack.addArrangedSubview(verify)
        verify.textField.font = Theme.Ramp.font(.code)
        verify.textField.addAction(UIAction { [weak self] _ in self?.draftChanged() }, for: .editingChanged)
        suggestions.axis = .horizontal
        suggestions.spacing = Theme.Spacing.s
        suggestions.alignment = .leading
        let suggestionScroll = UIScrollView()
        suggestionScroll.showsHorizontalScrollIndicator = false
        suggestionScroll.translatesAutoresizingMaskIntoConstraints = false
        suggestions.translatesAutoresizingMaskIntoConstraints = false
        suggestionScroll.addSubview(suggestions)
        NSLayoutConstraint.activate([
            suggestions.topAnchor.constraint(equalTo: suggestionScroll.contentLayoutGuide.topAnchor),
            suggestions.bottomAnchor.constraint(equalTo: suggestionScroll.contentLayoutGuide.bottomAnchor),
            suggestions.leadingAnchor.constraint(equalTo: suggestionScroll.contentLayoutGuide.leadingAnchor),
            suggestions.trailingAnchor.constraint(equalTo: suggestionScroll.contentLayoutGuide.trailingAnchor),
            suggestions.heightAnchor.constraint(equalTo: suggestionScroll.frameLayoutGuide.heightAnchor),
        ])
        stack.addArrangedSubview(suggestionScroll)
        stack.addArrangedSubview(caption(DelegateComposerWords.verifyHelp))

        stack.addArrangedSubview(read)
        stack.addArrangedSubview(labelled(DelegateComposerWords.notesLabel, editor(notes, minHeight: 60, placeholder: "")))

        ladder.mode = .compose
        ladder.onChange = { [weak self] start, ceiling in
            self?.draft.tier = start
            self?.draft.ceiling = ceiling
            self?.render()
        }
        stack.addArrangedSubview(labelled(DelegateComposerWords.ladderLabel, ladder, help: DelegateComposerWords.ladderHelp))

        modeControl.addAction(UIAction { [weak self] _ in self?.draftChanged() }, for: .valueChanged)
        stack.addArrangedSubview(labelled(DelegateComposerWords.modeLabel, modeControl))
        effortControl.addAction(UIAction { [weak self] _ in self?.draftChanged() }, for: .valueChanged)
        stack.addArrangedSubview(labelled(DelegateComposerWords.effortLabel, effortControl))

        for label in [cautions, problems] {
            label.numberOfLines = 0
            label.font = Theme.Ramp.font(.rowNote)
            stack.addArrangedSubview(label)
        }
        cautions.textColor = Theme.Color.warning
        problems.textColor = Theme.Color.danger

        send.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        stack.addArrangedSubview(send)
    }

    private func fill() {
        goal.text = draft.goal
        paths.text = draft.paths
        verify.textField.text = draft.verify
        read.textField.text = draft.read
        notes.text = draft.notes
        modeControl.selectedSegmentIndex = DelegateMode.allCases.firstIndex(of: draft.mode) ?? 0
        effortControl.selectedSegmentIndex = draft.effort.flatMap { DelegateEffort.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        ladder.rungs = board.tiers.map { tier in
            DelegateRung(tier: tier.tier, label: tier.label, model: tier.activeEntry?.model, state: .pending)
        }
        ladder.set(start: draft.tier, ceiling: draft.ceiling)
    }

    private func labelled(_ title: String, _ control: UIView, help: String? = nil) -> UIView {
        let label = UILabel()
        label.text = title.localizedUppercase
        label.font = Theme.Ramp.font(.panelFootnote)
        label.textColor = Theme.Color.secondaryLabel
        label.accessibilityLabel = title
        var views: [UIView] = [label, control]
        if let help { views.append(caption(help)) }
        let column = UIStackView(arrangedSubviews: views)
        column.axis = .vertical
        column.spacing = Theme.Spacing.xs
        return column
    }

    private func caption(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.font = Theme.Ramp.font(.rowNote)
        label.textColor = Theme.Color.tertiaryLabel
        return label
    }

    private func editor(_ view: UITextView, minHeight: CGFloat, placeholder: String) -> UITextView {
        view.font = Theme.Ramp.font(.answer)
        view.backgroundColor = Theme.Color.groupedSurface
        view.layer.cornerRadius = Theme.Radius.control
        view.layer.cornerCurve = .continuous
        view.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        view.isScrollEnabled = false
        view.delegate = self
        view.autocorrectionType = .no
        view.autocapitalizationType = .sentences
        view.accessibilityHint = placeholder
        view.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight).isActive = true
        return view
    }

    private func classMenu() -> UIMenu {
        let classes = board.classes.isEmpty ? [draft.taskClass] : board.classes
        return UIMenu(children: classes.map { name in
            UIAction(title: name, state: name == draft.taskClass ? .on : .off) { [weak self] _ in
                self?.draft.taskClass = name
                self?.classButton.menu = self?.classMenu()
                self?.render()
            }
        })
    }

    func textViewDidChange(_ textView: UITextView) {
        draftChanged()
    }

    private func draftChanged() {
        draft.goal = goal.text ?? ""
        draft.paths = paths.text ?? ""
        draft.verify = verify.textField.text ?? ""
        draft.read = read.textField.text ?? ""
        draft.notes = notes.text ?? ""
        draft.repo = repo.textField.text ?? ""
        draft.mode = DelegateMode.allCases[safe: modeControl.selectedSegmentIndex] ?? .normal
        draft.effort = effortControl.selectedSegmentIndex == 0 ? nil : DelegateEffort.allCases[safe: effortControl.selectedSegmentIndex - 1]
        render()
    }

    private func render() {
        classButton.configuration?.title = draft.taskClass
        let problems = draft.problems
        self.problems.text = problems.joined(separator: "\n")
        self.problems.isHidden = problems.isEmpty
        let cautions = draft.cautions
        self.cautions.text = cautions.isEmpty ? nil : DelegateComposerWords.cautionsTitle + "\n" + cautions.joined(separator: "\n")
        self.cautions.isHidden = cautions.isEmpty
        send.isEnabled = draft.canSend && !sending
        send.setLoading(sending)
        renderSuggestions()
    }

    private func renderSuggestions() {
        for view in suggestions.arrangedSubviews { view.removeFromSuperview() }
        let current = draft.verify
        for suggestion in DelegateDraft.verifySuggestions(paths: draft.pathList, repo: draft.repo) where suggestion != current {
            var config = UIButton.Configuration.tinted()
            config.title = suggestion
            config.cornerStyle = .capsule
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = Theme.Ramp.font(.chip)
                return attributes
            }
            let chip = UIButton(configuration: config)
            chip.addAction(UIAction { [weak self] _ in
                self?.verify.textField.text = suggestion
                self?.draftChanged()
            }, for: .touchUpInside)
            suggestions.addArrangedSubview(chip)
        }
        suggestions.superview?.isHidden = suggestions.arrangedSubviews.isEmpty
    }

    @objc private func sendTapped() {
        guard draft.canSend, !sending else { return }
        sending = true
        render()
        Theme.Haptics.send()
        let draft = draft
        Task { [weak self] in
            guard let self else { return }
            do {
                let runID = try await self.desk.start(draft, host: self.host)
                AppLogger.ui.info("delegate packet started run \(runID) on \(self.host)")
                self.dismiss(animated: true) { [weak self] in self?.onStarted?(runID) }
            } catch {
                self.sending = false
                self.render()
                Theme.Haptics.error()
                let alert = UIAlertController(
                    title: String(localized: "The packet did not start"),
                    message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .cancel))
                self.present(alert, animated: true)
            }
        }
    }
}
