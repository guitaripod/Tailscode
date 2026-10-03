import CodingAgentKit
import TailscodeCore
import UIKit

/// The packet form. It asks first for what only the person knows — the goal and the repository,
/// picked rather than typed where this machine already knows one — then where the worker may
/// write and whether the patch waits to be read, and folds everything the class already decides
/// into one Plan line that opens. What stops a packet from going and what is merely worth saying
/// before it goes are two different lists, and both are `DelegateDraft`'s.
@MainActor
final class DelegateComposerViewController: UIViewController, UITextViewDelegate {
    var onStarted: ((String) -> Void)?

    private let host: String
    private let serverName: String
    private let desk = DelegateGate.desk
    private var draft: DelegateDraft
    private var board: DelegateBoard { desk.board(host: host, serverName: serverName) }
    private var hadCapabilities: Bool
    private var planTouched = false
    private var choices: [DelegateRepoChoice] = []

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let goal = UITextView()
    private let goalPlaceholder = UILabel()
    private let repo = FormField(title: DelegateComposerWords.repoLabel, placeholder: DelegateComposerWords.repoPlaceholder, keyboard: .URL)
    private let choiceRow = UIStackView()
    private let choiceBlock = UIStackView()
    private let paths = UITextView()
    private let reviewSwitch = UISwitch()
    private let reviewHelp = UILabel()
    private let planHeader = UIControl()
    private let planSummary = UILabel()
    private let planChevron = UIImageView(image: UIImage(systemName: "chevron.right"))
    private let planBody = UIStackView()
    private let classButton = UIButton(configuration: .tinted())
    private let verify = FormField(title: DelegateComposerWords.verifyLabel, placeholder: DelegateComposerWords.verifyPlaceholder)
    private let suggestions = UIStackView()
    private let read = FormField(title: DelegateComposerWords.readLabel, placeholder: "README.md")
    private let notes = UITextView()
    private let ladder = TierLadderControl()
    private let modeControl = UISegmentedControl(items: DelegateMode.allCases.map(DelegateWords.mode))
    private let effortControl = UISegmentedControl(items: [DelegateComposerWords.effortDefault] + DelegateEffort.allCases.map(DelegateWords.effort))
    private let legendLabel = UILabel()
    private let cautions = UILabel()
    private let problems = UILabel()
    private let send = PrimaryButton(title: DelegateComposerWords.sendTitle)
    private var sending = false

    init(host: String, serverName: String, draft: DelegateDraft? = nil) {
        self.host = host
        self.serverName = serverName
        let board = DelegateGate.desk.board(host: host, serverName: serverName)
        let choices = DelegateRepoChoices.make(runs: board.runs, chats: Self.footprints(host: host))
        self.draft = draft ?? DelegateDraft(capabilities: board.capabilities, repo: choices.first?.path ?? "")
        self.choices = choices
        hadCapabilities = board.capabilities != nil
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = DelegateComposerWords.title
        if #available(iOS 26.0, *) { navigationItem.subtitle = serverName }
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        build()
        fill()
        render()
        NotificationCenter.default.addObserver(
            self, selector: #selector(deskChanged), name: DelegateDesk.didChange, object: nil)
        if board.phase == .idle { desk.probe(host: host, serverName: serverName) }
    }

    #if DEBUG
        /// `TAILSCODE_DELEGATE_CLASS=<name>` picks a class the way the menu would,
        /// `TAILSCODE_DELEGATE_PLAN=1` opens the Plan and `TAILSCODE_DELEGATE_SCROLL=1` lands on the
        /// ladder, so a simulator can be photographed with the legend and the rungs' notes in view.
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            let env = ProcessInfo.processInfo.environment
            if let name = env["TAILSCODE_DELEGATE_CLASS"], !name.isEmpty, name != draft.taskClass {
                choose(taskClass: name)
            }
            if env["TAILSCODE_DELEGATE_PLAN"] == "1" || env["TAILSCODE_DELEGATE_SCROLL"] == "1" {
                setPlan(open: true, animated: false)
            }
            if env["TAILSCODE_DELEGATE_SCROLL"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    guard let self else { return }
                    self.view.layoutIfNeeded()
                    let target = self.ladder.convert(self.ladder.bounds, to: self.scroll)
                    let y = max(min(target.minY - 120, self.scroll.contentSize.height - self.scroll.bounds.height + self.scroll.adjustedContentInset.bottom), 0)
                    self.scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                }
            }
        }
    #endif

    /// This machine's chats, as the slice a repository choice and an apply check need.
    private static func footprints(host: String) -> [DelegateChatFootprint] {
        DelegateChatFootprint.from(SessionListCache.load(), host: host)
    }

    /// The dispatcher answered after the form opened — a chat handed its task over before the board
    /// had ever been asked — so the class, the ladder and the review switch are filled now, unless
    /// the person already set them.
    @objc private func deskChanged() {
        let board = board
        let fresh = DelegateRepoChoices.make(runs: board.runs, chats: Self.footprints(host: host))
        if fresh != choices {
            choices = fresh
            if draft.repo.isEmpty, let first = fresh.first {
                draft.repo = first.path
                repo.textField.text = first.path
            }
            renderChoices()
        }
        guard !hadCapabilities, let capabilities = board.capabilities else { return }
        hadCapabilities = true
        if !planTouched {
            let seeded = DelegateDraft(capabilities: capabilities, repo: draft.repo)
            draft.choose(taskClass: seeded.taskClass, capabilities: capabilities)
            verify.textField.text = draft.verify
        }
        classButton.menu = classMenu()
        ladder.rungs = board.composerRungs(taskClass: draft.taskClass)
        ladder.set(start: draft.tier, ceiling: draft.ceiling)
        render()
    }

    private func build() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        view.addSubview(scroll)
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.l + 4
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

        stack.addArrangedSubview(labelled(DelegateComposerWords.goalLabel, editor(goal, minHeight: 140, placeholder: DelegateComposerWords.goalPlaceholder)))
        installPlaceholder()

        let repoBlock = UIStackView(arrangedSubviews: [repo, choiceBlock])
        repoBlock.axis = .vertical
        repoBlock.spacing = Theme.Spacing.s
        stack.addArrangedSubview(repoBlock)
        repo.textField.text = draft.repo
        repo.textField.font = Theme.Ramp.font(.code)
        repo.textField.addAction(UIAction { [weak self] _ in self?.draftChanged() }, for: .editingChanged)
        buildChoices()

        stack.addArrangedSubview(
            labelled(
                DelegateComposerWords.pathsLabel, editor(paths, minHeight: 72, placeholder: DelegateComposerWords.pathsPlaceholder),
                help: DelegateComposerWords.pathsHelp + " " + DelegateComposerWords.pathsOptional))
        paths.font = Theme.Ramp.font(.code)
        paths.autocapitalizationType = .none

        stack.addArrangedSubview(reviewRow())
        stack.addArrangedSubview(planBlock())

        for label in [cautions, problems] {
            label.numberOfLines = 0
            label.font = Theme.Ramp.font(.rowNote)
            label.adjustsFontForContentSizeCategory = true
            stack.addArrangedSubview(label)
        }
        cautions.textColor = Theme.Color.warning
        problems.textColor = Theme.Color.danger
        stack.setCustomSpacing(Theme.Spacing.s, after: cautions)

        send.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        stack.addArrangedSubview(send)
    }

    private func installPlaceholder() {
        goalPlaceholder.text = DelegateComposerWords.goalPlaceholder
        goalPlaceholder.font = Theme.Ramp.font(.answer)
        goalPlaceholder.textColor = Theme.Color.tertiaryLabel
        goalPlaceholder.numberOfLines = 0
        goalPlaceholder.isUserInteractionEnabled = false
        goalPlaceholder.isAccessibilityElement = false
        goalPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        goal.addSubview(goalPlaceholder)
        NSLayoutConstraint.activate([
            goalPlaceholder.topAnchor.constraint(equalTo: goal.topAnchor, constant: 10),
            goalPlaceholder.leadingAnchor.constraint(equalTo: goal.frameLayoutGuide.leadingAnchor, constant: 13),
            goalPlaceholder.trailingAnchor.constraint(equalTo: goal.frameLayoutGuide.trailingAnchor, constant: -13),
        ])
    }

    /// Where this machine's chats work and where its runs went, one tap each; the field stays the
    /// truth, so a path nobody has used yet is still typed.
    private func buildChoices() {
        choiceBlock.axis = .vertical
        choiceBlock.spacing = Theme.Spacing.xs
        choiceRow.axis = .horizontal
        choiceRow.spacing = Theme.Spacing.s
        choiceRow.alignment = .center
        let rowScroll = UIScrollView()
        rowScroll.showsHorizontalScrollIndicator = false
        rowScroll.translatesAutoresizingMaskIntoConstraints = false
        choiceRow.translatesAutoresizingMaskIntoConstraints = false
        rowScroll.addSubview(choiceRow)
        NSLayoutConstraint.activate([
            choiceRow.topAnchor.constraint(equalTo: rowScroll.contentLayoutGuide.topAnchor),
            choiceRow.bottomAnchor.constraint(equalTo: rowScroll.contentLayoutGuide.bottomAnchor),
            choiceRow.leadingAnchor.constraint(equalTo: rowScroll.contentLayoutGuide.leadingAnchor),
            choiceRow.trailingAnchor.constraint(equalTo: rowScroll.contentLayoutGuide.trailingAnchor),
            choiceRow.heightAnchor.constraint(equalTo: rowScroll.frameLayoutGuide.heightAnchor),
        ])
        let label = UILabel()
        label.text = DelegateComposerWords.repoChoicesLabel
        label.font = Theme.Ramp.font(.rowNote)
        label.textColor = Theme.Color.tertiaryLabel
        choiceBlock.addArrangedSubview(label)
        choiceBlock.addArrangedSubview(rowScroll)
        renderChoices()
    }

    private func renderChoices() {
        for view in choiceRow.arrangedSubviews { view.removeFromSuperview() }
        for choice in choices {
            let chip = UIButton(configuration: .tinted())
            chip.accessibilityLabel = choice.name
            chip.accessibilityHint = choice.detail + ", " + choice.path
            chip.addAction(UIAction { [weak self] _ in self?.pick(choice) }, for: .touchUpInside)
            choiceRow.addArrangedSubview(chip)
        }
        choiceBlock.isHidden = choices.isEmpty
        paintChoices()
    }

    private func paintChoices() {
        let current = draft.repo.trimmingCharacters(in: .whitespacesAndNewlines)
        for (chip, choice) in zip(choiceRow.arrangedSubviews.compactMap { $0 as? UIButton }, choices) {
            let picked = choice.path == current || choice.path + "/" == current
            var config: UIButton.Configuration = picked ? .filled() : .tinted()
            config.cornerStyle = .capsule
            config.title = choice.name
            config.baseBackgroundColor = Theme.Color.accent
            config.baseForegroundColor = picked ? Theme.Color.onAccent : Theme.Color.accent
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = Theme.Ramp.font(.chip)
                return attributes
            }
            chip.configuration = config
            chip.accessibilityTraits = picked ? [.button, .selected] : .button
        }
    }

    private func pick(_ choice: DelegateRepoChoice) {
        Theme.Haptics.selection()
        repo.textField.text = choice.path
        draftChanged()
    }

    private func reviewRow() -> UIView {
        let title = UILabel()
        title.text = DelegateComposerWords.reviewLabel
        title.font = Theme.Ramp.font(.rowTitle)
        title.numberOfLines = 0
        title.adjustsFontForContentSizeCategory = true
        reviewHelp.font = Theme.Ramp.font(.rowNote)
        reviewHelp.textColor = Theme.Color.tertiaryLabel
        reviewHelp.numberOfLines = 0
        reviewHelp.adjustsFontForContentSizeCategory = true
        let words = UIStackView(arrangedSubviews: [title, reviewHelp])
        words.axis = .vertical
        words.spacing = 2
        reviewSwitch.onTintColor = Theme.Color.accent
        reviewSwitch.accessibilityLabel = DelegateComposerWords.reviewLabel
        reviewSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            Theme.Haptics.selection()
            self.draft.review = self.reviewSwitch.isOn
            self.render()
        }, for: .valueChanged)
        reviewSwitch.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [words, reviewSwitch])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Spacing.m
        return card(row)
    }

    /// Everything the class already decides, folded to one line that opens.
    private func planBlock() -> UIView {
        let label = UILabel()
        label.text = DelegateComposerWords.planLabel
        label.font = Theme.Ramp.font(.rowTitle)
        label.adjustsFontForContentSizeCategory = true
        planSummary.font = Theme.Ramp.font(.rowMeta)
        planSummary.textColor = Theme.Color.secondaryLabel
        planSummary.numberOfLines = 2
        planSummary.adjustsFontForContentSizeCategory = true
        planChevron.tintColor = Theme.Color.tertiaryLabel
        planChevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        planChevron.setContentHuggingPriority(.required, for: .horizontal)
        let words = UIStackView(arrangedSubviews: [label, planSummary])
        words.axis = .vertical
        words.spacing = 2
        words.isUserInteractionEnabled = false
        planChevron.isUserInteractionEnabled = false
        let headerRow = UIStackView(arrangedSubviews: [words, planChevron])
        headerRow.axis = .horizontal
        headerRow.alignment = .center
        headerRow.spacing = Theme.Spacing.m
        headerRow.isUserInteractionEnabled = false
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        planHeader.addSubview(headerRow)
        NSLayoutConstraint.activate([
            headerRow.topAnchor.constraint(equalTo: planHeader.topAnchor),
            headerRow.bottomAnchor.constraint(equalTo: planHeader.bottomAnchor),
            headerRow.leadingAnchor.constraint(equalTo: planHeader.leadingAnchor),
            headerRow.trailingAnchor.constraint(equalTo: planHeader.trailingAnchor),
        ])
        planHeader.isAccessibilityElement = true
        planHeader.accessibilityTraits = .button
        planHeader.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            Theme.Haptics.selection()
            self.setPlan(open: self.planBody.isHidden, animated: true)
        }, for: .touchUpInside)

        planBody.axis = .vertical
        planBody.spacing = Theme.Spacing.l
        planBody.isHidden = true
        planBody.addArrangedSubview(caption(DelegateComposerWords.planHelp))

        planBody.addArrangedSubview(labelled(DelegateComposerWords.classLabel, classButton, help: DelegateComposerWords.classHelp))
        classButton.showsMenuAsPrimaryAction = true
        classButton.contentHorizontalAlignment = .leading
        classButton.menu = classMenu()

        let verifyBlock = UIStackView(arrangedSubviews: [verify, suggestionStrip(), caption(DelegateComposerWords.verifyHelp)])
        verifyBlock.axis = .vertical
        verifyBlock.spacing = Theme.Spacing.s
        planBody.addArrangedSubview(verifyBlock)
        verify.textField.font = Theme.Ramp.font(.code)
        verify.textField.addAction(UIAction { [weak self] _ in self?.draftChanged() }, for: .editingChanged)

        ladder.mode = .compose
        ladder.onChange = { [weak self] start, ceiling in
            self?.planTouched = true
            self?.draft.tier = start
            self?.draft.ceiling = ceiling
            self?.render()
        }
        legendLabel.numberOfLines = 0
        legendLabel.font = Theme.Ramp.font(.rowNote)
        legendLabel.textColor = Theme.Color.label
        let ladderBlock = labelled(DelegateComposerWords.ladderLabel, ladder, help: DelegateComposerWords.ladderHelp)
        (ladderBlock as? UIStackView)?.insertArrangedSubview(legendLabel, at: 2)
        planBody.addArrangedSubview(ladderBlock)

        modeControl.addAction(UIAction { [weak self] _ in
            self?.planTouched = true
            self?.draftChanged()
        }, for: .valueChanged)
        planBody.addArrangedSubview(labelled(DelegateComposerWords.modeLabel, modeControl))
        effortControl.addAction(UIAction { [weak self] _ in self?.draftChanged() }, for: .valueChanged)
        planBody.addArrangedSubview(labelled(DelegateComposerWords.effortLabel, effortControl))
        planBody.addArrangedSubview(read)
        read.textField.addAction(UIAction { [weak self] _ in self?.draftChanged() }, for: .editingChanged)
        planBody.addArrangedSubview(labelled(DelegateComposerWords.notesLabel, editor(notes, minHeight: 60, placeholder: "")))
        notes.backgroundColor = Theme.Color.groupedBackground

        let column = UIStackView(arrangedSubviews: [planHeader, planBody])
        column.axis = .vertical
        column.spacing = Theme.Spacing.l
        return card(column)
    }

    private func setPlan(open: Bool, animated: Bool) {
        let change = {
            self.planBody.isHidden = !open
            self.planBody.alpha = open ? 1 : 0
            self.planChevron.transform = open ? CGAffineTransform(rotationAngle: .pi / 2) : .identity
            self.stack.layoutIfNeeded()
        }
        planHeader.accessibilityValue = open ? String(localized: "Expanded") : String(localized: "Collapsed")
        guard animated, !UIAccessibility.isReduceMotionEnabled else { return change() }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut], animations: change)
    }

    private func suggestionStrip() -> UIView {
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
        return suggestionScroll
    }

    private func card(_ content: UIView) -> UIView {
        let card = UIView()
        card.backgroundColor = Theme.Color.groupedSurface
        card.layer.cornerRadius = Theme.Radius.card
        card.layer.cornerCurve = .continuous
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: Theme.Spacing.m + 2),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Theme.Spacing.m - 2),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.Spacing.l),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.Spacing.l),
        ])
        return card
    }

    private func fill() {
        goal.text = draft.goal
        paths.text = draft.paths
        verify.textField.text = draft.verify
        read.textField.text = draft.read
        notes.text = draft.notes
        modeControl.selectedSegmentIndex = DelegateMode.allCases.firstIndex(of: draft.mode) ?? 0
        effortControl.selectedSegmentIndex = draft.effort.flatMap { DelegateEffort.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        ladder.rungs = board.composerRungs(taskClass: draft.taskClass)
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
        label.adjustsFontForContentSizeCategory = true
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
                self?.planTouched = true
                self?.choose(taskClass: name)
            }
        })
    }

    private func choose(taskClass name: String) {
        draft.choose(taskClass: name, capabilities: board.capabilities)
        verify.textField.text = draft.verify
        ladder.rungs = board.composerRungs(taskClass: name)
        ladder.set(start: draft.tier, ceiling: draft.ceiling)
        classButton.menu = classMenu()
        render()
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
        let board = board
        goalPlaceholder.isHidden = !draft.goal.isEmpty
        classButton.configuration?.title = draft.taskClass
        let supportsReview = board.supportsReview
        reviewSwitch.isEnabled = supportsReview
        reviewSwitch.isOn = supportsReview && draft.review
        reviewHelp.text = supportsReview ? DelegateComposerWords.reviewHelp : DelegateComposerWords.reviewUnsupported
        let summary = draft.planSummary(capabilities: board.capabilities, tierOrder: board.tierOrder)
        planSummary.text = summary
        planHeader.accessibilityLabel = DelegateComposerWords.planLabel + ", " + summary
        let problems = draft.problems
        self.problems.text = problems.joined(separator: "\n")
        self.problems.isHidden = problems.isEmpty
        let cautions = draft.cautions
        self.cautions.text = cautions.isEmpty ? nil : DelegateComposerWords.cautionsTitle + "\n" + cautions.joined(separator: "\n")
        self.cautions.isHidden = cautions.isEmpty
        send.isEnabled = draft.canSend && !sending
        send.setLoading(sending)
        paintChoices()
        renderSuggestions()
        renderLegend()
    }

    /// The one sentence that resolves the ladder the way the daemon will, and the implied range
    /// drawn on the rungs so an unset ladder is still a picture.
    private func renderLegend() {
        let plan = draft.plan(capabilities: board.capabilities, tierOrder: board.tierOrder)
        legendLabel.text = plan.legend
        ladder.setImplied(start: plan.start, ceiling: plan.ceiling)
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
                AppLogger.ui.info("delegate packet started run \(runID) on \(self.host) review=\(draft.review && self.board.supportsReview)")
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
