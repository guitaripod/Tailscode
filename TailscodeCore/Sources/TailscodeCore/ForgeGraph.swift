import Foundation

/// Which transformer renders the video. The two on the box are the same 22B model twice — one
/// distilled to reach a picture in eight sampler steps, one not — and they are not interchangeable
/// in the one place it matters: the noise schedule. A distilled model driven on a long schedule
/// wastes minutes; an undistilled one driven on the short schedule arrives half-formed. So the
/// schedule belongs to the model rather than to the recipe, and picking a model picks both.
public enum ForgeModel: String, Sendable, Codable, Hashable, CaseIterable {
    case distilled
    case dev

    public var fileName: String {
        switch self {
        case .distilled: return "ltx-2.5-22b-distilled-transformer-bf16.safetensors"
        case .dev: return "ltx-2.5-22b-dev-transformer-bf16.safetensors"
        }
    }

    public var label: String {
        switch self {
        case .distilled: return Localized.text("Fast")
        case .dev: return Localized.text("Fine")
        }
    }

    public var detail: String {
        switch self {
        case .distilled: return Localized.text("Eight steps, about twenty seconds a clip")
        case .dev: return Localized.text("Longer schedule, more detail, several times the wait")
        }
    }

    /// The measured schedule for the distilled model, and a longer one of the same shape for the
    /// model that is not distilled. The distilled numbers are the ones verified end to end on the
    /// box; the dev schedule keeps every one of them and subdivides between them, which is the
    /// conservative way to lengthen a curve nobody has re-measured.
    public var stageOneSigmas: String {
        switch self {
        case .distilled:
            return "1.0, 0.99375, 0.9875, 0.98125, 0.975, 0.909375, 0.725, 0.421875, 0.0"
        case .dev:
            return "1.0, 0.996875, 0.99375, 0.990625, 0.9875, 0.98125, 0.975, 0.95, 0.909375, "
                + "0.85, 0.725, 0.575, 0.421875, 0.25, 0.125, 0.0"
        }
    }

    public var stageTwoSigmas: String {
        switch self {
        case .distilled: return "0.85, 0.7250, 0.4219, 0.0"
        case .dev: return "0.85, 0.7875, 0.7250, 0.575, 0.4219, 0.2, 0.0"
        }
    }
}

/// A frame size the renderer will actually take, offered as a short list rather than two number
/// fields. Every one is a multiple of 32 in both directions because the latent grid is, and 1280
/// by 704 is the size the whole graph was verified at.
public struct ForgeSize: Sendable, Codable, Hashable, Identifiable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var id: String { "\(width)x\(height)" }
    public var label: String { "\(width)×\(height)" }

    public static let landscape = ForgeSize(width: 1280, height: 704)
    public static let portrait = ForgeSize(width: 704, height: 1280)
    public static let square = ForgeSize(width: 960, height: 960)
    public static let small = ForgeSize(width: 832, height: 480)

    public static let options: [ForgeSize] = [landscape, portrait, square, small]
}

/// Everything a person chose, and nothing about how it is rendered. A recipe is what gets stored
/// in history, restored into the next draft and shown under a finished clip, so it is a plain
/// value — and it normalises itself on the way in rather than trusting a caller, because the two
/// numbers the model cannot survive being wrong about are the frame size and the frame count.
public struct ForgeRecipe: Sendable, Codable, Hashable {
    /// The latent grid the model works on. A frame size that is not a multiple of this is not a
    /// preference the renderer argues with — it is a tensor that will not assemble.
    public static let block = 32
    public static let minimumSide = 256
    public static let maximumSide = 1920
    public static let secondsRange = 1...20
    public static let fpsOptions = [16, 24, 30]

    public var prompt: String
    public var negative: String
    public let width: Int
    public let height: Int
    public let seconds: Int
    public let fps: Int
    public var seed: Int
    public var model: ForgeModel

    public init(
        prompt: String = "", negative: String = "", width: Int = ForgeSize.landscape.width,
        height: Int = ForgeSize.landscape.height, seconds: Int = 5, fps: Int = 24, seed: Int = 0,
        model: ForgeModel = .distilled
    ) {
        self.prompt = prompt
        self.negative = negative
        self.width = ForgeRecipe.blocked(width)
        self.height = ForgeRecipe.blocked(height)
        self.seconds = min(max(seconds, ForgeRecipe.secondsRange.lowerBound), ForgeRecipe.secondsRange.upperBound)
        self.fps = ForgeRecipe.fpsOptions.contains(fps) ? fps : 24
        self.seed = max(0, seed)
        self.model = model
    }

    public var size: ForgeSize { ForgeSize(width: width, height: height) }

    /// The frame count the sampler is given. LTX counts the first frame as a keyframe rather than
    /// as one of the interval frames, so a five second clip at 24fps is 121 latent frames and not
    /// 120 — get this wrong and the render either refuses or comes back a frame short of its own
    /// audio.
    public var length: Int { seconds * fps + 1 }

    /// The first pass samples at half the asked-for size and the latent upsampler doubles it back,
    /// which is the whole reason two passes exist: the expensive pass runs on a quarter of the
    /// pixels. Half is derived here rather than stated in the graph so the two can never drift.
    public var stageOneWidth: Int { width / 2 }
    public var stageOneHeight: Int { height / 2 }

    public var isRenderable: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The line under a clip: what it is, how long, how smooth, on which model, from which seed.
    /// One sentence so three clients cannot each invent their own.
    public var summary: String {
        Localized.text(
            "%@ · %@s · %@fps · %@ · seed %@", size.label, "\(seconds)", "\(fps)",
            model.label.lowercased(), "\(seed)")
    }

    public func with(prompt: String) -> ForgeRecipe {
        ForgeRecipe(
            prompt: prompt, negative: negative, width: width, height: height, seconds: seconds,
            fps: fps, seed: seed, model: model)
    }

    public func with(negative: String) -> ForgeRecipe {
        ForgeRecipe(
            prompt: prompt, negative: negative, width: width, height: height, seconds: seconds,
            fps: fps, seed: seed, model: model)
    }

    public func with(size: ForgeSize) -> ForgeRecipe {
        ForgeRecipe(
            prompt: prompt, negative: negative, width: size.width, height: size.height,
            seconds: seconds, fps: fps, seed: seed, model: model)
    }

    public func with(seconds: Int) -> ForgeRecipe {
        ForgeRecipe(
            prompt: prompt, negative: negative, width: width, height: height, seconds: seconds,
            fps: fps, seed: seed, model: model)
    }

    public func with(fps: Int) -> ForgeRecipe {
        ForgeRecipe(
            prompt: prompt, negative: negative, width: width, height: height, seconds: seconds,
            fps: fps, seed: seed, model: model)
    }

    public func with(model: ForgeModel) -> ForgeRecipe {
        ForgeRecipe(
            prompt: prompt, negative: negative, width: width, height: height, seconds: seconds,
            fps: fps, seed: seed, model: model)
    }

    public func with(seed: Int) -> ForgeRecipe {
        ForgeRecipe(
            prompt: prompt, negative: negative, width: width, height: height, seconds: seconds,
            fps: fps, seed: seed, model: model)
    }

    /// A seed small enough to read out loud and retype. The point of showing a seed at all is that
    /// somebody can ask for the same clip again, which a sixty-four-bit number defeats. A re-roll
    /// is told what it is replacing, because a button that hands back the number that was already
    /// there reads as broken rather than as unlucky.
    public static func freshSeed(avoiding previous: Int? = nil) -> Int {
        let value = Int.random(in: 0..<seedCeiling)
        guard value == previous else { return value }
        return (value + 1) % seedCeiling
    }

    private static let seedCeiling = 1_000_000

    private static func blocked(_ side: Int) -> Int {
        let clamped = min(max(side, minimumSide), maximumSide)
        let rounded = Int((Double(clamped) / Double(block)).rounded()) * block
        return min(max(rounded, minimumSide), maximumSide)
    }
}

/// One value on one node's input. ComfyUI's API format admits exactly two kinds — a literal, or a
/// two-element array naming another node and which of its outputs to take — and keeping them apart
/// in the type is what lets the graph be checked before it is posted rather than after the server
/// refuses it.
public enum ForgeValue: Sendable, Equatable {
    case text(String)
    case whole(Int)
    case decimal(Double)
    case link(String, Int)

    var json: Any {
        switch self {
        case .text(let value): return value
        case .whole(let value): return value
        case .decimal(let value): return value
        case .link(let key, let slot): return [key, slot]
        }
    }
}

public struct ForgeNode: Sendable, Equatable, Identifiable {
    public let key: String
    public let classType: String
    public let inputs: [String: ForgeValue]

    public init(key: String, classType: String, inputs: [String: ForgeValue]) {
        self.key = key
        self.classType = classType
        self.inputs = inputs
    }

    public var id: String { key }

    public var links: [(field: String, key: String, slot: Int)] {
        inputs.compactMap { field, value in
            guard case .link(let key, let slot) = value else { return nil }
            return (field, key, slot)
        }
        .sorted { $0.field < $1.field }
    }

    var json: [String: Any] {
        ["class_type": classType, "inputs": inputs.mapValues(\.json)]
    }
}

/// How many outputs each node class has, which is the only thing a link can be wrong about that
/// the graph itself cannot show. Two classes here answer twice — the conditioning that carries a
/// positive and a negative, and the separator that hands back video and audio — and every link in
/// the graph that takes slot 1 takes it from one of those two.
enum ForgeClass {
    static let outputs: [String: Int] = [
        "UNETLoader": 1,
        "CLIPLoader": 1,
        "VAELoader": 1,
        "LatentUpscaleModelLoader": 1,
        "CLIPTextEncode": 1,
        "LTXVConditioning": 2,
        "EmptyLTXVLatentVideo": 1,
        "LTXVEmptyLatentAudio": 1,
        "LTXVConcatAVLatent": 1,
        "RandomNoise": 1,
        "KSamplerSelect": 1,
        "ManualSigmas": 1,
        "LTXVDualCFGGuider": 1,
        "SamplerCustomAdvanced": 2,
        "LTXVSeparateAVLatent": 2,
        "LTXVLatentUpsampler": 1,
        "VAEDecodeTiled": 1,
        "LTXVAudioVAEDecode": 1,
        "CreateVideo": 1,
        "SaveVideo": 0,
    ]
}

/// The graph posted to ComfyUI, built rather than templated. It is the one place in this app that
/// knows what LTX-2.5 needs — two sampler passes with an upsampler between them, a video latent
/// and an audio latent concatenated and separated around each pass, and a save node at the end —
/// and it is deliberately a value rather than a JSON blob so the invariants that break silently on
/// a server five hundred milliseconds away can be checked here in a microsecond.
public struct ForgeGraph: Sendable, Equatable {
    /// Where the box writes finished clips, relative to ComfyUI's own output directory. Every clip
    /// this app made lands in one place, which is what makes a history that survives the app.
    public static let prefix = "video/forge"
    public static let clipEncoder = "gemma4-12b-with-proj-ltx-2.5-bf16.safetensors"
    public static let videoVAE = "ltx-2.5-video-vae-bf16.safetensors"
    public static let audioVAE = "ltx-2.5-audio-vae-bf16.safetensors"
    public static let upscaler = "ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors"
    /// The second pass refines what the first pass already decided, so its noise is fixed: varying
    /// it would change the picture without changing the seed anybody was shown.
    public static let refinementSeed = 42
    public static let outputKey = "save"

    public let recipe: ForgeRecipe
    public let nodes: [ForgeNode]

    public init(recipe: ForgeRecipe, prefix: String = ForgeGraph.prefix) {
        self.recipe = recipe
        nodes = ForgeGraph.build(recipe: recipe, prefix: prefix)
    }

    /// A graph assembled from nodes handed in rather than built from a recipe. The checks need it:
    /// `problems` exists to catch a link that resolves to nothing, and a builder that cannot make
    /// that mistake cannot demonstrate that it would be caught.
    init(recipe: ForgeRecipe, nodes: [ForgeNode]) {
        self.recipe = recipe
        self.nodes = nodes
    }

    public func node(_ key: String) -> ForgeNode? { nodes.first { $0.key == key } }

    public var keys: [String] { nodes.map(\.key) }

    /// The body ComfyUI is posted. Untyped on purpose: it is a wire format, and everything worth
    /// asserting about it has already been asserted on the typed nodes above.
    public var payload: [String: Any] {
        var graph: [String: Any] = [:]
        for node in nodes { graph[node.key] = node.json }
        return graph
    }

    /// Everything wrong with this graph, in sentences. A graph that cannot be wrong is not worth
    /// checking; this one is assembled from a recipe a person typed, so it can be — and a dangling
    /// link posted to the server comes back as a validation error naming a node key nobody has
    /// ever seen. Empty means it is safe to post.
    public var problems: [String] {
        var found: [String] = []
        var seen = Set<String>()
        for node in nodes where !seen.insert(node.key).inserted {
            found.append(Localized.text("%@ is in the graph twice", node.key))
        }
        for node in nodes where ForgeClass.outputs[node.classType] == nil {
            found.append(Localized.text("%@ is not a node type this graph knows", node.classType))
        }
        for node in nodes {
            for link in node.links {
                guard let target = self.node(link.key) else {
                    found.append(
                        Localized.text("%@ takes %@ from %@, which is not in the graph", node.key,
                            link.field, link.key))
                    continue
                }
                let outputs = ForgeClass.outputs[target.classType] ?? 0
                if link.slot < 0 || link.slot >= outputs {
                    found.append(
                        Localized.text("%@ takes output %@ of %@, which has %@", node.key,
                            "\(link.slot)", link.key, "\(outputs)"))
                }
            }
        }
        if recipe.length != recipe.seconds * recipe.fps + 1 {
            found.append(Localized.text("the frame count does not match the duration"))
        }
        if recipe.width % ForgeRecipe.block != 0 || recipe.height % ForgeRecipe.block != 0 {
            found.append(Localized.text("the frame size is not a multiple of %@", "\(ForgeRecipe.block)"))
        }
        if node("lat_v")?.inputs["width"] != .whole(recipe.stageOneWidth) {
            found.append(Localized.text("the first pass is not sampling at half size"))
        }
        return found
    }

    private static func build(recipe: ForgeRecipe, prefix: String) -> [ForgeNode] {
        let rate = Double(recipe.fps)
        return [
            ForgeNode(
                key: "unet", classType: "UNETLoader",
                inputs: [
                    "unet_name": .text(recipe.model.fileName), "weight_dtype": .text("default"),
                ]),
            ForgeNode(
                key: "clip", classType: "CLIPLoader",
                inputs: [
                    "clip_name": .text(clipEncoder), "type": .text("ltxv"),
                    "device": .text("default"),
                ]),
            ForgeNode(key: "vae_v", classType: "VAELoader", inputs: ["vae_name": .text(videoVAE)]),
            ForgeNode(key: "vae_a", classType: "VAELoader", inputs: ["vae_name": .text(audioVAE)]),
            ForgeNode(
                key: "upscaler", classType: "LatentUpscaleModelLoader",
                inputs: ["model_name": .text(upscaler)]),

            ForgeNode(
                key: "pos", classType: "CLIPTextEncode",
                inputs: ["text": .text(recipe.prompt), "clip": .link("clip", 0)]),
            ForgeNode(
                key: "neg", classType: "CLIPTextEncode",
                inputs: ["text": .text(recipe.negative), "clip": .link("clip", 0)]),
            ForgeNode(
                key: "cond", classType: "LTXVConditioning",
                inputs: [
                    "positive": .link("pos", 0), "negative": .link("neg", 0),
                    "frame_rate": .decimal(rate),
                ]),

            ForgeNode(
                key: "lat_v", classType: "EmptyLTXVLatentVideo",
                inputs: [
                    "width": .whole(recipe.stageOneWidth), "height": .whole(recipe.stageOneHeight),
                    "length": .whole(recipe.length), "batch_size": .whole(1),
                ]),
            ForgeNode(
                key: "lat_a", classType: "LTXVEmptyLatentAudio",
                inputs: [
                    "frames_number": .whole(recipe.length), "frame_rate": .decimal(rate),
                    "batch_size": .whole(1), "audio_vae": .link("vae_a", 0),
                ]),
            ForgeNode(
                key: "av1", classType: "LTXVConcatAVLatent",
                inputs: ["video_latent": .link("lat_v", 0), "audio_latent": .link("lat_a", 0)]),

            ForgeNode(
                key: "noise1", classType: "RandomNoise",
                inputs: ["noise_seed": .whole(recipe.seed)]),
            ForgeNode(
                key: "sampler", classType: "KSamplerSelect",
                inputs: ["sampler_name": .text("euler_ancestral")]),
            ForgeNode(
                key: "sig1", classType: "ManualSigmas",
                inputs: ["sigmas": .text(recipe.model.stageOneSigmas)]),
            ForgeNode(
                key: "guider1", classType: "LTXVDualCFGGuider",
                inputs: [
                    "model": .link("unet", 0), "positive": .link("cond", 0),
                    "negative": .link("cond", 1), "video_cfg": .decimal(1.0),
                    "audio_cfg": .decimal(1.0),
                ]),
            ForgeNode(
                key: "pass1", classType: "SamplerCustomAdvanced",
                inputs: [
                    "noise": .link("noise1", 0), "guider": .link("guider1", 0),
                    "sampler": .link("sampler", 0), "sigmas": .link("sig1", 0),
                    "latent_image": .link("av1", 0),
                ]),
            ForgeNode(
                key: "split1", classType: "LTXVSeparateAVLatent",
                inputs: ["av_latent": .link("pass1", 0)]),

            ForgeNode(
                key: "up", classType: "LTXVLatentUpsampler",
                inputs: [
                    "samples": .link("split1", 0), "upscale_model": .link("upscaler", 0),
                    "vae": .link("vae_v", 0),
                ]),
            ForgeNode(
                key: "av2", classType: "LTXVConcatAVLatent",
                inputs: ["video_latent": .link("up", 0), "audio_latent": .link("split1", 1)]),

            ForgeNode(
                key: "noise2", classType: "RandomNoise",
                inputs: ["noise_seed": .whole(refinementSeed)]),
            ForgeNode(
                key: "sig2", classType: "ManualSigmas",
                inputs: ["sigmas": .text(recipe.model.stageTwoSigmas)]),
            ForgeNode(
                key: "guider2", classType: "LTXVDualCFGGuider",
                inputs: [
                    "model": .link("unet", 0), "positive": .link("cond", 0),
                    "negative": .link("cond", 1), "video_cfg": .decimal(1.0),
                    "audio_cfg": .decimal(1.0),
                ]),
            ForgeNode(
                key: "pass2", classType: "SamplerCustomAdvanced",
                inputs: [
                    "noise": .link("noise2", 0), "guider": .link("guider2", 0),
                    "sampler": .link("sampler", 0), "sigmas": .link("sig2", 0),
                    "latent_image": .link("av2", 0),
                ]),
            ForgeNode(
                key: "split2", classType: "LTXVSeparateAVLatent",
                inputs: ["av_latent": .link("pass2", 0)]),

            ForgeNode(
                key: "pixels", classType: "VAEDecodeTiled",
                inputs: [
                    "samples": .link("split2", 0), "vae": .link("vae_v", 0),
                    "tile_size": .whole(512), "overlap": .whole(64), "temporal_size": .whole(64),
                    "temporal_overlap": .whole(16),
                ]),
            ForgeNode(
                key: "audio", classType: "LTXVAudioVAEDecode",
                inputs: ["samples": .link("split2", 1), "audio_vae": .link("vae_a", 0)]),
            ForgeNode(
                key: "video", classType: "CreateVideo",
                inputs: [
                    "images": .link("pixels", 0), "audio": .link("audio", 0),
                    "fps": .decimal(rate), "bit_depth": .whole(8),
                ]),
            ForgeNode(
                key: outputKey, classType: "SaveVideo",
                inputs: [
                    "video": .link("video", 0), "filename_prefix": .text(prefix),
                    "format": .text("auto"), "codec": .text("auto"),
                ]),
        ]
    }
}
