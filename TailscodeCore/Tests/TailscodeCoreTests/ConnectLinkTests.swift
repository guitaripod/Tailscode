import CodingAgentKit
import CodingAgentKitApple
import Foundation
import Testing

@testable import TailscodeCore

private func link(
    host: String = "studio.tail1234.ts.net", agent: PairingAgent = .claude, port: Int = 4098,
    name: String? = "Studio", key: String? = nil
) -> String {
    PairingLink(host: host, port: port, agent: agent, name: name, key: key)!.url.absoluteString
}

private func profile(_ id: String, _ url: String, _ backend: AgentType = .claudeCode)
    -> ConnectionProfile
{
    ConnectionProfile(id: id, name: id, backend: backend, baseURL: URL(string: url)!)
}

@Suite("Connect link reading")
struct ConnectLinkReadingTests {
    @Test("a link with no key reads whole")
    func readsALink() throws {
        let reading = ConnectLink.read(link())
        let parsed = try #require(reading.link)
        #expect(parsed.host == "studio.tail1234.ts.net")
        #expect(parsed.port == 4098)
        #expect(parsed.agent == .claude)
        #expect(parsed.name == "Studio")
        #expect(parsed.key == nil)
    }

    @Test("a link with a key keeps it for later and never prints it")
    func keyIsRedactedInTheLog() throws {
        let parsed = try #require(ConnectLink.read(link(agent: .omp, key: "s3cret-Pass")).link)
        #expect(parsed.key == "s3cret-Pass")
        let line = ConnectLink.logLine(parsed)
        #expect(!line.contains("s3cret"))
        #expect(line.contains("<redacted>"))
        let plan = ConnectLinkPlan.make(link: parsed, profiles: [])
        #expect(!plan.logLine.contains("s3cret"))
        #expect(!"\(plan)".contains("s3cret"))
    }

    @Test("a link opened from a URL is read the same way")
    func readsAURL() {
        let url = URL(string: link(agent: .opencode, name: nil))!
        #expect(ConnectLink.read(url: url).link?.agent == .opencode)
    }

    @Test("the link is found among other words, as a message carries it")
    func findsALinkInProse() throws {
        let text = "Here you go (\(link())) from the install, thanks"
        #expect(try #require(ConnectLink.firstLink(in: text)).name == "Studio")
        #expect(ConnectLink.firstLink(in: "<\(link())>") != nil)
        #expect(ConnectLink.firstLink(in: "see https://example.com for more") == nil)
    }

    @Test("the scheme is matched without regard to case")
    func schemeCase() {
        let upper = link().replacingOccurrences(of: "tailscode://connect", with: "TAILSCODE://CONNECT")
        #expect(ConnectLink.read(upper).link != nil)
    }

    @Test("each way a link can be wrong is told apart")
    func rejections() {
        #expect(ConnectLink.read("   ") == .rejected(.empty))
        #expect(ConnectLink.read("100.101.102.103") == .rejected(.notALink))
        #expect(ConnectLink.read("https://tailscode.app") == .rejected(.notALink))
        #expect(ConnectLink.read("tailscode://settings") == .rejected(.wrongAction))
        #expect(ConnectLink.read("tailscode://session/abc") == .rejected(.wrongAction))
        #expect(ConnectLink.read("tailscode://connect") == .rejected(.malformed))
        #expect(
            ConnectLink.read("tailscode://connect?host=studio&port=99999&agent=claude")
                == .rejected(.malformed))
        #expect(
            ConnectLink.read("tailscode://connect?host=studio&port=4098&agent=gpt")
                == .rejected(.malformed))
        #expect(
            ConnectLink.read("tailscode://connect?host=studio&port=4098") == .rejected(.malformed))
    }

    @Test("every rejection has words and none of them repeats what was pasted")
    func rejectionWords() {
        let hostile = "tailscode://connect?host=<script>alert(1)</script>&port=1&agent=claude"
        guard case .rejected(let rejection) = ConnectLink.read(hostile) else {
            Issue.record("a script in the host must not read as a link")
            return
        }
        for each in [ConnectLink.Rejection.empty, .notALink, .wrongAction, .malformed, rejection] {
            let message = ConnectLinkReading.rejection(each)
            #expect(!message.title.isEmpty && !message.detail.isEmpty)
            #expect(!message.detail.contains("script"))
            #expect(!message.title.contains("script"))
        }
    }
}

@Suite("Hostile links reaching the handler")
struct HostileConnectLinkTests {
    @Test(
        "a link that breaks the format is never a link",
        arguments: [
            "tailscode://connect?host=user:pw@studio&port=4098&agent=claude",
            "tailscode://connect?host=studio/../x&port=4098&agent=claude",
            "tailscode://connect?host=studio&port=4098&agent=claude#frag",
            "tailscode://connect?host=studio&host=evil&port=4098&agent=claude",
            "tailscode://connect?host=studio&port=0&agent=claude",
            "tailscode://connect?host=studio&port=-1&agent=claude",
            "tailscode://connect?host=studio&port=04098x&agent=claude",
            "tailscode://connect?host=&port=4098&agent=claude",
            "tailscode://connect?host=stu%00dio&port=4098&agent=claude",
            "tailscode://connect?host=studio%0d%0a&port=4098&agent=claude",
            "tailscode://connect?host=%ff%fe&port=4098&agent=claude",
            "tailscode://connect?host=studio&port=4098&agent=claude%",
            "tailscode://connect?host=studio&port=4098&agent=claude&v=0",
            "tailscode://connect?host=studio&port=4098&agent=claude&v=x",
            "tailscode://connect?host=-studio&port=4098&agent=claude",
            "tailscode://connect?host=[::1&port=4098&agent=claude",
        ])
    func refused(_ text: String) {
        #expect(ConnectLink.read(text).link == nil)
    }

    @Test("an oversize link is refused rather than parsed")
    func oversize() {
        let long = "tailscode://connect?host=studio&port=4098&agent=claude&name=" + String(repeating: "a", count: 3000)
        #expect(ConnectLink.read(long) == .rejected(.malformed))
        let key = String(repeating: "k", count: 201)
        #expect(
            ConnectLink.read("tailscode://connect?host=studio&port=4098&agent=claude&key=\(key)").link
                == nil)
    }

    @Test("a name cannot smuggle direction overrides or control characters onto the screen")
    func nameIsCleaned() throws {
        let encoded = "Stu%E2%80%AEdio%0A%00Mac"
        let text = "tailscode://connect?host=studio&port=4098&agent=claude&name=\(encoded)"
        let parsed = try #require(ConnectLink.read(text).link)
        #expect(parsed.name == "StudioMac")
        let plan = ConnectLinkPlan.make(link: parsed, profiles: [])
        #expect(plan.displayName == "StudioMac")
        #expect(!ConnectLinkReading.headline(parsed).contains("\u{202E}"))
    }

    @Test("a name is cut to what fits on a line")
    func nameLength() throws {
        let long = String(repeating: "m", count: 200)
        let text = "tailscode://connect?host=studio&port=4098&agent=claude&name=\(long)"
        #expect(try #require(ConnectLink.read(text).link).name?.count == 64)
    }

    @Test("an unknown parameter is ignored so a newer link still reads")
    func newerLink() {
        let text = "tailscode://connect?v=2&host=studio&port=4098&agent=claude&color=blue"
        #expect(ConnectLink.read(text).link != nil)
    }

    @Test("a hostile link reaching the flow never saves or sends its key anywhere")
    func flowRefusesHostile() async {
        let recorder = FirstRunRecorder()
        let flow = FirstRunFlow(platform: .iPhone, environment: recorder.environment())
        await flow.paste("tailscode://connect?host=user:pw@evil.example&port=4098&agent=claude&key=hunter2")
        let state = await flow.snapshot
        #expect(state.link == nil)
        #expect(state.notice != nil)
        #expect(await recorder.probes.isEmpty)
        #expect(await recorder.saves.isEmpty)
        #expect(!(await recorder.logs.joined().contains("hunter2")))
    }
}

@Suite("Connect link plan")
struct ConnectLinkPlanTests {
    @Test("with no server yet a link goes to first run with the agent pre-selected")
    func firstRun() throws {
        let parsed = try #require(ConnectLink.read(link(agent: .omp, port: 4099)).link)
        let plan = ConnectLinkPlan.make(link: parsed, profiles: [])
        #expect(plan.destination == .firstRun)
        #expect(plan.agent == .omp)
        #expect(plan.baseURL.absoluteString == "http://studio.tail1234.ts.net:4099")
        #expect(plan.probesAutomatically)
        #expect(plan.isOnTailnet)
    }

    @Test("with servers already added a link asks before adding")
    func confirmAddition() throws {
        let parsed = try #require(ConnectLink.read(link()).link)
        let plan = ConnectLinkPlan.make(
            link: parsed, profiles: [profile("other", "http://other.tail1234.ts.net:4098")])
        #expect(plan.destination == .confirmAddition)
    }

    @Test("a link for the server already added just opens it")
    func duplicate() throws {
        let parsed = try #require(ConnectLink.read(link()).link)
        let have = profile("studio-id", "http://Studio.tail1234.ts.net.:4098")
        let plan = ConnectLinkPlan.make(link: parsed, profiles: [profile("x", "http://x:1"), have])
        #expect(plan.destination == .openExisting(profileID: "studio-id"))
        #expect(plan.opensExisting)
        #expect(!plan.probesAutomatically)
    }

    @Test("the same machine on another port is not the same server")
    func samePortOnly() throws {
        let parsed = try #require(ConnectLink.read(link()).link)
        let plan = ConnectLinkPlan.make(
            link: parsed, profiles: [profile("o", "http://studio.tail1234.ts.net:4099")])
        #expect(plan.destination == .confirmAddition)
    }

    @Test("a tailnet scan's other names for the machine count as the same server")
    func aliases() throws {
        let parsed = try #require(ConnectLink.read(link(host: "100.101.102.103")).link)
        let device = TailscaleDevice(
            name: "studio.tail1234.ts.net", hostname: "studio", addresses: ["100.101.102.103"],
            os: "linux")
        let plan = ConnectLinkPlan.make(
            link: parsed, profiles: [profile("s", "http://studio.tail1234.ts.net:4098")],
            devices: [device])
        #expect(plan.destination == .openExisting(profileID: "s"))
    }

    @Test("a host that is not on a tailnet says so, and is not probed until the person goes on")
    func notOnTailnet() throws {
        let parsed = try #require(ConnectLink.read(link(host: "192.168.1.20")).link)
        let plan = ConnectLinkPlan.make(link: parsed, profiles: [])
        #expect(!plan.isOnTailnet)
        #expect(!plan.probesAutomatically)
        #expect(plan.lines.contains { $0.hasPrefix("This address is not on a tailnet: 192.168.1.20") })
        #expect(plan.lines.last == "Saved nothing yet. Nothing is kept until you press Connect.")
    }

    @Test("the key is released only after the person confirms")
    func keyWaitsForConfirmation() throws {
        let parsed = try #require(ConnectLink.read(link(agent: .opencode, port: 4096, key: "pw1")).link)
        let plan = ConnectLinkPlan.make(link: parsed, profiles: [])
        #expect(plan.carriesKey)
        #expect(plan.key(confirmed: false) == nil)
        #expect(plan.key(confirmed: true) == "pw1")
        #expect(plan.lines.contains(ConnectLinkReading.keyNote))
    }

    @Test("an IPv6 tailnet address makes a URL a probe can use")
    func ipv6() throws {
        let parsed = try #require(ConnectLink.read(link(host: "fd7a:115c:a1e0::1")).link)
        let plan = ConnectLinkPlan.make(link: parsed, profiles: [])
        #expect(plan.baseURL.absoluteString == "http://[fd7a:115c:a1e0::1]:4098")
        #expect(plan.baseURL.host == "fd7a:115c:a1e0::1")
        #expect(plan.isOnTailnet)
    }

    @Test("the words name the machine and the agent")
    func words() throws {
        let parsed = try #require(ConnectLink.read(link(name: "Studio")).link)
        #expect(ConnectLinkReading.headline(parsed) == "Add Studio")
        #expect(ConnectLinkReading.agentLine(parsed) == "Claude Code at studio.tail1234.ts.net:4098")
        let nameless = try #require(ConnectLink.read(link(name: nil)).link)
        #expect(ConnectLinkReading.headline(nameless) == "Add studio.tail1234.ts.net")
        #expect(ConnectLinkReading.alreadyAdded("Studio").contains("already added"))
    }
}
