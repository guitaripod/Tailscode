import CodingAgentKit
import CodingAgentKitApple
import MidgarCore
import TailscodeCore
import UIKit

/// What every machine keeps besides conversations — the schedules it asks and the agents it found
/// that nobody has been told about — read together for Home's line, the nudge and the Scheduled
/// screen. Read on Home's own refresh and after any change made here, never on a clock of its own.
@MainActor
final class MachineDesk {
    static let shared = MachineDesk()
    static let didChange = Notification.Name("tailscode.machineDesk.didChange")

    private(set) var board = ScheduleBoard.empty
    private(set) var news: [(profile: ConnectionProfile, agents: [MachineAgent])] = []
    private var loadedAt: Date?
    private var loading: Task<Void, Never>?

    private init() {}

    func backend(for profile: ConnectionProfile) -> (any CodingAgentBackend)? {
        ConnectionController.shared.makeBackend(for: profile)
    }

    func backend(forProfileID id: String) -> (any CodingAgentBackend)? {
        profile(id).flatMap(backend(for:))
    }

    func profile(_ id: String) -> ConnectionProfile? {
        ConnectionController.shared.profiles.first { $0.id == id }
    }

    func refresh(force: Bool = false) {
        guard loading == nil else { return }
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < 30 { return }
        loading = Task { [weak self] in
            guard let self else { return }
            let servers = ConnectionController.shared.profiles.compactMap { profile in
                self.backend(for: profile).map { (profile: profile, backend: $0) }
            }
            let board = await ScheduleBoard.load(servers)
            var news: [(profile: ConnectionProfile, agents: [MachineAgent])] = []
            for server in servers {
                guard let hosting = server.backend as? any MachineAgentHosting,
                    let report = try? await hosting.machineAgents(refreshBrains: false)
                else { continue }
                let unseen = AgentNewsStore.unseen(report, profileID: server.profile.id)
                if !unseen.isEmpty { news.append((server.profile, unseen)) }
            }
            self.board = board
            self.news = news
            self.loadedAt = Date()
            self.loading = nil
            MidgarLog.info(
                "machine desk: \(board.rows.count) schedules, \(news.count) machines with news", category: .session)
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    /// The news Home says once: the first machine with agents nobody has been told about.
    var headline: (title: String, detail: String)? {
        MachineAgentReading.news(news.map { (machine: $0.profile.name, agents: $0.agents) })
    }

    /// Adds every agent the news names and says nothing about them again.
    func addNews() {
        guard let first = news.first, let hosting = backend(for: first.profile) as? any MachineAgentHosting
        else { return }
        AgentNewsStore.markSeen(first.agents, profileID: first.profile.id)
        news.removeFirst()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        Task { [weak self] in
            for agent in first.agents { _ = try? await hosting.addAgent(agent.id) }
            self?.refresh(force: true)
        }
    }

    func dismissNews() {
        guard let first = news.first else { return }
        AgentNewsStore.markSeen(first.agents, profileID: first.profile.id)
        news.removeFirst()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// The model as the machine names it on the wire: an agent's model carries its agent, which
    /// the catalog knows even before the backend has heard its own status.
    static func wireModel(
        _ selection: ModelSelection?, profileID: String, backend: any CodingAgentBackend
    ) -> String? {
        guard let selection else { return nil }
        let catalog = ModelCatalogStore.cached(profileID)
        if catalog.contains(where: {
            $0.agentName != nil && $0.id == selection.modelID && $0.providerID == selection.providerID
        }) {
            return "\(selection.providerID)/\(selection.modelID)"
        }
        return QuickAskLaterHandoff.wireModel(selection, backend: backend)
    }

    /// Whether the machine keeps schedules, asked of the machine rather than guessed.
    static func keepsSchedules(_ backend: any CodingAgentBackend) async -> Bool {
        if backend.capabilities.supportsSchedules { return true }
        guard let scheduling = backend as? any MachineScheduling else { return false }
        return (try? await scheduling.machineSchedules()) != nil
    }
}

/// The few things a screen about a machine needs to reach in the rest of the app: a conversation
/// by its id, and Home's composer aimed at a model.
@MainActor
enum MachineRouter {
    static var home: HomeViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            for window in scene.windows {
                if let workspace = window.rootViewController as? WorkspaceSplitViewController {
                    return workspace.home
                }
            }
        }
        return nil
    }

    /// Closes whatever this screen sits in and opens the conversation.
    static func openChat(sessionID: String, from presenter: UIViewController) {
        Theme.Haptics.tap()
        let open: () -> Void = { home?.openSession(withID: sessionID) }
        if let root = presenter.presentingViewController {
            root.dismiss(animated: true, completion: open)
        } else {
            open()
        }
    }

    /// Opens Home's composer aimed at a model on a machine: the first chat with an agent starts
    /// there, the same road the chooser's "new chat there" takes.
    static func compose(
        profile: ConnectionProfile, selection: ModelSelection, modelName: String,
        from presenter: UIViewController
    ) {
        let pick = ModelPick(
            profileID: profile.id, selection: selection, isElsewhere: true, serverName: profile.name,
            modelName: modelName)
        let aim = {
            guard let home else { return ModelFleet.adopt(pick) }
            if let workspace = home.workspace {
                workspace.showHome()
            } else {
                home.navigationController?.popToRootViewController(animated: false)
            }
            home.aimCompose(at: profile.id, carrying: pick)
        }
        if let root = presenter.presentingViewController {
            root.dismiss(animated: true, completion: aim)
        } else {
            presenter.navigationController?.popToRootViewController(animated: false)
            aim()
        }
    }
}

/// The mark an agent wears in a list: its initial on a tile of its own colour, so a row of agents
/// reads at a glance without anyone's logo.
enum AgentMark {
    static func color(for id: String, isBuiltIn: Bool) -> UIColor {
        if isBuiltIn { return Theme.Color.modelFamily(ModelTint.family("claude-opus", providerID: "anthropic")) }
        switch id {
        case "hermes": return Theme.Color.warning
        case "gemini": return Theme.Color.info
        case "codex-acp": return Theme.Color.success
        case "goose", "kimi": return Theme.Color.secondaryLabel
        default:
            let palette = [Theme.Color.accent, Theme.Color.special, Theme.Color.info, Theme.Color.warning]
            let sum = id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
            return palette[sum % palette.count]
        }
    }

    static func image(initial: String, color: UIColor, side: CGFloat = 30) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        return renderer.image { _ in
            let rect = CGRect(x: 0, y: 0, width: side, height: side)
            color.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: side * 0.26).fill()
            let font = UIFont.systemFont(ofSize: side * 0.5, weight: .bold)
            let text = NSAttributedString(
                string: initial, attributes: [.font: font, .foregroundColor: UIColor.white])
            let size = text.size()
            text.draw(at: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2))
        }.withRenderingMode(.alwaysOriginal)
    }

    static func image(for row: AgentRowReading) -> UIImage {
        image(initial: row.initial, color: color(for: row.id, isBuiltIn: row.isBuiltIn))
    }

    static func tone(_ tone: AgentTone) -> UIColor {
        switch tone {
        case .ready: return Theme.Color.success
        case .attention: return Theme.Color.warning
        case .working: return Theme.Color.accent
        case .neutral: return Theme.Color.secondaryLabel
        case .failed: return Theme.Color.danger
        }
    }
}

/// How a schedule's mark is drawn here.
extension ScheduleMark {
    var color: UIColor {
        switch self {
        case .answered: return Theme.Color.success
        case .failed: return Theme.Color.danger
        case .caughtUp, .missed: return Theme.Color.warning
        case .running, .waiting: return Theme.Color.accent
        case .quiet, .paused, .done: return Theme.Color.tertiaryLabel
        }
    }
}
