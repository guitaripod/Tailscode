import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore
import UIKit

extension ServerDetailViewController {
    /// The agents this machine hosts and the schedules it keeps, asked of the machine itself: one
    /// that has neither answers with nothing, and shows neither section.
    func loadMachine(from backend: any CodingAgentBackend) async {
        if let hosting = backend as? any MachineAgentHosting {
            agentsReport = try? await hosting.machineAgents(refreshBrains: false)
            if agentsReport != nil {
                registryCount = (try? await hosting.agentRegistry())?.count
            }
        } else {
            agentsReport = nil
        }
        if let scheduling = backend as? any MachineScheduling {
            schedulesHere = try? await scheduling.machineSchedules()
        } else {
            schedulesHere = nil
        }
        #if DEBUG
            openMachineForVerification()
        #endif
    }

    var agentRows: [AgentRowReading] {
        MachineAgentReading.rows(
            agentsReport, machine: profile.name, builtIn: profile.backend == .claudeCode ? .claudeCode : nil)
    }

    var agentItems: [Item] {
        agentRows.map { .agent($0.id) } + [.moreAgents]
    }

    func configureAgent(_ content: inout UIListContentConfiguration, cell: UICollectionViewListCell, id: String) {
        guard let row = agentRows.first(where: { $0.id == id }) else { return }
        content.text = row.title
        content.secondaryText = row.isBuiltIn
            ? (auth?.accountLabel.map { Localized.text("Built in · signed in as %@", $0) } ?? row.subtitle)
            : row.subtitle
        content.secondaryTextProperties.color =
            row.tone == .neutral ? Theme.Color.secondaryLabel : AgentMark.tone(row.tone)
        content.secondaryTextProperties.numberOfLines = 0
        content.image = AgentMark.image(for: row)
        if let press = row.press, let title = row.pressTitle {
            let button = MachinePage.pill(title) { [weak self] in self?.press(press, agent: id) }
            cell.accessories = [.customView(configuration: .init(customView: button, placement: .trailing()))]
        } else if !row.isBuiltIn {
            cell.accessories = [.disclosureIndicator()]
        }
    }

    func configureScheduled(_ content: inout UIListContentConfiguration) {
        let schedules = schedulesHere ?? []
        content.image = UIImage(systemName: "clock")
        content.imageProperties.tintColor = Theme.Color.accent
        guard !schedules.isEmpty else {
            content.text = ScheduleWords.empty
            content.secondaryText = ScheduleWords.reach(profile.name)
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.secondaryTextProperties.numberOfLines = 0
            return
        }
        content.text = Localized.text("%d scheduled", schedules.count)
        let board = ScheduleBoard.make(
            [ScheduleBoard.Source(profileID: profile.id, machine: profile.name, schedules: schedules)])
        if let next = board.next, let date = next.schedule.next {
            content.secondaryText = Localized.text(
                "Next: \u{201C}%@\u{201D} %@", next.title,
                ScheduleWords.moment(date, calendar: ScheduleDetailViewController.calendar(next.schedule)))
        }
        content.secondaryTextProperties.color = Theme.Color.secondaryLabel
    }

    private var hosting: (any MachineAgentHosting)? { backend as? any MachineAgentHosting }

    private func press(_ press: AgentPress, agent id: String) {
        guard press == .add, let hosting else { return openAgent(id) }
        Theme.Haptics.tap()
        Task { [weak self] in
            _ = try? await hosting.addAgent(id)
            await self?.reloadAgents()
            self?.openAgent(id)
        }
    }

    func reloadAgents() async {
        guard let hosting else { return }
        agentsReport = try? await hosting.machineAgents(refreshBrains: false)
        applySnapshot()
        reconfigure(agentItems)
    }

    func openAgent(_ id: String) {
        guard let hosting, let agent = agentsReport?.agents.first(where: { $0.id == id }) else { return }
        Theme.Haptics.tap()
        let card = AgentCardViewController(profile: profile, hosting: hosting, agent: agent, report: agentsReport)
        card.onChange = { [weak self] in Task { await self?.reloadAgents() } }
        navigationController?.pushViewController(card, animated: true)
    }

    func openRegistry() {
        guard let hosting else { return }
        Theme.Haptics.tap()
        let registry = AgentRegistryViewController(profile: profile, hosting: hosting)
        registry.onChange = { [weak self] in Task { await self?.reloadAgents() } }
        navigationController?.pushViewController(registry, animated: true)
    }

    #if DEBUG
        /// Puts the Agents section, an agent's card or the registry on screen at launch, so each
        /// can be photographed in the demo without a hand.
        private static var openedForVerification = false

        private func openMachineForVerification() {
            let environment = ProcessInfo.processInfo.environment
            guard !Self.openedForVerification, agentsReport != nil,
                navigationController?.topViewController === self
            else { return }
            Self.openedForVerification = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(0.4))
                guard let self else { return }
                if let id = environment["TAILSCODE_OPEN_AGENT"] {
                    self.openAgent(id)
                } else if environment["TAILSCODE_OPEN_MORE_AGENTS"] != nil {
                    self.openRegistry()
                } else if environment["TAILSCODE_OPEN_MACHINE_AGENTS"] != nil,
                    let first = self.agentItems.first, let indexPath = self.dataSource.indexPath(for: first)
                {
                    self.collectionView.scrollToItem(at: indexPath, at: .top, animated: false)
                    self.collectionView.contentOffset.y -= 44
                }
            }
        }
    #endif
}
