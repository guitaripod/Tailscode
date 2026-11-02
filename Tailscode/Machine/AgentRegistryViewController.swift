import CodingAgentKit
import CodingAgentKitApple
import MidgarCore
import TailscodeCore
import UIKit

/// The ACP registry as this machine can run it: every agent with its maker, how it is run, its
/// version, and one press that installs it on the machine — never on this device.
@MainActor
final class AgentRegistryViewController: UIViewController, UISearchResultsUpdating {
    private let profile: ConnectionProfile
    private let hosting: any MachineAgentHosting
    private var agents: [RegistryAgent] = []
    private var installing: Set<String> = []
    private var query = ""
    private var column: UIStackView!
    private var scroll: UIScrollView!
    private var loaded = false
    var onChange: (() -> Void)?

    init(profile: ConnectionProfile, hosting: any MachineAgentHosting) {
        self.profile = profile
        self.hosting = hosting
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = Localized.text("More agents")
        navigationItem.largeTitleDisplayMode = .never
        (scroll, column) = MachinePage.install(in: self)
        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = MachineAgentReading.searchRegistry
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        render()
        Task { await load() }
    }

    func updateSearchResults(for searchController: UISearchController) {
        query = searchController.searchBar.text?.trimmingCharacters(in: .whitespaces) ?? ""
        render()
    }

    private func load() async {
        agents = (try? await hosting.agentRegistry()) ?? []
        loaded = true
        render()
    }

    private func render() {
        MachinePage.clear(column)
        guard loaded else {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            column.addArrangedSubview(spinner)
            return
        }
        let shown = agents.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                || ($0.description ?? "").localizedCaseInsensitiveContains(query)
        }
        guard !shown.isEmpty else {
            column.addArrangedSubview(
                MachinePage.footnote(
                    agents.isEmpty
                        ? Localized.text("The registry did not answer from %@.", profile.name)
                        : Localized.text("No agent matches.")))
            return
        }
        let card = MachineCardView()
        for agent in shown {
            let words = MachineAgentReading.registryRow(agent, machine: profile.name)
            let row = MachineRowView(
                title: words.title, detail: words.subtitle,
                image: AgentMark.image(
                    initial: String(agent.name.prefix(1)).uppercased(),
                    color: AgentMark.color(for: agent.id, isBuiltIn: false)))
            if installing.contains(agent.id) {
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.startAnimating()
                row.trail(spinner)
            } else if let press = words.press {
                let pill = MachinePage.pill(press) { [weak self] in self?.install(agent) }
                pill.isEnabled = words.enabled
                if !words.enabled {
                    pill.configuration?.baseForegroundColor =
                        agent.here == nil ? Theme.Color.secondaryLabel : Theme.Color.success
                }
                row.trail(pill)
            }
            card.add(row)
        }
        column.addArrangedSubview(card)
        column.addArrangedSubview(MachinePage.footnote(MachineAgentReading.registryNote))
    }

    private func install(_ agent: RegistryAgent) {
        installing.insert(agent.id)
        render()
        let hosting = self.hosting
        Task { [weak self] in
            do {
                let added = try await hosting.installAgent(agent.id)
                guard let self else { return }
                self.installing.remove(agent.id)
                Theme.Haptics.success()
                MidgarLog.info("installed \(agent.id) on \(self.profile.name)", category: .connection)
                await self.load()
                self.onChange?()
                MachineDesk.shared.refresh(force: true)
                let card = AgentCardViewController(
                    profile: self.profile, hosting: hosting, agent: added,
                    report: try? await hosting.machineAgents(refreshBrains: false))
                card.onChange = self.onChange
                self.navigationController?.pushViewController(card, animated: true)
            } catch {
                guard let self else { return }
                self.installing.remove(agent.id)
                self.render()
                let alert = UIAlertController(
                    title: Localized.text("%@ was not installed", agent.name),
                    message: AgentCardViewController.words(error), preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: Localized.text("OK"), style: .default))
                self.present(alert, animated: true)
            }
        }
    }
}
