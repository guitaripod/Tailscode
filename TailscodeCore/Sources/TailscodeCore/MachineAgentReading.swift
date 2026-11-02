import CodingAgentKit
import CodingAgentKitApple
import Foundation

/// What a press on an agent does. A client maps each to its own control; the words come with it.
public enum AgentPress: Sendable, Hashable {
    case add
    case open
    case install
    case giveBrain
    case enterKey(env: String)
    case signIn(method: String)
    case check
    case startChat
    case remove
}

/// The tone a row or step wears, which each client draws in its own colours.
public enum AgentTone: String, Sendable, Hashable {
    case ready, attention, working, neutral, failed
}

/// One agent as the machine's Agents section lists it.
public struct AgentRowReading: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let tone: AgentTone
    /// The trailing button, when the row's next step is one press; nil opens the card.
    public let press: AgentPress?
    public let pressTitle: String?
    /// The agent's initial, for a mark when no icon is drawn.
    public let initial: String
    public let isBuiltIn: Bool
}

/// One row of the card's checklist.
public struct AgentSetupStep: Sendable, Hashable, Identifiable {
    public enum State: String, Sendable, Hashable { case done, next, waiting, failed, working }

    public let id: String
    public let title: String
    public let detail: String
    public let state: State
    public let press: AgentPress?
    public let pressTitle: String?
}

/// A brain an agent could think with, as the card lists it.
public struct BrainOption: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let choice: AgentBrainChoice?
    /// A provider reached with a key, which the card asks for before it can be chosen.
    public let keyProvider: String?
}

/// Everything a client draws about the agents a machine runs. Words are written here, facts come
/// from the machine (`MachineAgent`), and no client invents a sentence.
public enum MachineAgentReading {
    public static var section: String { Localized.text("Agents") }
    public static var moreAgents: String { Localized.text("More agents…") }
    public static var permissionNote: String {
        Localized.text("Agents on this machine say yes to their own permission questions, as Claude Code does, so a turn never waits on your device.")
    }
    public static var searchRegistry: String { Localized.text("Search agents") }
    public static var registryNote: String {
        Localized.text("From the ACP registry. Downloads are checked against the registry's checksum and run on the machine, not on this device.")
    }
    public static var keyPlaceholder: String { Localized.text("Paste the key") }
    public static var keyNote: String { Localized.text("Kept on the machine, readable only by its user. It never comes back to this device.") }
    public static var signInInputPlaceholder: String { Localized.text("Type what it asks for") }
    public static var removeTitle: String { Localized.text("Remove from this machine") }

    public static func moreAgentsDetail(_ count: Int) -> String {
        Localized.text("%d in the ACP registry", count)
    }

    /// The machine's own agent first, then every other one it knows.
    public static func rows(_ report: MachineAgentsReport?, machine: String, builtIn: AgentType?) -> [AgentRowReading] {
        var rows: [AgentRowReading] = []
        if let builtIn {
            rows.append(
                AgentRowReading(
                    id: "·builtin", title: builtIn.displayName, subtitle: Localized.text("Built in"),
                    tone: .ready, press: nil, pressTitle: nil, initial: initial(builtIn.displayName),
                    isBuiltIn: true))
        }
        for agent in report?.agents ?? [] { rows.append(row(agent, machine: machine)) }
        return rows
    }

    public static func row(_ agent: MachineAgent, machine: String) -> AgentRowReading {
        let (subtitle, tone) = state(agent, machine: machine)
        var press: AgentPress?
        var pressTitle: String?
        if !agent.added, agent.state == .notAdded {
            press = .add
            pressTitle = Localized.text("Add")
        }
        return AgentRowReading(
            id: agent.id, title: agent.name, subtitle: subtitle, tone: tone, press: press,
            pressTitle: pressTitle, initial: initial(agent.name), isBuiltIn: false)
    }

    /// The agent's state in a few words, and the tone they wear.
    public static func state(_ agent: MachineAgent, machine: String) -> (String, AgentTone) {
        switch agent.state {
        case .ready:
            if let brain = agent.brain {
                if brain.kind == "local", let model = agent.models.first(where: {
                    $0.id == agent.currentModel || $0.id == "custom:\(brain.model ?? "")"
                }) {
                    return (Localized.text("Ready · thinks with %@ on %@", model.name, machine), .ready)
                }
                return (Localized.text("Ready · thinks with %@", brain.name), .ready)
            }
            let count = agent.models.count
            return (
                count > 1 ? Localized.text("Ready · %d models", count) : Localized.text("Ready"), .ready
            )
        case .checking: return (Localized.text("Checking…"), .working)
        case .installing: return (Localized.text("Installing…"), .working)
        case .notAdded:
            switch agent.source {
            case "found":
                return (
                    agent.version.map { Localized.text("Found on %@ · %@", machine, $0) }
                        ?? Localized.text("Found on %@", machine), .neutral)
            case "installed": return (Localized.text("Installed on %@", machine), .neutral)
            default: return (Localized.text("Runs on %@ with %@", machine, agent.distribution ?? "uvx"), .neutral)
            }
        case .needsBrain: return (Localized.text("Needs a brain"), .attention)
        case .needsKey: return (Localized.text("Needs a key"), .attention)
        case .needsSignIn: return (Localized.text("Needs sign-in"), .attention)
        case .missingRuntime:
            return (Localized.text("Needs %@ on %@", runtimeName(agent.runtime), machine), .attention)
        case .failed: return (Localized.text("Did not answer"), .failed)
        }
    }

    static func runtimeName(_ runtime: String?) -> String {
        switch runtime {
        case "node": return "Node.js"
        case "uv": return "uv"
        default: return runtime ?? Localized.text("a runtime")
        }
    }

    static func initial(_ name: String) -> String {
        name.first.map { String($0).uppercased() } ?? "?"
    }

    /// The card's checklist, in the order a machine proves an agent: on the machine, a brain when
    /// it needs one, a key or a sign-in when it asks, and the real session that proves it answers.
    public static func steps(_ agent: MachineAgent, machine: String, now: Date = Date()) -> [AgentSetupStep] {
        var steps: [AgentSetupStep] = []
        let onMachineDone = agent.state != .missingRuntime && agent.state != .installing
        steps.append(
            AgentSetupStep(
                id: "machine", title: Localized.text("On %@", machine),
                detail: onMachineDetail(agent, machine: machine),
                state: agent.state == .installing ? .working : (onMachineDone ? .done : .failed),
                press: agent.state == .missingRuntime ? .check : nil,
                pressTitle: agent.state == .missingRuntime ? Localized.text("Check again") : nil))
        if agent.brainStyle != nil {
            let has = agent.brain != nil || agent.state == .ready
            steps.append(
                AgentSetupStep(
                    id: "brain", title: Localized.text("A brain"),
                    detail: agent.brain.map { brainDetail($0, agent: agent) }
                        ?? Localized.text("%@ needs a model to think with.", agent.name),
                    state: has ? .done : (agent.state == .needsBrain ? .next : .waiting),
                    press: has ? nil : .giveBrain, pressTitle: has ? nil : Localized.text("Choose")))
        }
        for key in agent.keys {
            steps.append(
                AgentSetupStep(
                    id: "key·\(key.env)", title: key.name,
                    detail: key.set
                        ? Localized.text("Kept on %@", machine)
                        : Localized.text("%@ reads it as %@.", agent.name, key.env),
                    state: key.set ? .done : (agent.state == .needsKey ? .next : .waiting),
                    press: key.set ? nil : .enterKey(env: key.env),
                    pressTitle: key.set ? nil : Localized.text("Paste")))
        }
        if agent.state == .needsSignIn, let method = agent.signIn.first(where: { $0.kind == "terminal" }) ?? agent.signIn.first {
            steps.append(
                AgentSetupStep(
                    id: "signin", title: Localized.text("Signed in"),
                    detail: method.description ?? method.name, state: .next,
                    press: .signIn(method: method.id), pressTitle: Localized.text("Sign in")))
        }
        steps.append(answered(agent, machine: machine, now: now))
        return steps
    }

    private static func onMachineDetail(_ agent: MachineAgent, machine: String) -> String {
        if agent.state == .missingRuntime {
            return Localized.text("%@ runs with %@, which is not installed on %@.", agent.name, runtimeName(agent.runtime), machine)
        }
        let version = agent.version.map { " " + $0 } ?? ""
        switch agent.source {
        case "found": return Localized.text("%@%@, already on this machine", agent.name, version)
        case "installed": return Localized.text("%@%@, installed from the registry", agent.name, version)
        default: return Localized.text("%@%@, run with %@", agent.name, version, agent.distribution ?? "uvx")
        }
    }

    private static func brainDetail(_ brain: MachineAgent.Brain, agent: MachineAgent) -> String {
        if brain.kind == "local" {
            let model = agent.models.first { $0.id == agent.currentModel }?.name ?? brain.model ?? ""
            return Localized.text("%@ on %@", model, brain.name)
        }
        return Localized.text("%@, with its key kept on the machine", brain.name)
    }

    private static func answered(_ agent: MachineAgent, machine: String, now: Date) -> AgentSetupStep {
        switch agent.state {
        case .ready:
            let count = agent.models.count
            let models = count > 1 ? Localized.text("It offered %d models.", count) : Localized.text("It answered.")
            return AgentSetupStep(
                id: "answered", title: Localized.text("Answered"),
                detail: models + " " + Localized.text("It is in the model pill now."), state: .done,
                press: .startChat, pressTitle: Localized.text("Start a chat with %@", agent.name))
        case .checking:
            return AgentSetupStep(
                id: "answered", title: Localized.text("Answered"),
                detail: Localized.text("%@ is opening a real chat with it…", machine), state: .working,
                press: nil, pressTitle: nil)
        case .failed:
            return AgentSetupStep(
                id: "answered", title: Localized.text("Answered"),
                detail: agent.failure.map { Localized.text("It said: %@", $0) } ?? Localized.text("It did not answer."),
                state: .failed, press: .check, pressTitle: Localized.text("Try again"))
        case .notAdded:
            return AgentSetupStep(
                id: "answered", title: Localized.text("Answered"),
                detail: Localized.text("%@ opens a real chat with it to prove it works.", machine),
                state: .waiting, press: .add, pressTitle: Localized.text("Add to %@", machine))
        default:
            return AgentSetupStep(
                id: "answered", title: Localized.text("Answered"),
                detail: Localized.text("%@ opens a real chat with it to prove it works.", machine),
                state: .waiting, press: nil, pressTitle: nil)
        }
    }

    /// The brains the card offers: every model a server on the machine runs, then the providers
    /// a key would open.
    public static func brains(_ report: MachineAgentsReport?, for agent: MachineAgent, machine: String) -> [BrainOption] {
        var options: [BrainOption] = []
        for server in report?.brains ?? [] {
            for model in server.models {
                options.append(
                    BrainOption(
                        id: "\(server.id)·\(model.id)", title: model.name,
                        detail: Localized.text("%@ · this machine", server.name),
                        choice: .local(brain: server.id, model: model.id), keyProvider: nil))
            }
        }
        if agent.brainStyle == "hermes" {
            for provider in [("openrouter", "OpenRouter"), ("anthropic", "Anthropic"), ("deepseek", "DeepSeek"), ("xai", "xAI")] {
                options.append(
                    BrainOption(
                        id: "key·\(provider.0)", title: Localized.text("%@ key…", provider.1),
                        detail: Localized.text("kept on %@", machine), choice: nil, keyProvider: provider.0))
            }
        }
        return options
    }

    /// The press the card leads with, worded.
    public static func primary(_ agent: MachineAgent, brains: [BrainOption], machine: String) -> (AgentPress, String)? {
        switch agent.state {
        case .notAdded: return (.add, Localized.text("Add to %@", machine))
        case .needsBrain:
            guard let first = brains.first(where: { $0.choice != nil }) else { return nil }
            return (.giveBrain, Localized.text("Think with %@", first.title))
        case .needsKey:
            guard let key = agent.keys.first(where: { !$0.set }) else { return nil }
            return (.enterKey(env: key.env), Localized.text("Paste a %@", key.name))
        case .needsSignIn:
            guard let method = agent.signIn.first(where: { $0.kind == "terminal" }) ?? agent.signIn.first else { return nil }
            return (.signIn(method: method.id), Localized.text("Sign in to %@", agent.name))
        case .ready: return (.startChat, Localized.text("Start a chat with %@", agent.name))
        case .failed, .missingRuntime: return (.check, Localized.text("Try again"))
        case .checking, .installing: return nil
        }
    }

    /// One registry agent as "More agents" lists it.
    public static func registryRow(_ agent: RegistryAgent, machine: String) -> (title: String, subtitle: String, press: String?, enabled: Bool) {
        var facts: [String] = []
        if let author = agent.authors?.first { facts.append(author) }
        if let distribution = agent.distribution { facts.append(distribution) }
        if !agent.version.isEmpty { facts.append(agent.version) }
        let subtitle = facts.joined(separator: " · ")
        switch agent.here {
        case "added": return (agent.name, subtitle, Localized.text("Added"), false)
        case "installed": return (agent.name, subtitle, Localized.text("Installed"), false)
        case "found": return (agent.name, subtitle, Localized.text("Found"), false)
        default:
            if !agent.installable {
                let need = agent.runtime.map { Localized.text("Needs %@", runtimeName($0)) }
                return (agent.name, subtitle, need ?? Localized.text("Not for this machine"), false)
            }
            return (agent.name, subtitle, Localized.text("Install"), true)
        }
    }

    /// A sign-in relayed from the machine, as the card's console says it.
    public static func signInState(_ relay: AgentSignInRelay) -> String {
        switch relay.state {
        case .running: return Localized.text("Waiting for you")
        case .succeeded: return Localized.text("Signed in. Checking…")
        case .failed: return relay.exitCode.map { Localized.text("It stopped (exit %d).", Int($0)) } ?? Localized.text("It stopped.")
        case .cancelled: return Localized.text("Cancelled")
        }
    }

    /// Agents a machine has that nobody has looked at yet, said once on Home.
    public static func news(_ found: [(machine: String, agents: [MachineAgent])]) -> (title: String, detail: String)? {
        let fresh = found.filter { !$0.agents.isEmpty }
        guard let first = fresh.first else { return nil }
        let names = first.agents.map(\.name)
        let list = names.formatted(.list(type: .and))
        return (
            Localized.text("%@ has %@", first.machine, list),
            names.count > 1
                ? Localized.text("Add them to the model pill?") : Localized.text("Add it to the model pill?")
        )
    }
}

/// Which found agents this device has already been told about, so the news is said once.
public enum AgentNewsStore {
    public static let key = "tailscode.agentNews.seen"

    public static func seen() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    /// Agents worth telling about on one machine: found or runnable, not added, never told.
    public static func unseen(_ report: MachineAgentsReport?, profileID: String) -> [MachineAgent] {
        let told = seen()
        return (report?.agents ?? []).filter {
            !$0.added && $0.state == .notAdded && $0.source == "found" && !told.contains("\(profileID)·\($0.id)")
        }
    }

    public static func markSeen(_ agents: [MachineAgent], profileID: String) {
        var told = seen()
        for agent in agents { told.insert("\(profileID)·\(agent.id)") }
        UserDefaults.standard.set(Array(told).sorted(), forKey: key)
    }
}
