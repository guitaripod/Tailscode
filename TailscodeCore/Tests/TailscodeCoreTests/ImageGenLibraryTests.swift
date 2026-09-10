import Foundation
import Testing

@testable import TailscodeCore

/// The gallery's readers, pinned against the shapes the machine actually produces: the listing
/// route's lines, a PNG head as ComfyUI writes it, and the three graphs the store has verified.
struct ImageGenLibraryTests {
    private static let qwenTextGraph = """
        {"9":{"class_type":"SaveImage","inputs":{"images":["8",0],"filename_prefix":"tailscode"}},
         "66":{"class_type":"EmptySD3LatentImage","inputs":{"width":1024,"height":1024,"batch_size":1}},
         "10":{"class_type":"VAELoader","inputs":{"vae_name":"qwen_image_vae.safetensors"}},
         "70":{"class_type":"FluxKontextMultiReferenceLatentMethod","inputs":{"conditioning":["68",0],"reference_latents_method":"index_timestep_zero"}},
         "71":{"class_type":"FluxKontextMultiReferenceLatentMethod","inputs":{"conditioning":["69",0],"reference_latents_method":"index_timestep_zero"}},
         "69":{"class_type":"CLIPTextEncode","inputs":{"clip":["61",0],"text":""}},
         "61":{"class_type":"CLIPLoader","inputs":{"clip_name":"qwen_2.5_vl_7b_fp8_scaled.safetensors","device":"default","type":"qwen_image"}},
         "8":{"class_type":"VAEDecode","inputs":{"samples":["65",0],"vae":["10",0]}},
         "68":{"class_type":"CLIPTextEncode","inputs":{"clip":["61",0],"text":"a serene mountain lake at dusk"}},
         "12":{"class_type":"UNETLoader","inputs":{"unet_name":"qwen_image_edit_2511_fp8mixed.safetensors","weight_dtype":"default"}},
         "65":{"class_type":"KSampler","inputs":{"model":["64",0],"positive":["70",0],"negative":["71",0],"latent_image":["66",0],"seed":7313980724340221071,"steps":30,"cfg":1.0,"sampler_name":"euler","scheduler":"simple","denoise":1.0}},
         "64":{"class_type":"CFGNorm","inputs":{"model":["90",0],"strength":1.0,"set_cfg_norm":false}},
         "90":{"class_type":"ModelSamplingAuraFlow","inputs":{"model":["12",0],"shift":3.1}}}
        """

    private static let kleinEditGraph = """
        {"81":{"class_type":"LoadImage","inputs":{"image":"test_edit.png"}},
         "80":{"class_type":"ImageScaleToTotalPixels","inputs":{"image":["81",0],"upscale_method":"nearest-exact","megapixels":1.0,"resolution_steps":64}},
         "99":{"class_type":"GetImageSize","inputs":{"image":["80",0]}},
         "66":{"class_type":"EmptyFlux2LatentImage","inputs":{"width":["99",0],"height":["99",1],"batch_size":1}},
         "62":{"class_type":"Flux2Scheduler","inputs":{"width":["99",0],"height":["99",1],"steps":4}},
         "70":{"class_type":"UNETLoader","inputs":{"unet_name":"flux-2-klein-4b.safetensors","weight_dtype":"default"}},
         "71":{"class_type":"CLIPLoader","inputs":{"clip_name":"qwen_3_4b.safetensors","type":"flux2","device":"default"}},
         "72":{"class_type":"VAELoader","inputs":{"vae_name":"flux2-vae.safetensors"}},
         "74":{"class_type":"CLIPTextEncode","inputs":{"clip":["71",0],"text":"Add a red wizard hat on top of the monitor."}},
         "82":{"class_type":"ConditioningZeroOut","inputs":{"conditioning":["74",0]}},
         "122":{"class_type":"VAEEncode","inputs":{"pixels":["80",0],"vae":["72",0]}},
         "121":{"class_type":"ReferenceLatent","inputs":{"conditioning":["82",0],"latent":["122",0]}},
         "123":{"class_type":"ReferenceLatent","inputs":{"conditioning":["74",0],"latent":["122",0]}},
         "63":{"class_type":"CFGGuider","inputs":{"model":["70",0],"positive":["123",0],"negative":["121",0],"cfg":1.0}},
         "73":{"class_type":"RandomNoise","inputs":{"noise_seed":42}},
         "61":{"class_type":"KSamplerSelect","inputs":{"sampler_name":"euler"}},
         "64":{"class_type":"SamplerCustomAdvanced","inputs":{"noise":["73",0],"guider":["63",0],"sampler":["61",0],"sigmas":["62",0],"latent_image":["66",0]}},
         "65":{"class_type":"VAEDecode","inputs":{"samples":["64",0],"vae":["72",0]}},
         "9":{"class_type":"SaveImage","inputs":{"images":["65",0],"filename_prefix":"klein_edit"}}}
        """

    private static let qwenEditGraph = """
        {"81":{"class_type":"LoadImage","inputs":{"image":"launch.png"}},
         "88":{"class_type":"FluxKontextImageScale","inputs":{"image":["81",0]}},
         "12":{"class_type":"UNETLoader","inputs":{"unet_name":"qwen_image_edit_2511_fp8mixed.safetensors","weight_dtype":"default"}},
         "61":{"class_type":"CLIPLoader","inputs":{"clip_name":"qwen_2.5_vl_7b_fp8_scaled.safetensors","type":"qwen_image","device":"default"}},
         "10":{"class_type":"VAELoader","inputs":{"vae_name":"qwen_image_vae.safetensors"}},
         "68":{"class_type":"TextEncodeQwenImageEditPlus","inputs":{"clip":["61",0],"vae":["10",0],"prompt":"make the sky bright orange","image1":["88",0]}},
         "69":{"class_type":"TextEncodeQwenImageEditPlus","inputs":{"clip":["61",0],"vae":["10",0],"prompt":"","image1":["88",0]}},
         "70":{"class_type":"FluxKontextMultiReferenceLatentMethod","inputs":{"conditioning":["68",0],"reference_latents_method":"index_timestep_zero"}},
         "71":{"class_type":"FluxKontextMultiReferenceLatentMethod","inputs":{"conditioning":["69",0],"reference_latents_method":"index_timestep_zero"}},
         "90":{"class_type":"ModelSamplingAuraFlow","inputs":{"model":["12",0],"shift":3.1}},
         "64":{"class_type":"CFGNorm","inputs":{"model":["90",0],"strength":1.0,"set_cfg_norm":false}},
         "65":{"class_type":"KSampler","inputs":{"model":["64",0],"positive":["70",0],"negative":["71",0],"latent_image":["75",0],"seed":2252231596,"steps":40,"cfg":1.0,"sampler_name":"euler","scheduler":"simple","denoise":1.0}},
         "75":{"class_type":"VAEEncode","inputs":{"pixels":["88",0],"vae":["10",0]}},
         "8":{"class_type":"VAEDecode","inputs":{"samples":["65",0],"vae":["10",0]}},
         "9":{"class_type":"SaveImage","inputs":{"images":["8",0],"filename_prefix":"edit_qwen"}}}
        """

    private static func graph(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    /// A PNG head exactly as PIL writes one for ComfyUI: signature, IHDR, a `tEXt` prompt chunk,
    /// then the first picture chunk — truncated, the way a ranged read hands it over.
    private static func png(width: Int, height: Int, texts: [(String, String)], international: Bool = false)
        -> Data
    {
        var data = Data(PNGHead.signature)
        func chunk(_ type: String, _ body: [UInt8]) {
            let length = UInt32(body.count)
            data.append(contentsOf: [
                UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF),
                UInt8(length & 0xFF),
            ])
            data.append(contentsOf: Array(type.utf8))
            data.append(contentsOf: body)
            data.append(contentsOf: [0, 0, 0, 0])
        }
        var ihdr: [UInt8] = []
        for value in [width, height] {
            ihdr += [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        }
        ihdr += [8, 6, 0, 0, 0]
        chunk("IHDR", ihdr)
        for (key, value) in texts {
            if international {
                chunk("iTXt", Array(key.utf8) + [0, 0, 0] + [0] + [0] + Array(value.utf8))
            } else {
                chunk("tEXt", Array(key.utf8) + [0] + Array(value.utf8))
            }
        }
        chunk("IDAT", [1, 2, 3, 4])
        return data.prefix(data.count - 3)
    }

    @Test func listingKeepsOrderAndOnlyPictures() {
        let items = ImageGenLibraryReading.items(fromListing: [
            "tailscode_00071_.png [output]", "tailscode_00070_.png [output]",
            "clip_00001_.mp4 [output]", ".DS_Store [output]", "scan.jpeg [output]",
        ] as [String])
        #expect(items.map(\.filename) == ["tailscode_00071_.png", "tailscode_00070_.png", "scan.jpeg"])
        #expect(items[2].kind == .jpeg)
        #expect(items[0].annotatedName == "tailscode_00071_.png [output]")
        #expect(ImageGenLibraryReading.items(fromListing: ["not": "a list"]).isEmpty)
    }

    @Test func pngHeadReadsDimensionsAndText() {
        let data = Self.png(width: 1280, height: 896, texts: [("prompt", Self.qwenTextGraph)])
        let size = PNGHead.dimensions(data)
        #expect(size?.width == 1280 && size?.height == 896)
        #expect(PNGHead.texts(data)["prompt"] == Self.qwenTextGraph)
        let facts = PNGHead.facts(data)
        #expect(facts.width == 1280)
        #expect(facts.recipe?.prompt == "a serene mountain lake at dusk")
        #expect(facts.aspect == .landscape)
        #expect(PNGHead.dimensions(Data([1, 2, 3])) == nil)
        #expect(PNGHead.texts(Data(PNGHead.signature)).isEmpty)
    }

    @Test func pngHeadReadsInternationalText() {
        let data = Self.png(
            width: 64, height: 64, texts: [("prompt", Self.qwenTextGraph)], international: true)
        #expect(PNGHead.graph(data)?.count == 13)
    }

    @Test func qwenTextRecipe() throws {
        let recipe = try #require(ComfyRecipe.read(graph: Self.graph(Self.qwenTextGraph)))
        #expect(recipe.prompt == "a serene mountain lake at dusk")
        #expect(recipe.negative == "")
        #expect(recipe.seed == 7_313_980_724_340_221_071)
        #expect(recipe.steps == 30)
        #expect(recipe.engine == .quality)
        #expect(recipe.mode == .generate)
        #expect(recipe.width == 1024 && recipe.height == 1024)
    }

    @Test func kleinEditRecipeFollowsGuiderAndNoise() throws {
        let recipe = try #require(ComfyRecipe.read(graph: Self.graph(Self.kleinEditGraph)))
        #expect(recipe.prompt == "Add a red wizard hat on top of the monitor.")
        #expect(recipe.seed == 42)
        #expect(recipe.steps == 4)
        #expect(recipe.engine == .fast)
        #expect(recipe.mode == .edit)
        #expect(recipe.reference == "test_edit.png")
        #expect(recipe.width == nil, "a size wired from the reference is not a number")
    }

    @Test func qwenEditRecipeReadsThePromptField() throws {
        let recipe = try #require(ComfyRecipe.read(graph: Self.graph(Self.qwenEditGraph)))
        #expect(recipe.prompt == "make the sky bright orange")
        #expect(recipe.steps == 40)
        #expect(recipe.mode == .edit)
        #expect(recipe.model == "qwen_image_edit_2511_fp8mixed.safetensors")
    }

    @Test func foreignGraphIsAPictureWithNoWords() {
        #expect(ComfyRecipe.read(graph: [:]) == nil)
        let odd = ComfyRecipe.read(graph: ["1": ["class_type": "SaveImage", "inputs": [:]]])
        #expect(odd?.prompt == nil)
        #expect(ImageGenFacts.caption(for: ImageGenLibraryFacts(recipe: odd)) == ImageGenLibraryWords.noWords)
        #expect(ImageGenFacts.caption(for: nil) == ImageGenLibraryWords.noWords)
    }

    @Test func factsLineSaysWhatIsKnown() {
        let facts = ImageGenLibraryFacts(
            bytes: 1_158_316, modifiedAt: nil, width: 1024, height: 1024,
            recipe: ComfyRecipe(seed: 12_345_678_901_234, steps: 30, engine: .quality))
        let line = ImageGenFacts.line(for: facts)
        #expect(line.hasPrefix("Qwen · 1024×1024"))
        #expect(line.contains("#1234…1234"))
        #expect(ImageGenFacts.line(for: nil) == "")
        #expect(ImageGenFacts.size(1_158_316) == "1.1 MB")
        #expect(ImageGenFacts.size(23_968) == "23 KB")
    }

    @Test func builtGraphsRoundTripThroughTheReader() throws {
        let edit = ImageGenClient.graph(
            prompt: "hat", engine: .fast, mode: .edit, aspect: .square, seed: 7,
            referenceName: "tailscode_00003_.png [output]")
        let recipe = try #require(ComfyRecipe.read(graph: edit))
        #expect(recipe.prompt == "hat" && recipe.seed == 7 && recipe.mode == .edit)
        #expect(recipe.reference == "tailscode_00003_.png [output]")
        #expect(recipe.engine == .fast)
        let json = try JSONSerialization.data(withJSONObject: edit)
        #expect(!json.isEmpty, "the graph serialises, which is what the queue needs")

        let paint = ImageGenClient.graph(
            prompt: "lake", engine: .fast, mode: .generate, aspect: .wide, seed: 9,
            referenceName: nil)
        let painted = try #require(ComfyRecipe.read(graph: paint))
        #expect(painted.mode == .generate && painted.width == 1536)

        let qwen = ImageGenClient.graph(
            prompt: "sky", engine: .quality, mode: .edit, aspect: .square, seed: 3,
            referenceName: "ref.png")
        #expect(ComfyRecipe.read(graph: qwen)?.prompt == "sky")
    }

    @Test func queuePlaceIsReadOffTheMachinesQueue() {
        let queue: [String: Any] = [
            "queue_running": [[0, "abc", [:], [:], []]],
            "queue_pending": [[1, "def", [:], [:], []]],
        ]
        #expect(ImageGenClient.place(of: "abc", inQueue: queue) == .running)
        #expect(ImageGenClient.place(of: "def", inQueue: queue) == .pending)
        #expect(ImageGenClient.place(of: "zzz", inQueue: queue) == .gone)
    }

    @Test func headersAreRead() {
        #expect(
            ImageGenLibraryReading.total(fromContentRange: "bytes 0-65535/1158316", contentLength: nil)
                == 1_158_316)
        #expect(ImageGenLibraryReading.total(fromContentRange: nil, contentLength: "900") == 900)
        let date = ImageGenLibraryReading.date(fromHTTP: "Mon, 07 Sep 2026 16:51:03 GMT")
        #expect(date?.timeIntervalSince1970 == 1_788_799_863)
    }

    @Test func libraryWordsAreHonestAboutStaleness() {
        let now = Date(timeIntervalSince1970: 1_788_800_000)
        #expect(ImageGenLibraryWords.line(count: 0, staleSince: nil) == ImageGenLibraryWords.count(0))
        #expect(
            ImageGenLibraryWords.line(count: 3, staleSince: now.addingTimeInterval(-120), now: now)
                == "3 pictures · as of 2 min ago")
        #expect(ImageGenLibraryWords.day(now, now: now) == "Today")
        #expect(ImageGenLibraryWords.day(now.addingTimeInterval(-86_400), now: now) == "Yesterday")
        #expect(!ImageGenLibraryWords.day(now.addingTimeInterval(-86_400 * 9), now: now).isEmpty)
    }

    @Test func cacheRoundTripsFactsAndListing() {
        let cache = ImageGenLibraryCache(endpoint: ImageGenEndpoint(host: "test-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: cache.root) }
        let item = ImageGenLibraryItem(filename: "a.png", subfolder: "sub")
        #expect(cache.facts(item) == nil)
        let facts = ImageGenLibraryFacts(bytes: 5, width: 2, height: 3, recipe: ComfyRecipe(prompt: "x"))
        cache.store(facts, for: item)
        #expect(cache.facts(item) == facts)
        #expect(cache.listing() == nil)
        cache.store(listing: [item])
        #expect(cache.listing()?.items == [item])
        #expect(cache.thumbnailURL(item, format: .webp).lastPathComponent == "sub__a.png.webp")
    }

    @Test func sightingAnswersPerEngine() {
        let sighting = ImageGenSighting(
            host: "arch:8188", reachable: true,
            missingModels: ["diffusion_models/flux-2-klein-4b.safetensors"])
        #expect(sighting.available(.quality))
        #expect(!sighting.available(.fast))
        #expect(sighting.missing(for: .fast).map(\.name) == ["flux-2-klein-4b.safetensors"])
        #expect(ImageGenMachineWords.summary(sighting).contains("Quality"))
        #expect(ImageGenMachineWords.summary(nil) == ImageGenMachineWords.neverChecked)
        let full = ImageGenSighting(host: "arch:8188", reachable: true)
        #expect(ImageGenMachineWords.summary(full).contains("both"))
        var slot = ImageGenSlot(endpoint: ImageGenEndpoint(host: "arch"))
        slot.setEngine(.fast)
        #expect(slot.engineAvailable(given: sighting) == false)
        #expect(slot.engineAvailable(given: nil) == nil)
    }

    @Test func doorCheckHolds() {
        let failures = ImageGenDoorCheck.run()
        #expect(failures.isEmpty, "\(failures)")
    }
}
