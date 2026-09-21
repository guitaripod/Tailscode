import Foundation

/// Which transformer renders the video. The two on the box are the same 22B model twice — one
/// distilled to reach a picture in eight sampler steps, one not — and they are not interchangeable
/// in the one place it matters: how the first pass is driven. The distilled model runs a fixed
/// eight-sigma schedule at a guidance of one; the undistilled one needs LTX's own shifted
/// schedule, twenty steps of it, and real guidance against a negative prompt — driven on the
/// distilled recipe it decodes to fog. So the drive belongs to the model rather than to the
/// recipe, and picking a model picks the whole of it.
public enum ForgeModel: String, Sendable, Codable, Hashable, CaseIterable {
    case distilled
    case dev

    public var fileName: String {
        switch self {
        case .distilled: return "ltx-2.5-22b-distilled-transformer-bf16.safetensors"
        case .dev: return "ltx-2.5-22b-dev-transformer-bf16.safetensors"
        }
    }

    public static var family: String { "LTX-2.5" }

    public var label: String {
        switch self {
        case .distilled: return Localized.text("%@ Fast", Self.family)
        case .dev: return Localized.text("%@ Fine", Self.family)
        }
    }

    public var detail: String {
        switch self {
        case .distilled: return Localized.text("Eight steps, about twenty seconds a clip")
        case .dev: return Localized.text("Twenty guided steps, the avoid list counts, several times the wait")
        }
    }

    /// How the first pass is scheduled: the distilled model's eight measured sigmas, or LTX's own
    /// shifted scheduler for the undistilled one, as the reference graphs drive them.
    public enum Schedule: Sendable, Equatable {
        case fixed(String)
        case shifted(steps: Int, maxShift: Double, baseShift: Double, stretch: Bool, terminal: Double)
    }

    /// The measured schedule for the distilled model. The dev numbers are LTX's reference
    /// scheduler settings, verified on the box on 2026-09-22 against the fog the distilled
    /// schedule made of the same model.
    public var stageOneSchedule: Schedule {
        switch self {
        case .distilled:
            return .fixed("1.0, 0.99375, 0.9875, 0.98125, 0.975, 0.909375, 0.725, 0.421875, 0.0")
        case .dev:
            return .shifted(steps: 20, maxShift: 2.05, baseShift: 0.95, stretch: true, terminal: 0.1)
        }
    }

    /// The distilled model's first-pass sigmas as text, which is what the graph and the checks
    /// name; the dev model has none, its schedule being computed on the machine.
    public var stageOneSigmas: String {
        if case .fixed(let sigmas) = stageOneSchedule { return sigmas }
        return ""
    }

    public var stageTwoSigmas: String {
        switch self {
        case .distilled: return "0.85, 0.7250, 0.4219, 0.0"
        case .dev: return "0.909375, 0.725, 0.421875, 0.0"
        }
    }

    /// Guidance on the first pass. One for the distilled model, which was trained to need none;
    /// three for the undistilled one, which is where the negative prompt starts to mean anything.
    public var guidance: Double {
        switch self {
        case .distilled: return 1.0
        case .dev: return 3.0
        }
    }

    public var sampler: String {
        switch self {
        case .distilled: return "euler_ancestral"
        case .dev: return "euler"
        }
    }

    /// Whether the avoid list reaches the render. At a guidance of one a negative prompt changes
    /// nothing, so the distilled model ignores it and the surface says so.
    public var heedsNegative: Bool { guidance > 1 }

    /// What the undistilled model is told to avoid when nobody wrote anything: the failure modes
    /// guidance is there to steer away from.
    public static let defaultNegative = "blurry, distorted, low quality, jittery, watermark, text"
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

    /// The offered size whose shape is closest to a picture's, so a clip that starts from a
    /// photograph is not cropped to a frame the photograph never had.
    public static func nearest(width: Int, height: Int) -> ForgeSize {
        guard width > 0, height > 0 else { return landscape }
        let wanted = log(Double(width) / Double(height))
        return options.min {
            abs(log(Double($0.width) / Double($0.height)) - wanted)
                < abs(log(Double($1.width) / Double($1.height)) - wanted)
        } ?? landscape
    }

    /// The size a helper's answer points at. The helper speaks in picture ratios; a clip has
    /// three shapes, so anything wide is landscape, anything tall is portrait, and a square is
    /// a square.
    public static func following(_ aspect: ImageGenAspect) -> ForgeSize {
        switch aspect {
        case .square: return square
        case .landscape, .screen, .wide: return landscape
        case .portrait, .tall: return portrait
        }
    }

    public var name: String {
        switch self {
        case Self.landscape: return Localized.text("Landscape")
        case Self.portrait: return Localized.text("Portrait")
        case Self.square: return Localized.text("Square")
        case Self.small: return Localized.text("Small")
        default: return label
        }
    }
}

/// The picture a clip starts from, when it starts from one. Three places a first frame can come
/// from and three different things the graph has to do about each: a file on this device has to
/// be put on the machine first and is then named by whoever put it there; a picture the machine
/// already keeps is named in its own directory and no byte travels; and a clip already made is
/// opened on the machine and its last frame taken, which is how one clip continues into the next.
public enum ForgeFrame: Sendable, Codable, Hashable {
    case file(String)
    case kept(String)
    case clipEnd(ForgeAsset)

    /// The word the chip wears: the file's own name, or the clip it continues.
    public var label: String {
        switch self {
        case .file(let path): return (path as NSString).lastPathComponent
        case .kept(let name):
            let bare = name.replacingOccurrences(of: " [output]", with: "")
                .replacingOccurrences(of: " [input]", with: "")
            return (bare as NSString).lastPathComponent
        case .clipEnd(let asset): return asset.filename
        }
    }

    /// What starting from it means, for the row under the chip.
    public var detail: String {
        switch self {
        case .file, .kept: return Localized.text("The clip opens on this picture")
        case .clipEnd: return Localized.text("The clip opens where this one ended")
        }
    }

    public var isClipEnd: Bool {
        if case .clipEnd = self { return true }
        return false
    }

    /// Whether the picture is still on this device only. The graph cannot name it until the
    /// render has put it on the machine.
    public var needsUpload: Bool {
        if case .file = self { return true }
        return false
    }
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
    /// What is heard. LTX-2.5 renders a soundtrack with every clip whether or not anybody asked
    /// for one, so the sound is a thing to describe rather than a thing to switch on; it goes to
    /// the model as the last sentence of the prompt.
    public var sound: String
    /// The picture the clip opens on, or nil for a clip made from words alone.
    public var frame: ForgeFrame?
    public let width: Int
    public let height: Int
    public let seconds: Int
    public let fps: Int
    public var seed: Int
    public var model: ForgeModel

    public init(
        prompt: String = "", negative: String = "", sound: String = "", frame: ForgeFrame? = nil,
        width: Int = ForgeSize.landscape.width, height: Int = ForgeSize.landscape.height,
        seconds: Int = 5, fps: Int = 24, seed: Int = 0, model: ForgeModel = .distilled
    ) {
        self.prompt = prompt
        self.negative = negative
        self.sound = sound
        self.frame = frame
        self.width = ForgeRecipe.blocked(width)
        self.height = ForgeRecipe.blocked(height)
        self.seconds = min(max(seconds, ForgeRecipe.secondsRange.lowerBound), ForgeRecipe.secondsRange.upperBound)
        self.fps = ForgeRecipe.fpsOptions.contains(fps) ? fps : 24
        self.seed = max(0, seed)
        self.model = model
    }

    private enum CodingKeys: String, CodingKey {
        case prompt, negative, sound, frame, width, height, seconds, fps, seed, model
    }

    /// A recipe written before the sound and the first frame existed still reads.
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            prompt: try box.decodeIfPresent(String.self, forKey: .prompt) ?? "",
            negative: try box.decodeIfPresent(String.self, forKey: .negative) ?? "",
            sound: try box.decodeIfPresent(String.self, forKey: .sound) ?? "",
            frame: try box.decodeIfPresent(ForgeFrame.self, forKey: .frame),
            width: try box.decodeIfPresent(Int.self, forKey: .width) ?? ForgeSize.landscape.width,
            height: try box.decodeIfPresent(Int.self, forKey: .height) ?? ForgeSize.landscape.height,
            seconds: try box.decodeIfPresent(Int.self, forKey: .seconds) ?? 5,
            fps: try box.decodeIfPresent(Int.self, forKey: .fps) ?? 24,
            seed: try box.decodeIfPresent(Int.self, forKey: .seed) ?? 0,
            model: try box.decodeIfPresent(ForgeModel.self, forKey: .model) ?? .distilled)
    }

    /// The sentence the verified image-to-video graph opens its prompt with. The model is told
    /// in words as well as in latents that the picture is the first frame, so a description that
    /// starts mid-motion does not fight the conditioning.
    public static let openingLine = "Use the provided start image as the first frame."

    /// What the text encoder is actually given: the opening line when the clip starts from a
    /// picture, the words, then the sound as its own closing sentence. One reader so the graph,
    /// the tests and the helper's own instructions all mean the same paragraph.
    /// What the negative encoder is given: the person's avoid list, or — for the model that
    /// actually steers by it — the default one when the list is empty. The distilled model runs at
    /// a guidance of one, where nothing here matters, and is given the words as typed.
    public var renderedNegative: String {
        let words = negative.trimmingCharacters(in: .whitespacesAndNewlines)
        guard words.isEmpty, model.heedsNegative else { return words }
        return ForgeModel.defaultNegative
    }

    public var renderedPrompt: String {
        var parts: [String] = []
        if frame != nil { parts.append(Self.openingLine) }
        let words = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { parts.append(words) }
        let heard = sound.trimmingCharacters(in: .whitespacesAndNewlines)
        if !heard.isEmpty { parts.append(heard) }
        return parts.joined(separator: " ")
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
        let base = Localized.text(
            "%@ · %@s · %@fps · %@ · seed %@", size.label, "\(seconds)", "\(fps)",
            model.label.lowercased(), "\(seed)")
        guard let frame else { return base }
        return base + " · " + Localized.text("from %@", frame.label)
    }

    public func with(prompt: String) -> ForgeRecipe { copy(prompt: prompt) }

    public func with(negative: String) -> ForgeRecipe { copy(negative: negative) }

    public func with(sound: String) -> ForgeRecipe { copy(sound: sound) }

    public func with(frame: ForgeFrame?) -> ForgeRecipe { copy(frame: .some(frame)) }

    public func with(size: ForgeSize) -> ForgeRecipe { copy(width: size.width, height: size.height) }

    public func with(seconds: Int) -> ForgeRecipe { copy(seconds: seconds) }

    public func with(fps: Int) -> ForgeRecipe { copy(fps: fps) }

    public func with(model: ForgeModel) -> ForgeRecipe { copy(model: model) }

    public func with(seed: Int) -> ForgeRecipe { copy(seed: seed) }

    private func copy(
        prompt: String? = nil, negative: String? = nil, sound: String? = nil,
        frame: ForgeFrame?? = nil, width: Int? = nil, height: Int? = nil, seconds: Int? = nil,
        fps: Int? = nil, seed: Int? = nil, model: ForgeModel? = nil
    ) -> ForgeRecipe {
        ForgeRecipe(
            prompt: prompt ?? self.prompt, negative: negative ?? self.negative,
            sound: sound ?? self.sound, frame: frame ?? self.frame, width: width ?? self.width,
            height: height ?? self.height, seconds: seconds ?? self.seconds, fps: fps ?? self.fps,
            seed: seed ?? self.seed, model: model ?? self.model)
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
    case flag(Bool)
    case link(String, Int)

    var json: Any {
        switch self {
        case .text(let value): return value
        case .whole(let value): return value
        case .decimal(let value): return value
        case .flag(let value): return value
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
        "LTXVScheduler": 1,
        "VAEDecodeTiled": 1,
        "LTXVAudioVAEDecode": 1,
        "CreateVideo": 1,
        "SaveVideo": 0,
        "LoadImage": 2,
        "LoadVideo": 1,
        "GetVideoComponents": 5,
        "ImageFromBatch": 1,
        "LTXVPreprocess": 1,
        "LTXVImgToVideoInplace": 1,
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

    /// How strongly the first frame holds each pass, as the verified image-to-video graph sets
    /// them: the first pass is guided rather than pinned so the motion can begin, and the second
    /// pass, refining at full size, is pinned to the picture exactly.
    public static let firstPassHold = 0.7
    public static let secondPassHold = 1.0
    /// The compression the verified graph applies to a start picture before encoding it, so a
    /// clean render is not asked to continue a picture cleaner than anything it will make.
    public static let frameCompression = 18
    /// A frame index past any clip this app can make: `ImageFromBatch` clamps it to the last
    /// frame there is, which is the one frame the next clip needs.
    public static let lastFrameIndex = 16384

    public let recipe: ForgeRecipe
    public let nodes: [ForgeNode]
    /// The name the machine gave the start picture when it was put there. Nil for a recipe that
    /// starts from words or from a picture the machine already holds.
    public let uploadedFrame: String?

    public init(recipe: ForgeRecipe, prefix: String = ForgeGraph.prefix, uploadedFrame: String? = nil) {
        self.recipe = recipe
        self.uploadedFrame = uploadedFrame
        nodes = ForgeGraph.build(recipe: recipe, prefix: prefix, uploadedFrame: uploadedFrame)
    }

    /// A graph assembled from nodes handed in rather than built from a recipe. The checks need it:
    /// `problems` exists to catch a link that resolves to nothing, and a builder that cannot make
    /// that mistake cannot demonstrate that it would be caught.
    init(recipe: ForgeRecipe, nodes: [ForgeNode]) {
        self.recipe = recipe
        self.nodes = nodes
        uploadedFrame = nil
    }

    /// Whether the clip opens on a picture. The graph then carries the start nodes and both
    /// passes are held to the frame.
    public var startsFromFrame: Bool { node("start1") != nil }

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
        if recipe.frame?.needsUpload == true, uploadedFrame == nil {
            found.append(Localized.text("the start picture was never put on the machine"))
        }
        return found
    }

    private static func build(recipe: ForgeRecipe, prefix: String, uploadedFrame: String?) -> [ForgeNode] {
        let rate = Double(recipe.fps)
        let start = startNodes(recipe: recipe, uploadedFrame: uploadedFrame)
        let held = !start.isEmpty
        return start + [
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
                inputs: ["text": .text(recipe.renderedPrompt), "clip": .link("clip", 0)]),
            ForgeNode(
                key: "neg", classType: "CLIPTextEncode",
                inputs: ["text": .text(recipe.renderedNegative), "clip": .link("clip", 0)]),
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
                inputs: [
                    "video_latent": .link(held ? "start1" : "lat_v", 0),
                    "audio_latent": .link("lat_a", 0),
                ]),

            ForgeNode(
                key: "noise1", classType: "RandomNoise",
                inputs: ["noise_seed": .whole(recipe.seed)]),
            ForgeNode(
                key: "sampler", classType: "KSamplerSelect",
                inputs: ["sampler_name": .text(recipe.model.sampler)]),
            scheduleNode(recipe.model),
            ForgeNode(
                key: "guider1", classType: "LTXVDualCFGGuider",
                inputs: [
                    "model": .link("unet", 0), "positive": .link("cond", 0),
                    "negative": .link("cond", 1), "video_cfg": .decimal(recipe.model.guidance),
                    "audio_cfg": .decimal(recipe.model.guidance),
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
                inputs: [
                    "video_latent": .link(held ? "start2" : "up", 0),
                    "audio_latent": .link("split1", 1),
                ]),

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

    /// The first pass's sigmas: the distilled model's eight fixed ones, or LTX's own scheduler
    /// shifted against the latent's size for the undistilled one.
    private static func scheduleNode(_ model: ForgeModel) -> ForgeNode {
        switch model.stageOneSchedule {
        case .fixed(let sigmas):
            return ForgeNode(key: "sig1", classType: "ManualSigmas", inputs: ["sigmas": .text(sigmas)])
        case .shifted(let steps, let maxShift, let baseShift, let stretch, let terminal):
            return ForgeNode(
                key: "sig1", classType: "LTXVScheduler",
                inputs: [
                    "steps": .whole(steps), "max_shift": .decimal(maxShift),
                    "base_shift": .decimal(baseShift), "stretch": .flag(stretch),
                    "terminal": .decimal(terminal), "latent": .link("lat_v", 0),
                ])
        }
    }

    /// The nodes a clip that opens on a picture needs, as the verified image-to-video graph has
    /// them: the picture opened — a file the machine was handed, a picture it keeps, or the last
    /// frame of a clip it made — compressed the way the model expects, then written into the
    /// first frame of each pass's latent by `LTXVImgToVideoInplace`, which scales the picture to
    /// the latent's own size. Empty for a clip made from words alone.
    private static func startNodes(recipe: ForgeRecipe, uploadedFrame: String?) -> [ForgeNode] {
        guard let frame = recipe.frame else { return [] }
        var nodes: [ForgeNode] = []
        let picture: String
        switch frame {
        case .file:
            guard let uploadedFrame else { return [] }
            nodes.append(
                ForgeNode(key: "still", classType: "LoadImage", inputs: ["image": .text(uploadedFrame)]))
            picture = "still"
        case .kept(let name):
            nodes.append(ForgeNode(key: "still", classType: "LoadImage", inputs: ["image": .text(name)]))
            picture = "still"
        case .clipEnd(let asset):
            nodes.append(
                ForgeNode(key: "reel", classType: "LoadVideo", inputs: ["file": .text(asset.annotatedName)]))
            nodes.append(
                ForgeNode(key: "frames", classType: "GetVideoComponents", inputs: ["video": .link("reel", 0)]))
            nodes.append(
                ForgeNode(
                    key: "last", classType: "ImageFromBatch",
                    inputs: [
                        "image": .link("frames", 0), "batch_index": .whole(lastFrameIndex),
                        "length": .whole(1),
                    ]))
            picture = "last"
        }
        nodes.append(
            ForgeNode(
                key: "prep", classType: "LTXVPreprocess",
                inputs: ["image": .link(picture, 0), "img_compression": .whole(frameCompression)]))
        nodes.append(
            ForgeNode(
                key: "start1", classType: "LTXVImgToVideoInplace",
                inputs: [
                    "vae": .link("vae_v", 0), "image": .link("prep", 0), "latent": .link("lat_v", 0),
                    "strength": .decimal(firstPassHold), "bypass": .flag(false),
                ]))
        nodes.append(
            ForgeNode(
                key: "start2", classType: "LTXVImgToVideoInplace",
                inputs: [
                    "vae": .link("vae_v", 0), "image": .link("prep", 0), "latent": .link("up", 0),
                    "strength": .decimal(secondPassHold), "bypass": .flag(false),
                ]))
        return nodes
    }
}
