import Foundation
import Testing

@testable import TailscodeCore

@Suite struct PlainModelScoutTests {
    let swap = URL(string: "http://127.0.0.1:8081/v1")!
    let ollama = URL(string: "http://127.0.0.1:11434/v1")!

    func json(_ text: String) -> Data { Data(text.utf8) }

    var swapList: Data {
        json(
            """
            {"object":"list","data":[
            {"id":"flint","name":"Flint","description":"Flint 40B · llama.cpp · Q8_0 · 256K","status":{"value":"unloaded"}},
            {"id":"gpulens-helper","name":"gpulens Helper","description":"Qwen3 4B Instruct · llama.cpp · Q4_K_M · 4K","status":{"value":"unloaded"}},
            {"id":"nemotron-3.5-bolt-74b-a9b-24gb-abliterated-gguf","name":"Bolt Unchained","description":"Nemotron 3.5 Bolt 74B · Uncensored · llama.cpp · IQ2 · DFlash · 256K","status":{"value":"loaded"}},
            {"id":"qwen3-0_6b-gguf","name":"Qwen3 0.6B","description":"Qwen3 0.6B · llama.cpp · Q4_K_M · 16K","status":{"value":"unloaded"}},
            {"id":"qwen3-4b-instruct-gguf","name":"Qwen3 Instruct","description":"Qwen3 4B Instruct · llama.cpp · Q4_K_M · 16K","status":{"value":"unloaded"}},
            {"id":"qwen3-4b-thinking-gguf","name":"Qwen3 Thinking","description":"Qwen3 4B Thinking · llama.cpp · Q4_K_M · 16K","status":{"value":"unloaded"}},
            {"id":"unrager-4b-gguf","name":"unrager Live","description":"unrager 4B · llama.cpp · Q8_0 · 8K","status":{"value":"loaded"}},
            {"id":"sglang-gptoss120b","name":"GPT-OSS","description":"GPT-OSS 120B · SGLang · MXFP4 · DFlash · 128K","status":{"value":"unloaded"}}
            ]}
            """)
    }

    @Test func sizesAreReadFromNamesAndDescriptions() {
        let cases: [(String, Double?)] = [
            ("qwen3-4b-instruct-gguf", 4), ("lfm2-1_2b-gguf", 1.2), ("Qwen3 0.6B", 0.6), ("gemma4-e2b-gguf", 2),
            ("nemotron-3.5-bolt-74b-a9b-24gb-gguf", 74), ("qwen3:4b", 4), ("llama3.1:8b", 8), ("7.6B", 7.6),
            ("phi3:3.8b-mini", 3.8), ("flint", nil), ("qwen3", nil), ("Flint 40B · llama.cpp · Q8_0", 40),
        ]
        for (text, size) in cases {
            #expect(PlainModelScout.parameters(in: [text]) == size, "\(text)")
        }
    }

    @Test func llamaSwapsListCarriesWhatIsRunning() {
        let models = PlainModelScout.models(fromList: swapList, kind: .llamaSwap, base: swap)
        #expect(models.count == 8)
        #expect(models.first { $0.id == "unrager-4b-gguf" }?.running == true)
        #expect(models.first { $0.id == "flint" }?.running == false)
        #expect(models.first { $0.id == "flint" }?.parameters == 40)
        #expect(models.first { $0.id == "gpulens-helper" }?.parameters == 4)
        let running = PlainModelScout.swapRunning(json(#"{"running":[{"model":"unrager-4b-gguf","state":"ready"}]}"#))
        #expect(running == ["unrager-4b-gguf"])
        #expect(PlainModelScout.swapRunning(json(#"{"models":[]}"#)) == nil)
    }

    @Test func aRunningGeneralModelLeadsWhateverItsSizeAndABigOneIsNeverStarted() {
        let models = PlainModelScout.models(fromList: swapList, kind: .llamaSwap, base: swap)
        let order = PlainModelScout.ranked(models).map(\.model.id)
        #expect(order.first == "nemotron-3.5-bolt-74b-a9b-24gb-abliterated-gguf")
        #expect(order[1] == "unrager-4b-gguf")
        #expect(order.firstIndex(of: "qwen3-4b-instruct-gguf")! < order.firstIndex(of: "flint")!)
        #expect(order.firstIndex(of: "flint")! < order.firstIndex(of: "sglang-gptoss120b")!)
        #expect(order.firstIndex(of: "qwen3-4b-thinking-gguf")! > order.firstIndex(of: "qwen3-0_6b-gguf")!)
        #expect(PlainModelScout.choose(models) == .use(models.first { $0.id.hasPrefix("nemotron") }!))
        #expect(PlainModelScout.bestReady(models)?.id.hasPrefix("nemotron") == true)
    }

    @Test func aSmallInstructModelThatIsRunningLeadsABigOne() {
        var models = PlainModelScout.models(fromList: swapList, kind: .llamaSwap, base: swap)
        models = models.map { model in
            var model = model
            if model.id == "gpulens-helper" { model.running = true }
            return model
        }
        #expect(PlainModelScout.bestReady(models)?.id == "gpulens-helper")
        let helper = models.first { $0.id == "gpulens-helper" }!
        let bolt = models.first { $0.id.hasPrefix("nemotron") }!
        #expect(PlainModelScout.bestReady(models, refused: [PlainModelScout.key(helper)])?.id == bolt.id)
        let gone = models.filter { $0.running != true }
        #expect(PlainModelScout.bestReady(gone) == nil)
        let generic = PlainModelScout.Model(id: "served", kind: .other, base: swap)
        #expect(PlainModelScout.bestReady([generic])?.id == "served")
    }

    @Test func aModelLlamaSwapWouldHaveToStartIsAskedAboutNotStarted() {
        let models = PlainModelScout.models(fromList: swapList, kind: .llamaSwap, base: swap)
        let refused = Set(models.filter { $0.running == true }.map(PlainModelScout.key))
        guard case .ask(let model) = PlainModelScout.choose(models, refused: refused) else {
            Issue.record("a model that is not running on llama-swap is asked about")
            return
        }
        #expect(model.title == "Qwen3 Instruct" || model.id == "gpulens-helper")
    }

    @Test func ollamaStartsASmallModelBesideTheOthersWithoutAsking() {
        let tags = PlainModelScout.ollamaModels(
            json(
                #"{"models":[{"name":"qwen3:4b","details":{"parameter_size":"4.0B"}},{"name":"llama3.3:70b","details":{"parameter_size":"70.6B"}},{"name":"nomic-embed-text:latest","details":{"parameter_size":"137M"}}]}"#
            ))!
        #expect(tags.count == 3 && tags[0].parameters == 4)
        let models = tags.map { PlainModelScout.Model(id: $0.name, parameters: $0.parameters, running: false, kind: .ollama, base: ollama) }
        guard case .use(let model) = PlainModelScout.choose(models) else {
            Issue.record("Ollama keeps several models loaded, so a small one is used without asking")
            return
        }
        #expect(model.id == "qwen3:4b")
        #expect(PlainModelScout.score(models[2]) == nil)
    }

    @Test func lmStudiosStatesAreRead() {
        let states = PlainModelScout.lmStudioStates(
            json(
                #"{"object":"list","data":[{"id":"qwen2.5-3b-instruct","type":"llm","state":"loaded"},{"id":"text-embedding-nomic","type":"embeddings","state":"not-loaded"}]}"#
            ))
        #expect(states?["qwen2.5-3b-instruct"]?.loaded == true)
        #expect(states?["text-embedding-nomic"]?.embedding == true)
        #expect(PlainModelScout.lmStudioStates(swapList) == nil)
    }

    @Test func nothingFoundIsNone() {
        #expect(PlainModelScout.choose([]) == .none)
        let whisper = PlainModelScout.Model(id: "whisper-large-v3", running: true, kind: .other, base: swap)
        #expect(PlainModelScout.choose([whisper]) == .none)
    }

    @Test func aTrialLineMustReadAsDoing() {
        #expect(PlainModelScout.passes("Checking what changed in the project"))
        #expect(!PlainModelScout.passes("The status of the repository"))
        #expect(!PlainModelScout.passes(nil))
    }
}
