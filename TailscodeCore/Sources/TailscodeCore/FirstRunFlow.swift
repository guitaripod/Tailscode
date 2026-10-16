import CodingAgentKit
import CodingAgentKitApple
import Foundation

public struct FirstRunProbe: Sendable {
    public let url: URL
    public let outcome: ConnectionProbe.Outcome
    public let reachability: PortReachability.Verdict?

    public init(
        url: URL, outcome: ConnectionProbe.Outcome, reachability: PortReachability.Verdict? = nil
    ) {
        self.url = url
        self.outcome = outcome
        self.reachability = reachability
    }
}

public enum FirstRunSave: Sendable, Equatable {
    case saved
    case needsPro
    case failed(String)
}

/// The four things first run needs from the client that it cannot do itself: where servers are
/// kept, how a server is saved (the phone's save can refuse a second one without Pro), and the
/// logger. Probing and the Claude sign-in read have defaults, because they are the same
/// everywhere, and a test replaces them to put a machine in any state.
public struct FirstRunEnvironment: Sendable {
    public var offersTailnetScan: Bool
    public var profiles: @Sendable () async -> [ConnectionProfile]
    public var save: @Sendable (ConnectionProfile, String?) async -> FirstRunSave
    public var probe:
        @Sendable (_ address: HostAddress, _ password: String?, _ agent: AgentType, _ interactive: Bool)
            async -> FirstRunProbe
    public var account: @Sendable (_ profile: ConnectionProfile, _ password: String?) async -> ServerAuth?
    public var mintPassword: @Sendable () -> String
    public var log: @Sendable (String) -> Void
    public var typingDelay: Duration

    public init(
        offersTailnetScan: Bool = true,
        profiles: @escaping @Sendable () async -> [ConnectionProfile],
        save: @escaping @Sendable (ConnectionProfile, String?) async -> FirstRunSave,
        probe: @escaping @Sendable (HostAddress, String?, AgentType, Bool) async -> FirstRunProbe =
            FirstRunEnvironment.liveProbe,
        account: @escaping @Sendable (ConnectionProfile, String?) async -> ServerAuth? =
            FirstRunEnvironment.liveAccount,
        mintPassword: @escaping @Sendable () -> String = { BridgeInstall.makePassword() },
        log: @escaping @Sendable (String) -> Void = { _ in },
        typingDelay: Duration = .milliseconds(900)
    ) {
        self.offersTailnetScan = offersTailnetScan
        self.profiles = profiles
        self.save = save
        self.probe = probe
        self.account = account
        self.mintPassword = mintPassword
        self.log = log
        self.typingDelay = typingDelay
    }

    public static let liveProbe:
        @Sendable (HostAddress, String?, AgentType, Bool) async -> FirstRunProbe = {
            address, password, agent, interactive in
            let verdict = await ProbeSweep.best(
                address: address, password: password, preferring: agent,
                policy: interactive ? ProbeSweep.interactivePolicy : ProbeSweep.typingPolicy,
                retryUnreachable: interactive)
            var reachability: PortReachability.Verdict?
            if case .unreachable = verdict.outcome, let host = verdict.url.host,
                let port = verdict.url.port.flatMap({ UInt16(exactly: $0) })
            {
                reachability = await PortReachability.check(host: host, port: port)
            }
            return FirstRunProbe(url: verdict.url, outcome: verdict.outcome, reachability: reachability)
        }

    public static let liveAccount: @Sendable (ConnectionProfile, String?) async -> ServerAuth? = {
        profile, password in
        guard let backend = profile.makeBackend(password: password) as? any AuthenticatingBackend
        else { return nil }
        return await withTaskGroup(of: ServerAuth?.self) { group in
            group.addTask { try? await backend.authStatus() }
            group.addTask {
                try? await Task.sleep(for: .seconds(8))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// First run as one machine that three clients draw. It holds the checklist's state, runs the
/// probe, holds back a link's key until the person has pressed Connect, saves, and reads Claude's
/// sign-in straight after, publishing a `FirstRunPlan` after each change. A client forwards what
/// the person does and draws the plan; it keeps no state of its own about where the person is.
///
/// Never `@MainActor`: a client hops to its own main thread when it draws.
public actor FirstRunFlow {
    private var state: FirstRunState
    private let environment: FirstRunEnvironment
    private var continuations: [UUID: AsyncStream<FirstRunPlan>.Continuation] = [:]
    private var probeTask: Task<Void, Never>?
    private var generation = 0
    private var minted: String?
    private var provenPassword: String?
    private var savedProfile: ConnectionProfile?
    private var savedSecret: String?

    public init(
        platform: FirstRunPlatform, mode: FirstRunState.Mode = .firstRun,
        environment: FirstRunEnvironment
    ) {
        var state = FirstRunState(platform: platform, mode: mode)
        state.offersTailnetScan = environment.offersTailnetScan
        self.state = state
        self.environment = environment
    }

    public var snapshot: FirstRunState { state }
    public var plan: FirstRunPlan { FirstRunPlan.make(state) }

    public var saved: (profile: ConnectionProfile, password: String?)? {
        savedProfile.map { ($0, savedSecret) }
    }

    public func plans() -> AsyncStream<FirstRunPlan> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.yield(FirstRunPlan.make(state))
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.drop(id) }
            }
        }
    }

    private func drop(_ id: UUID) {
        continuations[id] = nil
    }

    private func publish() {
        let plan = FirstRunPlan.make(state)
        for continuation in continuations.values { continuation.yield(plan) }
    }

    public func tailscale(_ reading: TailscaleReading) {
        let wasBlocked = state.tailscale.map(\.blocksReaching) ?? true
        guard state.tailscale != reading else { return }
        state.tailscale = reading
        publish()
        guard wasBlocked, !reading.blocksReaching, hasTarget else { return }
        switch state.machine {
        case .idle, .failed: startProbe(userInitiated: false)
        case .looking, .found, .holdsKey: break
        }
    }

    public func clipboard(_ text: String?) {
        let link = text.flatMap(ConnectLink.firstLink(in:))
        guard link != state.clipboard else { return }
        state.clipboard = link
        publish()
    }

    public func useClipboardLink() async {
        guard let link = state.clipboard else { return }
        await accept(link)
    }

    /// Anything that arrives as text: a paste, an opened URL, a scanned code. A link goes to the
    /// checklist; anything else is read as an address, the way it always has been.
    public func paste(_ text: String) async {
        guard !state.hasLiveConnection else { return }
        switch ConnectLink.read(text) {
        case .link(let link):
            await accept(link)
        case .rejected(.empty):
            typeAddress(text)
        case .rejected(.notALink):
            if let password = BridgeInstall.password(in: text) {
                setSecret(password, note: Localized.text("Password taken from what you pasted."))
            }
            typeAddress(text)
        case .rejected(let rejection):
            environment.log(ConnectLink.logLine(rejection: rejection))
            state.way = .paste
            state.link = nil
            state.typed = text
            state.machine = .idle
            state.notice = ConnectLinkReading.rejection(rejection)
            publish()
        }
    }

    public func typeAddress(_ text: String) {
        guard !state.hasLiveConnection else { return }
        probeTask?.cancel()
        state.way = .paste
        state.link = nil
        state.typed = text
        state.notice = nil
        state.machine = .idle
        publish()
        guard case .address = HostAddress.read(text, defaultPort: HostAddress.port(for: state.agent)) else {
            return
        }
        startProbe(userInitiated: false, after: environment.typingDelay)
    }

    public func choose(_ kind: FirstRunPlan.Way.Kind) {
        switch kind {
        case .link:
            state.way = .paste
            state.notice = nil
        case .install:
            state.way = .install
            ensureInstall()
        case .scan, .tailnet:
            return
        }
        publish()
    }

    public func back() {
        probeTask?.cancel()
        state.way = .choosing
        state.link = nil
        state.typed = ""
        state.notice = nil
        state.machine = .idle
        state.password = ""
        state.passwordShown = false
        state.passwordNote = nil
        publish()
    }

    public func selectAgent(_ agent: AgentType) {
        guard state.agent != agent else { return }
        state.agent = agent
        if state.way == .install { ensureInstall() }
        publish()
        if state.way == .paste, hasTarget { startProbe(userInitiated: false, after: .milliseconds(100)) }
    }

    public func setPassword(_ text: String) {
        state.password = text
        publish()
        guard hasTarget else { return }
        startProbe(userInitiated: false, after: environment.typingDelay)
    }

    public func revealPassword() {
        guard !state.passwordShown else { return }
        state.passwordShown = true
        state.passwordNote = state.way == .install
            ? ServerPasswordRule.line(for: state.agent) : ServerPasswordRule.summary
        publish()
    }

    public func handedOver() {
        guard let password = state.install?.password, state.password.isEmpty else { return }
        setSecret(
            password,
            note: Localized.text("Filled in below, so this device and the machine carry the same password."))
        publish()
    }

    public func retry() {
        guard hasTarget else { return }
        startProbe(userInitiated: true)
    }

    public func confirmOffTailnet() {
        state.offTailnetConfirmed = true
        publish()
        startProbe(userInitiated: true)
    }

    /// A machine the tailnet scan found, taken as it stands: nothing is typed and nothing is probed
    /// again, because the scan already asked it.
    public func adopt(_ suggestion: TailnetScanner.Suggestion) {
        guard !state.hasLiveConnection else { return }
        probeTask?.cancel()
        state.agent = suggestion.backend
        state.way = .paste
        state.link = nil
        state.typed = suggestion.baseURL.absoluteString
        state.notice = nil
        if suggestion.tailnetOnly {
            state.machine = .failed(
                ConnectDiagnosis.make(
                    outcome: .authFailed(.tailnetOnly), address: address(for: suggestion.baseURL),
                    tailnetAddress: tailnetAddress, alternatePort: nil, sentPassword: false,
                    reachability: nil, deviceName: state.platform.thisDevice)
                    ?? ConnectDiagnosis.offTailnet(deviceName: state.platform.thisDevice))
        } else if suggestion.requiresAuth {
            revealPassword()
            startProbe(userInitiated: true)
        } else {
            provenPassword = nil
            state.machine = .found(
                FirstRunState.Found(
                    agent: suggestion.backend, version: suggestion.version, url: suggestion.baseURL,
                    label: suggestion.recommendedProfileName))
        }
        publish()
    }

    public func connect() async {
        guard !state.hasLiveConnection else { return }
        guard let (found, credential) = await confirmedMachine() else { return }
        state.connection = .saving
        publish()
        let name = state.link?.link.name ?? FirstRunReading.profileName(for: found.url)
        let profile = ConnectionProfile(
            id: UUID().uuidString, name: name, backend: found.agent, baseURL: found.url,
            username: ProbeSweep.username(for: found.agent))
        environment.log("first run saving \(found.agent.rawValue) at \(found.url.absoluteString)")
        switch await environment.save(profile, credential) {
        case .saved:
            savedProfile = profile
            savedSecret = credential
            state.connection = .saved(name: name)
            publish()
            await readClaude(profile: profile, password: credential)
        case .needsPro:
            state.connection = .failed(Self.needsPro)
            publish()
        case .failed(let message):
            state.connection = .failed(Self.couldNotSave(message))
            publish()
        }
    }

    public func signInFinished(account: String?) {
        state.claude = .signedIn(account: account)
        state.finished = true
        publish()
    }

    public func skipSignIn() {
        state.finished = true
        publish()
    }

    public func acknowledgeOutcome() {
        state.outcome = nil
        publish()
    }

    private var hasTarget: Bool { target() != nil }

    private var tailnetAddress: String? {
        switch state.tailscale {
        case .up(let address): return address
        case .none, .some(.sandboxed): return "unknown"
        case .some: return nil
        }
    }

    private func address(for url: URL) -> HostAddress {
        HostAddress(url: url, portWasInferred: false)
    }

    private func target() -> (address: HostAddress, label: String)? {
        if let plan = state.link {
            return (address(for: plan.baseURL), plan.displayName)
        }
        guard case .address(let address) = HostAddress.read(
            state.typed, defaultPort: HostAddress.port(for: state.agent))
        else { return nil }
        return (address, address.displayHost)
    }

    private func ensureInstall() {
        if BridgeInstall.needsPassword(state.agent), minted == nil { minted = environment.mintPassword() }
        state.install = BridgeInstall.install(
            for: state.agent, password: BridgeInstall.needsPassword(state.agent) ? minted : nil)
    }

    private func setSecret(_ password: String, note: String) {
        state.password = password
        state.passwordShown = true
        state.passwordNote = note
    }

    private func accept(_ link: PairingLink) async {
        guard !state.hasLiveConnection else { return }
        let plan = ConnectLinkPlan.make(link: link, profiles: await environment.profiles())
        environment.log(plan.logLine)
        probeTask?.cancel()
        if case .openExisting(let id) = plan.destination {
            state.outcome = .openExisting(profileID: id)
            publish()
            return
        }
        state.link = plan
        state.agent = plan.agent
        state.way = .link
        state.typed = ""
        state.notice = nil
        state.password = ""
        state.passwordShown = false
        state.passwordNote = nil
        state.machine = .idle
        state.connection = .notYet
        state.offTailnetConfirmed = false
        provenPassword = nil
        publish()
        if plan.probesAutomatically { startProbe(userInitiated: false) }
    }

    private func startProbe(userInitiated: Bool, after delay: Duration = .zero) {
        probeTask?.cancel()
        guard let (address, label) = target() else { return }
        if let plan = state.link, !plan.probesAutomatically, !state.offTailnetConfirmed,
            !userInitiated
        {
            return
        }
        if let reading = state.tailscale, reading.blocksReaching {
            state.machine = userInitiated ? .failed(offTailnet) : .idle
            publish()
            return
        }
        generation += 1
        let mine = generation
        let credential = state.password.isEmpty ? nil : state.password
        let agent = state.agent
        state.machine = .looking(label: label)
        publish()
        probeTask = Task { [environment] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let result = await environment.probe(address, credential, agent, userInitiated)
            guard !Task.isCancelled else { return }
            self.consume(result, address: address, label: label, credential: credential, generation: mine)
        }
    }

    private var offTailnet: ConnectDiagnosis {
        ConnectDiagnosis.offTailnet(deviceName: state.platform.thisDevice)
    }

    private func consume(
        _ result: FirstRunProbe, address: HostAddress, label: String, credential: String?,
        generation mine: Int
    ) {
        guard mine == generation else { return }
        environment.log("first run probe \(address.displayHost): \(Self.describe(result.outcome))")
        switch result.outcome {
        case .ok(let agent, let version):
            state.agent = agent
            provenPassword = credential
            state.machine = .found(
                FirstRunState.Found(agent: agent, version: version, url: result.url, label: label))
        case .authFailed(.password) where holdsUnusedKey(credential):
            state.machine = .holdsKey(label: label, agent: state.agent, url: result.url)
        case .authFailed(.password):
            revealPassword()
            state.machine = .failed(diagnosis(result, address: address, sentPassword: credential != nil))
        default:
            state.machine = .failed(diagnosis(result, address: address, sentPassword: credential != nil))
        }
        publish()
    }

    private func holdsUnusedKey(_ credential: String?) -> Bool {
        state.link?.carriesKey == true && credential == nil
    }

    private func diagnosis(_ result: FirstRunProbe, address: HostAddress, sentPassword: Bool)
        -> ConnectDiagnosis
    {
        let alternate = state.link == nil ? address.probeCandidates().first { $0 != result.url } : nil
        return ConnectDiagnosis.make(
            outcome: result.outcome, address: address, tailnetAddress: tailnetAddress,
            alternatePort: alternate, sentPassword: sentPassword, reachability: result.reachability,
            deviceName: state.platform.thisDevice,
            offersLocalNetworkSettings: state.platform.isPhone) ?? offTailnet
    }

    private func confirmedMachine() async -> (FirstRunState.Found, String?)? {
        switch state.machine {
        case .found(let found):
            return (found, provenPassword)
        case .holdsKey(let label, let agent, let url):
            let key = state.link?.key(confirmed: true)
            state.connection = .saving
            publish()
            let result = await environment.probe(address(for: url), key, agent, true)
            switch result.outcome {
            case .ok(let agent, let version):
                return (FirstRunState.Found(agent: agent, version: version, url: result.url, label: label), key)
            default:
                state.connection = .notYet
                state.machine = .failed(
                    diagnosis(result, address: address(for: url), sentPassword: true))
                publish()
                return nil
            }
        case .idle, .looking, .failed:
            return nil
        }
    }

    private func readClaude(profile: ConnectionProfile, password: String?) async {
        guard profile.backend == .claudeCode else {
            state.claude = .cannotSay
            state.finished = true
            publish()
            return
        }
        state.claude = .checking
        publish()
        let auth = await environment.account(profile, password)
        switch auth {
        case .none:
            state.claude = .cannotSay
            state.finished = true
        case .some(let auth) where auth.loggedIn:
            state.claude = .signedIn(account: auth.accountLabel)
            state.finished = true
        case .some:
            state.claude = .signedOut
        }
        publish()
    }

    private static func describe(_ outcome: ConnectionProbe.Outcome) -> String {
        switch outcome {
        case .ok(let agent, let version): return "\(agent.rawValue) \(version ?? "")"
        case .authFailed(let challenge): return "auth failed (\(challenge))"
        case .unreachable: return "unreachable"
        case .notAnAgentServer: return "not an agent server"
        }
    }

    private static var needsPro: ConnectDiagnosis {
        ConnectDiagnosis(
            symbol: "star.circle", title: Localized.text("A second server needs Pro"),
            detail: Localized.text(
                "Tailscode Pro is a one-time purchase that lifts the one-server limit. Your first server keeps working either way."
            ),
            fix: .seePro, actionTitle: Localized.text("See Pro"))
    }

    private static func couldNotSave(_ message: String) -> ConnectDiagnosis {
        ConnectDiagnosis(
            symbol: "exclamationmark.triangle", title: Localized.text("Couldn't save that server"),
            detail: message, fix: .none, actionTitle: nil)
    }
}
