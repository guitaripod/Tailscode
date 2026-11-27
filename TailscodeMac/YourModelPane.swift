import AppKit
import CodingAgentKitApple
import MidgarCore
import ObjectiveC
import TailscodeCore

/// The Your model page of Settings: the language model the person runs, found without typing,
/// proved by asking it two sentences with the time to the first word and the rate shown, and put
/// to work. The models found are one pop-up grouped by machine, as a Mac lists a choice. Nothing is
/// loaded on the page's own account: a model llama-swap would have to load waits for a press.
@MainActor
final class YourModelPane: NSObject {
    private static var key: UInt8 = 0

    private let nameLabel = NSTextField(labelWithString: YourModelWords.title)
    private let placeLabel = MacDialogs.detailLabel(YourModelWords.explainer, wraps: true)
    private let spinner = NSProgressIndicator()
    private let proofLabel = NSTextField(labelWithString: "")
    private let quoteLabel = MacDialogs.detailLabel("", wraps: true)
    private let proveButton = NSButton(title: YourModelWords.proveAgain, target: nil, action: nil)
    private let lookButton = NSButton(title: YourModelWords.lookAgain, target: nil, action: nil)
    private let suggestRow = NSStackView()
    private let suggestTitle = NSTextField(labelWithString: "")
    private let suggestButton = NSButton(title: "", target: nil, action: nil)
    private let privacyLabel = MacDialogs.detailLabel("", wraps: true)
    private let modelsPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modelsCount = MacDialogs.detailLabel("", wraps: false)
    private let studioToggle = NSButton(checkboxWithTitle: YourModelWords.studioTitle, target: nil, action: nil)
    private let sampleLabel = MacDialogs.detailLabel("", wraps: true)
    private let agentsTitle = NSTextField(labelWithString: YourModelWords.agentsTitle)
    private let agentsDetail = MacDialogs.detailLabel(YourModelWords.agentsNone, wraps: true)
    private let carryButton = NSButton(title: YourModelWords.carry, target: nil, action: nil)
    private let getOneColumn = NSStackView()

    private var servers: [YourModelServer] = []
    private var profiles: [ConnectionProfile] = []
    private var listed: [YourModelCandidate?] = []
    private var suggested: YourModelCandidate?
    private var looking = false
    private var proving = false
    private var generation = 0
    private var sampleTask: Task<Void, Never>?

    /// Fills `column` with the page and ties this pane's life to it.
    static func fill(_ column: NSStackView) {
        let pane = YourModelPane()
        objc_setAssociatedObject(column, &key, pane, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        pane.build(into: column)
        for label in column.arrangedSubviews where label is NSTextField {
            label.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -48).isActive = true
        }
        if let filed = YourModelStore.current() { pane.showFiled(filed, candidate: nil) }
        pane.look(choosing: YourModelStore.current() == nil)
    }

    private func build(into column: NSStackView) {
        column.addArrangedSubview(MacDialogs.sectionHeader(YourModelWords.title))
        nameLabel.font = MacTheme.Ramp.font(.panelTitle)
        nameLabel.lineBreakMode = .byTruncatingTail
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let heading = NSStackView(views: [nameLabel, spinner])
        heading.orientation = .horizontal
        heading.spacing = MacTheme.Spacing.s
        column.addArrangedSubview(heading)
        column.addArrangedSubview(placeLabel)
        proofLabel.font = MacTheme.Ramp.font(.panelLabel)
        proofLabel.isHidden = true
        quoteLabel.isHidden = true
        column.addArrangedSubview(proofLabel)
        column.addArrangedSubview(quoteLabel)
        target(proveButton, #selector(proveAgain))
        target(lookButton, #selector(lookAgain))
        for button in [proveButton, lookButton, suggestButton, carryButton] { button.bezelStyle = .rounded }
        proveButton.isHidden = true
        let buttons = NSStackView(views: [proveButton, lookButton])
        buttons.orientation = .horizontal
        buttons.spacing = MacTheme.Spacing.s
        column.addArrangedSubview(buttons)

        suggestTitle.font = MacTheme.Ramp.font(.panelLabel)
        target(suggestButton, #selector(useSuggested))
        suggestButton.keyEquivalent = "\r"
        let suggestText = NSStackView(views: [suggestTitle, MacDialogs.detailLabel(YourModelWords.suggestBody, wraps: true)])
        suggestText.orientation = .vertical
        suggestText.alignment = .leading
        suggestText.spacing = 2
        suggestRow.setViews([suggestText, NSView(), suggestButton], in: .leading)
        suggestRow.orientation = .horizontal
        suggestRow.spacing = MacTheme.Spacing.s
        suggestRow.isHidden = true
        column.addArrangedSubview(suggestRow)

        let lock = NSImageView(image: NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil) ?? NSImage())
        lock.contentTintColor = .tertiaryLabelColor
        lock.setContentHuggingPriority(.required, for: .horizontal)
        let privacy = NSStackView(views: [lock, privacyLabel])
        privacy.orientation = .horizontal
        privacy.alignment = .firstBaseline
        privacy.spacing = MacTheme.Spacing.xs
        privacy.isHidden = true
        column.addArrangedSubview(privacy)

        column.addArrangedSubview(spacer(MacTheme.Spacing.m))
        column.addArrangedSubview(MacDialogs.sectionHeader(YourModelWords.others))
        modelsPopUp.target = self
        modelsPopUp.action = #selector(pickedModel)
        modelsPopUp.autoenablesItems = false
        let models = NSStackView(views: [modelsPopUp, modelsCount])
        models.orientation = .horizontal
        models.spacing = MacTheme.Spacing.s
        column.addArrangedSubview(models)

        column.addArrangedSubview(spacer(MacTheme.Spacing.m))
        column.addArrangedSubview(MacDialogs.sectionHeader(YourModelWords.usesTitle))
        studioToggle.font = MacTheme.Ramp.font(.panelLabel)
        studioToggle.state = (YourModelStore.current()?.enabled ?? true) ? .on : .off
        target(studioToggle, #selector(studioChanged))
        column.addArrangedSubview(studioToggle)
        column.addArrangedSubview(indented(MacDialogs.detailLabel(YourModelWords.studioSubtitle, wraps: true)))
        let typed = NSTextField(labelWithString: YourModelWords.youType + ": " + YourModelWords.sampleBrief)
        typed.font = MacTheme.Ramp.font(.panelLabel)
        let show = NSButton(title: YourModelWords.showMe, target: self, action: #selector(showSample))
        show.bezelStyle = .rounded
        let sample = NSStackView(views: [typed, show])
        sample.orientation = .horizontal
        sample.spacing = MacTheme.Spacing.s
        column.addArrangedSubview(indented(sample))
        sampleLabel.isHidden = true
        column.addArrangedSubview(indented(sampleLabel))

        column.addArrangedSubview(spacer(MacTheme.Spacing.m))
        column.addArrangedSubview(MacDialogs.sectionHeader(YourModelWords.agentsTitle))
        agentsTitle.font = MacTheme.Ramp.font(.panelLabel)
        target(carryButton, #selector(carry))
        carryButton.isHidden = true
        let agentsRow = NSStackView(views: [agentsTitle, NSView(), carryButton])
        agentsRow.orientation = .horizontal
        agentsRow.spacing = MacTheme.Spacing.s
        column.addArrangedSubview(agentsRow)
        column.addArrangedSubview(agentsDetail)

        getOneColumn.orientation = .vertical
        getOneColumn.alignment = .leading
        getOneColumn.spacing = MacTheme.Spacing.s
        getOneColumn.isHidden = true
        column.addArrangedSubview(getOneColumn)
    }

    private func look(choosing: Bool) {
        guard !looking else { return }
        looking = true
        spinner.startAnimation(nil)
        lookButton.isEnabled = false
        let profiles = ServerDirectory.shared.profiles
        let places = YourModelSurvey.places(
            profiles: profiles, painting: ImageGenDoor.current().endpoint, thisDevice: true)
        if YourModelStore.current() == nil { placeLabel.stringValue = YourModelWords.lookingOn(places.map(\.machine)) }
        Task { [weak self] in
            let servers = await YourModelSurvey.survey(places)
            self?.landed(servers, profiles: profiles, choosing: choosing)
        }
    }

    private func landed(_ servers: [YourModelServer], profiles: [ConnectionProfile], choosing: Bool) {
        looking = false
        spinner.stopAnimation(nil)
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
            nameLabel.stringValue = YourModelWords.noneTitle
            placeLabel.stringValue = YourModelWords.noneBody
        }
        renderModels()
        renderAgents()
        renderSuggestion()
        renderGetOne()
        MidgarLog.info("your model survey servers=\(servers.count) filed=\(YourModelStore.current()?.model ?? "none")", category: .ui)
    }

    private func choose(_ candidate: YourModelCandidate, byHand: Bool) {
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
        nameLabel.stringValue = filed.label ?? filed.model
        var lines = [candidate.map(YourModelWords.place) ?? YourModelWords.place(filed)]
        if let candidate {
            if let state = YourModelWords.state(candidate) { lines[0] += " · " + state }
            if filed.chosenByHand != true { lines.append(YourModelWords.defaultReason(candidate)) }
        }
        placeLabel.stringValue = lines.joined(separator: "\n")
        privacyLabel.stringValue = YourModelWords.privacy(filed)
        privacyLabel.superview?.isHidden = false
        studioToggle.state = filed.enabled ? .on : .off
    }

    private func proveIfFree(_ candidate: YourModelCandidate?) {
        if YourModelPick.asksOnItsOwn(candidate) {
            prove()
            return
        }
        quoteLabel.isHidden = false
        proofLabel.isHidden = false
        proofLabel.stringValue = candidate == nil ? YourModelWords.notFoundTitle : YourModelWords.notLoadedTitle
        quoteLabel.stringValue = candidate.flatMap(YourModelWords.caution) ?? YourModelWords.notFoundBody
        proveButton.title = candidate == nil ? YourModelWords.proveAgain : YourModelWords.loadAndAsk
        proveButton.isHidden = false
    }

    private func prove() {
        guard !proving, let filed = YourModelStore.current() else { return }
        proving = true
        generation += 1
        let mine = generation
        proveButton.isHidden = false
        proveButton.isEnabled = false
        proveButton.title = YourModelWords.proveAgain
        proofLabel.isHidden = false
        proofLabel.stringValue = YourModelWords.proving(filed.label ?? filed.model)
        quoteLabel.isHidden = true
        Task { [weak self] in
            do {
                let proof = try await YourModelProving.prove(filed) { [weak self] text in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == mine else { return }
                        self.quoteLabel.isHidden = false
                        self.quoteLabel.stringValue = "“" + text + "”"
                    }
                }
                self?.finish(line: proof.line, quote: "“" + proof.text + "”", generation: mine)
                MidgarLog.info("your model proof first=\(proof.firstWord) rate=\(proof.perSecond ?? -1)", category: .ui)
            } catch {
                let reason = (error as? ImageGenEnhancer.Failure)?.reason ?? error.localizedDescription
                self?.finish(line: YourModelWords.provingFailed(reason), quote: nil, generation: mine)
            }
        }
    }

    private func finish(line: String, quote: String?, generation mine: Int) {
        proving = false
        proveButton.isEnabled = true
        guard generation == mine else { return }
        proofLabel.stringValue = line
        if let quote {
            quoteLabel.isHidden = false
            quoteLabel.stringValue = quote
        }
    }

    private func renderModels() {
        modelsPopUp.removeAllItems()
        listed = []
        let filed = YourModelStore.current()
        let total = servers.flatMap(\.models).count
        modelsCount.stringValue = total == 0 ? YourModelWords.noneTitle : YourModelWords.found(models: total, servers: servers.count)
        modelsPopUp.isEnabled = total > 0
        let menu = modelsPopUp.menu ?? NSMenu()
        var selected: NSMenuItem?
        for server in servers {
            let heading = NSMenuItem(title: server.heading, action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
            listed.append(nil)
            for candidate in YourModelPick.ranked([server]) {
                let item = NSMenuItem(title: candidate.label, action: nil, keyEquivalent: "")
                item.indentationLevel = 1
                item.toolTip = YourModelWords.detail(candidate)
                if let state = YourModelWords.state(candidate) { item.title += "  —  " + state }
                menu.addItem(item)
                listed.append(candidate)
                if candidate.address == filed?.address, candidate.model == filed?.model { selected = item }
            }
        }
        if let selected { modelsPopUp.select(selected) }
    }

    private func renderAgents() {
        guard let filed = YourModelStore.current() else {
            agentsTitle.stringValue = YourModelWords.agentsTitle
            agentsDetail.stringValue = YourModelWords.agentsNone
            carryButton.isHidden = true
            return
        }
        agentsTitle.stringValue = filed.label ?? filed.model
        let offers = YourModelAgents.offers(of: filed.model, profiles: profiles)
        guard let first = offers.first else {
            agentsDetail.stringValue = YourModelWords.agentsNone
            carryButton.isHidden = true
            return
        }
        agentsDetail.stringValue = YourModelWords.agentsOffer(offers.map(\.said))
        let carried = YourModelAgents.isCarried(first)
        carryButton.title = carried ? YourModelWords.carried : YourModelWords.carry
        carryButton.isEnabled = !carried
        carryButton.isHidden = false
    }

    private func renderSuggestion() {
        suggested = YourModelPick.suggestion(for: YourModelStore.current(), in: servers)
        suggestRow.isHidden = suggested == nil
        guard let suggested else { return }
        suggestTitle.stringValue = YourModelWords.suggestTitle(suggested)
        suggestButton.title = YourModelWords.suggestAction(suggested)
    }

    private func renderGetOne() {
        getOneColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let none = servers.isEmpty && YourModelStore.current() == nil
        getOneColumn.isHidden = !none
        guard none else { return }
        getOneColumn.addArrangedSubview(spacer(MacTheme.Spacing.m))
        getOneColumn.addArrangedSubview(MacDialogs.sectionHeader(YourModelWords.getOneTitle))
        getOneColumn.addArrangedSubview(MacDialogs.detailLabel(YourModelWords.noneBody, wraps: true))
        for (index, profile) in profiles.prefix(4).enumerated() {
            let button = NSButton(title: YourModelWords.getOneAction, target: self, action: #selector(askAgent))
            button.bezelStyle = .rounded
            button.tag = index
            let label = NSTextField(labelWithString: profile.name)
            label.font = MacTheme.Ramp.font(.panelLabel)
            let row = NSStackView(views: [label, NSView(), button])
            row.orientation = .horizontal
            getOneColumn.addArrangedSubview(row)
            getOneColumn.addArrangedSubview(MacDialogs.detailLabel(YourModelWords.getOneBody(profile.name), wraps: true))
        }
    }

    @objc private func proveAgain() { prove() }
    @objc private func lookAgain() { look(choosing: false) }

    @objc private func useSuggested() {
        guard let suggested else { return }
        choose(suggested, byHand: true)
    }

    @objc private func pickedModel() {
        let index = modelsPopUp.indexOfSelectedItem
        guard listed.indices.contains(index), let candidate = listed[index] else { return }
        choose(candidate, byHand: true)
    }

    @objc private func studioChanged() {
        YourModelStore.setStudio(studioToggle.state == .on)
    }

    @objc private func carry() {
        guard let filed = YourModelStore.current(),
            let offer = YourModelAgents.offers(of: filed.model, profiles: profiles).first
        else { return }
        if YourModelAgents.carry(offer, name: filed.label) == .full {
            agentsDetail.stringValue = YourModelWords.partyFull
            return
        }
        renderAgents()
    }

    /// Opens a new chat on the server with the setup ask in its box, unsent.
    @objc private func askAgent(_ sender: NSButton) {
        guard profiles.indices.contains(sender.tag),
            let main = NSApp.windows.lazy.compactMap({ $0.windowController as? MainWindowController }).first
        else { return }
        sender.window?.close()
        main.window?.makeKeyAndOrderFront(nil)
        main.presentNewChat(on: profiles[sender.tag], carrying: CarryPlan(brief: nil, draft: YourModelGetOne.brief))
    }

    @objc private func showSample() {
        guard let filed = YourModelStore.current() else { return }
        sampleTask?.cancel()
        sampleLabel.isHidden = false
        sampleLabel.stringValue = YourModelWords.itWrites + ": …"
        let enhancer = ImageGenEnhancer(helper: filed)
        let ask = ImageGenRewriteAsk(brief: YourModelWords.sampleBrief, context: ImageGenRewriteContext())
        sampleTask = Task { [weak self] in
            do {
                let read = try await enhancer.stream(ask) { [weak self] text in
                    Task { @MainActor [weak self] in
                        self?.sampleLabel.stringValue = YourModelWords.itWrites + ": " + YourModelWords.excerpt(text)
                    }
                }
                self?.sampleLabel.stringValue = YourModelWords.itWrites + ": " + YourModelWords.excerpt(read.prompt)
            } catch {
                guard !Task.isCancelled else { return }
                self?.sampleLabel.stringValue = YourModelWords.provingFailed(
                    (error as? ImageGenEnhancer.Failure)?.reason ?? error.localizedDescription)
            }
        }
    }

    private func target(_ button: NSButton, _ action: Selector) {
        button.target = self
        button.action = action
    }

    private func indented(_ view: NSView) -> NSView {
        let wrapper = NSStackView(views: [view])
        wrapper.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        return wrapper
    }

    private func spacer(_ height: CGFloat) -> NSView {
        let view = NSView()
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }
}
