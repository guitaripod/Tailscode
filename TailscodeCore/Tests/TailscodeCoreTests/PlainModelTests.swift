import Foundation
import Testing

@testable import TailscodeCore

@Suite struct PlainModelEndpointTests {
    @Test(arguments: [
        "http://127.0.0.1:8080/v1", "http://localhost:11434/v1", "https://studio.local/v1",
        "http://192.168.1.197:8080/v1/", "http://10.0.0.5/v1", "http://172.16.4.2/v1",
        "http://100.101.102.103:8080/v1", "http://arch.tail1234.ts.net:8080/v1", "http://[::1]:8080/v1",
        "http://[fd7a:115c:a1e0::1]:8080/v1",
    ])
    func aMachineOrNetworkThePersonOwnsIsAllowed(address: String) {
        #expect(PlainModel.endpoint(address) != nil)
    }

    @Test(arguments: [
        "", "not a url", "ftp://127.0.0.1/v1", "https://api.openai.com/v1", "http://8.8.8.8/v1",
        "http://172.32.0.1/v1", "http://100.128.0.1/v1", "http://192.169.0.1/v1", "http://example.com/v1",
        "http://user:pass@127.0.0.1/v1", "http://127.0.0.1/v1?key=1", "http://127.0.0.1.evil.com/v1",
        "http://999.0.0.1/v1", "http://localhost.evil.com/v1",
    ])
    func anythingElseIsRefused(address: String) {
        #expect(PlainModel.endpoint(address) == nil)
    }

    @Test func theTrailingSlashGoesAndThePathStays() {
        #expect(PlainModel.endpoint(" http://127.0.0.1:8080/v1/ ")?.absoluteString == "http://127.0.0.1:8080/v1")
    }
}

@Suite struct PlainModelRedactionTests {
    @Test func aSecretAssignedToANameIsTakenOut() {
        let said = PlainModel.redact("API_TOKEN=abc123 SECRET_KEY='x y' swift build")
        #expect(!said.contains("abc123") && !said.contains("x y") && said.contains("swift build"))
    }

    @Test func aHeaderAndAFlagAreTakenOut() {
        let header = PlainModel.redact("curl -H \"Authorization: Bearer sk-live-1234\" https://x.example/api")
        #expect(!header.contains("sk-live-1234") && header.contains("https://x.example/api"))
        let flag = PlainModel.redact("tool --password hunter2 --api-key=zzz123 go")
        #expect(!flag.contains("hunter2") && !flag.contains("zzz123") && flag.hasSuffix("go"))
    }

    @Test func aPasswordInAnAddressIsTakenOut() {
        #expect(!PlainModel.redact("git clone https://me:hunter2@host.example/r.git").contains("hunter2"))
    }

    @Test func aLongUnbrokenRunIsTakenOut() {
        let said = PlainModel.redact("deploy ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 now")
        #expect(!said.contains("ABCDEFGHIJKLMNOP") && said.hasPrefix("deploy") && said.hasSuffix("now"))
    }

    @Test func anOrdinaryCommandIsLeftAlone() {
        #expect(PlainModel.redact("./deploy-edge --region eu --canary 5") == "./deploy-edge --region eu --canary 5")
    }

    @Test func nothingMoreThanFourHundredCharactersIsSent() {
        #expect(PlainModel.redact(String(repeating: "a ", count: 400)).count <= 400)
    }
}

@Suite struct PlainModelRequestTests {
    private func body(_ raw: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: PlainModel.request(model: "m", raw: raw)) as? [String: Any])
    }

    @Test func theRequestAsksForOneLineAndSendsTheRedactedCommand() throws {
        let sent = try body("./x TOKEN=abc123 go")
        let messages = try #require(sent["messages"] as? [[String: String]])
        #expect(sent["model"] as? String == "m" && sent["stream"] as? Bool == false)
        #expect(messages[0]["role"] == "system" && messages[0]["content"] == PlainModel.systemPrompt)
        #expect(messages[1]["role"] == "user" && messages[1]["content"]?.contains("abc123") == false)
    }

    private func reply(_ content: String) -> String? {
        let object: [String: Any] = ["choices": [["message": ["role": "assistant", "content": content]]]]
        return PlainModel.reply(from: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    @Test func aShortPlainLineIsShown() {
        #expect(reply("Deploying the site to the edge servers") == "Deploying the site to the edge servers")
        #expect(reply("  \"Restarting the web server.\"\n") == "Restarting the web server")
        #expect(reply("<think>hmm</think>\nCleaning up old files") == "Cleaning up old files")
    }

    @Test func aReplyThatIsNotFitIsNotShown() {
        #expect(reply("") == nil)
        #expect(reply("Running a command") == nil)
        #expect(reply("running a command.") == nil)
        #expect(reply("Done") == nil)
        #expect(reply(String(repeating: "word ", count: 30)) == nil)
        #expect(reply("Running rm -rf build && swift build") == nil)
        #expect(reply("Opening /etc/passwd") == nil)
        #expect(PlainModel.reply(from: Data("not json".utf8)) == nil)
    }
}
