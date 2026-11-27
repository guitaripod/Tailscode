import CAdw
import CGtkShim
import CodingAgentKitApple
import Foundation
import TailscodeCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Your model: the language model the person runs, found without typing, proved by asking it, and
/// put to work. The page opens on what is filed and checks it again at once; with nothing filed it
/// looks on this machine, every machine a server was added for and the machine that paints, files
/// the model the person keeps warm and asks it for two sentences, timing them. Below are every
/// model found, what it does for the person with a sample of each, the agents that already run it
/// and, when nothing answered, an agent that can set one up.
enum SettingsYourModelPage {
    /// Opens a new chat on a server with words in its box, never sent. Set by the main window.
    nonisolated(unsafe) static var askAgent: (@Sendable (ConnectionProfile, String) -> Void)?

    /// Opens Settings on this page, for a surface that uses the model. Set by the main window.
    nonisolated(unsafe) static var open: (@Sendable () -> Void)?

    static func fill(_ page: UnsafeMutablePointer<GtkWidget>, _ context: SettingsContext) {
        let panel = YourModelPanel()
        SettingsRows.keep(panel, alive: page)
        panel.build(on: page)
        Gtk.onMain { panel.opened() }
    }
}

final class YourModelPanel: @unchecked Sendable {
    private var hero: Gtk.WeakWidget?
    private var spinner: Gtk.WeakWidget?
    private var lookButton: Gtk.WeakWidget?
    private var proofRow: Gtk.WeakWidget?
    private var proofButton: Gtk.WeakWidget?
    private var privacyRow: Gtk.WeakWidget?
    private var suggestRow: Gtk.WeakWidget?
    private var suggestButton: Gtk.WeakWidget?
    private var suggested: YourModelCandidate?
    private weak var plainWords: PlainWordsSetup?
    private var modelsGroup: Gtk.WeakWidget?
    private var modelRows: [Gtk.WeakWidget] = []
    private var usesGroup: Gtk.WeakWidget?
    private var studioSwitch: Gtk.WeakWidget?
    private var studioSample: Gtk.WeakWidget?
    private var wallSample: Gtk.WeakWidget?
    private var agentsRow: Gtk.WeakWidget?
    private var carryButton: Gtk.WeakWidget?
    private var getOneGroup: Gtk.WeakWidget?
    private var getOneRows: [Gtk.WeakWidget] = []

    private var servers: [YourModelServer] = []
    private var profiles: [ConnectionProfile] = []
    private var looking = false
    private var proving = false
    private var generation = 0

    func build(on page: UnsafeMutablePointer<GtkWidget>) {
        let main = SettingsRows.group(YourModelWords.title, on: page, description: YourModelWords.explainer)
        let hero = Self.row(title: YourModelWords.title, subtitle: YourModelWords.looking)
        let spinner = gtk_spinner_new()!
        gtk_widget_set_valign(spinner, GTK_ALIGN_CENTER)
        adw_action_row_add_suffix(ptr(hero), spinner)
        let look = Gtk.button(YourModelWords.lookAgain, css: ["flat"]) { [weak self] in
            Gtk.onMain { [weak self] in self?.look(choosing: false) }
        }
        gtk_widget_set_valign(look, GTK_ALIGN_CENTER)
        adw_action_row_add_suffix(ptr(hero), look)
        SettingsRows.add(hero, to: main)

        let proof = Self.row(title: "", subtitle: "")
        let again = Gtk.button(YourModelWords.proveAgain, css: ["flat"]) { [weak self] in
            Gtk.onMain { [weak self] in self?.prove() }
        }
        gtk_widget_set_valign(again, GTK_ALIGN_CENTER)
        adw_action_row_add_suffix(ptr(proof), again)
        gtk_widget_set_visible(proof, 0)
        SettingsRows.add(proof, to: main)

        let suggest = Self.row(title: "", subtitle: YourModelWords.suggestBody)
        let use = Gtk.button("", css: ["suggested-action"]) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, let suggested = self.suggested else { return }
                self.choose(suggested, byHand: true)
            }
        }
        gtk_widget_set_valign(use, GTK_ALIGN_CENTER)
        adw_action_row_add_suffix(ptr(suggest), use)
        gtk_widget_set_visible(suggest, 0)
        SettingsRows.add(suggest, to: main)

        let privacy = Self.row(title: Localized.text("Where its words go"), subtitle: "")
        gtk_widget_set_visible(privacy, 0)
        SettingsRows.add(privacy, to: main)

        let models = SettingsRows.group(YourModelWords.others, on: page)
        gtk_widget_set_visible(models, 0)

        let uses = SettingsRows.group(YourModelWords.usesTitle, on: page)
        let studio = SettingsRows.switchRow(
            title: YourModelWords.studioTitle, subtitle: YourModelWords.studioSubtitle,
            value: YourModelStore.current()?.enabled ?? true
        ) { on in
            YourModelStore.setStudio(on)
        }
        adw_action_row_set_subtitle_lines(ptr(studio), 0)
        SettingsRows.add(studio, to: uses)
        let studioSample = Self.sampleRow(
            title: YourModelWords.youType + ": " + YourModelWords.sampleBrief
        ) { [weak self] in
            Gtk.onMain { [weak self] in self?.showStudioSample() }
        }
        SettingsRows.add(studioSample, to: uses)
        let (words, setup) = SettingsPlainWords.add(to: page)
        plainWords = setup
        let wallSample = Self.sampleRow(
            title: YourModelWords.rulesSay + ": " + AgentPlain.command(YourModelWords.sampleCommand, tense: .running).text
        ) { [weak self] in
            Gtk.onMain { [weak self] in self?.showWallSample() }
        }
        SettingsRows.add(wallSample, to: words)

        let agents = SettingsRows.group(YourModelWords.agentsTitle, on: page)
        let agentsRow = Self.row(title: YourModelWords.agentsTitle, subtitle: YourModelWords.agentsNone)
        let carry = Gtk.button(YourModelWords.carry, css: ["flat"]) { [weak self] in
            Gtk.onMain { [weak self] in self?.carry() }
        }
        gtk_widget_set_valign(carry, GTK_ALIGN_CENTER)
        gtk_widget_set_visible(carry, 0)
        adw_action_row_add_suffix(ptr(agentsRow), carry)
        SettingsRows.add(agentsRow, to: agents)

        let getOne = SettingsRows.group(YourModelWords.getOneTitle, on: page, description: YourModelWords.noneBody)
        gtk_widget_set_visible(getOne, 0)

        self.hero = Gtk.WeakWidget(hero)
        self.spinner = Gtk.WeakWidget(spinner)
        self.lookButton = Gtk.WeakWidget(look)
        self.proofRow = Gtk.WeakWidget(proof)
        self.proofButton = Gtk.WeakWidget(again)
        self.privacyRow = Gtk.WeakWidget(privacy)
        self.suggestRow = Gtk.WeakWidget(suggest)
        self.suggestButton = Gtk.WeakWidget(use)
        self.modelsGroup = Gtk.WeakWidget(models)
        self.usesGroup = Gtk.WeakWidget(uses)
        self.studioSwitch = Gtk.WeakWidget(studio)
        self.studioSample = Gtk.WeakWidget(studioSample)
        self.wallSample = Gtk.WeakWidget(wallSample)
        self.agentsRow = Gtk.WeakWidget(agentsRow)
        self.carryButton = Gtk.WeakWidget(carry)
        self.getOneGroup = Gtk.WeakWidget(getOne)
    }

    /// What the page does as it opens: shows what is filed and asks it again, and looks either way,
    /// choosing the default when nothing is filed yet.
    func opened() {
        if let filed = YourModelStore.current() {
            showFiled(filed, candidate: nil)
        }
        look(choosing: YourModelStore.current() == nil)
    }

    func look(choosing: Bool) {
        guard !looking else { return }
        looking = true
        setSpinning(true)
        Task { [weak self] in
            let profiles = await ServerDirectory.shared.profiles()
            let places = YourModelSurvey.places(
                profiles: profiles, painting: ImageGenDoor.current().endpoint, thisDevice: true)
            Gtk.onMain { [weak self] in
                guard let self, YourModelStore.current() == nil else { return }
                self.setHero(title: YourModelWords.title, subtitle: YourModelWords.lookingOn(places.map(\.machine)))
            }
            let servers = await YourModelSurvey.survey(places)
            Gtk.onMain { [weak self] in self?.landed(servers, profiles: profiles, choosing: choosing) }
        }
    }

    private func landed(_ servers: [YourModelServer], profiles: [ConnectionProfile], choosing: Bool) {
        looking = false
        setSpinning(false)
        self.servers = servers
        self.profiles = profiles
        let best = YourModelPick.best(servers)
        if let best, choosing || YourModelPick.replaces(YourModelStore.current(), with: best) {
            choose(best, byHand: false)
        } else if let filed = YourModelStore.current() {
            let candidate = YourModelPick.find(filed, in: servers)
            showFiled(filed, candidate: candidate)
            proveIfFree(candidate)
        }
        renderModels()
        renderGetOne()
        renderAgents()
        renderSuggestion()
        if YourModelStore.current() == nil {
            setHero(title: YourModelWords.noneTitle, subtitle: YourModelWords.noneBody)
        }
        AppLog.write(.ui, "YOUR-MODEL survey servers=\(servers.count) models=\(servers.flatMap(\.models).count) filed=\(YourModelStore.current()?.model ?? "none")")
    }

    private func choose(_ candidate: YourModelCandidate, byHand: Bool) {
        YourModelStore.choose(candidate, byHand: byHand)
        if Preferences.plainWords, Preferences.plainWordsFound || Preferences.plainWordsAddress.isEmpty,
            let filed = YourModelStore.current(), YourModelStore.isPrivate(filed)
        {
            Preferences.setPlainWordsAddress(YourModelStore.plainWordsAddress(filed))
            Preferences.setPlainWordsModel(filed.model)
            Preferences.setPlainWordsFound(label: candidate.label)
            SettingsPlainWords.changed()
            plainWords?.opened()
        }
        showFiled(YourModelStore.current() ?? candidate.helper(chosenByHand: byHand), candidate: candidate)
        renderModels()
        renderAgents()
        renderSuggestion()
        resetSamples()
        proveIfFree(candidate)
    }

    private func renderSuggestion() {
        guard let row = suggestRow?.widget, let button = suggestButton?.widget else { return }
        suggested = YourModelPick.suggestion(for: YourModelStore.current(), in: servers)
        guard let suggested else {
            gtk_widget_set_visible(row, 0)
            return
        }
        adw_preferences_row_set_title(ptr(row), YourModelWords.suggestTitle(suggested))
        gtk_button_set_label(ptr(button), YourModelWords.suggestAction(suggested))
        gtk_widget_set_visible(row, 1)
    }

    /// Asks the model at once when that costs nothing; a model llama-swap would have to load, or one
    /// its server did not list, waits for the person to press.
    private func proveIfFree(_ candidate: YourModelCandidate?) {
        if YourModelPick.asksOnItsOwn(candidate) {
            prove()
            return
        }
        let caution = candidate.flatMap(YourModelWords.caution) ?? YourModelWords.notFoundBody
        setProof(
            title: candidate == nil ? YourModelWords.notFoundTitle : YourModelWords.notLoadedTitle,
            subtitle: caution, busy: false,
            button: candidate == nil ? YourModelWords.proveAgain : YourModelWords.loadAndAsk)
    }

    private func showFiled(_ filed: ImageGenHelper, candidate: YourModelCandidate?) {
        let place = candidate.map(YourModelWords.place) ?? YourModelWords.place(filed)
        var lines = [place]
        if let candidate {
            if let state = YourModelWords.state(candidate) { lines[0] += " · " + state }
            if filed.chosenByHand != true { lines.append(YourModelWords.defaultReason(candidate)) }
        }
        setHero(title: filed.label ?? filed.model, subtitle: lines.joined(separator: "\n"))
        if let row = privacyRow?.widget {
            adw_action_row_set_subtitle(ptr(row), YourModelWords.privacy(filed))
            gtk_widget_set_visible(row, 1)
        }
        if let toggle = studioSwitch?.widget {
            adw_switch_row_set_active(OpaquePointer(toggle), filed.enabled ? 1 : 0)
        }
    }

    func prove() {
        guard !proving, let filed = YourModelStore.current() else { return }
        proving = true
        generation += 1
        let mine = generation
        setProof(title: YourModelWords.proving(filed.label ?? filed.model), subtitle: "", busy: true)
        Task { [weak self] in
            do {
                let proof = try await YourModelProving.prove(filed) { [weak self] text in
                    Gtk.onMain { [weak self] in
                        guard let self, self.generation == mine else { return }
                        self.setProof(title: YourModelWords.proving(filed.label ?? filed.model), subtitle: "“" + text + "”", busy: true)
                    }
                }
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.proving = false
                    guard self.generation == mine else { return }
                    self.setProof(title: proof.line, subtitle: "“" + proof.text + "”", busy: false)
                    AppLog.write(.ui, "YOUR-MODEL proof \(filed.model) first=\(proof.firstWord) rate=\(proof.perSecond ?? -1)")
                }
            } catch {
                let reason = (error as? ImageGenEnhancer.Failure)?.reason ?? error.localizedDescription
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.proving = false
                    guard self.generation == mine else { return }
                    self.setProof(title: YourModelWords.provingFailed(reason), subtitle: "", busy: false)
                }
            }
        }
    }

    private func renderModels() {
        guard let group = modelsGroup?.widget else { return }
        for row in modelRows.compactMap(\.widget) { adw_preferences_group_remove(ptr(group), ptr(row)) }
        modelRows = []
        let filed = YourModelStore.current()
        let total = servers.flatMap(\.models).count
        adw_preferences_group_set_description(ptr(group), total == 0 ? nil : YourModelWords.found(models: total, servers: servers.count))
        gtk_widget_set_visible(group, total == 0 ? 0 : 1)
        for server in servers {
            let expander = adw_expander_row_new()!
            adw_preferences_row_set_use_markup(ptr(expander), 0)
            adw_preferences_row_set_title(ptr(expander), server.heading)
            adw_expander_row_set_subtitle(ptr(expander), Localized.text("%@ · %d models", server.address, server.models.count))
            let holdsFiled = server.models.contains { $0.address == filed?.address && $0.model == filed?.model }
            let opens = server.models.count <= 6 && (holdsFiled || servers.count == 1)
            adw_expander_row_set_expanded(ptr(expander), opens ? 1 : 0)
            for candidate in YourModelPick.ranked([server]) {
                let row = Self.row(title: candidate.label, subtitle: YourModelWords.detail(candidate))
                let isFiled = candidate.address == filed?.address && candidate.model == filed?.model
                let mark = Gtk.label(isFiled ? "✓" : "", css: "accent", wrap: false, selectable: false)
                gtk_widget_set_valign(mark, GTK_ALIGN_CENTER)
                adw_action_row_add_suffix(ptr(row), mark)
                gtk_list_box_row_set_activatable(ptr(UnsafeMutableRawPointer(row)), 1)
                Gtk.connect(UnsafeMutableRawPointer(row), "activated") { [weak self] in
                    Gtk.onMain { [weak self] in self?.choose(candidate, byHand: true) }
                }
                adw_expander_row_add_row(ptr(expander), row)
            }
            SettingsRows.add(expander, to: group)
            modelRows.append(Gtk.WeakWidget(expander))
        }
    }

    private func renderAgents() {
        guard let row = agentsRow?.widget, let button = carryButton?.widget else { return }
        guard let filed = YourModelStore.current() else {
            adw_action_row_set_subtitle(ptr(row), YourModelWords.agentsNone)
            gtk_widget_set_visible(button, 0)
            return
        }
        adw_preferences_row_set_title(ptr(row), filed.label ?? filed.model)
        let offers = YourModelAgents.offers(of: filed.model, profiles: profiles)
        guard let first = offers.first else {
            adw_action_row_set_subtitle(ptr(row), YourModelWords.agentsNone)
            gtk_widget_set_visible(button, 0)
            return
        }
        adw_action_row_set_subtitle(ptr(row), YourModelWords.agentsOffer(offers.map(\.said)))
        let carried = YourModelAgents.isCarried(first)
        gtk_button_set_label(ptr(button), carried ? YourModelWords.carried : YourModelWords.carry)
        gtk_widget_set_sensitive(button, carried ? 0 : 1)
        gtk_widget_set_visible(button, 1)
    }

    private func carry() {
        guard let filed = YourModelStore.current(),
            let offer = YourModelAgents.offers(of: filed.model, profiles: profiles).first,
            let row = agentsRow?.widget
        else { return }
        if YourModelAgents.carry(offer, name: filed.label) == .full {
            adw_action_row_set_subtitle(ptr(row), YourModelWords.partyFull)
            return
        }
        renderAgents()
    }

    private func renderGetOne() {
        guard let group = getOneGroup?.widget else { return }
        for row in getOneRows.compactMap(\.widget) { adw_preferences_group_remove(ptr(group), ptr(row)) }
        getOneRows = []
        let none = servers.isEmpty && YourModelStore.current() == nil
        gtk_widget_set_visible(group, none ? 1 : 0)
        guard none else { return }
        for profile in profiles.prefix(4) {
            let row = SettingsRows.buttonRow(
                profile.name, subtitle: YourModelWords.getOneBody(profile.name), label: YourModelWords.getOneAction
            ) {
                SettingsYourModelPage.askAgent?(profile, YourModelGetOne.brief)
            }
            adw_preferences_row_set_use_markup(ptr(row), 0)
            adw_action_row_set_subtitle_lines(ptr(row), 0)
            SettingsRows.add(row, to: group)
            getOneRows.append(Gtk.WeakWidget(row))
        }
    }

    private func showStudioSample() {
        guard let filed = YourModelStore.current(), let row = studioSample?.widget else { return }
        adw_action_row_set_subtitle(ptr(row), YourModelWords.itWrites + ": …")
        let enhancer = ImageGenEnhancer(helper: filed)
        let ask = ImageGenRewriteAsk(brief: YourModelWords.sampleBrief, context: ImageGenRewriteContext())
        let weakRow = Gtk.WeakWidget(row)
        Task {
            do {
                let read = try await enhancer.stream(ask) { text in
                    Gtk.onMain {
                        guard let row = weakRow.widget else { return }
                        adw_action_row_set_subtitle(ptr(row), YourModelWords.itWrites + ": " + YourModelWords.excerpt(text))
                    }
                }
                Gtk.onMain {
                    guard let row = weakRow.widget else { return }
                    adw_action_row_set_subtitle(ptr(row), YourModelWords.itWrites + ": " + YourModelWords.excerpt(read.prompt))
                }
            } catch {
                let reason = (error as? ImageGenEnhancer.Failure)?.reason ?? error.localizedDescription
                Gtk.onMain {
                    guard let row = weakRow.widget else { return }
                    adw_action_row_set_subtitle(ptr(row), YourModelWords.provingFailed(reason))
                }
            }
        }
    }

    private func showWallSample() {
        guard let filed = YourModelStore.current(), let row = wallSample?.widget,
            let url = URL(string: YourModelStore.plainWordsAddress(filed) + "/chat/completions")
        else { return }
        adw_action_row_set_subtitle(ptr(row), YourModelWords.itSays + ": …")
        let weakRow = Gtk.WeakWidget(row)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = PlainModel.request(model: filed.model, raw: YourModelWords.sampleCommand)
        Task {
            let data = try? await URLSession.shared.data(for: request).0
            let line = data.flatMap(PlainModel.reply(from:))
            Gtk.onMain {
                guard let row = weakRow.widget else { return }
                adw_action_row_set_subtitle(
                    ptr(row),
                    line.map { YourModelWords.itSays + ": ✦ " + $0 }
                        ?? YourModelWords.provingFailed(Localized.text("no plain line came back")))
            }
        }
    }

    private func resetSamples() {
        if let row = studioSample?.widget { adw_action_row_set_subtitle(ptr(row), "") }
        if let row = wallSample?.widget { adw_action_row_set_subtitle(ptr(row), "") }
    }

    private func setHero(title: String, subtitle: String) {
        guard let row = hero?.widget else { return }
        adw_preferences_row_set_title(ptr(row), title)
        adw_action_row_set_subtitle(ptr(row), subtitle)
    }

    private func setSpinning(_ on: Bool) {
        if let spinner = spinner?.widget {
            gtk_widget_set_visible(spinner, on ? 1 : 0)
            if on { gtk_spinner_start(op(spinner)) } else { gtk_spinner_stop(op(spinner)) }
        }
        if let button = lookButton?.widget { gtk_widget_set_visible(button, on ? 0 : 1) }
    }

    private func setProof(title: String, subtitle: String, busy: Bool, button label: String = YourModelWords.proveAgain) {
        guard let row = proofRow?.widget else { return }
        adw_preferences_row_set_title(ptr(row), title)
        adw_action_row_set_subtitle(ptr(row), subtitle)
        gtk_widget_set_visible(row, 1)
        if let button = proofButton?.widget {
            gtk_widget_set_sensitive(button, busy ? 0 : 1)
            gtk_button_set_label(ptr(button), label)
        }
    }

    static func row(title: String, subtitle: String) -> UnsafeMutablePointer<GtkWidget> {
        let row = adw_action_row_new()!
        adw_preferences_row_set_use_markup(ptr(row), 0)
        adw_preferences_row_set_title(ptr(row), title)
        adw_action_row_set_subtitle(ptr(row), subtitle)
        adw_action_row_set_subtitle_lines(ptr(row), 0)
        return row
    }

    static func sampleRow(title: String, onShow: @escaping @Sendable () -> Void) -> UnsafeMutablePointer<GtkWidget> {
        let row = Self.row(title: title, subtitle: "")
        let button = Gtk.button(YourModelWords.showMe, css: ["flat"], onClick: onShow)
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        adw_action_row_add_suffix(ptr(row), button)
        return row
    }
}
