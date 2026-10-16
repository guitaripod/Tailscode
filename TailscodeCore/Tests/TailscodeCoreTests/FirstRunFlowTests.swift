import CodingAgentKit
import CodingAgentKitApple
import Foundation
import Testing

@testable import TailscodeCore

private let studio = "http://studio.tail1234.ts.net:4098"

private func link(
    host: String = "studio.tail1234.ts.net", agent: PairingAgent = .claude, port: Int = 4098,
    key: String? = nil
) -> String {
    PairingLink(host: host, port: port, agent: agent, name: "Studio", key: key)!.url.absoluteString
}

private func flow(
    _ platform: FirstRunPlatform = .iPhone, recorder: FirstRunRecorder,
    tailscale: TailscaleReading? = .up(address: "100.101.102.103"),
    mode: FirstRunState.Mode = .firstRun
) async -> FirstRunFlow {
    let flow = FirstRunFlow(platform: platform, mode: mode, environment: recorder.environment())
    if let tailscale { await flow.tailscale(tailscale) }
    return flow
}

private func isFound(_ state: FirstRunState) -> Bool {
    if case .found = state.machine { return true }
    return false
}

@Suite("First run flow")
struct FirstRunFlowTests {
    @Test("a link lands on a checklist with the agent chosen and the machine already probed")
    func linkProbesWithoutBeingAsked() async {
        let recorder = FirstRunRecorder()
        await recorder.answer(studio, with: .ok(agentType: .claudeCode, version: "1.14.0"))
        let flow = await flow(recorder: recorder)
        await flow.paste(link())
        let state = await settle(flow) { isFound($0) }
        #expect(state.agent == .claudeCode)
        #expect(state.way == .link)
        guard case .found(let found) = state.machine else {
            Issue.record("expected a found machine")
            return
        }
        #expect(found.version == "1.14.0")
        #expect(await recorder.probes.map(\.url.absoluteString) == [studio])
        #expect(await recorder.saves.isEmpty)
        let plan = await flow.plan
        #expect(plan.row(.tailscale)?.glyph == .proven)
        #expect(plan.row(.machine)?.glyph == .proven)
        #expect(plan.row(.connected)?.glyph == .current)
        #expect(plan.primary?.title == "Connect to Studio")
    }

    @Test("nothing is saved until Connect, and a claude machine with no key saves with no password")
    func connectSavesAfterConfirmation() async throws {
        let recorder = FirstRunRecorder()
        await recorder.answer(studio, with: .ok(agentType: .claudeCode, version: "1.14.0"))
        await recorder.setAuth(ServerAuth(loggedIn: true, email: "me@example.com"))
        let flow = await flow(recorder: recorder)
        await flow.paste(link())
        _ = await settle(flow) { isFound($0) }
        #expect(await recorder.saves.isEmpty)
        await flow.connect()
        let saves = await recorder.saves
        #expect(saves.count == 1)
        let (profile, password) = try #require(saves.first)
        #expect(profile.name == "Studio")
        #expect(profile.backend == .claudeCode)
        #expect(profile.baseURL.absoluteString == studio)
        #expect(profile.username == "claude")
        #expect(password == nil)
        let state = await flow.snapshot
        #expect(state.connection == .saved(name: "Studio"))
        #expect(state.claude == .signedIn(account: "me@example.com"))
        #expect(state.finished)
    }

    @Test("the key a link carries is not sent to the host before Connect, and is the password after it")
    func keyWaitsForConnect() async throws {
        let recorder = FirstRunRecorder()
        let omp = "http://studio.tail1234.ts.net:4099"
        await recorder.answer(omp, with: .authFailed(.password))
        let flow = await flow(recorder: recorder)
        await flow.paste(link(agent: .omp, port: 4099, key: "LINKKEY"))
        let held = await settle(flow) {
            if case .holdsKey = $0.machine { return true }
            return false
        }
        guard case .holdsKey(let label, let agent, _) = held.machine else {
            Issue.record("expected the machine to hold the key")
            return
        }
        #expect(label == "Studio")
        #expect(agent == .omp)
        #expect(await recorder.probes.allSatisfy { $0.password == nil })
        #expect(await recorder.saves.isEmpty)
        #expect(!held.passwordShown)
        let plan = await flow.plan
        #expect(plan.primary?.title == "Connect to Studio")

        await recorder.answer(omp, with: .ok(agentType: .omp, version: "0.8.0"))
        await flow.connect()
        let probes = await recorder.probes
        #expect(probes.last?.password == "LINKKEY")
        let saves = await recorder.saves
        #expect(saves.first?.1 == "LINKKEY")
        #expect(saves.first?.0.backend == .omp)
        #expect(await flow.snapshot.finished)
        #expect(!(await recorder.logs.joined(separator: "\n")).contains("LINKKEY"))
    }

    @Test("a key the machine rejects is a rejected password, and nothing is saved")
    func rejectedKey() async {
        let recorder = FirstRunRecorder()
        let url = "http://studio.tail1234.ts.net:4096"
        await recorder.answer(url, with: .authFailed(.password))
        let flow = await flow(recorder: recorder)
        await flow.paste(link(agent: .opencode, port: 4096, key: "STALE"))
        _ = await settle(flow) {
            if case .holdsKey = $0.machine { return true }
            return false
        }
        await flow.connect()
        let state = await flow.snapshot
        guard case .failed(let diagnosis) = state.machine else {
            Issue.record("expected a failure")
            return
        }
        #expect(diagnosis.title == "That password was rejected")
        #expect(state.connection == .notYet)
        #expect(await recorder.saves.isEmpty)
    }

    @Test("a link for a server that is already added opens it and probes nothing")
    func duplicateOpensExisting() async {
        let recorder = FirstRunRecorder()
        let existing = ConnectionProfile(
            id: "have", name: "Studio", backend: .claudeCode, baseURL: URL(string: studio)!)
        await recorder.setProfiles([existing])
        let flow = await flow(recorder: recorder, mode: .addition)
        await flow.paste(link())
        let state = await flow.snapshot
        #expect(state.outcome == .openExisting(profileID: "have"))
        #expect(await recorder.probes.isEmpty)
        #expect(state.link == nil)
    }

    @Test("a link for another machine, with servers already added, is probed for the confirmation")
    func additionIsProbed() async {
        let recorder = FirstRunRecorder()
        await recorder.setProfiles([
            ConnectionProfile(id: "x", name: "X", backend: .openCode, baseURL: URL(string: "http://x:4096")!)
        ])
        await recorder.answer(studio, with: .ok(agentType: .claudeCode, version: "1.14.0"))
        let flow = await flow(recorder: recorder, mode: .addition)
        await flow.paste(link())
        let state = await settle(flow) { isFound($0) }
        #expect(state.link?.destination == .confirmAddition)
        let plan = await flow.plan
        #expect(plan.primary?.title == "Add Studio")
        #expect(plan.rows.map(\.id) == [.machine, .connected])
    }

    @Test("a host that is not on a tailnet is not probed until the person says to go on")
    func offTailnetWaits() async {
        let recorder = FirstRunRecorder()
        await recorder.answer("http://192.168.1.20:4098", with: .ok(agentType: .claudeCode, version: "1"))
        let flow = await flow(recorder: recorder)
        await flow.paste(link(host: "192.168.1.20"))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await recorder.probes.isEmpty)
        #expect(await flow.snapshot.link?.isOnTailnet == false)
        await flow.confirmOffTailnet()
        let state = await settle(flow) { isFound($0) }
        #expect(isFound(state))
        #expect(await recorder.probes.count == 1)
    }

    @Test("with Tailscale down nothing is probed, and it is when Tailscale comes up")
    func tailscaleGate() async {
        let recorder = FirstRunRecorder()
        await recorder.answer(studio, with: .ok(agentType: .claudeCode, version: "1.14.0"))
        let flow = await flow(recorder: recorder, tailscale: .daemonDown)
        await flow.paste(link())
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await recorder.probes.isEmpty)
        #expect(await flow.snapshot.machine == .idle)
        await flow.tailscale(.up(address: "100.101.102.103"))
        let state = await settle(flow) { isFound($0) }
        #expect(isFound(state))
    }

    @Test("an address typed or pasted is read as it always was, and the failure names the machine")
    func addressFailure() async {
        let recorder = FirstRunRecorder()
        await recorder.setReachability(.refused)
        let flow = await flow(.linux, recorder: recorder)
        await flow.paste("studio")
        let state = await settle(flow) {
            if case .failed = $0.machine { return true }
            return false
        }
        guard case .failed(let diagnosis) = state.machine else {
            Issue.record("expected a failure")
            return
        }
        #expect(state.way == .paste)
        #expect(await recorder.probes.first?.url.absoluteString == "http://studio:4098")
        #expect(diagnosis.detail.contains("studio"))
        #expect(!diagnosis.detail.localizedCaseInsensitiveContains("port"))
        #expect(diagnosis.fix == .retry)
    }

    @Test("a 401 with no key asks for the password and shows the rule for the kind")
    func passwordRequested() async {
        let recorder = FirstRunRecorder()
        await recorder.answer("http://studio:4096", with: .authFailed(.password))
        let flow = await flow(recorder: recorder)
        await flow.selectAgent(.openCode)
        await flow.paste("studio")
        let state = await settle(flow) { $0.passwordShown }
        #expect(state.passwordShown)
        #expect(state.passwordNote == ServerPasswordRule.summary)
        guard case .failed(let diagnosis) = state.machine else {
            Issue.record("expected a diagnosis")
            return
        }
        #expect(diagnosis.fix == .revealPassword)
        await recorder.answer("http://studio:4096", with: .ok(agentType: .openCode, version: "2.0"))
        await flow.setPassword("hunter2")
        let proven = await settle(flow) { isFound($0) }
        #expect(isFound(proven))
        #expect(await recorder.probes.last?.password == "hunter2")
        await flow.connect()
        #expect(await recorder.saves.first?.1 == "hunter2")
        #expect(await flow.snapshot.claude == .cannotSay)
        #expect(await flow.snapshot.finished)
    }

    @Test("a tailnet-only refusal sends the person to Tailscale and never reveals a password field")
    func tailnetOnly() async {
        let recorder = FirstRunRecorder()
        await recorder.answer(studio, with: .authFailed(.tailnetOnly))
        let flow = await flow(recorder: recorder)
        await flow.paste(link())
        let state = await settle(flow) {
            if case .failed = $0.machine { return true }
            return false
        }
        guard case .failed(let diagnosis) = state.machine else { return }
        #expect(diagnosis.fix == .openTailscale)
        #expect(!state.passwordShown)
    }

    @Test("a signed-out Claude is read straight after saving and keeps first run open until it signs in")
    func signedOutClaude() async {
        let recorder = FirstRunRecorder()
        await recorder.answer(studio, with: .ok(agentType: .claudeCode, version: "1.14.0"))
        await recorder.setAuth(ServerAuth(loggedIn: false))
        let flow = await flow(recorder: recorder)
        await flow.paste(link())
        _ = await settle(flow) { isFound($0) }
        await flow.connect()
        var state = await flow.snapshot
        #expect(state.claude == .signedOut)
        #expect(!state.finished)
        #expect(await flow.saved?.profile.name == "Studio")
        let plan = await flow.plan
        #expect(plan.primary?.intent == .signIn)
        await flow.signInFinished(account: "me@example.com")
        state = await flow.snapshot
        #expect(state.claude == .signedIn(account: "me@example.com"))
        #expect(state.finished)
    }

    @Test("signing in later leaves first run with the server saved")
    func skipSignIn() async {
        let recorder = FirstRunRecorder()
        await recorder.answer(studio, with: .ok(agentType: .claudeCode, version: "1.14.0"))
        await recorder.setAuth(ServerAuth(loggedIn: false))
        let flow = await flow(recorder: recorder)
        await flow.paste(link())
        _ = await settle(flow) { isFound($0) }
        await flow.connect()
        await flow.skipSignIn()
        #expect(await flow.snapshot.finished)
        #expect(await recorder.saves.count == 1)
    }

    @Test("a bridge too old to say whether it is signed in is not called signed out")
    func oldBridge() async {
        let recorder = FirstRunRecorder()
        await recorder.answer(studio, with: .ok(agentType: .claudeCode, version: "1.0.0"))
        await recorder.setAuth(nil)
        let flow = await flow(recorder: recorder)
        await flow.paste(link())
        _ = await settle(flow) { isFound($0) }
        await flow.connect()
        let state = await flow.snapshot
        #expect(state.claude == .cannotSay)
        #expect(state.finished)
        #expect(await recorder.accountCalls == 1)
    }

    @Test("opencode is never asked who it is signed in as")
    func opencodeIsNotAsked() async {
        let recorder = FirstRunRecorder()
        let url = "http://studio.tail1234.ts.net:4096"
        await recorder.answer(url, with: .ok(agentType: .openCode, version: "2.0.0"))
        let flow = await flow(recorder: recorder)
        await flow.paste(link(agent: .opencode, port: 4096))
        _ = await settle(flow) { isFound($0) }
        await flow.connect()
        #expect(await recorder.accountCalls == 0)
        #expect(await flow.snapshot.finished)
    }

    @Test("a second server without Pro is a diagnosis with the one fix, and is not finished")
    func needsPro() async {
        let recorder = FirstRunRecorder()
        await recorder.answer(studio, with: .ok(agentType: .claudeCode, version: "1.14.0"))
        await recorder.setSaveResult(.needsPro)
        let flow = await flow(recorder: recorder)
        await flow.paste(link())
        _ = await settle(flow) { isFound($0) }
        await flow.connect()
        let state = await flow.snapshot
        guard case .failed(let diagnosis) = state.connection else {
            Issue.record("expected a failed connection")
            return
        }
        #expect(diagnosis.fix == .seePro)
        #expect(!state.finished)
    }

    @Test("a save that fails says why and leaves the machine proven")
    func saveFails() async {
        let recorder = FirstRunRecorder()
        await recorder.answer(studio, with: .ok(agentType: .claudeCode, version: "1.14.0"))
        await recorder.setSaveResult(.failed("the keychain is locked"))
        let flow = await flow(recorder: recorder)
        await flow.paste(link())
        _ = await settle(flow) { isFound($0) }
        await flow.connect()
        let state = await flow.snapshot
        guard case .failed(let diagnosis) = state.connection else {
            Issue.record("expected a failed connection")
            return
        }
        #expect(diagnosis.detail == "the keychain is locked")
        #expect(isFound(state))
    }

    @Test("choosing the install mints a password only for the agents that need one")
    func installPassword() async {
        let recorder = FirstRunRecorder()
        let flow = await flow(.iPhone, recorder: recorder)
        await flow.choose(.install)
        var state = await flow.snapshot
        #expect(state.way == .install)
        #expect(state.install?.password == nil)
        await flow.handedOver()
        #expect(await flow.snapshot.passwordShown == false)
        await flow.selectAgent(.openCode)
        state = await flow.snapshot
        #expect(state.install?.password == "MINTED-PASSWORD")
        #expect(state.install?.command.contains("OPENCODE_SERVER_PASSWORD=MINTED-PASSWORD") == true)
        #expect(state.password.isEmpty)
        await flow.handedOver()
        state = await flow.snapshot
        #expect(state.password == "MINTED-PASSWORD")
        #expect(state.passwordShown)
        await flow.selectAgent(.omp)
        #expect(await flow.snapshot.install?.password == "MINTED-PASSWORD")
        await flow.selectAgent(.claudeCode)
        #expect(await flow.snapshot.install?.password == nil)
    }

    @Test("a link arriving while the install command is on screen takes over the checklist")
    func linkAfterInstall() async {
        let recorder = FirstRunRecorder()
        await recorder.answer(studio, with: .ok(agentType: .claudeCode, version: "1.14.0"))
        let flow = await flow(.linux, recorder: recorder)
        await flow.choose(.install)
        await flow.paste(link())
        let state = await settle(flow) { isFound($0) }
        #expect(state.way == .link)
        #expect(isFound(state))
    }

    @Test("something that is not a link or an address says what a link looks like")
    func damagedLink() async {
        let recorder = FirstRunRecorder()
        let flow = await flow(recorder: recorder)
        await flow.paste("tailscode://connect?host=studio&port=70000&agent=claude")
        let state = await flow.snapshot
        #expect(state.way == .paste)
        #expect(state.notice?.title == "That link is damaged")
        #expect(await recorder.probes.isEmpty)
        await flow.paste("tailscode://settings")
        #expect(await flow.snapshot.notice?.title == "This link asks for something else")
    }

    @Test("the clipboard offers a link and takes it when asked")
    func clipboardOffer() async {
        let recorder = FirstRunRecorder()
        await recorder.answer(studio, with: .ok(agentType: .claudeCode, version: "1.14.0"))
        let flow = await flow(.linux, recorder: recorder)
        await flow.clipboard("nothing here")
        #expect(await flow.snapshot.clipboard == nil)
        await flow.clipboard("run it, then \(link())")
        #expect(await flow.snapshot.clipboard?.host == "studio.tail1234.ts.net")
        await flow.choose(.link)
        let paste = await flow.plan.row(.machine)?.blocks.compactMap { block -> FirstRunPlan.Paste? in
            if case .paste(let paste) = block { return paste }
            return nil
        }.first
        #expect(paste?.offer == "Add Studio from your clipboard")
        await flow.useClipboardLink()
        let state = await settle(flow) { isFound($0) }
        #expect(isFound(state))
    }

    @Test("a machine the tailnet scan found is taken as it stands")
    func adoptsScan() async {
        let recorder = FirstRunRecorder()
        let flow = await flow(.linux, recorder: recorder)
        let suggestion = TailnetScanner.Suggestion(
            id: "a", name: "arch", baseURL: URL(string: "http://arch:4096")!, backend: .openCode,
            version: "2.0.0", requiresAuth: false, recommendedProfileName: "arch", os: nil, lastSeen: nil)
        await flow.adopt(suggestion)
        let state = await flow.snapshot
        guard case .found(let found) = state.machine else {
            Issue.record("expected a found machine")
            return
        }
        #expect(found.agent == .openCode)
        #expect(await recorder.probes.isEmpty)
        await flow.connect()
        #expect(await recorder.saves.first?.0.name == "arch")
    }

    @Test("a scanned machine that wants a password is probed and asks for it")
    func adoptsLockedScan() async {
        let recorder = FirstRunRecorder()
        await recorder.answer("http://arch:4096", with: .authFailed(.password))
        let flow = await flow(.linux, recorder: recorder)
        let suggestion = TailnetScanner.Suggestion(
            id: "a", name: "arch", baseURL: URL(string: "http://arch:4096")!, backend: .openCode,
            version: nil, requiresAuth: true, recommendedProfileName: "arch", os: nil, lastSeen: nil)
        await flow.adopt(suggestion)
        let state = await settle(flow) {
            if case .failed = $0.machine { return true }
            return false
        }
        #expect(state.passwordShown)
    }

    @Test("back returns to the three ways and forgets what was half done")
    func back() async {
        let recorder = FirstRunRecorder()
        let flow = await flow(recorder: recorder)
        await flow.choose(.link)
        await flow.typeAddress("studio")
        await flow.setPassword("half")
        await flow.revealPassword()
        await flow.back()
        let state = await flow.snapshot
        #expect(!state.passwordShown && state.password.isEmpty)
        #expect(state.way == .choosing)
        #expect(state.typed.isEmpty)
        #expect(state.machine == .idle)
    }

    @Test("every plan the flow publishes is delivered in order, starting with the current one")
    func stream() async {
        let recorder = FirstRunRecorder()
        let flow = await flow(recorder: recorder)
        var plans = await flow.plans().makeAsyncIterator()
        let first = await plans.next()
        #expect(first?.row(.machine)?.glyph == .current)
        await flow.choose(.install)
        var sawWaiting = false
        for _ in 0..<5 {
            guard let plan = await plans.next() else { break }
            if plan.row(.machine)?.pill == "Waiting" {
                sawWaiting = true
                break
            }
        }
        #expect(sawWaiting)
    }
}
