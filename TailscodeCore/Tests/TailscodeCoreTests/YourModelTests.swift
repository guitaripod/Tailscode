import CodingAgentKit
import CodingAgentKitApple
import Foundation
import Testing

@testable import TailscodeCore

@Suite struct YourModelTests {
    func json(_ text: String) -> Data { Data(text.utf8) }

    var swapList: Data {
        json(
            """
            {"data":[
            {"id":"flint","owned_by":"llama-swap","name":"Flint","description":"Flint 40B · llama.cpp · Q8_0 · 256K","status":{"value":"unloaded"}},
            {"id":"pennyroyal","owned_by":"llama-swap","name":"Pennyroyal","description":"Qwen 3.8 27B · Uncensored · SGLang · FP8 · DFlash2 · 256K","status":{"value":"loaded"}},
            {"id":"unrager-4b-gguf","owned_by":"llama-swap","name":"unrager Live","description":"unrager 4B · llama.cpp · Q8_0 · 8K","status":{"value":"loaded"}},
            {"id":"qwen3-embedding-0.6b","owned_by":"llama-swap","name":"Embed","status":{"value":"unloaded"}},
            {"id":"qwen3-4b-thinking-gguf","owned_by":"llama-swap","name":"Qwen3 Thinking","description":"Qwen3 4B Thinking · llama.cpp","status":{"value":"loaded"}}
            ]}
            """)
    }

    var swapRunning: Data {
        json(
            """
            {"running":[
            {"model":"pennyroyal","state":"ready","ttl":0,"name":"Pennyroyal"},
            {"model":"unrager-4b-gguf","state":"ready","ttl":600},
            {"model":"qwen3-4b-thinking-gguf","state":"ready","ttl":600}
            ]}
            """)
    }

    func swapServer(machine: String = "arch", address: String = "http://127.0.0.1:8081") -> YourModelServer {
        let software = YourModelSurvey.software(of: swapList, port: 8081)
        return YourModelSurvey.read(
            listing: swapList, address: address, machine: machine, software: software,
            memory: YourModelSurvey.Memory(swap: swapRunning))!
    }

    @Test func llamaSwapIsReadWithWhatItKeepsWarm() throws {
        let server = swapServer()
        #expect(server.software == "llama-swap")
        #expect(server.heading == "arch · llama-swap")
        #expect(!server.models.contains { $0.model == "qwen3-embedding-0.6b" } || YourModelPick.score(server.models.first { $0.model == "qwen3-embedding-0.6b" }!) == nil)
        let penny = try #require(server.models.first { $0.model == "pennyroyal" })
        #expect(penny.pinned && penny.running == true && penny.label == "Pennyroyal")
        #expect(penny.parameters == 27)
        let flint = try #require(server.models.first { $0.model == "flint" })
        #expect(flint.running == false && !flint.pinned)
    }

    @Test func theDefaultIsTheModelKeptWarm() {
        let best = YourModelPick.best([swapServer()])
        #expect(best?.model == "pennyroyal")
        let order = YourModelPick.ranked([swapServer()]).map(\.model)
        #expect(order.first == "pennyroyal")
        #expect(order.firstIndex(of: "unrager-4b-gguf")! < order.firstIndex(of: "flint")!)
        #expect(order.firstIndex(of: "unrager-4b-gguf")! < order.firstIndex(of: "qwen3-4b-thinking-gguf")!)
        #expect(!order.contains("qwen3-embedding-0.6b"))
    }

    @Test func amongRunningModelsTheLargerWritesBetter() {
        let small = YourModelCandidate(address: "http://a:8080", model: "qwen3-4b-instruct", running: true, machine: "a")
        let large = YourModelCandidate(address: "http://b:8080", model: "gemma4-26b-it", running: true, machine: "b")
        let idle = YourModelCandidate(address: "http://c:11434", model: "qwen3:14b", running: false, software: "Ollama", machine: "c")
        let server = { (candidate: YourModelCandidate) in
            YourModelServer(address: candidate.address, software: nil, machine: candidate.machine, models: [candidate])
        }
        #expect(YourModelPick.ranked([server(idle), server(small), server(large)]).map(\.model) == ["gemma4-26b-it", "qwen3-4b-instruct", "qwen3:14b"])
    }

    @Test func serversThatRunWhatTheyListAreRunning() throws {
        let list = json(#"{"data":[{"id":"Qwen/Qwen3-8B","owned_by":"vllm"}]}"#)
        let software = YourModelSurvey.software(of: list, port: 8000)
        #expect(software == "vLLM")
        let server = try #require(YourModelSurvey.read(listing: list, address: "http://box:8000", machine: "box", software: software))
        #expect(server.models.first?.running == true)
    }

    @Test func ollamaAndLMStudioSayWhatIsLoaded() throws {
        let list = json(#"{"data":[{"id":"qwen3:4b","owned_by":"library"},{"id":"llama3.2:3b","owned_by":"library"}]}"#)
        let loaded = json(#"{"models":[{"name":"qwen3:4b","details":{"parameter_size":"4.0B"}}]}"#)
        let server = try #require(
            YourModelSurvey.read(
                listing: list, address: "http://mac:11434", machine: "mac",
                software: YourModelSurvey.software(of: list, port: 11434), memory: YourModelSurvey.Memory(ollama: loaded)))
        #expect(server.software == "Ollama")
        #expect(server.models.map(\.running) == [true, false])
        let studio = json(#"{"data":[{"id":"qwen3-8b","state":"loaded","type":"llm"},{"id":"nomic-embed","state":"loaded","type":"embeddings"}]}"#)
        let studioList = json(#"{"data":[{"id":"qwen3-8b","owned_by":"organization_owner"},{"id":"nomic-embed","owned_by":"organization_owner"}]}"#)
        let lm = try #require(
            YourModelSurvey.read(
                listing: studioList, address: "http://mac:1234", machine: "mac",
                software: YourModelSurvey.software(of: studioList, port: 1234), memory: YourModelSurvey.Memory(lmStudio: studio)))
        #expect(lm.software == "LM Studio")
        #expect(lm.models.map(\.model) == ["qwen3-8b"])
    }

    @Test func theSameServerReachedTwiceIsKeptOnce() {
        let local = swapServer(machine: YourModelWords.thisDevice, address: "http://127.0.0.1:8081")
        let tailnet = swapServer(machine: "arch", address: "http://arch.tail1234.ts.net:8081")
        let other = swapServer(machine: "arch", address: "http://arch.tail1234.ts.net:9999")
        let kept = YourModelSurvey.deduplicated([local, tailnet, other])
        #expect(kept.map(\.address) == ["http://127.0.0.1:8081", "http://arch.tail1234.ts.net:9999"])
    }

    @Test func placesAreEachMachineOnceThisDeviceFirst() {
        let profiles = [
            ConnectionProfile(id: "1", name: "arch claude", backend: .claudeCode, baseURL: URL(string: "http://arch.tail1234.ts.net:4098")!),
            ConnectionProfile(id: "2", name: "arch omp", backend: .omp, baseURL: URL(string: "http://ARCH.tail1234.ts.net:4099")!),
            ConnectionProfile(id: "3", name: "mac", backend: .claudeCode, baseURL: URL(string: "http://100.64.0.7:4098")!),
        ]
        let places = YourModelSurvey.places(
            profiles: profiles, painting: ImageGenEndpoint(host: "arch.tail1234.ts.net"), thisDevice: true)
        #expect(places.map(\.host) == ["127.0.0.1", "arch.tail1234.ts.net", "100.64.0.7"])
        #expect(places.map(\.machine) == [YourModelWords.thisDevice, "arch", "100.64.0.7"])
        #expect(YourModelSurvey.places(profiles: [], painting: nil, thisDevice: false).isEmpty)
    }

    @Test func nothingIsLoadedBehindThePersonsBack() throws {
        let server = swapServer()
        let penny = try #require(server.models.first { $0.model == "pennyroyal" })
        let flint = try #require(server.models.first { $0.model == "flint" })
        #expect(YourModelPick.asksOnItsOwn(penny))
        #expect(!YourModelPick.asksOnItsOwn(flint))
        #expect(!YourModelPick.asksOnItsOwn(nil))
        let ollamaIdle = YourModelCandidate(address: "http://m:11434", model: "qwen3:4b", running: false, software: "Ollama", machine: "m")
        #expect(YourModelPick.asksOnItsOwn(ollamaIdle))
        let found = ImageGenHelper(address: "http://127.0.0.1:8081", model: "flint", chosenByHand: false)
        let legacy = ImageGenHelper(address: "http://127.0.0.1:8081", model: "flint")
        let picked = ImageGenHelper(address: "http://127.0.0.1:8081", model: "flint", chosenByHand: true)
        #expect(YourModelPick.replaces(found, with: penny) && YourModelPick.replaces(legacy, with: penny))
        #expect(!YourModelPick.replaces(picked, with: penny))
        #expect(!YourModelPick.replaces(penny.helper(chosenByHand: false), with: penny))
        #expect(YourModelPick.replaces(nil, with: penny) && !YourModelPick.replaces(found, with: nil))
        #expect(YourModelPick.suggestion(for: picked, in: [server])?.model == "pennyroyal")
        #expect(YourModelPick.suggestion(for: penny.helper(chosenByHand: true), in: [server]) == nil)
        #expect(YourModelPick.suggestion(for: nil, in: [server]) == nil)
        #expect(YourModelWords.suggestTitle(penny) == "Pennyroyal is kept warm")
        #expect(YourModelWords.excerpt("one two three", words: 2) == "one two …")
        #expect(YourModelWords.excerpt("one two", words: 2) == "one two")
    }

    @Test func theFiledModelIsFoundAgainAndTheRateIsHonest() {
        let helper = ImageGenHelper(address: "http://127.0.0.1:8081/", model: "pennyroyal")
        #expect(YourModelPick.find(helper, in: [swapServer()])?.label == "Pennyroyal")
        #expect(YourModelPick.find(nil, in: [swapServer()]) == nil)
        let start = Date(timeIntervalSince1970: 0)
        #expect(YourModelProving.rate(pieces: 101, from: start, to: start.addingTimeInterval(1)) == 100)
        #expect(YourModelProving.rate(pieces: 3, from: start, to: start.addingTimeInterval(1)) == nil)
    }

    @Test func thePrivacyLineKnowsWhereWordsGo() {
        let home = ImageGenHelper(address: "http://arch.tail1234.ts.net:8081", model: "pennyroyal")
        let away = ImageGenHelper(address: "http://models.example.com:8081", model: "pennyroyal")
        #expect(YourModelStore.isPrivate(home) && !YourModelStore.isPrivate(away))
        #expect(YourModelWords.privacy(home).contains("arch"))
        #expect(YourModelWords.privacy(away).contains("internet"))
        #expect(YourModelStore.plainWordsAddress(home) == "http://arch.tail1234.ts.net:8081/v1")
    }

    @Test func rowsSayWhatAModelIsAndWhy() throws {
        let penny = try #require(swapServer().models.first { $0.model == "pennyroyal" })
        #expect(YourModelWords.state(penny) == "Kept warm")
        #expect(YourModelWords.detail(penny).hasPrefix("Qwen 3.8 27B"))
        #expect(YourModelWords.defaultReason(penny).contains("llama-swap"))
        let flint = try #require(swapServer().models.first { $0.model == "flint" })
        #expect(YourModelWords.state(flint) == "Not loaded")
        #expect(YourModelWords.caution(flint)?.contains("may stop another") == true)
        #expect(YourModelWords.caution(penny) == nil)
        #expect(YourModelWords.seconds(0.214) == "214 ms" && YourModelWords.seconds(2.25) == "2.2 s" || YourModelWords.seconds(2.25) == "2.3 s")
        #expect(YourModelProof(firstWord: 0.2, perSecond: 147.6, text: "x").line == "First word in 200 ms · 148 tokens a second")
    }
}
