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
        #expect(ImageGenHelperFinder.preferred(amongNames: offered) == "qwen3-4b-instruct-gguf")
        #expect(ImageGenHelperFinder.preferred(amongNames: []) == nil)
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

/// The picker's half: every machine surveyed rather than the first, models read with the names
/// and loaded marks their servers give them, and a default that is the best writer rather than
/// the fastest one.
struct ImageGenHelperPickerTests {
    static let llamaSwap = """
        {"data":[
          {"id":"qwen3-4b-instruct-gguf","object":"model","owned_by":"llama-swap","name":"Qwen3 4B Instruct · llama.cpp · Q4_K_M · 16k","status":{"value":"loaded"}},
          {"id":"qwen38-nvfp4","object":"model","owned_by":"llama-swap","name":"Qwen 3.8 27B · NVFP4 · Daily · MTP","status":{"value":"unloaded"}},
          {"id":"sglang-gptoss120b","object":"model","owned_by":"llama-swap","name":"GPT-OSS 120B · SGLang · MXFP4","status":{"value":"unloaded"}},
          {"id":"qwen3-4b-thinking-gguf","object":"model","owned_by":"llama-swap","name":"Qwen3 4B Thinking","status":{"value":"unloaded"}},
          {"id":"gemma4-e2b-gguf","object":"model","owned_by":"llama-swap","name":"Gemma 4 E2B · llama.cpp","status":{"value":"unloaded"}},
          {"id":"nomic-embed-text","object":"model","owned_by":"llama-swap","name":"Nomic Embed","status":{"value":"loaded"}}
        ]}
        """
    static let ollama = """
        {"object":"list","data":[{"id":"qwen2.5:7b-instruct","object":"model","created":1,"owned_by":"library"},{"id":"llama3.2:1b","object":"model","created":1,"owned_by":"library"}]}
        """

    @Test func aListingIsReadWithItsNamesAndItsLoadedMarks() throws {
        let server = try #require(
            ImageGenHelperFinder.read(
                listing: Data(Self.llamaSwap.utf8), address: "http://127.0.0.1:8081/"))
        #expect(server.address == "http://127.0.0.1:8081")
        #expect(server.software == "llama-swap")
        #expect(server.heading == "llama-swap · 127.0.0.1:8081")
        #expect(server.models.count == 6)
        let big = try #require(server.models.first { $0.id == "qwen38-nvfp4" })
        #expect(big.name == "Qwen 3.8 27B · NVFP4 · Daily · MTP")
        #expect(big.loaded == false)
        #expect(big.billions == 27)
        #expect(big.detail == "qwen38-nvfp4")
        let small = try #require(server.models.first { $0.id == "qwen3-4b-instruct-gguf" })
        #expect(small.loaded == true)
        #expect(small.detail?.hasSuffix(ImageGenRewriteWords.loadedMark) == true)
        #expect(server.models.first { $0.id == "gemma4-e2b-gguf" }?.billions == 2)

        let plain = try #require(
            ImageGenHelperFinder.read(listing: Data(Self.ollama.utf8), address: "http://box:11434"))
        #expect(plain.software == "Ollama")
        #expect(plain.models.map(\.id) == ["qwen2.5:7b-instruct", "llama3.2:1b"])
        #expect(plain.models[0].name == nil)
        #expect(plain.models[0].loaded == nil)
        #expect(plain.models[0].billions == 7)
        #expect(plain.models[0].detail == nil)
    }

    /// The twenty-seven-billion writer beats the four-billion one that happens to be in memory:
    /// the paragraph is judged on what it says. The hundred-and-twenty-billion one is a minute's
    /// load for a paragraph, the thinking one spends its budget thinking, and the embedder is
    /// not a writer at all.
    @Test func theBestWriterIsTheDefaultNotTheFastest() throws {
        let server = try #require(
            ImageGenHelperFinder.read(
                listing: Data(Self.llamaSwap.utf8), address: "http://127.0.0.1:8081"))
        #expect(ImageGenHelperFinder.preferred(among: server.models)?.id == "qwen38-nvfp4")
        let across = try #require(ImageGenHelperFinder.preferred(across: [server]))
        #expect(across.model == "qwen38-nvfp4")
        #expect(across.label == "Qwen 3.8 27B · NVFP4 · Daily · MTP")
        #expect(across.name == "Qwen 3.8 27B")
        #expect(across.chip == "Qwen 3.8 27B")
        #expect(
            ImageGenHelperFinder.score(ImageGenHelperModel(id: "sglang-gptoss120b", name: "GPT-OSS 120B"))
                < ImageGenHelperFinder.score(ImageGenHelperModel(id: "qwen38-nvfp4", name: "Qwen 3.8 27B")))
        #expect(ImageGenHelperFinder.score(ImageGenHelperModel(id: "nomic-embed-text")) < -50)
    }

    @Test func aLoadedModelBreaksATieAndNothingMore() {
        let loaded = ImageGenHelperModel(id: "a-27b", loaded: true)
        let cold = ImageGenHelperModel(id: "b-27b", loaded: false)
        #expect(ImageGenHelperFinder.preferred(among: [cold, loaded])?.id == "a-27b")
        let coldBig = ImageGenHelperModel(id: "c-27b", loaded: false)
        let warmSmall = ImageGenHelperModel(id: "d-4b-instruct", loaded: true)
        #expect(ImageGenHelperFinder.preferred(among: [warmSmall, coldBig])?.id == "c-27b")
    }

    @Test func aHelperRemembersTheNameItWasListedUnder() throws {
        let helper = ImageGenHelper(
            address: "http://box:8081", model: ImageGenHelperModel(id: "qwen38-nvfp4", name: "Qwen 3.8 27B · NVFP4"))
        let data = try JSONEncoder().encode(helper)
        let back = try JSONDecoder().decode(ImageGenHelper.self, from: data)
        #expect(back.label == "Qwen 3.8 27B · NVFP4")
        #expect(back.name == "Qwen 3.8 27B")
        let old = Data("{\"address\":\"http://box:8081\",\"model\":\"qwen3-4b-instruct-gguf\",\"enabled\":true}".utf8)
        let legacy = try JSONDecoder().decode(ImageGenHelper.self, from: old)
        #expect(legacy.label == nil)
        #expect(legacy.name == "qwen3-4b-instruct-gguf")
    }
}

/// The streamed half: the paragraph read out of a JSON object that is still being written, the
/// context the helper is handed, and the card's own words.
struct ImageGenRewriteTests {
    @Test func theParagraphIsReadWhileTheObjectIsStillOpen() {
        #expect(ImageGenBrief.partialExpansion("") == "")
        #expect(ImageGenBrief.partialExpansion("{") == "")
        #expect(ImageGenBrief.partialExpansion("{\"rewritten_pro") == "")
        #expect(ImageGenBrief.partialExpansion("{\"rewritten_prompt\": \"") == "")
        #expect(ImageGenBrief.partialExpansion("{\"rewritten_prompt\": \"A wide photo") == "A wide photo")
        #expect(
            ImageGenBrief.partialExpansion("{\"rewritten_prompt\": \"A sign reads \\\"OPEN\\\" and")
                == "A sign reads \"OPEN\" and")
        #expect(
            ImageGenBrief.partialExpansion("{\"rewritten_prompt\": \"Done.\", \"wh_ratio\": \"3:2\"}")
                == "Done.")
        #expect(ImageGenBrief.partialExpansion("{\"rewritten_prompt\": \"Half an escape\\") == "Half an escape")
        #expect(ImageGenBrief.partialExpansion("{\"rewritten_prompt\": \"caf\\u00e9\"}") == "café")
        #expect(ImageGenBrief.partialExpansion("```json\n{\"rewritten_prompt\": \"Fenced") == "Fenced")
    }

    @Test func aModelThatWritesProseIsShownAsItWrites() {
        #expect(ImageGenBrief.partialExpansion("A wide realistic photograph of a fox") == "A wide realistic photograph of a fox")
        #expect(ImageGenBrief.partialExpansion("<think>hmm") == "")
        #expect(ImageGenBrief.partialExpansion("<think>hmm</think>\n{\"rewritten_prompt\": \"After") == "After")
        #expect(ImageGenBrief.stripThinking("<think>a</think>b<think>c") == "b")
        let read = ImageGenBrief.readExpansion("<think>plan</think>{\"rewritten_prompt\": \"Ok.\", \"wh_ratio\": \"9:16\"}")
        #expect(read?.prompt == "Ok.")
        #expect(read?.aspect == .tall)
    }

    @Test func theHelperIsToldWhatTheBriefDoesNotSay() {
        let chosen = ImageGenRewriteContext(engine: .quality, aspect: .wide, referenceCount: 0, negative: "text, watermark")
        let ask = ImageGenBrief.expansionAsk("cat astronaut", context: chosen)
        #expect(ask.contains("The request: cat astronaut"))
        #expect(ask.contains("Qwen Image 2.1"))
        #expect(ask.contains("already chosen: 21:9"))
        #expect(ask.contains("wh_ratio \"21:9\""))
        #expect(ask.contains("text, watermark"))
        #expect(ask.contains("rewritten_prompt"))

        let edit = ImageGenBrief.expansionAsk(
            "make <image1> wear the hat from <image2>",
            context: ImageGenRewriteContext(engine: .fast, aspect: .wide, referenceCount: 2))
        #expect(edit.contains("<image1>, <image2>"))
        #expect(!edit.contains("already chosen"), "an edit takes its shape from the picture")
        #expect(edit.contains("Klein"))

        let free = ImageGenBrief.expansionAsk("a fox", context: ImageGenRewriteContext())
        #expect(!free.contains("already chosen"))
        #expect(!free.contains("Keep out of the frame"))
        #expect(ImageGenBrief.expansionAsk("a fox") == free)
    }

    @Test func aRevisionCarriesTheParagraphAndTheInstruction() {
        let context = ImageGenRewriteContext(
            instruction: "more dramatic light", previous: "A wide photograph of a fox in flat noon light.")
        #expect(context.isRevision)
        let ask = ImageGenBrief.expansionAsk("fox", context: context)
        #expect(ask.contains("Instruction: more dramatic light"))
        #expect(ask.contains("Previous description: A wide photograph"))
        #expect(ask.contains("The original request: fox"))
        #expect(!ask.contains("Rules: open by naming"))
        #expect(!ImageGenRewriteContext(instruction: "  ", previous: "x").isRevision)
        #expect(!ImageGenRewriteContext(instruction: "x", previous: nil).isRevision)
    }

    @Test func theSlotTellsTheHelperItsOwnDecisions() {
        var slot = ImageGenSlot(endpoint: ImageGenEndpoint(host: "box"))
        slot.setEngine(.quality)
        slot.setAspect(.wide)
        slot.setNegative("blur")
        #expect(slot.rewriteContext(aspectChosen: true).aspect == .wide)
        #expect(slot.rewriteContext(aspectChosen: false).aspect == nil)
        #expect(slot.rewriteContext(aspectChosen: true).negative == "blur")
        slot.setEngine(.fast)
        #expect(slot.rewriteContext(aspectChosen: true).negative == "", "Klein reads no avoid list")
        slot.hold(ImageGenReference(path: "/tmp/a.png"))
        #expect(slot.rewriteContext(aspectChosen: true).aspect == nil, "an edit takes its shape from the picture")
        #expect(slot.rewriteContext(aspectChosen: true).referenceCount == 1)
    }

    @Test func theCardSaysWhoIsWritingAndWhatLanded() {
        let helper = ImageGenHelper(address: "http://box:8081", model: "qwen38-nvfp4", label: "Qwen 3.8 27B · NVFP4")
        var draft = ImageGenRewriteDraft(original: "fox", helper: helper)
        #expect(draft.isWriting)
        #expect(!draft.isUsable)
        #expect(draft.headline == "Writing with Qwen 3.8 27B on box:8081…")
        draft.written = "A wide photograph of a fox on a ridge"
        #expect(draft.headline == "Writing with Qwen 3.8 27B · 9 words…")
        draft.phase = .landed
        draft.aspect = .landscape
        #expect(draft.isUsable)
        #expect(draft.headline == "Rewritten by Qwen 3.8 27B · 9 words · 3:2")
        draft.phase = .failed("The prompt helper is not answering")
        #expect(draft.headline == "The prompt helper is not answering")
        #expect(!draft.isUsable)
    }
}

/// The socket's binary half: a sketch after every step, read out of ComfyUI's own framing.
struct ImageGenPreviewTests {
    private func frame(event: UInt32, kind: UInt32, body: [UInt8]) -> Data {
        var data = Data()
        for value in [event, kind] {
            data.append(contentsOf: [
                UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF),
                UInt8(value & 0xFF),
            ])
        }
        data.append(contentsOf: body)
        return data
    }

    @Test func aPreviewFrameIsReadByItsEventAndItsEncoding() throws {
        let jpeg = try #require(ImageGenPreviewFrame.read(frame(event: 1, kind: 1, body: [0xFF, 0xD8, 0xFF])))
        #expect(jpeg.encoding == .jpeg)
        #expect(jpeg.bytes == Data([0xFF, 0xD8, 0xFF]))
        let png = try #require(ImageGenPreviewFrame.read(frame(event: 1, kind: 2, body: [0x89, 0x50])))
        #expect(png.encoding == .png)
        #expect(ImageGenPreviewFrame.read(frame(event: 3, kind: 1, body: [1])) == nil, "a text event is not a picture")
        #expect(ImageGenPreviewFrame.read(frame(event: 1, kind: 9, body: [1])) == nil)
        #expect(ImageGenPreviewFrame.read(frame(event: 1, kind: 1, body: [])) == nil)
        #expect(ImageGenPreviewFrame.read(Data([0, 0, 0, 1])) == nil)
    }

    @Test func aFrameFrontedByMetadataIsReadPastIt() throws {
        let meta = Data("{\"node_id\":\"3\"}".utf8)
        var data = Data([0, 0, 0, 4])
        data.append(contentsOf: [0, 0, 0, UInt8(meta.count)])
        data.append(meta)
        data.append(contentsOf: [0, 0, 0, 1, 0xFF, 0xD8])
        let read = try #require(ImageGenPreviewFrame.read(data))
        #expect(read.encoding == .jpeg)
        #expect(read.bytes == Data([0xFF, 0xD8]))
        var short = Data([0, 0, 0, 4, 0, 0, 0, 200])
        short.append(meta)
        #expect(ImageGenPreviewFrame.read(short) == nil, "a length past the end is not a frame")
    }

    /// Linux Foundation hands a socket message over in sixteen-kilobyte pieces, each as if it
    /// were a message: the sketch is whole only once its encoding's end marker has arrived.
    @Test func aSketchSplitAcrossPiecesIsHandedOverWholeAndOnce() throws {
        var assembler = ImageGenPreviewAssembler()
        let whole = frame(event: 1, kind: 1, body: [0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9])
        let direct = assembler.feed(whole)
        #expect(direct?.bytes == Data([0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9]))

        #expect(assembler.feed(frame(event: 1, kind: 1, body: [0xFF, 0xD8, 1, 2])) == nil)
        #expect(assembler.feed(Data([3, 4, 5])) == nil)
        let joined = assembler.feed(Data([6, 0xFF, 0xD9]))
        #expect(joined?.encoding == .jpeg)
        #expect(joined?.bytes == Data([0xFF, 0xD8, 1, 2, 3, 4, 5, 6, 0xFF, 0xD9]))
        #expect(assembler.feed(Data([9, 9])) == nil, "a stray piece with nothing pending is not a picture")

        let iend: [UInt8] = [0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]
        #expect(assembler.feed(frame(event: 1, kind: 2, body: [0x89, 0x50, 0x4E, 0x47])) == nil)
        let png = assembler.feed(Data([0, 0, 0, 0] + iend))
        #expect(png?.encoding == .png)
        #expect(ImageGenPreviewAssembler.isComplete(Data([0xFF, 0xD8, 0xFF]), encoding: .jpeg) == false)
    }

    @Test func theSketchIsCaptionedByTheSamplersOwnStep() {
        #expect(ImageGenPreviewWords.caption(nil) == "Sketch")
        #expect(ImageGenPreviewWords.caption(ImageGenProgress(stage: .painting, step: 12, steps: 25)) == "Sketch · step 12 of 25")
        #expect(ImageGenPreviewWords.caption(ImageGenProgress(stage: .painting, step: 30, steps: 25)) == "Sketch · step 25 of 25")
    }
}
