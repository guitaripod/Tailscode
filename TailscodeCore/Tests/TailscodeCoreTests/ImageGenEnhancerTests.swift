import Foundation
import Testing

@testable import TailscodeCore

/// The prompt helper's own half: where one is looked for, which model is picked when a machine
/// offers a dozen, and what the studio does with an answer that is not the JSON it asked for.
struct ImageGenEnhancerTests {
    @Test func theMachineThatPaintsIsAskedFirst() {
        let endpoint = ImageGenEndpoint(host: "graphics-box", port: 8189)
        let candidates = ImageGenHelperFinder.candidates(near: endpoint)
        #expect(candidates.first?.contains("graphics-box") == true)
        #expect(candidates.contains("http://graphics-box:11434"))
        #expect(candidates.contains("http://127.0.0.1:8081"))
        #expect(
            candidates.count == ImageGenHelperFinder.ports.count * 2,
            "two hosts, the painting machine and this one")
        let alone = ImageGenHelperFinder.candidates(near: nil)
        #expect(alone.allSatisfy { $0.contains("127.0.0.1") })
    }

    /// Measured on real endpoints: a four-billion instruct model writes the paragraph in about a
    /// second and a half, a thinking model spends its budget thinking, and an embedding model is
    /// not a writer at all.
    @Test func theModelPickedIsOneThatCanActuallyWriteAParagraph() {
        let offered = [
            "nomic-embed-text", "qwen3-1_7b-gguf", "qwen3-4b-instruct-gguf",
            "qwen3-4b-thinking-gguf", "gemma3-1b-gguf",
        ]
        #expect(ImageGenHelperFinder.preferred(among: offered) == "qwen3-4b-instruct-gguf")
        #expect(ImageGenHelperFinder.preferred(among: []) == nil)
        #expect(
            ImageGenHelperFinder.score("qwen3-4b-thinking-gguf")
                < ImageGenHelperFinder.score("qwen3-4b-instruct-gguf"))
        #expect(ImageGenHelperFinder.score("bge-reranker") < 0)
    }

    @Test func aHelperIsNamedByItsModelAndItsMachine() {
        let helper = ImageGenHelper(address: "http://127.0.0.1:8081/", model: "qwen3-4b-instruct-gguf")
        #expect(helper.address == "http://127.0.0.1:8081", "a trailing slash is not an address")
        #expect(helper.displayHost == "127.0.0.1:8081")
        #expect(helper.chip.count <= 18)
        #expect(helper.enabled)
    }

    /// The studio asks for one JSON object; a model that wraps it, or ignores the format and
    /// writes the paragraph anyway, is still answering.
    @Test func anAnswerIsReadWhateverItIsWrappedIn() throws {
        let fenced = """
            ```json
            {"rewritten_prompt": "The image is a wide photograph of a fox.", "wh_ratio": "21:9"}
            ```
            """
        let read = try #require(ImageGenBrief.readExpansion(fenced))
        #expect(read.aspect == .wide)
        #expect(ImageGenBrief.readExpansion("{\"wh_ratio\": \"1:1\"}") == nil)
    }

    @Test func theHelperWritesToTheSameRulesTheStudioTeaches() {
        let system = ImageGenEnhancer.systemPrompt
        #expect(system.contains("rewritten_prompt"))
        #expect(system.contains("wh_ratio"))
        #expect(system.lowercased().contains("lighting"))
        #expect(system.contains("21:9"), "every shape the chips offer must be nameable")
        #expect(system.contains("9:16"))
        for ratio in ["1:1", "3:2", "2:3", "16:9", "9:16", "21:9"] {
            #expect(ImageGenBrief.aspect(forRatio: ratio) != nil)
        }
    }
}
