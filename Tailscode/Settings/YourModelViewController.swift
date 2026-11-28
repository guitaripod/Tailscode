import CodingAgentKitApple
import MidgarCore
import TailscodeCore
import UIKit

/// Your model: the language model the person runs on one of their machines, found without typing,
/// proved by asking it two sentences with the time to the first word and the rate shown, and put to
/// work. It never loads a model on its own: one llama-swap would have to load waits for a press,
/// and a model filed by hand that is not in memory is offered the warm one in its place.
@MainActor
final class YourModelViewController: UIViewController {
    private let scroll = UIScrollView()
    private let stack = UIStackView()

    private let glyph = UIImageView(image: UIImage(systemName: "sparkles"))
    private let nameLabel = UILabel()
    private let placeLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let firstWordValue = UILabel()
    private let rateValue = UILabel()
    private let statsRow = UIStackView()
    private let proofLabel = UILabel()
    private let quoteLabel = UILabel()
    private let proveButton = UIButton(configuration: Theme.Glass.buttonConfiguration())
    private let lookButton = UIButton(configuration: Theme.Glass.buttonConfiguration())

    private let suggestCard = UIStackView()
    private let suggestTitle = UILabel()
    private let suggestButton = UIButton(configuration: Theme.Glass.buttonConfiguration(prominent: true))
    private let privacyLabel = UILabel()

    private let modelsHeader = UILabel()
    private let modelsStack = UIStackView()
    private let studioSwitch = UISwitch()
    private let shortSwitch = UISwitch()
    private let shortSampleLabel = UILabel()
    private var shortTask: Task<Void, Never>?
    private let sampleLabel = UILabel()
    private let agentsTitle = UILabel()
    private let agentsDetail = UILabel()
    private let carryButton = UIButton(configuration: Theme.Glass.buttonConfiguration())
    private let getOneStack = UIStackView()
    private var getOneCard: UIView?

    private var servers: [YourModelServer] = []
    private var profiles: [ConnectionProfile] = []
    private var suggested: YourModelCandidate?
    private var opened: Set<String> = []
    private var looking = false
    private var proving = false
    private var generation = 0
    private var sampleTask: Task<Void, Never>?

    /// The page on its own, over whatever is in front: a surface that uses the model opens it
    /// without leaving where the person is.
    static func presentModally() {
        let root = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?
            .rootViewController
        guard let root else { return }
        let page = YourModelViewController()
        let navigation = UINavigationController(rootViewController: page)
        page.navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak navigation] _ in navigation?.dismiss(animated: true) })
        root.frontmostPresented.present(navigation, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = YourModelWords.title
        view.backgroundColor = Theme.Color.groupedBackground
        build()
        if let filed = YourModelStore.current() { showFiled(filed, candidate: nil) }
        look(choosing: YourModelStore.current() == nil)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isMovingFromParent || isBeingDismissed else { return }
        sampleTask?.cancel()
    }

    private func build() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        view.addSubview(scroll)
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.l
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Theme.Spacing.l),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Spacing.xxl),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
        ])
        stack.addArrangedSubview(heroCard())
        stack.addArrangedSubview(card(suggestionContent()))
        stack.arrangedSubviews.last?.isHidden = true
        stack.addArrangedSubview(privacyNote())
        stack.addArrangedSubview(modelsHeader)
        stack.addArrangedSubview(modelsStack)
        stack.addArrangedSubview(sectionLabel(YourModelWords.usesTitle))
        stack.addArrangedSubview(card(shortContent()))
        stack.addArrangedSubview(card(studioContent()))
        stack.addArrangedSubview(sectionLabel(YourModelWords.agentsTitle))
        stack.addArrangedSubview(card(agentsContent()))
        let getOne = card(getOneContent())
        getOne.isHidden = true
        getOneCard = getOne
        stack.addArrangedSubview(getOne)
        modelsHeader.font = Theme.Ramp.font(.sectionLabel)
        modelsHeader.textColor = Theme.Color.secondaryLabel
        modelsHeader.numberOfLines = 0
        modelsHeader.isHidden = true
        modelsStack.axis = .vertical
        modelsStack.spacing = Theme.Spacing.m
    }

    private func heroCard() -> UIView {
        glyph.tintColor = Theme.Color.accent
        glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 30, weight: .semibold)
        glyph.contentMode = .scaleAspectFit
        nameLabel.font = Theme.Font.display(.title1, weight: .semibold)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.numberOfLines = 0
        nameLabel.textAlignment = .center
        nameLabel.text = YourModelWords.title
        placeLabel.font = Theme.Ramp.font(.panelDetail)
        placeLabel.textColor = Theme.Color.secondaryLabel
        placeLabel.numberOfLines = 0
        placeLabel.textAlignment = .center
        placeLabel.text = YourModelWords.explainer
        spinner.hidesWhenStopped = true

        statsRow.axis = .horizontal
        statsRow.distribution = .fillEqually
        statsRow.spacing = Theme.Spacing.m
        statsRow.addArrangedSubview(stat(firstWordValue, caption: Localized.text("first word")))
        statsRow.addArrangedSubview(stat(rateValue, caption: Localized.text("tokens a second")))
        statsRow.isHidden = true

        proofLabel.font = Theme.Ramp.font(.panelLabel)
        proofLabel.numberOfLines = 0
        proofLabel.textAlignment = .center
        proofLabel.isHidden = true
        quoteLabel.font = Theme.Ramp.font(.cardBody)
        quoteLabel.textColor = Theme.Color.secondaryLabel
        quoteLabel.numberOfLines = 0
        quoteLabel.isHidden = true

        style(proveButton, YourModelWords.proveAgain) { [weak self] in self?.prove() }
        style(lookButton, YourModelWords.lookAgain) { [weak self] in self?.look(choosing: false) }
        proveButton.isHidden = true
        let buttons = UIStackView(arrangedSubviews: [proveButton, lookButton])
        buttons.axis = .horizontal
        buttons.spacing = Theme.Spacing.s
        buttons.distribution = .fillEqually

        let column = UIStackView(arrangedSubviews: [
            glyph, nameLabel, placeLabel, spinner, statsRow, proofLabel, quoteLabel, buttons,
        ])
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = Theme.Spacing.s
        column.setCustomSpacing(Theme.Spacing.m, after: placeLabel)
        column.setCustomSpacing(Theme.Spacing.m, after: quoteLabel)
        return card(column)
    }

    private func stat(_ value: UILabel, caption: String) -> UIView {
        value.font = Theme.Font.display(.title2, weight: .semibold)
        value.adjustsFontForContentSizeCategory = true
        value.textAlignment = .center
        let label = UILabel()
        label.text = caption
        label.font = Theme.Ramp.font(.panelFootnote)
        label.textColor = Theme.Color.secondaryLabel
        label.textAlignment = .center
        let column = UIStackView(arrangedSubviews: [value, label])
        column.axis = .vertical
        column.spacing = 2
        return column
    }

    private func suggestionContent() -> UIView {
        suggestTitle.font = Theme.Ramp.font(.cardTitle)
        suggestTitle.numberOfLines = 0
        let body = UILabel()
        body.text = YourModelWords.suggestBody
        body.font = Theme.Ramp.font(.panelDetail)
        body.textColor = Theme.Color.secondaryLabel
        body.numberOfLines = 0
        style(suggestButton, "") { [weak self] in
            guard let self, let suggested = self.suggested else { return }
            self.choose(suggested, byHand: true)
        }
        suggestCard.axis = .vertical
        suggestCard.spacing = Theme.Spacing.s
        [suggestTitle, body, suggestButton].forEach(suggestCard.addArrangedSubview)
        return suggestCard
    }

    private func privacyNote() -> UIView {
        privacyLabel.font = Theme.Ramp.font(.panelFootnote)
        privacyLabel.textColor = Theme.Color.secondaryLabel
        privacyLabel.numberOfLines = 0
        let lock = UIImageView(image: UIImage(systemName: "lock.fill"))
        lock.tintColor = Theme.Color.tertiaryLabel
        lock.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11)
        lock.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [lock, privacyLabel])
        row.axis = .horizontal
        row.alignment = .firstBaseline
        row.spacing = Theme.Spacing.s
        row.isHidden = true
        return row
    }

    private func shortContent() -> UIView {
        let title = UILabel()
        title.text = NeuralGistWords.settingTitle
        title.font = Theme.Ramp.font(.cardTitle)
        title.numberOfLines = 0
        let subtitle = UILabel()
        subtitle.text = NeuralGistWords.settingSubtitle
        subtitle.font = Theme.Ramp.font(.panelDetail)
        subtitle.textColor = Theme.Color.secondaryLabel
        subtitle.numberOfLines = 0
        let text = UIStackView(arrangedSubviews: [title, subtitle])
        text.axis = .vertical
        text.spacing = 2
        shortSwitch.isOn = NeuralGistSetting.isOn
        shortSwitch.accessibilityLabel = NeuralGistWords.settingTitle
        shortSwitch.addAction(
            UIAction { [weak self] _ in
                Theme.Haptics.tap()
                NeuralGistSetting.set(self?.shortSwitch.isOn ?? true)
            }, for: .valueChanged)
        let top = UIStackView(arrangedSubviews: [text, shortSwitch])
        top.axis = .horizontal
        top.alignment = .center
        top.spacing = Theme.Spacing.m

        let rules = UILabel()
        rules.text = YourModelWords.rulesSay + ": " + NeuralGistSample.rulesWords
        rules.font = Theme.Ramp.font(.panelLabel)
        rules.numberOfLines = 0
        shortSampleLabel.font = Theme.Ramp.font(.cardBody)
        shortSampleLabel.textColor = Theme.Color.secondaryLabel
        shortSampleLabel.numberOfLines = 0
        shortSampleLabel.isHidden = true
        let show = UIButton(configuration: Theme.Glass.buttonConfiguration())
        style(show, YourModelWords.showMe) { [weak self] in self?.showShortSample() }

        let column = UIStackView(arrangedSubviews: [top, rules, shortSampleLabel, show])
        column.axis = .vertical
        column.spacing = Theme.Spacing.s
        column.setCustomSpacing(Theme.Spacing.l, after: top)
        return column
    }

    private func showShortSample() {
        guard let filed = YourModelStore.current() else { return }
        Theme.Haptics.tap()
        shortTask?.cancel()
        shortSampleLabel.isHidden = false
        shortSampleLabel.text = YourModelWords.itSays + ": …"
        shortTask = Task { [weak self] in
            let gist = await NeuralGistSample.write(helper: filed)
            guard !Task.isCancelled else { return }
            self?.shortSampleLabel.text =
                gist.map { YourModelWords.itSays + ": " + NeuralGistSample.line($0) } ?? NeuralGistSample.failed
        }
    }

    private func studioContent() -> UIView {
        let title = UILabel()
        title.text = YourModelWords.studioTitle
        title.font = Theme.Ramp.font(.cardTitle)
        title.numberOfLines = 0
        let subtitle = UILabel()
        subtitle.text = YourModelWords.studioSubtitle
        subtitle.font = Theme.Ramp.font(.panelDetail)
        subtitle.textColor = Theme.Color.secondaryLabel
        subtitle.numberOfLines = 0
        let text = UIStackView(arrangedSubviews: [title, subtitle])
        text.axis = .vertical
        text.spacing = 2
        studioSwitch.isOn = YourModelStore.current()?.enabled ?? true
        studioSwitch.addAction(
            UIAction { [weak self] _ in
                Theme.Haptics.tap()
                YourModelStore.setStudio(self?.studioSwitch.isOn ?? true)
            }, for: .valueChanged)
        let top = UIStackView(arrangedSubviews: [text, studioSwitch])
        top.axis = .horizontal
        top.alignment = .center
        top.spacing = Theme.Spacing.m

        let typed = UILabel()
        typed.text = YourModelWords.youType + ": " + YourModelWords.sampleBrief
        typed.font = Theme.Ramp.font(.panelLabel)
        typed.numberOfLines = 0
        sampleLabel.font = Theme.Ramp.font(.cardBody)
        sampleLabel.textColor = Theme.Color.secondaryLabel
        sampleLabel.numberOfLines = 0
        sampleLabel.isHidden = true
        let show = UIButton(configuration: Theme.Glass.buttonConfiguration())
        style(show, YourModelWords.showMe) { [weak self] in self?.showSample() }

        let column = UIStackView(arrangedSubviews: [top, typed, sampleLabel, show])
        column.axis = .vertical
        column.spacing = Theme.Spacing.s
        column.setCustomSpacing(Theme.Spacing.l, after: top)
        return column
    }

    private func agentsContent() -> UIView {
        agentsTitle.font = Theme.Ramp.font(.cardTitle)
        agentsTitle.numberOfLines = 0
        agentsDetail.font = Theme.Ramp.font(.panelDetail)
        agentsDetail.textColor = Theme.Color.secondaryLabel
        agentsDetail.numberOfLines = 0
        agentsDetail.text = YourModelWords.agentsNone
        style(carryButton, YourModelWords.carry) { [weak self] in self?.carry() }
        carryButton.isHidden = true
        let column = UIStackView(arrangedSubviews: [agentsTitle, agentsDetail, carryButton])
        column.axis = .vertical
        column.spacing = Theme.Spacing.s
        return column
    }

    private func getOneContent() -> UIView {
        let title = UILabel()
        title.text = YourModelWords.getOneTitle
        title.font = Theme.Ramp.font(.cardTitle)
        let body = UILabel()
        body.text = YourModelWords.noneBody
        body.font = Theme.Ramp.font(.panelDetail)
        body.textColor = Theme.Color.secondaryLabel
        body.numberOfLines = 0
        getOneStack.axis = .vertical
        getOneStack.spacing = Theme.Spacing.s
        [title, body].forEach(getOneStack.addArrangedSubview)
        return getOneStack
    }

    private func look(choosing: Bool) {
        guard !looking else { return }
        looking = true
        spinner.startAnimating()
        lookButton.isEnabled = false
        let profiles = ConnectionController.shared.profiles
        let places = YourModelSurvey.places(
            profiles: profiles, painting: ImageGenDoor.current().endpoint, thisDevice: false)
        if YourModelStore.current() == nil { placeLabel.text = YourModelWords.lookingOn(places.map(\.machine)) }
        Task { [weak self] in
            let servers = await YourModelSurvey.survey(places)
            self?.landed(servers, profiles: profiles, choosing: choosing)
        }
    }

    private func landed(_ servers: [YourModelServer], profiles: [ConnectionProfile], choosing: Bool) {
        looking = false
        spinner.stopAnimating()
        lookButton.isEnabled = true
        self.servers = servers
        self.profiles = profiles
        let best = YourModelPick.best(servers)
        if let best, choosing || YourModelPick.replaces(YourModelStore.current(), with: best) {
            choose(best, byHand: false)
        } else if let filed = YourModelStore.current() {
            let candidate = YourModelPick.find(filed, in: servers)
            showFiled(filed, candidate: candidate)
            proveIfFree(candidate)
        } else {
            nameLabel.text = YourModelWords.noneTitle
            placeLabel.text = YourModelWords.noneBody
        }
        renderModels()
        renderAgents()
        renderSuggestion()
        renderGetOne()
        MidgarLog.info("your model survey servers=\(servers.count) filed=\(YourModelStore.current()?.model ?? "none")", category: .ui)
    }

    private func choose(_ candidate: YourModelCandidate, byHand: Bool) {
        Theme.Haptics.tap()
        YourModelStore.choose(candidate, byHand: byHand)
        showFiled(YourModelStore.current() ?? candidate.helper(chosenByHand: byHand), candidate: candidate)
        renderModels()
        renderAgents()
        renderSuggestion()
        sampleTask?.cancel()
        sampleLabel.isHidden = true
        proveIfFree(candidate)
    }

    private func showFiled(_ filed: ImageGenHelper, candidate: YourModelCandidate?) {
        nameLabel.text = filed.label ?? filed.model
        var lines = [candidate.map(YourModelWords.place) ?? YourModelWords.place(filed)]
        if let candidate {
            if let state = YourModelWords.state(candidate) { lines[0] += " · " + state }
            if filed.chosenByHand != true { lines.append(YourModelWords.defaultReason(candidate)) }
        }
        placeLabel.text = lines.joined(separator: "\n")
        privacyLabel.text = YourModelWords.privacy(filed)
        privacyLabel.superview?.isHidden = false
        studioSwitch.isOn = filed.enabled
    }

    private func proveIfFree(_ candidate: YourModelCandidate?) {
        if YourModelPick.asksOnItsOwn(candidate) {
            prove()
            return
        }
        statsRow.isHidden = true
        quoteLabel.isHidden = true
        proofLabel.isHidden = false
        proofLabel.text =
            (candidate == nil ? YourModelWords.notFoundTitle : YourModelWords.notLoadedTitle) + "\n"
            + (candidate.flatMap(YourModelWords.caution) ?? YourModelWords.notFoundBody)
        setTitle(proveButton, candidate == nil ? YourModelWords.proveAgain : YourModelWords.loadAndAsk)
        proveButton.isHidden = false
    }

    private func prove() {
        guard !proving, let filed = YourModelStore.current() else { return }
        proving = true
        generation += 1
        let mine = generation
        proveButton.isHidden = false
        proveButton.isEnabled = false
        setTitle(proveButton, YourModelWords.proveAgain)
        statsRow.isHidden = true
        proofLabel.isHidden = false
        proofLabel.text = YourModelWords.proving(filed.label ?? filed.model)
        quoteLabel.isHidden = true
        Task { [weak self] in
            do {
                let proof = try await YourModelProving.prove(filed) { [weak self] text in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == mine else { return }
                        self.quoteLabel.isHidden = false
                        self.quoteLabel.text = "“" + text + "”"
                    }
                }
                self?.proved(proof, generation: mine)
            } catch {
                self?.failed((error as? ImageGenEnhancer.Failure)?.reason ?? error.localizedDescription, generation: mine)
            }
        }
    }

    private func proved(_ proof: YourModelProof, generation mine: Int) {
        proving = false
        proveButton.isEnabled = true
        guard generation == mine else { return }
        firstWordValue.text = YourModelWords.seconds(proof.firstWord)
        rateValue.text = proof.perSecond.map { String(Int($0.rounded())) } ?? "—"
        statsRow.isHidden = false
        proofLabel.isHidden = true
        quoteLabel.isHidden = false
        quoteLabel.text = "“" + proof.text + "”"
        MidgarLog.info("your model proof first=\(proof.firstWord) rate=\(proof.perSecond ?? -1)", category: .ui)
    }

    private func failed(_ reason: String, generation mine: Int) {
        proving = false
        proveButton.isEnabled = true
        guard generation == mine else { return }
        proofLabel.isHidden = false
        proofLabel.text = YourModelWords.provingFailed(reason)
    }

    private func renderModels() {
        modelsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let total = servers.flatMap(\.models).count
        modelsHeader.isHidden = total == 0
        modelsHeader.text = YourModelWords.others.uppercased() + " · " + YourModelWords.found(models: total, servers: servers.count)
        let filed = YourModelStore.current()
        for server in servers {
            let ranked = YourModelPick.ranked([server])
            let shows = opened.contains(server.id) ? ranked : Array(ranked.prefix(5))
            let column = UIStackView()
            column.axis = .vertical
            column.spacing = Theme.Spacing.xs
            let heading = UILabel()
            heading.text = server.heading
            heading.font = Theme.Ramp.font(.cardTitle)
            column.addArrangedSubview(heading)
            for candidate in shows {
                let isFiled = candidate.address == filed?.address && candidate.model == filed?.model
                column.addArrangedSubview(modelButton(candidate, filed: isFiled))
            }
            if ranked.count > shows.count {
                var plain = UIButton.Configuration.plain()
                plain.title = Localized.text("Show all %d", ranked.count)
                plain.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)
                let more = UIButton(configuration: plain)
                more.contentHorizontalAlignment = .leading
                more.addAction(
                    UIAction { [weak self] _ in
                        self?.opened.insert(server.id)
                        self?.renderModels()
                    }, for: .touchUpInside)
                column.addArrangedSubview(more)
            }
            modelsStack.addArrangedSubview(card(column, interactive: true))
        }
    }

    private func modelButton(_ candidate: YourModelCandidate, filed: Bool) -> UIControl {
        let row = YourModelRow(title: candidate.label, detail: YourModelWords.detail(candidate), chosen: filed)
        row.addAction(UIAction { [weak self] _ in self?.choose(candidate, byHand: true) }, for: .touchUpInside)
        return row
    }

    private func renderAgents() {
        guard let filed = YourModelStore.current() else {
            agentsTitle.text = YourModelWords.agentsTitle
            agentsDetail.text = YourModelWords.agentsNone
            carryButton.isHidden = true
            return
        }
        agentsTitle.text = filed.label ?? filed.model
        let offers = YourModelAgents.offers(of: filed.model, profiles: profiles)
        guard let first = offers.first else {
            agentsDetail.text = YourModelWords.agentsNone
            carryButton.isHidden = true
            return
        }
        agentsDetail.text = YourModelWords.agentsOffer(offers.map(\.said))
        let carried = YourModelAgents.isCarried(first)
        setTitle(carryButton, carried ? YourModelWords.carried : YourModelWords.carry)
        carryButton.isEnabled = !carried
        carryButton.isHidden = false
    }

    private func carry() {
        guard let filed = YourModelStore.current(),
            let offer = YourModelAgents.offers(of: filed.model, profiles: profiles).first
        else { return }
        Theme.Haptics.tap()
        if YourModelAgents.carry(offer, name: filed.label) == .full {
            agentsDetail.text = YourModelWords.partyFull
            return
        }
        renderAgents()
    }

    private func renderSuggestion() {
        suggested = YourModelPick.suggestion(for: YourModelStore.current(), in: servers)
        suggestCard.superview?.isHidden = suggested == nil
        guard let suggested else { return }
        suggestTitle.text = YourModelWords.suggestTitle(suggested)
        setTitle(suggestButton, YourModelWords.suggestAction(suggested))
    }

    private func renderGetOne() {
        let none = servers.isEmpty && YourModelStore.current() == nil
        getOneCard?.isHidden = !none
        while getOneStack.arrangedSubviews.count > 2 { getOneStack.arrangedSubviews.last?.removeFromSuperview() }
        guard none else { return }
        for profile in profiles.prefix(4) {
            let button = UIButton(configuration: Theme.Glass.buttonConfiguration())
            style(button, YourModelWords.getOneAction + " · " + profile.name) { [weak self] in
                self?.askAgent(on: profile)
            }
            getOneStack.addArrangedSubview(button)
        }
    }

    /// Hands the setup ask to Home's box, aimed at the server, unsent: the person reads it and
    /// sends it, and the agent's every step is theirs to approve.
    private func askAgent(on profile: ConnectionProfile) {
        Theme.Haptics.tap()
        let brief = YourModelGetOne.brief
        let aim = {
            guard let home = MachineRouter.home else {
                UIPasteboard.general.string = brief
                return
            }
            if let workspace = home.workspace {
                workspace.showHome()
            } else {
                home.navigationController?.popToRootViewController(animated: false)
            }
            home.aimCompose(at: profile.id, carry: CarryPlan(brief: nil, draft: brief))
        }
        if let root = view.window?.rootViewController, root.presentedViewController != nil {
            root.dismiss(animated: true, completion: aim)
        } else {
            aim()
        }
    }

    private func showSample() {
        guard let filed = YourModelStore.current() else { return }
        Theme.Haptics.tap()
        sampleTask?.cancel()
        sampleLabel.isHidden = false
        sampleLabel.text = YourModelWords.itWrites + ": …"
        let enhancer = ImageGenEnhancer(helper: filed)
        let ask = ImageGenRewriteAsk(brief: YourModelWords.sampleBrief, context: ImageGenRewriteContext())
        sampleTask = Task { [weak self] in
            do {
                let read = try await enhancer.stream(ask) { [weak self] text in
                    Task { @MainActor [weak self] in
                        self?.sampleLabel.text = YourModelWords.itWrites + ": " + YourModelWords.excerpt(text)
                    }
                }
                self?.sampleLabel.text = YourModelWords.itWrites + ": " + YourModelWords.excerpt(read.prompt)
            } catch {
                guard !Task.isCancelled else { return }
                self?.sampleLabel.text = YourModelWords.provingFailed(
                    (error as? ImageGenEnhancer.Failure)?.reason ?? error.localizedDescription)
            }
        }
    }

    private func style(_ button: UIButton, _ title: String, action: @escaping () -> Void) {
        setTitle(button, title)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    }

    private func setTitle(_ button: UIButton, _ title: String) {
        button.configuration?.title = title
        button.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var attributes = $0
            attributes.font = Theme.Ramp.font(.panelDetail)
            return attributes
        }
    }

    private func sectionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text.uppercased()
        label.font = Theme.Ramp.font(.sectionLabel)
        label.textColor = Theme.Color.secondaryLabel
        return label
    }

    private func card(_ content: UIView, interactive: Bool = false) -> UIView {
        let glass = Theme.Glass.view()
        glass.layer.cornerRadius = Theme.Radius.card
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true
        glass.isUserInteractionEnabled = false
        glass.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(glass)
        container.addSubview(content)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: container.topAnchor),
            glass.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: Theme.Spacing.l),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Theme.Spacing.l),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Theme.Spacing.l),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Theme.Spacing.l),
        ])
        return container
    }
}

/// One model in the list: its name and what it is on the left, a mark on the right that says
/// whether it is the one in use. A press chooses it.
private final class YourModelRow: UIControl {
    init(title: String, detail: String, chosen: Bool) {
        super.init(frame: .zero)
        let name = UILabel()
        name.text = title
        name.font = Theme.Ramp.font(.rowTitle)
        name.numberOfLines = 0
        let about = UILabel()
        about.text = detail
        about.font = Theme.Ramp.font(.rowDetail)
        about.textColor = Theme.Color.secondaryLabel
        about.numberOfLines = 0
        let text = UIStackView(arrangedSubviews: [name, about])
        text.axis = .vertical
        text.spacing = 2
        let mark = UIImageView(image: UIImage(systemName: chosen ? "checkmark.circle.fill" : "circle"))
        mark.tintColor = chosen ? Theme.Color.accent : Theme.Color.tertiaryLabel
        mark.setContentHuggingPriority(.required, for: .horizontal)
        mark.setContentCompressionResistancePriority(.required, for: .horizontal)
        let line = UIStackView(arrangedSubviews: [text, mark])
        line.axis = .horizontal
        line.alignment = .center
        line.spacing = Theme.Spacing.m
        line.isUserInteractionEnabled = false
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.s),
            line.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.s),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityValue = detail
        accessibilityTraits = chosen ? [.button, .selected] : .button
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.5 : 1 }
    }
}
